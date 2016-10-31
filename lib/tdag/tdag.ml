open Core_kernel.Std
open Tdag_sig

module Make(D : Domain) = struct
  open D

  let ( >>= ) = Thread.bind
  let ( >>| ) x f = x >>= fun x -> Thread.return (f x)

  let rec map_p ~f = function
    | [] -> Thread.return []
    | h :: t ->
      let f_h = f h and map_f_t = map_p t ~f in
      f_h >>= fun f_h ->
      map_f_t >>| fun map_f_t ->
      f_h :: map_f_t

  module V = struct
    type t = Task.t
    let compare u v = String.compare (Task.id u) (Task.id v)
    let hash u = Hashtbl.hash (Task.id u)
    let equal u v =
      Task.id u = Task.id v
  end

  module G = Graph.Persistent.Digraph.Concrete(V)
  module Dfs = Graph.Traverse.Dfs(G)

  type t = G.t
  type task = Task.t
  type task_error = Task.error
  type 'a thread = 'a Thread.t
  type allocator = Allocator.t
  type config = Task.config

  type trace =
    | Run of { ready : time ;
               start : time ;
               end_ : time ;
               outcome : (unit, task_error) result }

    | Skipped of [ `Done_already
                 | `Missing_dep
                 | `Allocation_error of string ]

  and time = float

  type event =
    | Init of t
    | Task_ready of task
    | Task_started of task
    | Task_ended of task * (unit, task_error) result
    | Task_skipped of task * [ `Done_already
                             | `Missing_dep
                             | `Allocation_error of string ]

  class type logger = object
    method event : time -> event -> unit
    method stop : unit
    method wait4shutdown : unit thread
  end

  let empty = G.empty

  let add_task = G.add_vertex

  let add_dep g u ~on:v =
    G.add_edge g u v

  let dot_output g vertex_attributes edge_attributes fn =
    let module G = struct
      include G
      let graph_attributes _ = []
      let default_vertex_attributes _ = []
      let vertex_name t = sprintf "\"%s\"" (Task.id t)
      let vertex_attributes = vertex_attributes
      let edge_attributes = edge_attributes
      let get_subgraph _ = None
      let default_edge_attributes _ = []
    end in
    let module Dot = Graph.Graphviz.Dot(G) in
    Out_channel.with_file fn ~f:(fun oc ->
        Dot.output_graph oc g
      )

  let sources g =
    let f u accu =
      if G.in_degree g u = 0 then u :: accu
      else accu
    in
    G.fold_vertex f g []

  let successfull_trace = function
    | Run { outcome = Ok () }
    | Skipped `Done_already -> true
    | _ -> false

  let rec dft logger alloc config g thread_table u =
    let id = Task.id u in
    if String.Map.mem thread_table id then
      thread_table
    else
      let thread_table = G.fold_succ (Fn.flip (dft logger alloc config g)) g u thread_table in
      if String.Map.mem thread_table id then
        thread_table
      else
        let foreach_succ v accu =
          String.Map.find_exn thread_table (Task.id v) :: accu
        in
        let thread =
          Task.is_done config u >>= fun is_done ->
          if is_done then (
            logger#event (Unix.gettimeofday ()) (Task_skipped (u, `Done_already)) ;
            Thread.return (Skipped `Done_already)
          )
          else
            map_p ~f:ident (G.fold_succ foreach_succ g u []) >>= fun dep_traces ->
            if List.for_all dep_traces ~f:successfull_trace then (
              let ready = Unix.gettimeofday () in
              logger#event ready (Task_ready u) ;
              Allocator.request alloc (Task.requirement u) >>= function
              | Ok resource ->
                let start = Unix.gettimeofday () in
                logger#event start (Task_started u) ;
                Task.perform resource config u >>= fun outcome ->
                let end_ = Unix.gettimeofday () in
                logger#event end_ (Task_ended (u, outcome)) ;
                Allocator.release alloc resource ;
                Thread.return (Run { ready ; start ; end_ ; outcome })
              | Error (`Msg msg) ->
                let err = `Allocation_error msg in
                logger#event (Unix.gettimeofday ()) (Task_skipped (u, err)) ;
                Thread.return (Skipped err)
            )
            else (
              logger#event (Unix.gettimeofday ()) (Task_skipped (u, `Missing_dep)) ;
              Thread.return (Skipped `Missing_dep)
            )
        in
        String.Map.add thread_table id thread

  let null_logger = object
    method event _ _ = ()
    method stop = ()
    method wait4shutdown = Thread.return ()
  end

  let run ?(logger = null_logger) config alloc g =
    if Dfs.has_cycle g then failwith "Cycle in dependency graph" ;
    let sources = sources g in
    logger#event (Unix.gettimeofday ()) (Init g) ;
    let ids, threads =
      List.fold sources ~init:String.Map.empty ~f:(dft logger alloc config g)
      |> String.Map.to_alist
      |> List.unzip
    in
    map_p threads ~f:ident >>| fun traces ->
    List.zip_exn ids traces
    |> String.Map.of_alist_exn
end