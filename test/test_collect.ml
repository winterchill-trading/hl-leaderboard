open! Core
open! Async
open Hl_leaderboard
open Hl_protocol

let now = Time_ns.of_string_with_utc_offset "2026-10-13 06:00:00Z"
let now_ms = Time_ns.to_int_ns_since_epoch now / 1_000_000
let a1 = Address.of_string "0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf"
let a2 = Address.of_string "0xf5d81a135f756ca16544e53c20fc20643ec3ad53"
let a3 = Address.of_string "0x399965e15d4e61ec3529cc98b7f7ebb93b733336"

let template =
  In_channel.read_all "fixtures/fills_page.json"
  |> Api.decode_fills
  |> Or_error.ok_exn
  |> List.hd_exn
;;

let history ~n ~step_ms =
  List.init n ~f:(fun i ->
    { template with
      time = now_ms - Time_ns.Span.(to_int_ms day) + (i * step_ms)
    ; tid = i
    })
;;

let config dir =
  { (Collect.Config.default ~dir) with
    top_n = 2
  ; windows = [ Week; All_time ]
  ; min_account_value = 0.
  }
;;

let api server =
  Api.create
    ~base_url:(Fake_hl.base_url server)
    ~leaderboard_url:(Fake_hl.leaderboard_url server)
    ~rate_limit:(Rate_limit.create ~refill_per_minute:1_000_000_000 ())
    ~max_attempts:2
    Local
;;

let print_requests server ~skip =
  List.drop (Fake_hl.requests server) skip |> List.iter ~f:print_endline
;;

let%expect_test "collect, fail one address, resume, start over" =
  Log.Global.set_output [];
  let%bind dir = Unix.mkdtemp "/tmp/hl-leaderboard-collect" in
  let%bind server =
    Fake_hl.start
      ~leaderboard:(In_channel.read_all "fixtures/leaderboard.json")
      ~fills:[ a1, history ~n:4500 ~step_ms:1000; a3, history ~n:30 ~step_ms:60_000 ]
      ~state:(In_channel.read_all "fixtures/clearinghouse_state.json")
      ()
  in
  Fake_hl.fail_state server a3 true;
  Fake_hl.throttle_next server 1;
  let run () =
    let%map summary = Collect.run ~now:(fun () -> now) (api server) (config dir) in
    print_s [%sexp (summary : Collect.Summary.t Or_error.t)]
  in
  let%bind () = run () in
  print_requests server ~skip:0;
  [%expect
    {|
    (Ok
     ((candidates 3) (collected 2) (failed 1) (fills 4500) (weight 372)
      (retries 2) (resumed false)))
    GET /leaderboard
    userFillsByTime 0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf
    userFillsByTime 0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf
    userFillsByTime 0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf
    userFillsByTime 0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf
    clearinghouseState 0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf
    portfolio 0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf
    userFillsByTime 0xf5d81a135f756ca16544e53c20fc20643ec3ad53
    clearinghouseState 0xf5d81a135f756ca16544e53c20fc20643ec3ad53
    portfolio 0xf5d81a135f756ca16544e53c20fc20643ec3ad53
    userFillsByTime 0x399965e15d4e61ec3529cc98b7f7ebb93b733336
    clearinghouseState 0x399965e15d4e61ec3529cc98b7f7ebb93b733336
    clearinghouseState 0x399965e15d4e61ec3529cc98b7f7ebb93b733336
    |}];
  let seen = List.length (Fake_hl.requests server) in
  Fake_hl.fail_state server a3 false;
  let%bind () = run () in
  print_requests server ~skip:seen;
  [%expect
    {|
    (Ok
     ((candidates 3) (collected 3) (failed 0) (fills 0) (weight 42) (retries 0)
      (resumed true)))
    userFillsByTime 0x399965e15d4e61ec3529cc98b7f7ebb93b733336
    clearinghouseState 0x399965e15d4e61ec3529cc98b7f7ebb93b733336
    portfolio 0x399965e15d4e61ec3529cc98b7f7ebb93b733336
    |}];
  let%bind dataset = Dataset.load dir in
  List.iter (Or_error.ok_exn dataset).leaders ~f:(fun l ->
    printf
      "%s fills=%d state=%b row=%b\n"
      (Address.to_string l.address)
      (List.length l.fills)
      (Option.is_some l.state)
      (Option.is_some l.row));
  [%expect
    {|
    0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf fills=4500 state=true row=true
    0xf5d81a135f756ca16544e53c20fc20643ec3ad53 fills=0 state=true row=true
    0x399965e15d4e61ec3529cc98b7f7ebb93b733336 fills=30 state=true row=true
    |}];
  let seen = List.length (Fake_hl.requests server) in
  let%bind () = run () in
  print_requests server ~skip:seen;
  [%expect
    {|
    (Ok
     ((candidates 3) (collected 3) (failed 0) (fills 0) (weight 126) (retries 0)
      (resumed false)))
    GET /leaderboard
    userFillsByTime 0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf
    clearinghouseState 0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf
    portfolio 0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf
    userFillsByTime 0xf5d81a135f756ca16544e53c20fc20643ec3ad53
    clearinghouseState 0xf5d81a135f756ca16544e53c20fc20643ec3ad53
    portfolio 0xf5d81a135f756ca16544e53c20fc20643ec3ad53
    userFillsByTime 0x399965e15d4e61ec3529cc98b7f7ebb93b733336
    clearinghouseState 0x399965e15d4e61ec3529cc98b7f7ebb93b733336
    portfolio 0x399965e15d4e61ec3529cc98b7f7ebb93b733336
    |}];
  let%bind files = Sys.readdir dir in
  let%bind raw = Sys.readdir (dir ^/ "raw") in
  print_s
    [%message
      (List.sort (Array.to_list files) ~compare:String.compare : string list)
        (List.sort (Array.to_list raw) ~compare:String.compare : string list)];
  let magic path =
    let s = In_channel.read_all path in
    String.prefix s 4, String.suffix s 4
  in
  print_s
    [%message
      (magic (Layout.leaders_parquet dir) : string * string)
        (magic (Layout.fills_parquet dir) : string * string)];
  [%expect
    {|
    (("List.sort (Array.to_list files) ~compare:String.compare"
      (_manifest fills.parquet leaders.parquet raw))
     ("List.sort (Array.to_list raw) ~compare:String.compare"
      (fills leaderboard state)))
    (("magic (Layout.leaders_parquet dir)" (PAR1 PAR1))
     ("magic (Layout.fills_parquet dir)" (PAR1 PAR1)))
    |}];
  Fake_hl.close server
;;
