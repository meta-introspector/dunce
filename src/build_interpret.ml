open Import
open Build.Repr

module Vspec = Build.Vspec

module Target = struct
  type t =
    | Normal of Path.t
    | Vfile : _ Vspec.t -> t

  let path = function
    | Normal p -> p
    | Vfile (Vspec.T (p, _)) -> p

  let paths ts =
    List.fold_left ts ~init:Path.Set.empty ~f:(fun acc t ->
      Path.Set.add acc (path t))
end

module Static_deps = struct
  type t =
    { rule_deps   : Path.Set.t
    ; action_deps : Path.Set.t
    }
end

type file_kind = Reg | Dir

let inspect_path file_tree path =
  match Path.drop_build_context path with
  | None ->
    if not (Path.exists path) then
      None
    else if Path.is_directory path then
      Some Dir
    else
      Some Reg
  | Some path ->
    match File_tree.find_dir file_tree path with
    | Some _ ->
      Some Dir
    | None ->
      if Path.is_root path then
        Some Dir
      else if File_tree.file_exists file_tree
                (Path.parent_exn path)
                (Path.basename path) then
        Some Reg
      else
        None

let no_targets_allowed () =
  Exn.code_error "No targets allowed under a [Build.lazy_no_targets] \
                  or [Build.if_file_exists]" []
[@@inline never]

let static_deps t ~all_targets ~file_tree =
  let rec loop : type a b. (a, b) t -> Static_deps.t -> bool -> Static_deps.t
    = fun t acc targets_allowed ->
    match t with
    | Arr _ -> acc
    | Targets _ -> if not targets_allowed then no_targets_allowed (); acc
    | Store_vfile _ -> if not targets_allowed then no_targets_allowed (); acc
    | Compose (a, b) -> loop a (loop b acc targets_allowed) targets_allowed
    | First t -> loop t acc targets_allowed
    | Second t -> loop t acc targets_allowed
    | Split (a, b) -> loop a (loop b acc targets_allowed) targets_allowed
    | Fanout (a, b) -> loop a (loop b acc targets_allowed) targets_allowed
    | Paths fns -> { acc with action_deps = Path.Set.union fns acc.action_deps }
    | Paths_for_rule fns ->
      { acc with rule_deps = Path.Set.union fns acc.rule_deps }
    | Paths_glob state -> begin
        match !state with
        | G_evaluated l ->
          { acc with action_deps = Path.Set.union acc.action_deps l }
        | G_unevaluated (loc, dir, re) ->
          let targets = all_targets ~dir in
          let result =
            Path.Set.filter targets ~f:(fun path ->
              Re.execp re (Path.basename path))
          in
          if Path.Set.is_empty result then begin
            match inspect_path file_tree dir with
            | None ->
              Loc.warn loc "Directory %s doesn't exist."
                (Path.to_string_maybe_quoted
                   (Path.drop_optional_build_context dir))
            | Some Reg ->
              Loc.warn loc "%s is not a directory."
                (Path.to_string_maybe_quoted
                   (Path.drop_optional_build_context dir))
            | Some Dir ->
              (* diml: we should probably warn in this case as well *)
              ()
          end;
          state := G_evaluated result;
          let action_deps = Path.Set.union result acc.action_deps in
          { acc with action_deps }
      end
    | If_file_exists (p, state) -> begin
        match !state with
        | Decided (_, t) -> loop t acc false
        | Undecided (then_, else_) ->
          let dir = Path.parent_exn p in
          let targets = all_targets ~dir in
          if Path.Set.mem targets p then begin
            state := Decided (true, then_);
            loop then_ acc false
          end else begin
            state := Decided (false, else_);
            loop else_ acc false
          end
      end
    | Dyn_paths t -> loop t acc targets_allowed
    | Vpath (Vspec.T (p, _)) ->
      { acc with rule_deps = Path.Set.add acc.rule_deps p }
    | Contents p -> { acc with rule_deps = Path.Set.add acc.rule_deps p }
    | Lines_of p -> { acc with rule_deps = Path.Set.add acc.rule_deps p }
    | Record_lib_deps _ -> acc
    | Fail _ -> acc
    | Memo m -> loop m.t acc targets_allowed
    | Catch (t, _) -> loop t acc targets_allowed
    | Lazy_no_targets t -> loop (Lazy.force t) acc false
  in
  loop (Build.repr t)
    { rule_deps = Path.Set.empty
    ; action_deps = Path.Set.empty
    }
    true

