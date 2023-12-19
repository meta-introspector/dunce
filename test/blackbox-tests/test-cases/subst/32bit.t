When dune subst is called on a file larger than 16MiB, it should not crash.
See #9538.

  $ git init
  Initialized empty Git repository in $TESTCASE_ROOT/.git/

  $ cat > create.ml << EOF
  > let () = Unix.truncate "large.dat" 0x1_00_00_00
  > EOF
  $ touch large.dat
  $ ocaml unix.cma create.ml
  $ rm create.ml

  $ git add large.dat

  $ cat > dune-project << EOF
  > (lang dune 1.0)
  > (name project)
  > (package
  >  (name project))
  > EOF

  $ git add dune-project

  $ git commit -m create | tail -n 3
   2 files changed, 4 insertions(+)
   create mode 100644 dune-project
   create mode 100644 large.dat

  $ dune subst 2>&1 | head -n 6
  Error: exception Invalid_argument("Bytes.create")
  Raised by primitive operation at Stdune__Io.Make.eagerly_input_string in file
    "otherlibs/stdune/src/io.ml", line 273, characters 14-30
  Called from Stdune__Io.Make.read_all.(fun) in file
    "otherlibs/stdune/src/io.ml", line 308, characters 16-40
  Called from Stdune__Exn.protectx in file "otherlibs/stdune/src/exn.ml", line
