open! Core
open! Async
open Hl_protocol

module Network = struct
  type t =
    | Mainnet
    | Testnet
    | Local
  [@@deriving sexp, compare, equal, enumerate]

  let to_string = function
    | Mainnet -> "mainnet"
    | Testnet -> "testnet"
    | Local -> "local"
  ;;

  let of_string s =
    match String.lowercase s with
    | "mainnet" -> Mainnet
    | "testnet" -> Testnet
    | "local" -> Local
    | _ -> raise_s [%message "unknown network (mainnet, testnet or local)" s]
  ;;

  let arg_type = Command.Arg_type.create of_string
end

type t =
  { network : Network.t
  ; config : Hl_client.Config.t
  ; leaderboard_url : Uri.t option
  ; rate_limit : Rate_limit.t
  ; max_attempts : int
  ; time_source : Time_source.t
  ; mutable retries : int
  }

let create
  ?base_url
  ?leaderboard_url
  ?rate_limit
  ?(max_attempts = 5)
  ?(time_source = Time_source.wall_clock ())
  network
  =
  let config =
    match base_url, (network : Network.t) with
    | Some base_url, _ -> Hl_client.Config.create ~base_url ()
    | None, Mainnet -> Hl_client.Config.mainnet ()
    | None, Testnet -> Hl_client.Config.testnet ()
    | None, Local -> Hl_client.Config.local ()
  in
  let leaderboard_url =
    match leaderboard_url, network with
    | Some _, _ -> leaderboard_url
    | None, Mainnet -> Some (Uri.of_string (Leaderboard.url `Mainnet))
    | None, Testnet -> Some (Uri.of_string (Leaderboard.url `Testnet))
    | None, Local -> None
  in
  let time_source = Time_source.read_only time_source in
  { network
  ; config
  ; leaderboard_url
  ; rate_limit =
      Option.value_or_thunk rate_limit ~default:(fun () ->
        Rate_limit.hyperliquid ~time_source ())
  ; max_attempts
  ; time_source
  ; retries = 0
  }
;;

let network t = t.network
let info_uri t = Hl_client.Config.info_uri t.config
let rate_limit t = t.rate_limit
let retries t = t.retries

module Raw = struct
  type t =
    { recv_ts : Time_ns.t
    ; body : string
    }
end

let retryable status = status = 429 || status >= 500

let with_retries t ~what f =
  let rec go attempt =
    let%bind result = f () in
    let failure =
      match result with
      | Ok (status, _) when retryable status ->
        Some (Error.of_string (sprintf "HTTP %d" status))
      | Ok _ -> None
      | Error e -> Some e
    in
    match failure with
    | Some e when attempt < t.max_attempts ->
      t.retries <- t.retries + 1;
      let delay = Time_ns.Span.of_ms (500. *. (2. ** Float.of_int (attempt - 1))) in
      Log.Global.info_s
        [%message
          "retrying"
            (what : string)
            (attempt : int)
            (delay : Time_ns.Span.t)
            (e : Error.t)];
      let%bind () = Time_source.after t.time_source delay in
      go (attempt + 1)
    | _ ->
      return
        (match result with
         | Ok (status, body) when Venue_net.Http.is_success status ->
           Ok { Raw.recv_ts = Time_source.now t.time_source; body }
         | Ok (status, body) ->
           let body = String.prefix body 300 in
           Or_error.error_s [%message "HTTP error" (what : string) (status : int) body]
         | Error e -> Error (Error.tag_s e ~tag:[%message (what : string)]))
  in
  go 1
;;

let request_type json =
  match json with
  | `Assoc fields ->
    (match List.Assoc.find fields "type" ~equal:String.equal with
     | Some (`String s) -> s
     | _ -> "unknown")
  | _ -> "unknown"
;;

let info t json =
  let type_ = request_type json in
  let%bind () = Rate_limit.acquire t.rate_limit ~weight:(Rate_limit.Weight.info type_) in
  with_retries t ~what:type_ (fun () -> Venue_net.Http.post_json (info_uri t) json)
;;

let parse what body ~f =
  Or_error.try_with (fun () -> f (Yojson.Safe.from_string body))
  |> Or_error.tag_s ~tag:[%message "decode" (what : string)]
;;

let leaderboard t =
  let%map raw =
    match t.leaderboard_url with
    | Some uri -> with_retries t ~what:"leaderboard" (fun () -> Venue_net.Http.get uri)
    | None -> info t (`Assoc [ "type", `String "leaderboard" ])
  in
  let%bind.Or_error raw in
  let%map.Or_error lb = Board.of_string raw.body in
  raw, lb
;;

let decode_fills body =
  parse "fills" body ~f:(function
    | `List l -> List.map l ~f:User_fill.t_of_yojson
    | _ -> failwith "fills: not a list")
;;

let decode_clearinghouse_state body =
  parse "clearinghouseState" body ~f:Clearinghouse_state.t_of_yojson
;;

let user_fills_by_time t ~user ~start_time =
  let%bind raw =
    info
      t
      (`Assoc
        [ "type", `String "userFillsByTime"
        ; "user", `String (Address.to_string user)
        ; "startTime", `Int start_time
        ])
  in
  match raw with
  | Error _ as e -> return e
  | Ok raw ->
    (match decode_fills raw.body with
     | Error _ as e -> return e
     | Ok fills ->
       let extra =
         Rate_limit.Weight.per_items "userFillsByTime" ~items:(List.length fills)
       in
       let%map () = Rate_limit.acquire t.rate_limit ~weight:extra in
       Ok (raw, fills))
;;

let portfolio t ~user =
  let%map raw = info t (Portfolio.request user) in
  let%bind.Or_error raw in
  let%map.Or_error p = Portfolio.of_string raw.body in
  raw, p
;;

let clearinghouse_state t ~user =
  let%map raw =
    info
      t
      (`Assoc
        [ "type", `String "clearinghouseState"; "user", `String (Address.to_string user) ])
  in
  let%bind.Or_error raw in
  let%map.Or_error state = decode_clearinghouse_state raw.body in
  raw, state
;;
