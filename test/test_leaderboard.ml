open! Core
open Hl_leaderboard

let fixture () =
  In_channel.read_all "fixtures/leaderboard.json"
  |> Leaderboard.of_string
  |> Or_error.ok_exn
;;

let print_rows rows =
  List.iter rows ~f:(fun (row : Leaderboard.Row.t) ->
    let pnl w =
      match Leaderboard.Row.performance row w with
      | Some p -> Float.to_string_hum ~decimals:0 p.pnl
      | None -> "-"
    in
    printf
      "%s value=%s day=%s week=%s month=%s allTime=%s%s\n"
      (Hl_protocol.Address.to_string row.address)
      (Float.to_string_hum ~decimals:0 row.account_value)
      (pnl Day)
      (pnl Week)
      (pnl Month)
      (pnl All_time)
      (match row.display_name with
       | Some n -> " name=" ^ n
       | None -> ""))
;;

let%expect_test "decode a slice of a real mainnet leaderboard" =
  let t = fixture () in
  print_rows t;
  [%expect
    {|
    0x85ecf584f25db6f146718b86d493e33c5af72052 value=61_849_871 day=-764_342 week=-2_200_466 month=-816_730 allTime=4_069_863
    0xf5d81a135f756ca16544e53c20fc20643ec3ad53 value=73_971_880 day=2_540_096 week=3_346_893 month=-2_561_073 allTime=-5_733_789
    0x399965e15d4e61ec3529cc98b7f7ebb93b733336 value=24_752_287 day=-5_723 week=324_061 month=1_617_114 allTime=12_125_291
    0x8c625ff57d8a4374784c7eff585dfdc42ccec974 value=5_471_496 day=-53_732 week=225_362 month=875_030 allTime=2_475_778
    0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf value=121_558_287 day=5_273_730 week=13_624_980 month=-1_759_287 allTime=56_924_353
    0x7b7f72a28fe109fa703eeed7984f2a8a68fedee2 value=7_045_111 day=-9_930 week=157_175 month=318_670 allTime=-25_479_742 name=desk-seven
    |}]
;;

let%expect_test "top and candidates" =
  let t = fixture () in
  print_endline "top 2 by week";
  print_rows (Leaderboard.top t ~window:Week ~n:2);
  print_endline "candidates, top 2 by day and allTime";
  print_rows (Leaderboard.candidates t ~n:2 ~windows:[ Day; All_time ]);
  print_endline "account value >= 50M, top 1 by month";
  print_rows (Leaderboard.top ~min_account_value:50e6 t ~window:Month ~n:1);
  [%expect
    {|
    top 2 by week
    0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf value=121_558_287 day=5_273_730 week=13_624_980 month=-1_759_287 allTime=56_924_353
    0xf5d81a135f756ca16544e53c20fc20643ec3ad53 value=73_971_880 day=2_540_096 week=3_346_893 month=-2_561_073 allTime=-5_733_789
    candidates, top 2 by day and allTime
    0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf value=121_558_287 day=5_273_730 week=13_624_980 month=-1_759_287 allTime=56_924_353
    0xf5d81a135f756ca16544e53c20fc20643ec3ad53 value=73_971_880 day=2_540_096 week=3_346_893 month=-2_561_073 allTime=-5_733_789
    0x399965e15d4e61ec3529cc98b7f7ebb93b733336 value=24_752_287 day=-5_723 week=324_061 month=1_617_114 allTime=12_125_291
    account value >= 50M, top 1 by month
    0x85ecf584f25db6f146718b86d493e33c5af72052 value=61_849_871 day=-764_342 week=-2_200_466 month=-816_730 allTime=4_069_863
    |}]
;;

let%expect_test "JSON round trip" =
  let t = fixture () in
  let t' = Leaderboard.to_json t |> Leaderboard.of_json |> Or_error.ok_exn in
  print_s [%message (List.equal Leaderboard.Row.equal t t' : bool)];
  [%expect {| ("List.equal Leaderboard.Row.equal t t'" true) |}]
;;

let%expect_test "malformed rows name the index" =
  let bad =
    {|{"leaderboardRows": [{"ethAddress": "0x01", "accountValue": "1", "windowPerformances": []},
                           {"ethAddress": "0x02", "accountValue": "x"}]}|}
  in
  print_s [%sexp (Leaderboard.of_string bad : Leaderboard.t Or_error.t)];
  [%expect
    {| (Error (("leaderboard row" (i 1)) (Invalid_argument "Float.of_string x"))) |}]
;;
