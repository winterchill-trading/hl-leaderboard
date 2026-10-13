open! Core
open! Async
open Hl_leaderboard
open Hl_protocol

let template =
  In_channel.read_all "fixtures/fills_page.json"
  |> Api.decode_fills
  |> Or_error.ok_exn
  |> List.hd_exn
;;

let fill ~time ~tid = { template with time; tid }

(* A fake server over a fixed history, with a small page limit replaced by
   [Fill_pages.page_limit] fills per page. *)
let serve history ~start_time =
  let page =
    List.filter history ~f:(fun (f : User_fill.t) -> f.time >= start_time)
    |> Fn.flip List.take Fill_pages.page_limit
  in
  return (Ok (start_time, page))
;;

let run ?max_pages ?seen ~start_time history =
  let requests = Queue.create () in
  let%map result =
    Fill_pages.walk
      ?max_pages
      ?seen
      ~start_time
      ~fetch:(serve history)
      ~on_page:(fun start page ->
        Queue.enqueue requests (start, List.length page);
        return ())
      ()
  in
  let result = Or_error.ok_exn result in
  print_s
    [%message
      ""
        ~requests:(Queue.to_list requests : (int * int) list)
        ~fills:(List.length result.fills : int)
        ~distinct_tids:
          (List.map result.fills ~f:(fun f -> f.tid)
           |> List.dedup_and_sort ~compare:Int.compare
           |> List.length
           : int)
        ~complete:(result.complete : bool)
        ~next_start:(result.next_start : int)]
;;

let%expect_test "4500 fills, two per millisecond, cross page boundaries without loss" =
  let history = List.init 4500 ~f:(fun i -> fill ~time:(1000 + (i / 2)) ~tid:i) in
  let%bind () = run ~start_time:0 history in
  [%expect
    {|
    ((requests ((0 2000) (1999 2000) (2998 504))) (fills 4500)
     (distinct_tids 4500) (complete true) (next_start 3249))
    |}];
  let%bind () = run ~max_pages:2 ~start_time:0 history in
  [%expect
    {|
    ((requests ((0 2000) (1999 2000))) (fills 3998) (distinct_tids 3998)
     (complete false) (next_start 2998))
    |}];
  return ()
;;

let%expect_test "a page entirely inside one millisecond moves the start on" =
  let history =
    List.init 2000 ~f:(fun i -> fill ~time:5 ~tid:i)
    @ List.init 10 ~f:(fun i -> fill ~time:9 ~tid:(10_000 + i))
  in
  let%bind () = run ~start_time:0 history in
  [%expect
    {|
    ((requests ((0 2000) (5 2000) (6 10))) (fills 2010) (distinct_tids 2010)
     (complete true) (next_start 9))
    |}];
  return ()
;;

let%expect_test "resume skips fills seen in an earlier run" =
  let history = List.init 2100 ~f:(fun i -> fill ~time:(1000 + i) ~tid:i) in
  let seen = List.take history 2000 in
  let%bind () = run ~seen ~start_time:2999 history in
  [%expect
    {|
    ((requests ((2999 101))) (fills 100) (distinct_tids 100) (complete true)
     (next_start 3099))
    |}];
  return ()
;;
