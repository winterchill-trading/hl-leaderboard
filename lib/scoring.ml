open! Core
open! Async
open Hl_protocol
module LS = Leader_scoring
module Decode = Leader_scoring_hl.Hl_decode

let bodies path =
  match%map Raw_log.read path with
  | Ok entries -> entries
  | Error e ->
    Log.Global.info_s [%message "unreadable raw log" (path : string) (e : Error.t)];
    []
;;

let decode_all entries ~f =
  List.concat_map entries ~f:(fun (e : Raw_log.Entry.t) ->
    match
      Or_error.try_with (fun () -> Yojson.Safe.from_string e.body)
      |> Or_error.bind ~f:(f e)
    with
    | Ok items -> items
    | Error _ -> [])
;;

let history ~dir address =
  let%bind fill_pages = bodies (Layout.fills dir address) in
  let%bind funding_pages = bodies (Layout.funding dir address) in
  let%bind states = bodies (Layout.state dir address) in
  let%map portfolios = bodies (Layout.portfolio dir address) in
  let fills = decode_all fill_pages ~f:(fun _ j -> Decode.fills j) in
  let funding = decode_all funding_pages ~f:(fun _ j -> Decode.funding j) in
  let snapshots =
    decode_all states ~f:(fun e j ->
      Decode.snapshot ~time:e.recv_ts j |> Or_error.map ~f:List.return)
  in
  let equity_curve =
    match List.last portfolios with
    | None -> []
    | Some e ->
      (match
         Or_error.try_with (fun () -> Yojson.Safe.from_string e.body)
         |> Or_error.bind ~f:(Decode.portfolio ~window:"month")
       with
       | Ok curve -> curve
       | Error _ -> [])
  in
  let fetched_at =
    List.map
      (fill_pages @ funding_pages @ states @ portfolios)
      ~f:(fun (e : Raw_log.Entry.t) -> e.recv_ts)
    |> List.max_elt ~compare:Time_ns.compare
  in
  match fetched_at with
  | None -> Or_error.error_s [%message "nothing collected" (address : Address.t)]
  | Some fetched_at ->
    let fills_truncated =
      (* the venue keeps only the most recent fills: a long history whose first fill comes
         after the curve starts covers only its end *)
      match List.min_elt fills ~compare:LS.Fill.compare_by_time, List.hd equity_curve with
      | Some first, Some start when List.length fills >= 2000 ->
        Time_ns.( > ) first.time start.time
      | _ -> false
    in
    Ok
      (LS.History.normalize
         { LS.History.account = Address.to_string address
         ; venue = "hyperliquid"
         ; fetched_at
         ; fills
         ; funding
         ; snapshots
         ; equity_curve
         ; fills_truncated
         })
;;

let market ~dir =
  let books_dir = dir ^/ "raw" ^/ "books" in
  let%bind files =
    match%map Monitor.try_with (fun () -> Sys.readdir books_dir) with
    | Ok files -> Array.to_list files |> List.sort ~compare:String.compare
    | Error _ -> []
  in
  let%bind books =
    Deferred.List.filter_map ~how:`Sequential files ~f:(fun file ->
      let%map entries = bodies (books_dir ^/ file) in
      match List.last entries with
      | None -> None
      | Some e ->
        (match
           Or_error.try_with (fun () -> Yojson.Safe.from_string e.body)
           |> Or_error.bind ~f:Decode.book
         with
         | Ok book -> Some (book.coin, book)
         | Error _ -> None))
  in
  let%map market = bodies (Layout.market dir) in
  let open_interest =
    match List.last market with
    | None -> String.Map.empty
    | Some e ->
      Or_error.try_with (fun () -> Yojson.Safe.from_string e.body)
      |> Or_error.bind ~f:Decode.open_interest
      |> Result.ok
      |> Option.value ~default:String.Map.empty
  in
  String.Map.of_alist_reduce books ~f:(fun a _ -> a), open_interest
;;

module Scored = struct
  type t =
    { address : Address.t
    ; report : LS.Report.t
    ; ranked : LS.Score.Ranked.t
    }
end

let score_all ~dir (dataset : Dataset.t) =
  let%bind books, open_interest = market ~dir in
  let model = Lazy.force LS.Model.bundled in
  let%map reports =
    Deferred.List.filter_map ~how:`Sequential dataset.leaders ~f:(fun l ->
      match%map history ~dir l.address with
      | Error e ->
        Log.Global.info_s
          [%message "not scored" ~address:(l.address : Address.t) (e : Error.t)];
        None
      | Ok h ->
        let books = if Map.is_empty books then None else Some books in
        Some (l.address, LS.Report.create ?books ~open_interest ~model h))
  in
  let by_account =
    List.map reports ~f:(fun (a, _) -> Address.to_string a, a)
    |> String.Map.of_alist_reduce ~f:(fun a _ -> a)
  in
  LS.Report.rank (List.map reports ~f:snd)
  |> List.map ~f:(fun (report, ranked) ->
    { Scored.address = Map.find_exn by_account ranked.account; report; ranked })
;;

let num x = if Float.is_finite x then `Float x else `Null

let opt = function
  | Some x -> num x
  | None -> `Null
;;

let summary_json (s : Scored.t) =
  let m metric = opt (LS.Metrics.get s.report.metrics metric) in
  let worst =
    List.map s.report.alerts ~f:(fun a -> a.severity)
    |> List.max_elt ~compare:LS.Alerts.Severity.compare
  in
  `Assoc
    [ "score", num s.ranked.score
    ; "rank", Option.value_map s.ranked.rank ~default:`Null ~f:(fun r -> `Int r)
    ; "percentile", opt s.ranked.percentile
    ; "eligible", `Bool s.ranked.eligible
    ; "predicted_forward_sharpe", opt s.report.predicted
    ; ( "capacity_usd"
      , Option.value_map s.report.copyability ~default:`Null ~f:(fun c -> opt c.capacity)
      )
    ; "alerts", `Int (List.length s.report.alerts)
    ; ( "worst_alert"
      , Option.value_map worst ~default:`Null ~f:(fun v ->
          `String (LS.Alerts.Severity.to_string v)) )
    ; "total_return", m Total_return
    ; "sharpe", m Sharpe
    ; "sortino", m Sortino
    ; "max_drawdown", m Max_drawdown
    ; "win_rate", m Win_rate
    ; "leverage_p95", m Leverage_p95
    ; "trades", m Trades
    ]
;;

let write_reports ~dir scored =
  let%bind () = Unix.mkdir ~p:() (dir ^/ "reports") in
  Deferred.List.iter ~how:`Sequential scored ~f:(fun (s : Scored.t) ->
    let path = Layout.report dir s.address in
    let tmp = path ^ ".tmp" in
    let%bind () =
      Writer.save
        tmp
        ~contents:(Yojson.Safe.to_string (LS.Report.to_json s.report (Some s.ranked)))
    in
    Unix.rename ~src:tmp ~dst:path)
;;
