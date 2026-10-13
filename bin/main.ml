open! Core
open! Async
open Hl_leaderboard

let stderr_logging () = Log.Global.set_output [ Log.Output.stderr () ]

let collect =
  Command.async_or_error
    ~summary:"Fetch the leaderboard, then fills and account state of the top traders"
    ~readme:(fun () ->
      "Read-only: no keys, nothing is signed. Writes raw response logs and Parquet files \
       under -out; an interrupted run resumes where it stopped.")
    (let%map_open.Command dir =
       flag "out" (required string) ~doc:"DIR collection directory"
     and network =
       flag
         "network"
         (optional_with_default Api.Network.Mainnet Api.Network.arg_type)
         ~doc:"NET mainnet, testnet or local (hl-sim); default mainnet"
     and base_url =
       flag "base-url" (optional string) ~doc:"URL API root (overrides the network's)"
     and leaderboard_url =
       flag
         "leaderboard-url"
         (optional string)
         ~doc:"URL GET the leaderboard here instead of the stats host"
     and top_n =
       flag "top" (optional_with_default 20 int) ~doc:"N leaders per window (20)"
     and windows =
       flag
         "windows"
         (optional (Arg_type.comma_separated Board.Window.arg_type))
         ~doc:"W,.. day,week,month,allTime (all)"
     and min_account_value =
       flag
         "min-account-value"
         (optional_with_default 10_000. float)
         ~doc:"USD skip smaller accounts (10000)"
     and lookback_days =
       flag "lookback-days" (optional_with_default 30. float) ~doc:"D fill history (30)"
     and max_pages =
       flag
         "max-pages"
         (optional_with_default 5 int)
         ~doc:"P fill pages of 2000 per leader and run (5)"
     and roles =
       flag
         "include-roles"
         (optional (Arg_type.comma_separated Roles.arg_type))
         ~doc:
           "R,.. userRole values that may be candidates: user, agent, vault, subAccount, \
            missing (user)"
     and weight_per_minute =
       flag
         "weight-per-minute"
         (optional_with_default 1200 int)
         ~doc:"W request weight budget (1200, the documented limit)"
     in
     fun () ->
       stderr_logging ();
       let api =
         Api.create
           ?base_url:(Option.map base_url ~f:Uri.of_string)
           ?leaderboard_url:(Option.map leaderboard_url ~f:Uri.of_string)
           ~rate_limit:(Rate_limit.create ~refill_per_minute:weight_per_minute ())
           network
       in
       let config =
         { (Collect.Config.default ~dir) with
           top_n
         ; windows = Option.value windows ~default:Board.Window.all
         ; min_account_value
         ; lookback = Time_ns.Span.of_day lookback_days
         ; max_pages
         ; roles = Option.value roles ~default:Roles.default
         }
       in
       let%map.Deferred.Or_error summary = Collect.run api config in
       print_s [%sexp (summary : Collect.Summary.t)])
;;

let rank =
  Command.async_or_error
    ~summary:"Score every collected leader and write the ranking as JSON"
    (let%map_open.Command dir =
       flag "in" (required string) ~doc:"DIR collection directory"
     and out = flag "out" (required string) ~doc:"FILE ranking JSON (e.g. leaders.json)"
     and min_trades =
       flag
         "min-trades"
         (optional_with_default Rank.default_min_trades int)
         ~doc:(sprintf "N round trips needed to be ranked (%d)" Rank.default_min_trades)
     and print =
       flag "print" (optional_with_default 10 int) ~doc:"N print the top N (10)"
     in
     fun () ->
       stderr_logging ();
       let%bind.Deferred.Or_error dataset = Dataset.load dir in
       let now = Time_ns.now () in
       let entries =
         Rank.rank
           ~min_trades
           ~now_ms:(Time_ns.to_int_ns_since_epoch now / 1_000_000)
           dataset
       in
       let json = Rank.to_json ~generated_at:now entries in
       let%map () =
         Writer.save
           ~temp_file:(out ^ ".tmp")
           out
           ~contents:(Yojson.Safe.pretty_to_string json)
       in
       List.take entries print
       |> List.iter ~f:(fun (e : Rank.Entry.t) ->
         let s = e.score in
         printf
           "%3s %s score=%.4f pnl=%.0f return=%.3f mdd=%.3f win=%.2f trips=%d hold=%.1fh \
            consistency=%.2f\n"
           (Option.value_map e.rank ~default:"-" ~f:Int.to_string)
           (Hl_protocol.Address.to_string e.address)
           s.score
           (Hl_protocol.Usd.to_float s.pnl)
           s.return_
           s.max_drawdown
           s.win_rate
           s.trade_count
           (Float.of_int s.avg_hold_ns /. 3.6e12)
           s.consistency);
       Ok ())
;;

let serve =
  Command.async
    ~summary:"Serve /leaders and /leaders/<address> as JSON"
    (let%map_open.Command port =
       flag "port" (optional_with_default 8090 int) ~doc:"P (8090)"
     and dir = flag "dir" (required string) ~doc:"DIR collection directory"
     and leaders =
       flag "leaders" (optional string) ~doc:"FILE ranking JSON (DIR/leaders.json)"
     in
     fun () ->
       stderr_logging ();
       let leaders = Option.value leaders ~default:(dir ^/ "leaders.json") in
       let%bind server = Server.start ~dir ~leaders ~port in
       Log.Global.info_s [%message "serving" ~port:(Server.port server : int) dir leaders];
       Deferred.never ())
;;

let () =
  Command.group
    ~summary:"Hyperliquid leader discovery for copy trading (read-only)"
    [ "collect", collect; "rank", rank; "serve", serve ]
  |> Command_unix.run
;;