let lib_deps =
  let rec loop : type a b. (a, b) t -> Lib_deps_info.t -> Lib_deps_info.t
    = fun t acc ->
      match t with
      | Arr _ -> acc
      | Targets _ -> acc
      | Store_vfile _ -> acc
      | Compose (a, b) -> loop a (loop b acc)
      | First t -> loop t acc
      | Second t -> loop t acc
      | Split (a, b) -> loop a (loop b acc)
      | Fanout (a, b) -> loop a (loop b acc)
      | Paths _ -> acc
      | Paths_for_rule _ -> acc
      | Vpath _ -> acc
      | Paths_glob _ -> acc
      | Dyn_paths t -> loop t acc
      | Contents _ -> acc
      | Lines_of _ -> acc
      | Record_lib_deps deps -> Lib_deps_info.merge deps acc
      | Fail _ -> acc
      | If_file_exists (_, state) ->
        loop (get_if_file_exists_exn state) acc
      | Memo m -> loop m.t acc
      | Catch (t, _) -> loop t acc
      | Lazy_no_targets t -> loop (Lazy.force t) acc
  in
  fun t -> loop (Build.repr t) String.Map.empty

let targets =
  let rec loop : type a b. (a, b) t -> Target.t list -> Target.t list = fun t acc ->
    match t with
    | Arr _ -> acc
    | Targets targets ->
      List.fold_left targets ~init:acc ~f:(fun acc fn -> Target.Normal fn :: acc)
    | Store_vfile spec -> Vfile spec :: acc
    | Compose (a, b) -> loop a (loop b acc)
    | First t -> loop t acc
    | Second t -> loop t acc
    | Split (a, b) -> loop a (loop b acc)
    | Fanout (a, b) -> loop a (loop b acc)
    | Paths _ -> acc
    | Paths_for_rule _ -> acc
    | Vpath _ -> acc
    | Paths_glob _ -> acc
    | Dyn_paths t -> loop t acc
    | Contents _ -> acc
    | Lines_of _ -> acc
    | Record_lib_deps _ -> acc
    | Fail _ -> acc
    | If_file_exists (_, state) -> begin
        match !state with
        | Decided (v, _) ->
          Exn.code_error "Build_interpret.targets got decided if_file_exists"
            ["exists", Sexp.To_sexp.bool v]
        | Undecided (a, b) ->
          match loop a [], loop b [] with
          | [], [] -> acc
          | a, b ->
            let targets x = Path.Set.sexp_of_t (Target.paths x) in
            Exn.code_error "Build_interpret.targets: cannot have targets \
                            under a [if_file_exists]"
              [ "targets-a", targets a
              ; "targets-b", targets b
              ]
      end
    | Memo m -> loop m.t acc
    | Catch (t, _) -> loop t acc
    | Lazy_no_targets _ -> acc
  in
  fun t -> loop (Build.repr t) []

module Rule = struct
  type t =
    { context  : Context.t option
    ; build    : (unit, Action.t) Build.t
    ; targets  : Target.t list
    ; sandbox  : bool
    ; mode     : Dune_file.Rule.Mode.t
    ; locks    : Path.t list
    ; loc      : Loc.t option
    ; dir      : Path.t
    }

  let make ?(sandbox=false) ?(mode=Dune_file.Rule.Mode.Not_a_rule_stanza)
        ~context ?(locks=[]) ?loc build =
    let targets = targets build in
    let dir =
      match targets with
      | [] ->
        begin match loc with
        | Some loc -> Loc.fail loc "Rule has no targets specified"
        | None -> Exn.code_error "Build_interpret.Rule.make: no targets" []
        end
      | x :: l ->
        let dir = Path.parent_exn (Target.path x) in
        List.iter l ~f:(fun target ->
          let path = Target.path target in
          if Path.parent_exn path <> dir then
            match loc with
            | None ->
              Exn.code_error "rule has targets in different directories"
                [ "targets", Sexp.To_sexp.list Path.sexp_of_t
                               (List.map targets ~f:Target.path)
                ]
            | Some loc ->
              Loc.fail loc
                "Rule has targets in different directories.\nTargets:\n%s"
                (String.concat ~sep:"\n"
                   (List.map targets ~f:(fun t ->
                      sprintf "- %s"
                        (Target.path t |> Path.to_string_maybe_quoted)))));
        dir
    in
    { context
    ; build
    ; targets
    ; sandbox
    ; mode
    ; locks
    ; loc
    ; dir
    }
end
