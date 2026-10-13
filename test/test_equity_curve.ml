open! Core
open Hl_leaderboard
open Hl_protocol

let template =
  In_channel.read_all "fixtures/fills_page.json"
  |> Api.decode_fills
  |> Or_error.ok_exn
  |> List.hd_exn
;;

let fill ~time ~pnl ~fee =
  { template with
    time
  ; closed_pnl = Usd.of_string (Float.to_string pnl)
  ; fee = Usd.of_string (Float.to_string fee)
  }
;;

let%expect_test "walk back from the account value" =
  let fills =
    [ fill ~time:1000 ~pnl:0. ~fee:0.
    ; fill ~time:2000 ~pnl:100. ~fee:1.
    ; fill ~time:3000 ~pnl:(-50.) ~fee:1.
    ; fill ~time:4000 ~pnl:0. ~fee:(-0.5)
    ]
  in
  print_s
    [%sexp
      (Equity_curve.of_fills ~account_value:1000. ~now_ms:5000 fills : Equity_curve.t)];
  [%expect
    {|
    (((time_ms 999) (equity 951.5)) ((time_ms 2000) (equity 1050.5))
     ((time_ms 3000) (equity 999.5)) ((time_ms 4000) (equity 1000))
     ((time_ms 5000) (equity 1000)))
    |}];
  print_s
    [%sexp (Equity_curve.of_fills ~account_value:1000. ~now_ms:5000 [] : Equity_curve.t)];
  [%expect {| (((time_ms 5000) (equity 1000))) |}]
;;

let%test_unit "first point is the value less everything realized; last is the value" =
  let gen =
    Quickcheck.Generator.(
      list (both (Int.gen_incl (-1_000_000) 1_000_000) (Int.gen_incl (-1000) 1000)))
  in
  Quickcheck.test gen ~sexp_of:[%sexp_of: (int * int) list] ~f:(fun xs ->
    let fills =
      List.mapi xs ~f:(fun i (pnl, fee) ->
        fill
          ~time:(1000 + i)
          ~pnl:(Float.of_int pnl /. 100.)
          ~fee:(Float.of_int fee /. 100.))
    in
    let curve = Equity_curve.of_fills ~account_value:5000. ~now_ms:1_000_000 fills in
    let total = List.sum (module Float) fills ~f:Equity_curve.realized in
    let first = List.hd_exn curve
    and last = List.last_exn curve in
    [%test_pred: float] (fun d -> Float.(abs d < 1e-6)) (last.equity -. 5000.);
    if not (List.is_empty fills)
    then
      [%test_pred: float]
        (fun d -> Float.(abs d < 1e-6))
        (first.equity -. (5000. -. total));
    (* Nothing else moves equity, so the walk forward over the fills ends exactly at the
       account value: the step at [now] is zero. *)
    match List.drop_last_exn curve |> List.last with
    | None -> ()
    | Some p -> [%test_pred: float] (fun d -> Float.(abs d < 1e-6)) (p.equity -. 5000.))
;;
