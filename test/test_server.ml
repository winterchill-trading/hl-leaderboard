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

(* Six one-minute long round trips on BTC, alternating +40 / -10. *)
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
       [ { base with
           time = t
         ; side = Buy
         ; start_position = Size.zero
         ; closed_pnl = Usd.zero
         ; tid = 2 * i
         }
       ; { base with
           time = t + 60_000
         ; side = Sell
         ; start_position = Size.of_string "1"
         ; closed_pnl = Usd.of_string (if i % 2 = 0 then "40" else "-10")
         ; tid = (2 * i) + 1
         }
       ]))
;;

let get port path =
  let uri = Uri.of_string (sprintf "http://127.0.0.1:%d%s" port path) in
  let%bind resp, body = Cohttp_async.Client.get uri in
  let%map body = Cohttp_async.Body.to_string body in
  let status = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
  let cors =
    Cohttp.Header.get (Cohttp.Response.headers resp) "access-control-allow-origin"
  in
  status, cors, body
;;

let%expect_test "rank a collected directory and serve it" =
  Log.Global.set_output [];
  let%bind dir = Unix.mkdtemp "/tmp/hl-leaderboard-serve" in
  let%bind fake =
    Fake_hl.start
      ~leaderboard:(In_channel.read_all "fixtures/leaderboard.json")
      ~fills:[ a1, fills ]
      ~state:(In_channel.read_all "fixtures/clearinghouse_state.json")
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
  let%bind dataset = Dataset.load dir in
  let entries = Rank.rank ~min_trades:1 ~now_ms (Or_error.ok_exn dataset) in
  let leaders = dir ^/ "leaders.json" in
  let%bind server = Server.start ~dir ~leaders ~port:0 in
  let port = Server.port server in
  let show path =
    let%map status, cors, body = get port path in
    printf "%s -> %d cors=%s\n" path status (Option.value cors ~default:"-");
    body
  in
  let%bind body = show "/leaders" in
  print_endline body;
  [%expect
    {|
    /leaders -> 503 cors=*
    {"error":"no ranking yet; run hl-leaderboard rank"}
    |}];
  let%bind () =
    Writer.save
      leaders
      ~contents:(Yojson.Safe.to_string (Rank.to_json ~generated_at:now entries))
  in
  let%bind body = show "/leaders?limit=1" in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  json
  |> member "leaders"
  |> to_list
  |> List.iter ~f:(fun l ->
    printf
      "rank=%s address=%s trades=%d\n"
      (Yojson.Safe.to_string (member "rank" l))
      (member "address" l |> to_string)
      (member "components" l |> member "trade_count" |> to_int));
  [%expect
    {|
    /leaders?limit=1 -> 200 cors=*
    rank=1 address=0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf trades=6
    |}];
  let%bind body = show ("/leaders/" ^ Address.to_string a1 ^ "?limit=2") in
  let json = Yojson.Safe.from_string body in
  print_s
    [%message
      ""
        ~entry_rank:
          (Yojson.Safe.to_string (json |> member "entry" |> member "rank") : string)
        ~fill_count:(json |> member "fill_count" |> to_int : int)
        ~fills_returned:(json |> member "fills" |> to_list |> List.length : int)
        ~newest_first:
          (json
           |> member "fills"
           |> to_list
           |> List.map ~f:(fun f -> member "time" f |> to_int)
           : int list)
        ~equity_points:(json |> member "equity_curve" |> to_list |> List.length : int)
        ~positions:(json |> member "positions" |> to_list |> List.length : int)];
  [%expect
    {|
    /leaders/0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf?limit=2 -> 200 cors=*
    ((entry_rank 1) (fill_count 12) (fills_returned 2)
     (newest_first (1791868260000 1791868200000)) (equity_points 14)
     (positions 86))
    |}];
  let%bind (_ : string) = show "/leaders/not-an-address" in
  let%bind (_ : string) = show ("/leaders/0x" ^ String.make 40 'a') in
  let%bind (_ : string) = show "/leaders?limit=x" in
  let%bind (_ : string) = show "/nope" in
  let%bind body = show "/health" in
  print_endline body;
  [%expect
    {|
    /leaders/not-an-address -> 400 cors=*
    /leaders/0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -> 404 cors=*
    /leaders?limit=x -> 400 cors=*
    /nope -> 404 cors=*
    /health -> 200 cors=*
    "ok"
    |}];
  Server.close server
;;
