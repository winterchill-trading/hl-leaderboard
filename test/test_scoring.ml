open! Core
open! Async
open Hl_leaderboard
open Hl_protocol

let now = Time_ns.of_string_with_utc_offset "2026-10-13 06:00:00Z"
let now_ms = Time_ns.to_int_ns_since_epoch now / 1_000_000
let a1 = Address.of_string "0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf"

let template =
  In_channel.read_all "fixtures/fills_page.json"
  |> Api.decode_fills
  |> Or_error.ok_exn
  |> List.hd_exn
;;

(* Six one-minute BTC round trips, four winners. *)
let fills =
  List.concat
    (List.init 6 ~f:(fun i ->
       let t = now_ms - Time_ns.Span.(to_int_ms hour) + (i * 120_000) in
       let base =
         { template with
           coin = Coin.of_string "BTC"
         ; sz = Size.of_string "1"
         ; px = Price.of_string "100000"
         ; fee = Usd.of_string "1"
         }
       in
       [ { base with time = t; side = Buy; start_position = Size.zero; tid = 2 * i }
       ; { base with
           time = t + 60_000
         ; side = Sell
         ; px = Price.of_string (if i % 3 = 2 then "99900" else "100050")
         ; start_position = Size.of_string "1"
         ; tid = (2 * i) + 1
         }
       ]))
;;

let%expect_test "collect, score, write reports and serve them" =
  Log.Global.set_output [];
  let%bind dir = Unix.mkdtemp "/tmp/hl-leaderboard-scoring" in
  let%bind fake =
    Fake_hl.start
      ~leaderboard:(In_channel.read_all "fixtures/leaderboard.json")
      ~fills:[ a1, fills ]
      ~state:(In_channel.read_all "fixtures/clearinghouse_state.json")
      ~portfolio:(In_channel.read_all "fixtures/portfolio.json")
      ()
  in
  let api =
    Api.create
      ~base_url:(Fake_hl.base_url fake)
      ~leaderboard_url:(Fake_hl.leaderboard_url fake)
      ~rate_limit:(Rate_limit.create ~refill_per_minute:1_000_000_000 ())
      Local
  in
  let config =
    { (Collect.Config.default ~dir) with
      top_n = 1
    ; windows = [ Week; Month ]
    ; min_account_value = 0.
    }
  in
  let%bind summary = Collect.run ~now:(fun () -> now) api config in
  ignore (Or_error.ok_exn summary : Collect.Summary.t);
  let%bind () = Fake_hl.close fake in
  let%bind dataset = Dataset.load dir >>| Or_error.ok_exn in
  let%bind scored = Scoring.score_all ~dir dataset in
  List.iter scored ~f:(fun s ->
    let r = s.report.record in
    print_s
      [%message
        ""
          ~address:(s.address : Address.t)
          ~fills:(r.fills : int)
          ~source:(r.equity_source : Leader_scoring.Track_record.Equity_source.t)
          ~trades:(List.length r.trades : int)
          ~eligible:(s.ranked.eligible : bool)
          ~reasons:(s.ranked.reasons : string list)]);
  let%bind () = Scoring.write_reports ~dir scored in
  let entries = Rank.rank ~min_trades:1 ~now_ms dataset in
  let summaries =
    List.map scored ~f:(fun s -> Address.to_string s.address, Scoring.summary_json s)
    |> String.Map.of_alist_exn
  in
  let leaders = dir ^/ "leaders.json" in
  let%bind () =
    Writer.save
      leaders
      ~contents:
        (Yojson.Safe.to_string
           (Rank.to_json
              ~scoring:(fun a -> Map.find summaries (Address.to_string a))
              ~generated_at:now
              entries))
  in
  let%bind server = Server.start ~dir ~leaders ~port:0 in
  let get path =
    let uri = Uri.of_string (sprintf "http://127.0.0.1:%d%s" (Server.port server) path) in
    let%bind _, body = Cohttp_async.Client.get uri in
    Cohttp_async.Body.to_string body >>| Yojson.Safe.from_string
  in
  let open Yojson.Safe.Util in
  let%bind board = get "/leaders" in
  board
  |> member "leaders"
  |> to_list
  |> List.iter ~f:(fun l ->
    print_endline (member "scoring" l |> keys |> String.concat ~sep:" "));
  let%bind detail = get ("/leaders/" ^ Address.to_string a1) in
  let report = member "report" detail in
  print_s
    [%message
      ""
        ~report_keys:(keys report : string list)
        ~metrics:(member "metrics" report |> to_list |> List.length : int)];
  let%bind catalog = get "/scoring/metrics" in
  printf "catalog: %d metrics\n" (List.length (to_list catalog));
  let%bind () = Server.close server in
  [%expect
    {|
    ((address 0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf) (fills 12)
     (source Venue) (trades 91) (eligible true) (reasons ()))
    ((address 0x399965e15d4e61ec3529cc98b7f7ebb93b733336) (fills 0)
     (source Venue) (trades 86) (eligible false)
     (reasons ("0 closed trades, 5 needed")))
    score rank percentile eligible predicted_forward_sharpe capacity_usd alerts worst_alert total_return sharpe sortino max_drawdown win_rate leverage_p95 trades
    score rank percentile eligible predicted_forward_sharpe capacity_usd alerts worst_alert total_return sharpe sortino max_drawdown win_rate leverage_p95 trades
    ((report_keys
      (account equity_source from_ms until_ms fills fills_truncated bar_seconds
       score predicted_forward_sharpe metrics equity_curve capacity alerts))
     (metrics 34))
    catalog: 34 metrics
    |}];
  return ()
;;
