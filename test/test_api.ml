open! Core
open! Async
open Hl_leaderboard

let%expect_test "decode real fills and account state" =
  (* The first fills of a real 2000-fill mainnet page (all 2000 decoded when it was
     captured): spot coins ("@210") and builder-deployed perps ("xyz:NVDA") included. *)
  let page =
    In_channel.read_all "fixtures/fills_page.json" |> Api.decode_fills |> Or_error.ok_exn
  in
  List.iter page ~f:(fun f -> print_s [%sexp (f : Hl_protocol.User_fill.t)]);
  let st =
    In_channel.read_all "fixtures/clearinghouse_state.json"
    |> Api.decode_clearinghouse_state
    |> Or_error.ok_exn
  in
  print_s [%sexp (st.margin_summary : Hl_protocol.Clearinghouse_state.Margin_summary.t)];
  print_s [%message (List.length st.positions : int)];
  [%expect
    {|
    ((coin @210) (px 0.083432) (sz 127.6) (side Buy) (time 1791868226164)
     (start_position 182267.739985) (dir Buy) (closed_pnl 0)
     (hash 0x1aa54e78530e0c5b1c1f044672b5b902062b005dee012b2dbe6df9cb1201e645)
     (oid 572794944743) (crossed false) (fee -0.00031937) (tid 340738672993873)
     (fee_token (USDC)) (cloid (0x24604768530198016ff12fffffffffff)))
    ((coin @210) (px 0.083432) (sz 0.1) (side Buy) (time 1791868226164)
     (start_position 182395.339985) (dir Buy) (closed_pnl 0)
     (hash 0x7156c3ea84a2f4a672d0044672b5b902065500d01fa61378151f6f3d43a6ce91)
     (oid 572794944743) (crossed false) (fee -0.00000025) (tid 351744403284489)
     (fee_token (USDC)) (cloid (0x24604768530198016ff12fffffffffff)))
    ((coin xyz:NVDA) (px 224.58) (sz 14.529) (side Sell) (time 1791868226470)
     (start_position 1242.506) (dir "Close Long") (closed_pnl 7.831131)
     (hash 0xa6587e86dce95bf5a7d2044672b5bd020b65006c77ec7ac74a2129d99bed35e0)
     (oid 572794877077) (crossed false) (fee -0.009788) (tid 1083038902969507)
     (fee_token (USDC)) (cloid (0x1580291868221108940ff10fffffffff)))
    ((coin XPL) (px 0.083642) (sz 4379) (side Sell) (time 1791868226536)
     (start_position -2812617) (dir "Open Short") (closed_pnl 0)
     (hash 0x902816b342dbcc9391a1044672b5be0204570098dddeeb6533f0c20601dfa67e)
     (oid 572794955490) (crossed false) (fee -0.010988) (tid 823927423911328)
     (fee_token (USDC)) (cloid (0x75891868226334374ff10fffffffffff)))
    ((coin xyz:QCOM) (px 172.67) (sz 0.35) (side Buy) (time 1791868226536)
     (start_position -72.24) (dir "Close Short") (closed_pnl -0.289765)
     (hash 0xf5cf03e975fe518af748044672b5be02045900cf10f1705d9997af3c34f22b75)
     (oid 572794955841) (crossed true) (fee 0.002199) (tid 945412686878894)
     (fee_token (USDC)) (cloid (0x24604749915910400ff22fffffffffff)))
    ((coin HYPE) (px 82.405) (sz 6.06) (side Buy) (time 1791868227075)
     (start_position -47146.22) (dir "Close Short") (closed_pnl 11.20797)
     (hash 0x0000000000000000000000000000000000000000000000000000000000000000)
     (oid 572794957290) (crossed false) (fee -0.014981) (tid 537922028750916)
     (fee_token (USDC)) (cloid (0x65991868226520196ff10fffffffffff)))
    ((account_value 56472433.084829) (total_ntl_pos 101143769.61656999)
     (total_raw_usd 112464721.47679099) (total_margin_used 12045858.24335099))
    ("List.length st.positions" 86)
    |}];
  return ()
;;
