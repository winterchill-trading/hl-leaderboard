open! Core
open! Async
open Hl_protocol

module Leader = struct
  type t =
    { address : Address.t
    ; row : Board.Row.t option
    ; fills : User_fill.t list
    ; state : (Time_ns.t * Clearinghouse_state.t) option
    }
  [@@deriving sexp_of]
end

type t =
  { started : Time_ns.t option
  ; leaders : Leader.t list
  }
[@@deriving sexp_of]

module Key = struct
  type t = int * int [@@deriving sexp, compare, hash]
end

let load_fills dir address =
  let%map entries = Raw_log.read (Layout.fills dir address) in
  let%bind.Or_error entries in
  let seen = Hashtbl.create (module Key) in
  let%map.Or_error pages =
    List.map entries ~f:(fun { recv_ts = _; body } -> Api.decode_fills body)
    |> Or_error.all
  in
  List.concat pages
  |> List.filter ~f:(fun f ->
    match Hashtbl.add seen ~key:(Fill_pages.key f) ~data:() with
    | `Ok -> true
    | `Duplicate -> false)
  |> List.stable_sort ~compare:(fun (a : User_fill.t) b ->
    match Int.compare a.time b.time with
    | 0 -> Int.compare a.tid b.tid
    | c -> c)
;;

let load_state dir address =
  let%map.Deferred.Or_error entries = Raw_log.read (Layout.state dir address) in
  List.rev entries
  |> List.find_map ~f:(fun { Raw_log.Entry.recv_ts; body } ->
    match Api.decode_clearinghouse_state body with
    | Ok state -> Some (recv_ts, state)
    | Error _ -> None)
;;

let load_candidates dir =
  let path = Layout.candidates dir in
  match%bind Sys.file_exists_exn path with
  | false -> return (Ok [])
  | true ->
    let%map text = Reader.file_contents path in
    Board.of_string text
;;

let save_candidates dir rows =
  let path = Layout.candidates dir in
  let%bind () = Unix.mkdir ~p:() (Filename.dirname path) in
  Writer.save
    ~temp_file:(path ^ ".tmp")
    path
    ~contents:(Yojson.Safe.to_string (Board.to_json rows))
;;

let load_leader' dir ~rows address =
  let%bind.Deferred.Or_error fills = load_fills dir address in
  let%map.Deferred.Or_error state = load_state dir address in
  { Leader.address; row = Map.find rows address; fills; state }
;;

let rows_by_address rows =
  List.map rows ~f:(fun (r : Board.Row.t) -> r.eth_address, r)
  |> Address.Map.of_alist_reduce ~f:(fun first _ -> first)
;;

let load dir =
  let%bind.Deferred.Or_error rows = load_candidates dir in
  let%bind.Deferred.Or_error progress = Progress.load (Layout.progress dir) in
  let by_address = rows_by_address rows in
  let started, addresses =
    match progress with
    | Some p -> Some p.started, p.candidates
    | None -> None, List.map rows ~f:(fun r -> r.eth_address)
  in
  let%map.Deferred.Or_error leaders =
    Deferred.Or_error.List.map
      ~how:`Sequential
      addresses
      ~f:(load_leader' dir ~rows:by_address)
  in
  { started; leaders }
;;

let load_leader dir address =
  let%bind.Deferred.Or_error rows = load_candidates dir in
  load_leader' dir ~rows:(rows_by_address rows) address
;;
