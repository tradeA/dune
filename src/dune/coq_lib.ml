(* This file is licensed under The MIT License *)
(* (c) MINES ParisTech 2018-2019               *)
(* Written by: Emilio Jesús Gallego Arias *)

open! Stdune

(* At some point we may want to reify this into resolved status, for example:

   ; libraries : Lib.t list Or_exn.t

   etc.. *)
type t =
  { name : Loc.t * Coq_lib_name.t
  ; wrapper : string
  ; src_root : Path.Build.t
  ; obj_root : Path.Build.t
  ; theories : (Loc.t * Coq_lib_name.t) list
  ; libraries : (Loc.t * Lib_name.t) list
  ; package : Package.t option
  }

let name l = snd l.name

let location l = fst l.name

let wrapper l = l.wrapper

let src_root l = l.src_root

let obj_root l = l.obj_root

let libraries l = l.libraries

let package l = l.package

module Error = struct
  let make ?loc ?hints paragraphs =
    Error (User_error.E (User_error.make ?loc ?hints paragraphs))

  let duplicate_theory_name theory =
    let loc, name = theory.Dune_file.Coq.name in
    let name = Coq_lib_name.to_string name in
    make ~loc [ Pp.textf "Duplicate theory name: %s" name ]

  let theory_not_found ~loc name =
    let name = Coq_lib_name.to_string name in
    make ~loc [ Pp.textf "Theory %s not found" name ]

  let private_deps_not_allowed ~loc private_dep =
    let name = Coq_lib_name.to_string (name private_dep) in
    make ~loc
      [ Pp.textf
          "Theory %S is private, it cannot be a dependency of a public theory. \
           You need to associate %S to a package."
          name name
      ]

  let duplicate_boot_lib ~loc boot_theory =
    let name = Coq_lib_name.to_string (snd boot_theory.Dune_file.Coq.name) in
    make ~loc [ Pp.textf "Cannot have more than one boot library: %s)" name ]

  let cycle_found ~loc cycle =
    make ~loc
      [ Pp.textf "Cycle found"
      ; Pp.enumerate cycle ~f:(fun t ->
            Pp.text (Coq_lib_name.to_string (snd t.name)))
      ]
end

module DB = struct
  type lib = t

  type nonrec t =
    { boot : (Loc.t * t) option
    ; libs : t Coq_lib_name.Map.t
    }

  let boot_library { boot; _ } = boot

  let create_from_stanza ((dir, s) : Path.Build.t * Dune_file.Coq.t) =
    let name = snd s.name in
    ( name
    , { name = s.name
      ; wrapper = Coq_lib_name.wrapper name
      ; obj_root = dir
      ; src_root = dir
      ; theories = s.theories
      ; libraries = s.libraries
      ; package = s.package
      } )

  (* Should we register errors and printers, or raise is OK? *)
  let create_from_coqlib_stanzas sl =
    let libs =
      match Coq_lib_name.Map.of_list_map ~f:create_from_stanza sl with
      | Ok m -> m
      | Error (_name, _w1, (_, w2)) ->
        Result.ok_exn (Error.duplicate_theory_name w2)
    in
    let boot =
      match List.find_all ~f:(fun (_, s) -> s.Dune_file.Coq.boot) sl with
      | [] -> None
      | [ l ] -> Some ((snd l).loc, snd (create_from_stanza l))
      | _ :: (_, s2) :: _ ->
        Result.ok_exn (Error.duplicate_boot_lib ~loc:s2.loc s2)
    in
    { boot; libs }

  let resolve ?(allow_private_deps = true) db (loc, name) =
    match Coq_lib_name.Map.find db.libs name with
    | Some s ->
      if (not allow_private_deps) && Option.is_none s.package then
        Error.private_deps_not_allowed ~loc s
      else
        Ok s
    | None -> Error.theory_not_found ~loc name

  let find_many t ~loc = Result.List.map ~f:(fun name -> resolve t (loc, name))

  module Coq_lib_closure = Top_closure.Make (String.Set) (Or_exn)

  let requires db t : lib list Or_exn.t =
    let theories =
      match db.boot with
      | None -> t.theories
      (* XXX: Note that this means that we will prefix Coq with -Q, not sure we
         want to do that (yet), but seems like good practice. *)
      | Some (loc, stdlib) -> (loc, snd stdlib.name) :: t.theories
    in
    let open Result.O in
    let allow_private_deps = Option.is_none t.package in
    let* theories =
      Result.List.map ~f:(resolve ~allow_private_deps db) theories
    in
    let key t = Coq_lib_name.to_string (snd t.name) in
    let deps t =
      Result.List.map ~f:(resolve ~allow_private_deps db) t.theories
    in
    Result.bind (Coq_lib_closure.top_closure theories ~key ~deps) ~f:(function
      | Ok libs -> Ok libs
      | Error cycle -> Error.cycle_found ~loc:(location t) cycle)

  let resolve db l = resolve db l
end
