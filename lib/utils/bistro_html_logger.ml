open Core.Std
open Bistro_engine
open Rresult

type time = float

type event =
  | Task_started of Task.t
  | Task_ended of Task.t * (unit, Task.error) result
  | Task_done_already of Task.t

type model = {
  dag : Scheduler.DAG.t option ;
  events : (time * event) list ;
}

let ( >>= ) = Lwt.( >>= )
let ( >>| ) = Lwt.( >|= )

type t = {
  path : string ;
  config : Task.config ;
  mutable model : model ;
  mutable queue : (Scheduler.time * Scheduler.event) list ;
  mutable stop : bool ;
}

let create path config = {
  path ;
  config ;
  model = { dag = None ; events = [] } ;
  queue = [] ;
  stop = false ;
}

let some_change logger = logger.queue <> []

let translate_event time = function
  | Scheduler.Task_started t ->
    Some (Task_started t)
  | Scheduler.Task_ended (t, outcome) ->
    Some (Task_ended (t, outcome))
  | Scheduler.Task_skipped (t, `Done_already) ->
    Some (Task_done_already t)

  | Scheduler.Init _
  | Scheduler.Task_ready _
  | Scheduler.Task_skipped (_, (`Allocation_error _ | `Missing_dep)) -> None

let update model time evt =
  {
    dag = (
      match evt with
      | Scheduler.Init dag -> Some dag
      | _ -> model.dag
    ) ;
    events = (
      match translate_event time evt with
      | None -> model.events
      | Some evt -> (time, evt) :: model.events
    ) ;
  }

module Render = struct
  open Tyxml_html

  let new_elt_id =
    let c = ref 0 in
    fun () ->
      incr c ;
      sprintf "id%08d" !c

  let k = pcdata

  let item label contents =
    p (strong [k (label ^ ": ")] :: contents)

  let step_details ?outcome config ({Task.id ; np ; mem } as step)  =
    let outputs = match outcome with
      | Some res -> div [
          item "outcome" [
            a ~a:[a_href (Db.stdout config.Task.db id) ] [ k "stdout" ] ;
            k " " ;
            a ~a:[a_href (Db.stderr config.Task.db id) ] [ k "stderr" ] ;
          ] ;
        ]
      | None -> div []
    in
    let file_dumps =
      match Task.render_step_dumps ~np ~mem config step with
      | [] -> k"" ;
      | dumps ->
        let modals = List.map dumps ~f:(fun (fn, contents) ->
            let modal_id = new_elt_id () in
            let modal =
              div ~a:[a_id modal_id ; a_class ["modal";"fade"] ; Unsafe.string_attrib "role" "dialog"] [
                div ~a:[a_class ["modal-dialog"] ; a_style "width:70%"] [
                  div ~a:[a_class ["modal-content"]] [
                    div ~a:[a_class ["modal-header"]] [
                      button ~a:[a_class ["close"] ; a_user_data "dismiss" "modal"] [
                        entity "times"
                      ] ;
                      h4 [ k fn ]
                    ] ;
                    div ~a:[a_class ["modal-body"]] [
                      pre [ k contents ]
                    ]
                  ]
                ]
              ]
            in
            modal_id, fn, modal
          )
        in
        let links =
          List.map modals ~f:(fun (modal_id, fn, _) ->
              li [
                button ~a:[
                  a_class ["btn-link"] ;
                  a_user_data "toggle" "modal" ;
                  a_user_data "target" ("#" ^ modal_id)] [ k fn ]
              ]
            )
          |> ul
        in
        div (
          (item "file dumps" [])
          :: links
          :: List.map modals ~f:(fun (_,_,x) -> x)
        )
    in
    [
      item "id" [
        match outcome with
        | Some (Ok ()) ->
          let file_uri = Db.cache config.Task.db id in
          a ~a:[a_href file_uri] [ k id ]
        | Some (Error _) | None -> k id
      ] ;

      outputs ;

      item "command" [] ;
      pre [ k (Task.render_step_command ~np ~mem config step) ] ;

      file_dumps ;
    ]

  let outcome_par conf = function
    | None
    | Some (Ok ()) -> k""
    | Some (Error e) ->
      Task.(
        match e with
        | Input_doesn't_exist _ ->
          p [ k"Input doesn't exist" ]
        | Invalid_select (dir, sel) ->
          p [ k"No path " ; k (Bistro.string_of_path sel) ; k" in " ;
              k (Db.cache conf.db dir) ]
        | Step_failure sf ->
          p [ k (sprintf "Command failed with code %d" sf.exit_code) ]
      )

  let task ?outcome config = function
    | Task.Input (_, path) ->
      [ p [ k "input " ; k (Bistro.string_of_path path) ] ;
        outcome_par config outcome ]


    | Task.Select (_, `Input input_path, path) ->
      [ p [ k "select " ;
            k (Bistro.string_of_path path) ;
            k " in " ;
            k (Bistro.string_of_path input_path) ] ;
        outcome_par config outcome ]

    | Task.Select (_, `Step id, path) ->
      [ p [ k "select " ;
            k (Bistro.string_of_path path) ;
            k " in step " ;
            k id ] ;
        outcome_par config outcome ]

    | Task.Step step ->
      let elt_id = new_elt_id () in
      [
        div ~a:[a_class ["panel-group"]] [
          div ~a:[a_class ["panel";"panel-default"]] [
            div ~a:[a_class ["panel-heading"]] [
              h4 ~a:[a_class ["panel-title"]] [
                a ~a:[a_user_data "toggle" "collapse" ; a_href ("#" ^ elt_id) ] [ k step.Task.descr ]
              ] ;
              outcome_par config outcome ;
            ] ;
            div ~a:[a_id elt_id ; a_class ["panel-collapse";"collapse"]] (
              step_details ?outcome config step
            )

          ]
        ]
      ]

  let event config time evt =
    let table_line ?outcome action t =
      [
        td [ k Time.(to_string_trimmed ~zone:Zone.local (of_float time)) ] ;
        td [ action ] ;
        td (task ?outcome config t)
      ]
    in
    match evt with
    | Task_started t ->
      table_line (k "STARTED") t

    | Task_ended (t, outcome) ->
      let col = match outcome with
        | Ok _ -> "green"
        | Error _ -> "red"
      in
      let style = sprintf "color:%s; font-weight:bold;" col in
      let text = span ~a:[a_style style] [ k "ENDED" ] in
      table_line ~outcome text t

    | Task_done_already t ->
      table_line ~outcome:(Ok ()) (k "CACHED") t

  let event_table config m =
    let table =
      List.map m.events ~f:(fun (time, evt) -> tr (event config time evt))
      |> table ~a:[a_class ["table"]]
    in
    [
      p ~a:[a_style {|font-weight:700; color:"#959595"|}] [ k"EVENT LOG" ] ;
      table ;
    ]

  let head =
    head (title (pcdata "Bistro report")) [
      link ~rel:[`Stylesheet] ~href:"http://netdna.bootstrapcdn.com/bootstrap/3.0.2/css/bootstrap.min.css" () ;
      link ~rel:[`Stylesheet] ~href:"http://netdna.bootstrapcdn.com/bootstrap/3.0.2/css/bootstrap-theme.min.css" () ;
      script ~a:[a_src "https://code.jquery.com/jquery.js"] (pcdata "") ;
      script ~a:[a_src "http://netdna.bootstrapcdn.com/bootstrap/3.0.2/js/bootstrap.min.js"] (pcdata "") ;
    ]

  let model config m =
    let contents = List.concat [
        event_table config m ;
      ]
    in
    html head (body [ div ~a:[a_class ["container"]] contents ])

end

let save path doc =
  let buf = Buffer.create 253 in
  let formatter = Format.formatter_of_buffer buf in
  Tyxml_html.pp () formatter doc ;
  Lwt_io.with_file ~mode:Lwt_io.output path (fun oc ->
      let contents = Buffer.contents buf in
      Lwt_io.write oc contents
    )

let rec loop logger =
  if some_change logger then (
    logger.model <-
      List.fold_right logger.queue ~init:logger.model ~f:(fun (time, evt) model ->
          update model time evt
        ) ;
    logger.queue <- [] ;
    let doc = Render.model logger.config logger.model in
    save logger.path doc >>= fun () ->
    loop logger
  )
  else if logger.stop then Lwt.return ()
  else (
    Lwt_unix.sleep 1. >>= fun () ->
    loop logger
  )

class logger path config =
  let logger = create path config in
  let loop = loop logger in
  object
    method event time event =
      logger.queue <- (time, event) :: logger.queue

    method stop =
      logger.stop <- true

    method wait4shutdown = loop
  end

let create path config = new logger path config