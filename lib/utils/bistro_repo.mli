open Bistro.Std
open Bistro_engine

type item

type t = item list

val ( %> ) : string list -> _ workflow -> item

val to_app : outdir:string -> t -> unit Bistro_app.t

val build  :
  ?np:int ->
  ?mem:int ->
  ?logger:Scheduler.logger ->
  ?dag_dump:string ->
  ?keep_all:bool ->
  outdir:string -> t -> unit