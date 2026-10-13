open! Core
open Hl_leaderboard

let%expect_test "decode a mainnet portfolio and build the month curve" =
  let t =
    In_channel.read_all "fixtures/portfolio.json"
    |> Portfolio.of_string
    |> Or_error.ok_exn
  in
  List.iter t ~f:(fun (name, s) ->
    printf
      "%s points=%d/%d vlm=%.0f\n"
      name
      (List.length s.account_value)
      (List.length s.pnl)
      s.vlm);
  let curve = Portfolio.find t "month" |> Option.bind ~f:Portfolio.equity_curve in
  (match curve with
   | None -> print_endline "no curve"
   | Some c ->
     let first = List.hd_exn c
     and last = List.last_exn c in
     printf "curve: %d points, %.0f -> %.0f\n" (List.length c) first.equity last.equity);
  [%expect
    {|
    day points=13/13 vlm=0
    week points=66/66 vlm=1004
    month points=47/47 vlm=1065680
    allTime points=106/106 vlm=2417606881
    perpDay points=13/13 vlm=0
    perpWeek points=67/67 vlm=0
    perpMonth points=52/52 vlm=963729
    perpAllTime points=128/128 vlm=2387256665
    curve: 47 points, 30625823 -> 47185629
    |}]
;;

let%expect_test "no curve from an empty or non-positive window" =
  let s =
    Portfolio.of_string
      {|[["perpMonth", {"accountValueHistory": [[1, "0.0"]], "pnlHistory": [[1, "0.0"]], "vlm": 0}], ["day", {"accountValueHistory": [], "pnlHistory": [], "vlm": "0"}]]|}
  in
  let t = Or_error.ok_exn s in
  List.iter t ~f:(fun (name, series) ->
    printf "%s %b\n" name (Option.is_some (Portfolio.equity_curve series)));
  print_s [%sexp (Portfolio.of_string "{}" : Portfolio.t Or_error.t)];
  [%expect
    {|
    perpMonth false
    day false
    (Error (portfolio ("portfolio is not a list" {})))
    |}]
;;
