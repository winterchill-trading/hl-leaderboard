open! Core
open! Async
open Hl_protocol
module Score = Hl_copy_core.Score

module Entry = struct
  type t =
    { rank : int option
    ; address : Address.t
    ; display_name : string option
    ; role : User_role.Role.t option
    ; account_value : float
    ; leaderboard : (Board.Window.t * Leaderboard.Performance.t) list
    ; fills : int
    ; scored_fills : int
    ; first_fill_ms : int option
    ; last_fill_ms : int option
    ; positions : int
    ; curve_source : [ `Portfolio_month | `Fills ]
    ; truncated : bool
    ; score : Score.t
    }
  [@@deriving sexp_of]

  let option f = function
    | Some x -> f x
    | None -> `Null
  ;;

  let to_json t =
    let s = t.score in
    `Assoc
      [ "rank", option (fun r -> `Int r) t.rank
      ; "address", `String (Address.to_string t.address)
      ; "display_name", option (fun n -> `String n) t.display_name
      ; "role", option (fun r -> `String (User_role.Role.to_string r)) t.role
      ; "account_value", `Float t.account_value
      ; ( "leaderboard"
        , `Assoc
            (List.map t.leaderboard ~f:(fun (w, (p : Leaderboard.Performance.t)) ->
               ( Board.Window.to_string w
               , `Assoc [ "pnl", `Float p.pnl; "roi", `Float p.roi; "vlm", `Float p.vlm ]
               ))) )
      ; "fills", `Int t.fills
      ; "scored_fills", `Int t.scored_fills
      ; "first_fill_ms", option (fun x -> `Int x) t.first_fill_ms
      ; "last_fill_ms", option (fun x -> `Int x) t.last_fill_ms
      ; "positions", `Int t.positions
      ; ( "curve_source"
        , `String
            (match t.curve_source with
             | `Portfolio_month -> "portfolio_month"
             | `Fills -> "fills") )
      ; "truncated", `Bool t.truncated
      ; "score", `Float s.score
      ; ( "components"
        , `Assoc
            [ "pnl", `Float (Usd.to_float s.pnl)
            ; "return", `Float s.return_
            ; "max_drawdown", `Float s.max_drawdown
            ; "win_rate", `Float s.win_rate
            ; "trade_count", `Int s.trade_count
            ; "avg_hold_hours", `Float (Float.of_int s.avg_hold_ns /. 3.6e12)
            ; "consistency", `Float s.consistency
            ] )
      ]
  ;;
end

let is_perp (f : User_fill.t) =
  let coin = Coin.to_string f.coin in
  not (String.is_prefix coin ~prefix:"@" || String.mem coin '/')
;;

let synthetic_open (first : User_fill.t) =
  let long = Size.(first.start_position > zero) in
  { first with
    time = first.time - 1
  ; side = (if long then Buy else Sell)
  ; sz = (if long then first.start_position else Size.neg first.start_position)
  ; start_position = Size.zero
  ; dir = (if long then "Open Long" else "Open Short")
  ; closed_pnl = Usd.zero
  ; fee = Usd.zero
  ; tid = -1
  ; hash = "synthetic"
  ; crossed = false
  ; cloid = None
  }
;;

let scored_fills fills =
  let seen = Hash_set.create (module String) in
  List.concat_map fills ~f:(fun (f : User_fill.t) ->
    if not (is_perp f)
    then []
    else (
      match Hash_set.strict_add seen (Coin.to_string f.coin) with
      | Ok when not Size.(f.start_position = zero) -> [ synthetic_open f; f ]
      | Ok | Duplicate -> [ f ]))
;;

let to_copy_fill (f : User_fill.t) : Hl_copy_core.Fill.t =
  { time_ns = f.time * 1_000_000
  ; symbol = f.coin
  ; side = f.side
  ; size = f.sz
  ; price = f.px
  ; fee = f.fee
  ; closed_pnl = f.closed_pnl
  ; cloid = f.cloid
  }
;;

let account_value (leader : Dataset.Leader.t) =
  match leader.state, leader.row with
  | Some (_, state), _ -> Usd.to_float state.margin_summary.account_value
  | None, Some row -> row.account_value
  | None, None -> 0.
;;

let equity_curve ~now_ms (leader : Dataset.Leader.t) =
  match
    Option.bind leader.portfolio ~f:(fun p -> Portfolio.find p "month")
    |> Option.bind ~f:Portfolio.equity_curve
  with
  | Some curve -> curve, `Portfolio_month
  | None ->
    ( Equity_curve.of_fills
        ~account_value:(account_value leader)
        ~now_ms
        (scored_fills leader.fills)
    , `Fills )
;;

let truncation_threshold = 2000

let score_leader ~now_ms (leader : Dataset.Leader.t) =
  let account_value = account_value leader in
  let fills = scored_fills leader.fills in
  let curve, curve_source = equity_curve ~now_ms leader in
  let equity =
    curve
    |> List.map ~f:(fun (p : Equity_curve.Point.t) ->
      { Score.Equity_point.time_ns = p.time_ms * 1_000_000
      ; (* The curve is float arithmetic already (an approximation, see Equity_curve);
           rounding it to 1e-8 USD loses nothing that matters. *)
        equity = (Usd.of_float [@alert "-lossy"]) p.equity
      })
  in
  let score = Score.compute ~fills:(List.map fills ~f:to_copy_fill) ~equity () in
  { Entry.rank = None
  ; address = leader.address
  ; display_name = Option.bind leader.row ~f:(fun r -> r.display_name)
  ; role = leader.role
  ; account_value
  ; leaderboard =
      Option.value_map leader.row ~default:[] ~f:(fun r -> r.window_performances)
  ; fills = List.length leader.fills
  ; scored_fills = List.count fills ~f:(fun f -> f.tid >= 0)
  ; first_fill_ms = List.hd leader.fills |> Option.map ~f:(fun f -> f.time)
  ; last_fill_ms = List.last leader.fills |> Option.map ~f:(fun f -> f.time)
  ; positions =
      Option.value_map leader.state ~default:0 ~f:(fun (_, s) -> List.length s.positions)
  ; curve_source
  ; truncated =
      (List.length leader.fills >= truncation_threshold
       &&
       match List.hd leader.fills, List.hd curve with
       | Some f, Some p -> f.time > p.time_ms
       | _ -> false)
  ; score
  }
;;

let default_min_trades = 5

let rank ?(min_trades = default_min_trades) ~now_ms (dataset : Dataset.t) =
  let entries = List.map dataset.leaders ~f:(score_leader ~now_ms) in
  let ranked, unranked =
    List.partition_tf entries ~f:(fun e -> e.score.trade_count >= min_trades)
  in
  let order =
    List.sort ~compare:(fun (a : Entry.t) (b : Entry.t) ->
      match Float.compare b.score.score a.score.score with
      | 0 -> Address.compare a.address b.address
      | c -> c)
  in
  List.mapi (order ranked) ~f:(fun i e -> { e with rank = Some (i + 1) }) @ order unranked
;;

let formula =
  "score = return * (1 - max_drawdown) * (0.5 + 0.5 * consistency) * min(1, trade_count \
   / 20); see hl-copy-core Score"
;;

let to_json ~generated_at entries =
  `Assoc
    [ "generated_at", `String (Raw_log.format_ts generated_at)
    ; "formula", `String formula
    ; "leaders", `List (List.map entries ~f:Entry.to_json)
    ]
;;
