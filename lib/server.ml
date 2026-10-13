open! Core
open! Async
open Hl_protocol

type t = { server : (Socket.Address.Inet.t, int) Cohttp_async.Server.t }

let headers =
  Cohttp.Header.of_list
    [ "content-type", "application/json"; "access-control-allow-origin", "*" ]
;;

let respond_json ?(status = `OK) json =
  Cohttp_async.Server.respond_string ~status ~headers (Yojson.Safe.to_string json)
;;

let error status msg = respond_json ~status (`Assoc [ "error", `String msg ])

(* The ranking file, re-read when its mtime changes. *)
module Ranking = struct
  type t =
    { path : string
    ; mutable loaded : (Time_float.t * Yojson.Safe.t) option
    }

  let get t =
    match%bind Monitor.try_with_or_error (fun () -> Unix.stat t.path) with
    | Error _ -> return None
    | Ok stat ->
      (match t.loaded with
       | Some (mtime, json) when Time_float.equal mtime stat.mtime -> return (Some json)
       | _ ->
         (match%map
            Monitor.try_with_or_error (fun () ->
              Reader.file_contents t.path >>| Yojson.Safe.from_string)
          with
          | Ok json ->
            t.loaded <- Some (stat.mtime, json);
            Some json
          | Error e ->
            Log.Global.error_s [%message "cannot read ranking" t.path (e : Error.t)];
            Option.map t.loaded ~f:snd))
  ;;
end

let leaders_of ranking =
  match ranking with
  | `Assoc fields ->
    (match List.Assoc.find fields "leaders" ~equal:String.equal with
     | Some (`List l) -> l
     | _ -> [])
  | _ -> []
;;

let with_leaders ranking leaders =
  match ranking with
  | `Assoc fields ->
    `Assoc
      (List.map fields ~f:(fun (k, v) ->
         if String.equal k "leaders" then k, `List leaders else k, v))
  | json -> json
;;

let find_entry ranking address =
  leaders_of ranking
  |> List.find ~f:(fun entry ->
    match Yojson.Safe.Util.member "address" entry with
    | `String a -> String.equal a (Address.to_string address)
    | _ -> false)
;;

let leader_json ~dir ~ranking ~limit ~now_ms address =
  let%bind.Deferred.Or_error leader = Dataset.load_leader dir address in
  if Option.is_none leader.row
     && Option.is_none leader.state
     && List.is_empty leader.fills
  then return (Ok None)
  else (
    let curve, source = Rank.equity_curve ~now_ms leader in
    `Assoc
      [ "address", `String (Address.to_string address)
      ; ( "entry"
        , Option.bind ranking ~f:(fun r -> find_entry r address)
          |> Option.value ~default:`Null )
      ; "fill_count", `Int (List.length leader.fills)
      ; ( "fills"
        , `List
            (List.rev leader.fills
             |> Fn.flip List.take limit
             |> List.map ~f:User_fill.yojson_of_t) )
      ; ( "curve_source"
        , `String
            (match source with
             | `Portfolio_month -> "portfolio_month"
             | `Fills -> "fills") )
      ; ( "equity_curve"
        , `List
            (List.map curve ~f:(fun (p : Equity_curve.Point.t) ->
               `List [ `Int p.time_ms; `Float p.equity ])) )
      ; ( "positions"
        , match leader.state with
          | None -> `List []
          | Some (_, s) ->
            `List (List.map s.positions ~f:Clearinghouse_state.Position.yojson_of_t) )
      ]
    |> Option.some
    |> Or_error.return
    |> return)
;;

let parse_address s =
  let s = String.lowercase s in
  if String.length s = 42
     && String.is_prefix s ~prefix:"0x"
     && String.for_all (String.drop_prefix s 2) ~f:Char.is_hex_digit
  then Some (Address.of_string s)
  else None
;;

let limit_of uri ~default =
  match Uri.get_query_param uri "limit" with
  | None -> Ok default
  | Some s ->
    (match Int.of_string_opt s with
     | Some n when n >= 0 -> Ok n
     | _ -> Error "limit must be a non-negative integer")
;;

let start ~dir ~leaders ~port =
  let ranking = { Ranking.path = leaders; loaded = None } in
  let handler ~body:_ _addr (req : Cohttp.Request.t) =
    let uri = Cohttp.Request.uri req in
    let parts =
      String.split (Uri.path uri) ~on:'/' |> List.filter ~f:(Fn.non String.is_empty)
    in
    match Cohttp.Request.meth req, parts with
    | `GET, [ "health" ] -> respond_json (`String "ok")
    | `GET, [ "leaders" ] ->
      (match limit_of uri ~default:Int.max_value with
       | Error msg -> error `Bad_request msg
       | Ok limit ->
         (match%bind Ranking.get ranking with
          | None -> error `Service_unavailable "no ranking yet; run hl-leaderboard rank"
          | Some json ->
            respond_json (with_leaders json (List.take (leaders_of json) limit))))
    | `GET, [ "leaders"; address ] ->
      (match limit_of uri ~default:500, parse_address address with
       | Error msg, _ -> error `Bad_request msg
       | _, None -> error `Bad_request "address must be 0x and 40 hex digits"
       | Ok limit, Some address ->
         let%bind ranking_json = Ranking.get ranking in
         let now_ms = Time_ns.to_int_ns_since_epoch (Time_ns.now ()) / 1_000_000 in
         (match%bind leader_json ~dir ~ranking:ranking_json ~limit ~now_ms address with
          | Ok (Some json) -> respond_json json
          | Ok None -> error `Not_found "address not collected"
          | Error e -> error `Internal_server_error (Error.to_string_hum e)))
    | `GET, _ -> error `Not_found "not found"
    | _ -> error `Method_not_allowed "read-only API"
  in
  let%map server =
    Cohttp_async.Server.create
      ~on_handler_error:
        (`Call (fun _ exn -> Log.Global.error_s [%message "handler" (exn : exn)]))
      (Tcp.Where_to_listen.of_port port)
      handler
  in
  { server }
;;

let port t = Cohttp_async.Server.listening_on t.server
let close t = Cohttp_async.Server.close t.server
