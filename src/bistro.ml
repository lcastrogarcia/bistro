open Core.Std

type 'a path = Path of string

type env = {
  sh : 'a. ('a,unit,string,unit) format4 -> 'a ;
  stdout : out_channel ;
  stderr : out_channel ;
  debug : 'a. ('a,unit,string,unit) format4 -> 'a ;
  info  : 'a. ('a,unit,string,unit) format4 -> 'a ;
  error : 'a. ('a,unit,string,unit) format4 -> 'a ;
  with_temp_file : 'a. (string -> 'a) -> 'a ;
  np : int ;
  mem : int ; (** in MB *)
}

type primitive_info = {
  id : string ;
  version : int option ;
  np : int ;
  mem : int ;
}

type _ workflow =
  | Value_workflow : string * (env -> 'a) term -> 'a workflow
  | Path_workflow : string * (env -> string -> unit) term -> 'a path workflow
  | Extract : string * [`directory of 'a] path workflow * string list -> 'b path workflow

and _ term =
  | Prim : primitive_info * 'a -> 'a term
  | App : ('a -> 'b) term * 'a term * string option -> 'b term
  | String : string -> string term
  | Int : int -> int term
  | Bool : bool -> bool term
  | Workflow : 'a workflow -> 'a term
  | Option : 'a term option -> 'a option term
  | List : 'a term list -> 'a list term

let primitive_info id ?version ?(np = 1) ?(mem = 100) () = {
  id ; version ; np ; mem ;
}

module Term = struct
  type 'a t = 'a term

  let prim id ?version ?np ?mem x =
    Prim (primitive_info id ?version ?np ?mem (), x)

  let app ?n f x = App (f, x, n)

  let ( $ ) f x = app f x

  let arg ?n conv x f = app ?n f (conv x)

  let string s = String s
  let int i = Int i
  let bool b = Bool b
  let option f x = Option (Option.map x ~f)
  let list f xs = List (List.map xs ~f)
  let workflow w = Workflow w
end


let digest x =
  Digest.to_hex (Digest.string (Marshal.to_string x []))

module Description = struct
  type workflow =
    | Value_workflow of term
    | Path_workflow of term
    | Extract of workflow * string list
  and term =
    | Prim of primitive_info
    | App of term * term * string option
    | String of string
    | Int of int
    | Bool of bool
    | Workflow of workflow
    | Option of term option
    | List of term list
end


let rec term_description : type s. s term -> Description.term = function
  | Prim (info, _) -> Description.Prim info

  | App (f, x, lab) ->
    Description.App (term_description f,
                     term_description x,
                     lab)

  | String s -> Description.String s
  | Int i -> Description.Int i
  | Bool b -> Description.Bool b
  | Workflow w -> Description.Workflow (workflow_description w)
  | Option o -> Description.Option (Option.map o ~f:term_description)
  | List l -> Description.List (List.map l ~f:term_description)

and workflow_description : type s. s workflow -> Description.workflow = function
  | Value_workflow (_, t) -> Description.Value_workflow (term_description t)
  | Path_workflow (_, t) -> Description.Path_workflow (term_description t)
  | Extract (_, dir, path) -> Description.Extract (workflow_description dir, path)

let workflow t = Value_workflow (digest (term_description t, `value), t)
let path_workflow t = Path_workflow (digest (term_description t, `path), t)

let rec extract : type s. [`directory of s] path workflow -> string list -> 'a workflow = fun dir path ->
  match dir with
  | Extract (_, dir', path') -> extract dir' (path' @ path)
  | Path_workflow _ -> Extract (digest (workflow_description dir), dir , path)
  | Value_workflow _ -> assert false (* unreachable case, due to typing constraints *)

let id : type s. s workflow -> string = function
  | Value_workflow (id, _) -> id
  | Path_workflow (id, _) -> id
  | Extract (id, _, _) -> id






