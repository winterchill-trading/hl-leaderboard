open! Core
open! Async
open Hl_protocol

module Config = struct
  type t =
    { dir : string
    ; top_n : int
    ; windows : Board.Window.t list
    ; min_account_value : float
    ; lookback : Time_ns.Span.t
    ; max_pages : int
    ; roles : string list
    }
  [@@deriving sexp_of]

  let default ~dir =
    { dir
    ; top_n = 20
    ; windows = Board.Window.all
    ; min_account_value = 10_000.
    ; lookback = Time_ns.Span.of_day 30.
    ; max_pages = 5
    ; roles = Roles.default
    }
  ;;
end

module Summary = struct
  type t =
    { candidates : int
    ; excluded : int
    ; collected : int
    ; failed : int
    ; fills : int
    ; weight : int
    ; retries : int
    ; resumed : bool
    }
  [@@deriving sexp_of]
end

(* The leaderboard body is pretty-printed (about 40 MB with indentation); store it
   compact. Every value in it is a string or an int, so nothing is lost. *)
let compact body =
  if String.mem body '\n'
  then Yojson.Safe.to_string (Yojson.Safe.from_string body)
  else body
;;

let start_run ~now api (config : Config.t) =
  let%bind.Deferred.Or_error raw, board = Api.leaderboard api in
  let%bind () =
    Raw_log.append
      (Layout.leaderboard config.dir raw.recv_ts)
      ~recv_ts:raw.recv_ts
      (compact raw.body)
  in
  let role_of address =
    match%bind Api.user_role api ~user:address with
    | Ok (raw, role) ->
      let%map () =
        Raw_log.append (Layout.role config.dir address) ~recv_ts:raw.recv_ts raw.body
      in
      Some role
    | Error e ->
      Log.Global.info_s [%message "no role" (address : Address.t) (e : Error.t)];
      return None
  in
  let%bind rows, excluded =
    Roles.candidates
      ~min_account_value:config.min_account_value
      board
      ~n:config.top_n
      ~windows:config.windows
      ~roles:config.roles
      ~role_of
  in
  List.iter excluded ~f:(fun ((row : Board.Row.t), role) ->
    Log.Global.info_s
      [%message
        "skipped" ~address:(row.eth_address : Address.t) (role : User_role.Role.t option)]);
  Log.Global.info_s
    [%message
      "leaderboard"
        ~rows:(List.length board : int)
        ~candidates:(List.length rows : int)
        ~excluded:(List.length excluded : int)];
  let%bind () = Dataset.save_candidates config.dir rows in
  let progress =
    { Progress.started = now ()
    ; candidates = List.map rows ~f:(fun r -> r.eth_address)
    ; collected = []
    }
  in
  let%map () = Progress.save (Layout.progress config.dir) progress in
  Ok (progress, List.length excluded)
;;

(* [userFunding] pages from the newest payment already logged (or the lookback), at most
   500 payments per answer. Optional: hl-sim has no funding history, and a failure only
   leaves the track record without funding. *)
let collect_funding api ~path ~start_time address =
  let%bind seen = Raw_log.read path in
  let newest =
    match seen with
    | Error _ -> None
    | Ok entries ->
      List.filter_map entries ~f:(fun e ->
        match Yojson.Safe.from_string e.body with
        | `List items ->
          List.filter_map items ~f:(fun j ->
            match Yojson.Safe.Util.member "time" j with
            | `Int t -> Some t
            | _ -> None)
          |> List.max_elt ~compare:Int.compare
        | _ -> None
        | exception _ -> None)
      |> List.max_elt ~compare:Int.compare
  in
  let start = Option.value_map newest ~default:start_time ~f:(fun t -> Int.max start_time (t + 1)) in
  let rec page start n =
    if n >= 10
    then return ()
    else (
      match%bind
        Api.info
          api
          (`Assoc
            [ "type", `String "userFunding"
            ; "user", `String (Address.to_string address)
            ; "startTime", `Int start
            ])
      with
      | Error e ->
        Log.Global.info_s [%message "no funding" (address : Address.t) (e : Error.t)];
        return ()
      | Ok raw ->
        let times =
          match Yojson.Safe.from_string raw.body with
          | `List items ->
            List.filter_map items ~f:(fun j ->
              match Yojson.Safe.Util.member "time" j with
              | `Int t -> Some t
              | _ -> None)
          | _ -> []
          | exception _ -> []
        in
        let%bind () =
          if List.is_empty times then return () else Raw_log.append path ~recv_ts:raw.recv_ts raw.body
        in
        let%bind () =
          Rate_limit.acquire
            (Api.rate_limit api)
            ~weight:(Rate_limit.Weight.per_items "userFunding" ~items:(List.length times))
        in
        (match List.max_elt times ~compare:Int.compare with
         | Some newest when List.length times >= 500 -> page (newest + 1) (n + 1)
         | _ -> return ()))
  in
  page start 0
;;

