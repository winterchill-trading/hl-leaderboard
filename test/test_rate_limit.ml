open! Core
open! Async
open Hl_leaderboard

let start = Time_ns.of_string_with_utc_offset "2026-10-13 00:00:00Z"

let%expect_test "a full bucket serves a burst, then paces at the refill rate" =
  let time_source = Time_source.create ~now:start () in
  let t =
    Rate_limit.create
      ~time_source:(Time_source.read_only time_source)
      ~refill_per_minute:1200
      ()
  in
  let log = Queue.create () in
  let elapsed () =
    Time_ns.diff (Time_source.now time_source) start |> Time_ns.Span.to_string_hum
  in
  (* 60 requests of weight 20 drain the bucket; three more must wait 1 s each (20 tokens
     at 20 per second). *)
  let served = ref 0 in
  (* [List.init] calls [f] from the last index down, so number requests by service order
     instead. *)
  let requests =
    List.init 63 ~f:(fun _ ->
      let%map () = Rate_limit.acquire t ~weight:20 in
      incr served;
      if !served > 58
      then Queue.enqueue log (sprintf "request %d at %s" !served (elapsed ())))
  in
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  let rec drive () =
    match Time_source.next_alarm_fires_at time_source with
    | None -> return ()
    | Some at ->
      let%bind () = Time_source.advance_by_alarms time_source ~to_:at in
      let%bind () = Scheduler.yield_until_no_jobs_remain () in
      drive ()
  in
  let%bind () = drive () in
  let%bind () = Deferred.all_unit requests in
  Queue.iter log ~f:print_endline;
  print_s
    [%message
      ""
        ~total_weight:(Rate_limit.total_weight t : int)
        ~total_wait:(Rate_limit.total_wait t : Time_ns.Span.t)];
  [%expect
    {|
    request 59 at 0ns
    request 60 at 0ns
    request 61 at 1s
    request 62 at 2s
    request 63 at 3s
    ((total_weight 1260) (total_wait 3s))
    |}];
  return ()
;;

let%expect_test "weights" =
  List.iter
    [ "clearinghouseState", 0; "userFillsByTime", 2000; "userFillsByTime", 19; "meta", 0 ]
    ~f:(fun (type_, items) ->
      printf
        "%s up front %d, after %d items %d\n"
        type_
        (Rate_limit.Weight.info type_)
        items
        (Rate_limit.Weight.per_items type_ ~items));
  [%expect
    {|
    clearinghouseState up front 2, after 0 items 0
    userFillsByTime up front 20, after 2000 items 100
    userFillsByTime up front 20, after 19 items 0
    meta up front 20, after 0 items 0
    |}];
  return ()
;;

let%expect_test "an oversized request is charged the capacity" =
  let time_source = Time_source.create ~now:start () in
  let t =
    Rate_limit.create
      ~time_source:(Time_source.read_only time_source)
      ~capacity:10
      ~refill_per_minute:60
      ()
  in
  let%bind () = Rate_limit.acquire t ~weight:100 in
  printf
    "available %.1f, total weight %d\n"
    (Rate_limit.available t)
    (Rate_limit.total_weight t);
  [%expect {| available 0.0, total weight 10 |}];
  return ()
;;
