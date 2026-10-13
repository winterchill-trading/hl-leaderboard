open! Core
open Hl_leaderboard
open Hl_protocol

let template =
  In_channel.read_all "fixtures/fills_page.json"
  |> Api.decode_fills
  |> Or_error.ok_exn
  |> List.hd_exn
;;

let hour = 3_600_000
let usd x = Usd.of_string (Float.to_string x)

let fill ?(coin = "BTC") ~time ~side ~start ~pnl () =
  { template with
    coin = Coin.of_string coin
  ; time
  ; side
  ; sz = Size.of_string "1"
  ; px = Price.of_string "100000"
  ; start_position = Size.of_string (Int.to_string start)
  ; closed_pnl = usd pnl
  ; fee = usd 1.
  ; tid = time
  }
;;

(* [n] long round trips of one hour each, every 4 hours, with the given pnls. *)
let trips pnls =
  List.concat_mapi pnls ~f:(fun i pnl ->
    let t = 1_000_000 + (i * 4 * hour) in
    [ fill ~time:t ~side:Buy ~start:0 ~pnl:0. ()
    ; fill ~time:(t + hour) ~side:Sell ~start:1 ~pnl ()
    ])
;;

let leader address fills ~value : Dataset.Leader.t =
  let address = Address.of_string address in
  { address
  ; row =
      Some
        { Board.Row.eth_address = address
        ; account_value = value
        ; window_performances = []
        ; prize = 0
        ; display_name = None
        }
  ; fills
  ; state = None
  ; portfolio = None
  }
;;

let%expect_test "scored fills: perps only, with a synthetic open for a position already \
                 held"
  =
  let fills =
    [ fill ~time:1 ~side:Sell ~start:1 ~pnl:50. () (* closes a position opened earlier *)
    ; fill ~coin:"@107" ~time:2 ~side:Buy ~start:0 ~pnl:0. ()
    ; fill ~time:3 ~side:Buy ~start:0 ~pnl:0. ()
    ; fill ~coin:"xyz:NVDA" ~time:4 ~side:Sell ~start:0 ~pnl:0. ()
    ; fill ~time:5 ~side:Sell ~start:1 ~pnl:10. ()
    ]
  in
  List.iter (Rank.scored_fills fills) ~f:(fun f ->
    printf
      "%d %s %s %s start=%s tid=%d\n"
      f.time
      (Coin.to_string f.coin)
      (Side.to_wire f.side)
      (Size.to_string f.sz)
      (Size.to_string f.start_position)
      f.tid);
  [%expect
    {|
    0 BTC B 1 start=0 tid=-1
    1 BTC A 1 start=1 tid=1
    3 BTC B 1 start=0 tid=3
    4 xyz:NVDA A 1 start=0 tid=4
    5 BTC A 1 start=1 tid=5
    |}]
;;

let%expect_test "rank three leaders" =
  let mk = leader in
  let dataset =
    { Dataset.started = None
    ; leaders =
        [ mk "0x01" (trips (List.init 25 ~f:(fun _ -> 100.))) ~value:10_000.
        ; mk
            "0x02"
            (trips (List.init 25 ~f:(fun i -> if i % 2 = 0 then 300. else -200.)))
            ~value:10_000.
        ; mk "0x03" (trips [ 5000.; 5000. ]) ~value:10_000.
        ]
    }
  in
  let entries = Rank.rank ~now_ms:(1_000_000 + (200 * hour)) dataset in
  List.iter entries ~f:(fun e ->
    print_s
      [%message
        ""
          ~rank:(e.rank : int option)
          ~address:(e.address : Address.t)
          ~score:(e.score : Hl_copy_core.Score.t)]);
  [%expect
    {|
    ((rank (1)) (address 0x01)
     (score
      ((pnl 2450) (return_ 0.32450331125827814)
       (max_drawdown 0.00013245033112582781) (win_rate 1) (trade_count 25)
       (avg_hold_ns 3600000000000) (consistency 0.5) (score 0.24334524801543791))))
    ((rank (2)) (address 0x02)
     (score
      ((pnl 1450) (return_ 0.16959064327485379)
       (max_drawdown 0.022943037974683545) (win_rate 0.52) (trade_count 25)
       (avg_hold_ns 3600000000000) (consistency 0.5) (score 0.12427478902953584))))
    ((rank ()) (address 0x03)
     (score
      ((pnl 9996) (return_ 2499) (max_drawdown 0.25) (win_rate 1) (trade_count 2)
       (avg_hold_ns 3600000000000) (consistency 0.25) (score 117.140625))))
    |}];
  Rank.to_json ~generated_at:Time_ns.epoch (List.take entries 1)
  |> Yojson.Safe.pretty_to_string
  |> print_endline;
  [%expect
    {|
    {
      "generated_at": "1970-01-01T00:00:00.000000Z",
      "formula": "score = return * (1 - max_drawdown) * (0.5 + 0.5 * consistency) * min(1, trade_count / 20); see hl-copy-core Score",
      "leaders": [
        {
          "rank": 1,
          "address": "0x01",
          "display_name": null,
          "account_value": 10000.0,
          "leaderboard": {},
          "fills": 50,
          "scored_fills": 50,
          "first_fill_ms": 1000000,
          "last_fill_ms": 350200000,
          "positions": 0,
          "curve_source": "fills",
          "truncated": false,
          "score": 0.24334524801543791,
          "components": {
            "pnl": 2450.0,
            "return": 0.32450331125827814,
            "max_drawdown": 0.00013245033112582781,
            "win_rate": 1.0,
            "trade_count": 25,
            "avg_hold_hours": 1.0,
            "consistency": 0.5
          }
        }
      ]
    }
    |}]
;;
