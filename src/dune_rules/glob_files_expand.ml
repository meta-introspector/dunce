open! Import

(* Returns a list containing all descendant directories of the directory whose
   path is the concatenation of [relative_dir] onto [base_dir]. E.g., if
   [base_dir] is "foo/bar" and [relative_dir] is "baz/qux", then this function
   will return the list containing all descendants of the directory
   "foo/bar/baz/qux". The descendants of a directory are that directory's
   subdirectories, and each of of their subdirectories, and so on ad infinitum. *)
let get_descendants_of_relative_dir_relative_to_base_dir_local ~base_dir ~relative_dir =
  let base_dir = Path.Build.drop_build_context_exn base_dir in
  let rec get_descendants_rec relative_dir =
    let absolute_dir = Path.Source.relative base_dir relative_dir in
    let open Memo.O in
    let* children =
      Source_tree.find_dir absolute_dir
      >>| function
      | None -> []
      | Some dir -> Source_tree.Dir.sub_dirs dir |> String.Map.keys
    in
    let+ rest =
      Memo.List.concat_map children ~f:(fun child ->
        get_descendants_rec (Filename.concat relative_dir child))
    in
    relative_dir :: rest
  in
  get_descendants_rec relative_dir
;;

(* Takes a path to a directory [new_dir] and a path to a file [old_path] and
   returns the path to a file of the same name as that of [old_path],
   contained in the directory [new_dir]. *)
let replace_path_dir new_dir old_path =
  let basename = Path.basename old_path in
  match new_dir with
  | `External e -> Path.Outside_build_dir.External (Path.External.relative e basename)
  | `Relative r ->
    Path.Outside_build_dir.In_source_dir
      (Path.Source.of_string (Filename.concat r basename))
;;

let split_glob_string_into_parent_and_pattern glob_string =
  (* Extract the component of the string after the last path separator. This
     will be the entire string if it contains no path separators. *)
  let pattern_str = Filename.basename glob_string in
  (* Remove the pattern from the end of the string. This is done directly with
     string manipulation rather than [Filename.dirname] so that the result can
     be used to reconstruct strings representing paths to files matched by the
     glob in the style of the original glob. For example, the globs "*" and
     "./*" will match the same files, but we want the results of the latter to
     include the "./" prefix, but not the former. *)
  let parent_str =
    match String.drop_suffix glob_string ~suffix:pattern_str with
    | Some x -> x
    | None ->
      Code_error.raise
        (sprintf
           "Filename.basename did not return a suffix of the string \"%s\""
           glob_string)
        []
  in
  parent_str, pattern_str
;;

module Glob_dir = struct
  (* The directory component of a glob. Globs can either be relative to some
     base dir (typically the directory containing the dune file which contains
     the glob) or absolute. *)
  type t =
    | Absolute of Path.External.t
    | Relative of
        { relative_dir : string
        ; base_dir : Path.Build.t
        }

  let to_dyn = function
    | Absolute external_path ->
      Dyn.variant "Absolute" [ Path.External.to_dyn external_path ]
    | Relative { relative_dir; base_dir } ->
      Dyn.variant "Relative" [ Dyn.string relative_dir; Path.Build.to_dyn base_dir ]
  ;;
end

module Without_vars = struct
  (* A glob whose [String_with_vars.t] has been expanded. A [Glob.t] is a
     wildcard for matching filenames only, not entire paths. The [dir] field
     holds the directory component of the original glob. E.g., for the glob
     "foo/bar/*.txt", [dir] would be "foo/bar". *)
  type t =
    { glob : Glob.t
    ; dir : Glob_dir.t
    ; recursive : bool
    }

  (* Returns a list of pairs (file_selector, relative_path), which correspond
     to each directory that will be searched for files matching the glob. If the
     glob is not recursive, this list will be of length 1. The returned file
     selectors will expand globs relative to [base_dir], and the corresponding
     relative paths are the paths to each directory relative to [base_dir]. The
     relative paths are required to construct relative paths to the files found
     by expanding the glob. *)
  let file_selectors_with_relative_dirs { glob; dir; recursive } ~loc =
    match (dir : Glob_dir.t) with
    | Relative { relative_dir; base_dir } ->
      let make_file_selector relative_dir =
        let dir = Path.Build.relative base_dir relative_dir in
        File_selector.of_glob ~dir:(Path.build dir) glob
      in
      if recursive
      then
        get_descendants_of_relative_dir_relative_to_base_dir_local ~base_dir ~relative_dir
        |> Memo.map
             ~f:
               (List.map ~f:(fun relative_dir ->
                  make_file_selector relative_dir, `Relative relative_dir))
      else Memo.return [ make_file_selector relative_dir, `Relative relative_dir ]
    | Absolute dir ->
      if recursive
      then
        User_error.raise
          ~loc
          [ Pp.textf "Absolute paths in recursive globs are not supported." ]
      else
        Memo.return
          [ File_selector.of_glob ~dir:(Path.external_ dir) glob, `External dir ]
  ;;
end

module Expanded = struct
  type t =
    { matches : Path.Outside_build_dir.t list
    ; dir : Glob_dir.t
    }

  let to_dyn { matches; dir } =
    Dyn.record
      [ "matches", Dyn.list Path.Outside_build_dir.to_dyn matches
      ; "dir", Glob_dir.to_dyn dir
      ]
  ;;

  let matches { matches; _ } = matches

  let prefix { dir; _ } =
    match dir with
    | Glob_dir.Absolute path -> `External path
    | Relative { relative_dir; _ } -> `Relative relative_dir
  ;;
end

module Expand
    (M : Memo.S)
    (C : sig
       val collect_files : loc:Loc.t -> File_selector.t -> Path.Set.t M.t
     end) =
struct
  let expand_vars { Dep_conf.Glob_files.glob; recursive } ~f ~base_dir =
    let open M.O in
    let loc = String_with_vars.loc glob in
    let+ glob_str = f glob in
    let parent_str, pattern_str = split_glob_string_into_parent_and_pattern glob_str in
    let glob = Glob.of_string_exn loc pattern_str in
    let dir : Glob_dir.t =
      if Filename.is_relative parent_str
      then Relative { relative_dir = parent_str; base_dir }
      else Absolute (Path.External.of_string parent_str)
    in
    { Without_vars.glob; dir; recursive }
  ;;

  let expand (t : Dep_conf.Glob_files.t) ~f ~base_dir =
    let open M.O in
    let loc = String_with_vars.loc t.glob in
    let* without_vars = expand_vars t ~f ~base_dir in
    let+ matches =
      Without_vars.file_selectors_with_relative_dirs without_vars ~loc
      |> M.of_memo
      >>= M.List.concat_map ~f:(fun (file_selector, dir) ->
        C.collect_files ~loc file_selector
        >>| Path.Set.to_list_map ~f:(replace_path_dir dir))
      >>| List.sort ~compare:Path.Outside_build_dir.compare
    in
    { Expanded.matches; dir = without_vars.dir }
  ;;
end

let action_builder =
  let module Action_builder =
    Expand
      (Action_builder)
      (struct
        let collect_files = Action_builder.paths_matching
      end)
  in
  Action_builder.expand
;;

let memo =
  let module Memo =
    Expand
      (Memo)
      (struct
        let collect_files ~loc:_ = Build_system.eval_pred
      end)
  in
  Memo.expand
;;
