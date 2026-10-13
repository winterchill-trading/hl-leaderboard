open! Core
open! Async
open Hl_leaderboard

let ts = Time_ns.of_string_with_utc_offset "2026-10-13 06:25:07.123456789Z"

let%expect_test "format and read back, dropping a truncated tail" =
  print_string (Raw_log.line ~recv_ts:ts "{\"a\":\n 1}");
  [%expect {| 2026-10-13T06:25:07.123456Z {"a":  1} |}];
  let%bind () =
    Async_unix.Unix.mkdtemp "/tmp/hl-leaderboard-test"
    >>= fun dir ->
    let path = dir ^/ "x/y.ndjson" in
    let%bind () = Raw_log.append path ~recv_ts:ts "[1,2]" in
    let%bind () =
      Raw_log.append path ~recv_ts:(Time_ns.add ts Time_ns.Span.second) "[]"
    in
    let%bind () =
      Writer.with_file ~append:true path ~f:(fun w ->
        Writer.write w "2026-10-13T06:25:09.0000";
        return ())
    in
    let%map entries = Raw_log.read path in
    (* Print timestamps through [format_ts]: the sexp of a [Time_ns.t] uses the local
       zone, which differs between a laptop and CI. *)
    Or_error.ok_exn entries
    |> List.iter ~f:(fun { Raw_log.Entry.recv_ts; body } ->
      printf "%s %s\n" (Raw_log.format_ts recv_ts) body)
  in
  [%expect
    {|
    2026-10-13T06:25:07.123456Z [1,2]
    2026-10-13T06:25:08.123456Z []
    |}];
  let%map missing = Raw_log.read "/nonexistent/file.ndjson" in
  print_s [%sexp (missing : Raw_log.Entry.t list Or_error.t)];
  [%expect {| (Ok ()) |}]
;;