module Db = struct

  type t = string

  let cache_dir base = Filename.concat base "cache"
  let build_dir base = Filename.concat base "build"
  let tmp_dir base = Filename.concat base "tmp"
  let stderr_dir base = Filename.concat base "stderr"
  let stdout_dir base = Filename.concat base "stdout"
  let log_dir base = Filename.concat base "logs"
  let history_dir base = Filename.concat base "history"

  let well_formed_db path =
    if Sys.file_exists_exn path then (
      Sys.file_exists_exn (cache_dir path)
      && Sys.file_exists_exn (build_dir path)
      && Sys.file_exists_exn (tmp_dir path)
      && Sys.file_exists_exn (stderr_dir path)
      && Sys.file_exists_exn (stdout_dir path)
      && Sys.file_exists_exn (log_dir path)
      && Sys.file_exists_exn (history_dir path)
    )
    else false

  let init base =
    if Sys.file_exists_exn base
    then (
      if not (well_formed_db base)
      then invalid_argf "Bistro_db.init: the path %s is not available for a bistro database" base ()
    )
    else (
      Unix.mkdir_p (tmp_dir base) ;
      Unix.mkdir_p (build_dir base) ;
      Unix.mkdir_p (cache_dir base) ;
      Unix.mkdir_p (stderr_dir base) ;
      Unix.mkdir_p (stdout_dir base) ;
      Unix.mkdir_p (log_dir base) ;
      Unix.mkdir_p (history_dir base)
    ) ;
    base

  let aux_path f db w =
    Filename.concat (f db) (id w)

  let log_path db w = aux_path log_dir db w
  let build_path db w = aux_path build_dir db w
  let tmp_path db w = aux_path tmp_dir db w
  let stdout_path db w = aux_path stdout_dir db w
  let stderr_path db w = aux_path stderr_dir db w
  let history_path db w = aux_path history_dir db w

  let rec cache_path : type s. t -> s workflow -> string = fun db -> function
    | Extract (_, dir, p) ->
      List.fold (cache_path db dir :: p) ~init:"" ~f:Filename.concat
    | _ as w -> aux_path cache_dir db w


  let used_tag = "U"
  let created_tag = "C"

  let history_tag_of_string x =
    if x = used_tag then `used
    else if x = created_tag then `created
    else invalid_argf "Bistro.Db.history_tag_of_string: %s" x ()

  let append_history ~db ~msg u =
    Out_channel.with_file ~append:true (history_path db u) ~f:(fun oc ->
        let time_stamp = Time.to_string_fix_proto `Local (Time.now ()) in
        fprintf oc "%s: %s\n" time_stamp msg
      )

  let rec used : type s. t -> s workflow -> unit = fun db -> function
      | Extract (_, u, _) -> used db u
      | _ as w -> append_history ~db ~msg:used_tag w

  let created : type s. t -> s workflow -> unit = fun db -> function
      | Extract _ -> assert false
      | _ as u -> append_history ~db ~msg:created_tag u

  let parse_history_line l =
    let stamp, tag = String.lsplit2_exn l ~on:':' in
    Time.of_string_fix_proto `Local stamp,
    history_tag_of_string (String.lstrip tag)

  let rec history : type s. t -> s workflow -> (Core.Time.t * [`created | `used]) list = fun db -> function
      | Extract (_, dir, _) -> history db dir
      | _ as u ->
        let p_u = history_path db u in
        if Sys.file_exists_exn p_u then
          List.map (In_channel.read_lines p_u) ~f:parse_history_line
        else
          []

  let echo ~path msg =
    Out_channel.with_file ~append:true path ~f:(fun oc ->
        output_string oc msg ;
        output_string oc "\n"
      )

  let log db fmt =
    let f msg =
      let path =
        Filename.concat
          (log_dir db)
          (Time.format (Time.now ()) "%Y-%m-%d.log")
      in
      echo ~path msg
    in
    Printf.ksprintf f fmt
end

(* type 'a iterator = { f : 'b. 'a -> 'b workflow -> 'a } *)

(* let rec fold_deps_in_term : type s. s term -> init:'a -> it:'a iterator -> 'a = fun t ~init ~it -> *)
(*   match t with *)
(*   | String _ -> init *)
(*   | Int _ -> init *)
(*   | Bool _ -> init *)
(*   | Option None -> init *)
(*   | Prim _ -> init *)
(*   | App (f, x, _) -> *)
(*     let init = fold_deps_in_term f ~init ~it in *)
(*     fold_deps_in_term x ~init ~it *)
(*   | Value_workflow w -> it.f init w *)
(*   | Option (Some t) -> *)
(*     fold_deps_in_term t ~init ~it *)
(*   | List ts -> *)
(*     List.fold ts ~init ~f:(fun accu t -> fold_deps_in_term t ~init:accu ~it) *)

(* let rec fold_deps : type s. s workflow -> init:'a -> it:'a iterator -> 'a = fun w ~init ~it -> *)
(*   match w with *)
(*   | Value_workflow t -> fold_deps_in_term t ~init ~it *)
(*   | File t -> fold_deps_in_term t ~init ~it *)
(*   | Directory t -> fold_deps_in_term t ~init ~it *)
(*   | Extract (dir, path) -> fold_deps dir ~init ~it *)

let load_value fn =
  In_channel.with_file fn ~f:(fun ic ->
      Marshal.from_channel ic
    )

let remove_if_exists fn =
  if Sys.file_exists_exn fn
  then Sys.command (sprintf "rm -r %s" fn) |> ignore

module type Configuration = sig
  val db_path : string
  val np : int
  val mem : int
end

module Engine(Conf : Configuration) = struct
  open Lwt

  let db = Db.init Conf.db_path

  let rec send_task t = assert false

  let create_task x f =
    let stdout_path = Db.stdout_path db x in
    let stderr_path = Db.stderr_path db x in
    let tmp_path    = Db.tmp_path    db x in
    let build_path  = Db.build_path  db x in
    let cache_path  = Db.cache_path  db x in
    fun env ->
      remove_if_exists stdout_path ;
      remove_if_exists stderr_path ;
      remove_if_exists build_path  ;
      remove_if_exists tmp_path    ;
      Unix.mkdir tmp_path ;
      let outcome = try f env ; `Ok with exn -> `Error exn in
      match outcome, Sys.file_exists_exn build_path with
      | `Ok, true ->
        remove_if_exists tmp_path ;
        Unix.rename build_path cache_path ;
        `Ok
      | `Ok, false ->
        let msg = sprintf "Workflow %s failed to produce its target at the prescribed location" (id x) in
        `Error msg
      | `Error (Failure msg), _ ->
        let msg = sprintf "Workflow %s failed saying: %s" (id x) msg in
        `Error msg
      | `Error _, __ ->
        let msg = sprintf "Workflow %s failed with an exception." (id x) in
        `Error msg

  module Building_workflow = struct
    type t = Cons : _ workflow * unit Lwt.t -> t
    let equal (Cons (x, _)) (Cons (y, _)) = id x = id y
    let hash (Cons (x, _)) = String.hash (id x)
  end

  module Building_workflow_table = Caml.Weak.Make(Building_workflow)

  let building_workflow_table = Building_workflow_table.create 253

  let find_build_thread x =
    try
      let Building_workflow.Cons (_, t) =
        Building_workflow_table.find
          building_workflow_table
          (Building_workflow.Cons (x, Lwt.return ()))
      in Some t
    with Not_found -> None

  let add_build_thread x t =
    Building_workflow_table.add
      building_workflow_table
      (Building_workflow.Cons (x, t))

  let rec build : type s. s workflow -> unit Lwt.t = fun w ->
    match find_build_thread w with
    | Some t -> t
    | None ->
      let t = match w with
        | Extract (_, dir, path_in_dir) ->
          let dir_path = Db.cache_path db dir in
          let check_in_dir () =
            if not (Sys.file_exists_exn (Db.cache_path db w))
            then (
              let msg = sprintf "No file or directory named %s in directory workflow." (String.concat ~sep:"/" path_in_dir) in
              Lwt.fail (Failure msg)
            )
            else Lwt.return ()
          in
          if Sys.file_exists_exn dir_path then (
            Db.used db dir ;
            check_in_dir ()
          )
          else build dir >>= check_in_dir
        | Path_workflow (_, t) -> assert false
        | Value_workflow (_, t) -> assert false
      in
      add_build_thread w t ;
      t

  let eval : type s. s workflow -> s Lwt.t = fun w ->
    let path = Db.cache_path db w in
    let return_value : type s. s workflow -> s Lwt.t = function
      | Extract (_, dir, _) -> Lwt.return (Path path)
      | Path_workflow (_, t) -> Lwt.return (Path path)
      | Value_workflow (_, t) -> load_value path
    in
    build w >>= fun () -> return_value w
end