(* Order books of the coins the candidates trade most (by notional), and the venue's
   open interest, for leader-scoring's copyability estimate. [l2Book] weighs 2. *)
let collect_market api (config : Config.t) (dataset : Dataset.t) =
  let notional = String.Table.create () in
  List.iter dataset.leaders ~f:(fun (l : Dataset.Leader.t) ->
    List.iter l.fills ~f:(fun (f : User_fill.t) ->
      let coin = Coin.to_string f.coin in
      if not (Leader_scoring_hl.Hl_decode.is_spot coin)
      then
        Hashtbl.update notional coin ~f:(fun v ->
          Option.value v ~default:0.
          +. (Price.to_float f.px *. Size.to_float f.sz))));
  let coins =
    Hashtbl.to_alist notional
    |> List.sort ~compare:(fun (a, x) (b, y) ->
      match Float.compare y x with
      | 0 -> String.compare a b
      | c -> c)
    |> (fun l -> List.take l 25)
    |> List.map ~f:fst
  in
  let%bind () =
    Deferred.List.iter ~how:`Sequential coins ~f:(fun coin ->
      match%bind Api.info api (`Assoc [ "type", `String "l2Book"; "coin", `String coin ]) with
      | Ok raw -> Raw_log.append (Layout.book config.dir coin) ~recv_ts:raw.recv_ts raw.body
      | Error e ->
        Log.Global.info_s [%message "no book" (coin : string) (e : Error.t)];
        return ())
  in
  match%bind Api.info api (`Assoc [ "type", `String "metaAndAssetCtxs" ]) with
  | Ok raw -> Raw_log.append (Layout.market config.dir) ~recv_ts:raw.recv_ts raw.body
  | Error e ->
    Log.Global.info_s [%message "no open interest" (e : Error.t)];
    return ()
;;

let collect_one ~now api (config : Config.t) address =
  let%bind.Deferred.Or_error seen = Dataset.load_fills config.dir address in
  let floor_ms =
    Time_ns.sub (now ()) config.lookback
    |> Time_ns.to_int_ns_since_epoch
    |> fun ns -> ns / 1_000_000
  in
  let start_time =
    match List.last seen with
    | Some (f : User_fill.t) -> Int.max floor_ms f.time
    | None -> floor_ms
  in
  let path = Layout.fills config.dir address in
  let%bind.Deferred.Or_error walk =
    Fill_pages.walk
      ~max_pages:config.max_pages
      ~seen
      ~start_time
      ~fetch:(fun ~start_time -> Api.user_fills_by_time api ~user:address ~start_time)
      ~on_page:(fun (raw : Api.Raw.t) _ ->
        Raw_log.append path ~recv_ts:raw.recv_ts raw.body)
      ()
  in
  let%bind.Deferred.Or_error raw, _state = Api.clearinghouse_state api ~user:address in
  let%bind () =
    Raw_log.append (Layout.state config.dir address) ~recv_ts:raw.recv_ts raw.body
  in
  (* Optional: the simulator and older deployments have no [portfolio]; the score then
     falls back to the curve rebuilt from fills. *)
  let%bind () =
    match%bind Api.portfolio api ~user:address with
    | Ok (raw, _) ->
      Raw_log.append (Layout.portfolio config.dir address) ~recv_ts:raw.recv_ts raw.body
    | Error e ->
      Log.Global.info_s [%message "no portfolio" (address : Address.t) (e : Error.t)];
      return ()
  in
  let%map () =
    collect_funding api ~path:(Layout.funding config.dir address) ~start_time:floor_ms address
  in
  Log.Global.info_s
    [%message
      "collected"
        (address : Address.t)
        ~new_fills:(List.length walk.fills : int)
        ~pages:(walk.pages : int)
        ~complete:(walk.complete : bool)];
  Ok (List.length walk.fills)
;;

let run ?(now = Time_ns.now) api (config : Config.t) =
  let path = Layout.progress config.dir in
  let%bind.Deferred.Or_error existing = Progress.load path in
  let%bind.Deferred.Or_error progress, excluded, resumed =
    match existing with
    | Some p when not (List.is_empty (Progress.pending p)) -> return (Ok (p, 0, true))
    | _ ->
      let%map.Deferred.Or_error p, excluded = start_run ~now api config in
      p, excluded, false
  in
  let failed = ref 0 in
  let fills = ref 0 in
  let%bind progress =
    Deferred.List.fold
      (Progress.pending progress)
      ~init:progress
      ~f:(fun progress address ->
        match%bind collect_one ~now api config address with
        | Ok n ->
          fills := !fills + n;
          let progress = { progress with collected = progress.collected @ [ address ] } in
          let%map () = Progress.save path progress in
          progress
        | Error e ->
          (* Leave it pending: the next run retries it. *)
          incr failed;
          Log.Global.error_s
            [%message "collect failed" (address : Address.t) (e : Error.t)];
          return progress)
  in
  let%bind.Deferred.Or_error dataset = Dataset.load config.dir in
  let%bind () = collect_market api config dataset in
  let%map.Deferred.Or_error (_ : int) =
    In_thread.run (fun () ->
      Or_error.try_with (fun () -> Parquet_out.write ~dir:config.dir dataset))
  in
  { Summary.candidates = List.length progress.candidates
  ; excluded
  ; collected = List.length progress.collected
  ; failed = !failed
  ; fills = !fills
  ; weight = Rate_limit.total_weight (Api.rate_limit api)
  ; retries = Api.retries api
  ; resumed
  }
;;
