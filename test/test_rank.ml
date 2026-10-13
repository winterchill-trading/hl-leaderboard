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
  }
;;

let%expect_test "scored fills: perps only, from the first flat point per coin" =
  let fills =
    [ fill ~time:1 ~side:Sell ~start:3 ~pnl:50. () (* closes a position opened earlier *)
    ; fill ~coin:"@107" ~time:2 ~side:Buy ~start:0 ~pnl:0. ()
    ; fill ~time:3 ~side:Buy ~start:0 ~pnl:0. ()
    ; fill ~coin:"xyz:NVDA" ~time:4 ~side:Sell ~start:0 ~pnl:0. ()
    ; fill ~time:5 ~side:Sell ~start:1 ~pnl:10. ()
    ]
  in
  List.iter (Rank.scored_fills fills) ~f:(fun f ->
    printf "%d %s\n" f.time (Coin.to_string f.coin));
  [%expect {| |}]
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
  [%expect {| |}];
  Rank.to_json ~generated_at:Time_ns.epoch (List.take entries 1)
  |> Yojson.Safe.pretty_to_string
  |> print_endline;
  [%expect {| |}]
;;
