open! Core
open! Async
open Hl_protocol

type t =
  { server : (Socket.Address.Inet.t, int) Cohttp_async.Server.t
  ; requests : string Queue.t
  ; failing : Address.Hash_set.t
  ; mutable throttle : int
  }

let respond ?(status = `OK) body =
  Cohttp_async.Server.respond_string
    ~status
    ~headers:(Cohttp.Header.of_list [ "content-type", "application/json" ])
    body
;;

let page fills ~start_time =
  List.filter fills ~f:(fun (f : User_fill.t) -> f.time >= start_time)
  |> Fn.flip List.take 2000
;;

let start ?portfolio ~leaderboard ~fills ~state () =
  let requests = Queue.create () in
  let failing = Address.Hash_set.create () in
  let fills = Address.Map.of_alist_exn fills in
  let t_ref = ref None in
  let handler ~body _addr (req : Cohttp.Request.t) =
    let path = Uri.path (Cohttp.Request.uri req) in
    match Cohttp.Request.meth req, path with
    | `GET, "/leaderboard" ->
      Queue.enqueue requests "GET /leaderboard";
      respond leaderboard
    | `POST, "/info" ->
      let%bind body = Cohttp_async.Body.to_string body in
      let json = Yojson.Safe.from_string body in
      let field name = Yojson.Safe.Util.member name json in
      let type_ = Yojson.Safe.Util.to_string (field "type") in
      let user =
        match field "user" with
        | `String s -> Some (Address.of_string s)
        | _ -> None
      in
      Queue.enqueue
        requests
        (sprintf "%s %s" type_ (Option.value_map user ~default:"-" ~f:Address.to_string));
      let t = Option.value_exn !t_ref in
      if t.throttle > 0
      then (
        t.throttle <- t.throttle - 1;
        respond ~status:`Too_many_requests "null")
      else (
        match type_, user with
        | "userFillsByTime", Some user ->
          let start_time = Yojson.Safe.Util.to_int (field "startTime") in
          let all = Map.find fills user |> Option.value ~default:[] in
          respond
            (Yojson.Safe.to_string
               (`List (List.map (page all ~start_time) ~f:User_fill.yojson_of_t)))
        | "clearinghouseState", Some user ->
          if Hash_set.mem failing user
          then respond ~status:`Internal_server_error "{\"error\":\"down\"}"
          else respond state
        | "portfolio", Some _ when Option.is_some portfolio ->
          respond (Option.value_exn portfolio)
        | _ -> respond ~status:`Bad_request "\"unsupported\"")
    | _ -> respond ~status:`Not_found "\"not found\""
  in
  let%map server =
    Cohttp_async.Server.create
      ~on_handler_error:`Raise
      (Tcp.Where_to_listen.of_port 0)
      handler
  in
  let t = { server; requests; failing; throttle = 0 } in
  t_ref := Some t;
  t
;;

let port t = Cohttp_async.Server.listening_on t.server
let base_url t = Uri.of_string (sprintf "http://127.0.0.1:%d" (port t))
let leaderboard_url t = Uri.of_string (sprintf "http://127.0.0.1:%d/leaderboard" (port t))
let requests t = Queue.to_list t.requests

let fail_state t address on =
  if on then Hash_set.add t.failing address else Hash_set.remove t.failing address
;;

let throttle_next t n = t.throttle <- n
let close t = Cohttp_async.Server.close t.server
