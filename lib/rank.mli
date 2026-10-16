(** [hl-leaderboard rank]: score every collected leader with {!Hl_copy_core.Score} and
    order them, best first.

    Score input, per leader:
    - fills: perpetual fills only (spot pairs, [@107] or [PURR/USDC], cannot be mirrored
      on a perp account). The history usually starts with a position already open (it is
      cut at 10000 fills and at the lookback), and the score finds round trips by tracking
      the position from zero; so for each coin whose first fill has a non-zero
      [startPosition], a synthetic opening fill of that size (no pnl, no fee, [tid = -1])
      is put 1 ms before it. That trip's open time is therefore the start of the history,
      not the real one;
    - equity: the [month] window of the latest [portfolio] response
      ({!Portfolio.equity_curve}: account value at the window's start plus cumulative pnl,
      so deposits and withdrawals do not show as gains or drawdowns); without one,
      {!Equity_curve.of_fills} from the latest [clearinghouseState] account value (the
      leaderboard's when there is no state).

    [truncated] flags a leader with at least 2000 fills whose first fill is later than the
    start of the equity curve: the trade statistics (win rate, trips, holding time) then
    cover only the most recent part of the window, because Hyperliquid serves only the
    10000 most recent fills.

    Leaders with fewer than [min_trades] round trips are listed after the others, unranked
    ([rank = None]). *)

open! Core
open! Async
open Hl_protocol

module Entry : sig
  type t =
    { rank : int option
    ; address : Address.t
    ; display_name : string option
    ; role : User_role.Role.t option
    (** [None] when unknown; JSON: the wire name or null *)
    ; account_value : float
    ; leaderboard : (Board.Window.t * Leaderboard.Performance.t) list
    ; fills : int (** all fills collected *)
    ; scored_fills : int (** perp fills, without the synthetic opens *)
    ; first_fill_ms : int option
    ; last_fill_ms : int option
    ; positions : int
    ; curve_source : [ `Portfolio_month | `Fills ]
    ; truncated : bool
    ; score : Hl_copy_core.Score.t
    }
  [@@deriving sexp_of]

  val to_json : t -> Yojson.Safe.t
end

(** The fills given to the score (see above), oldest first, synthetic opens included. *)
val scored_fills : User_fill.t list -> User_fill.t list

(** The curve given to the score, and where it came from (see above). *)
val equity_curve
  :  now_ms:int
  -> Dataset.Leader.t
  -> Equity_curve.t * [ `Portfolio_month | `Fills ]

val to_copy_fill : User_fill.t -> Hl_copy_core.Fill.t
val score_leader : now_ms:int -> Dataset.Leader.t -> Entry.t

(** 5 round trips: below it a leader is listed unranked. The [rank] command's
    [-min-trades] default. *)
val default_min_trades : int

(** Best score first, ties to the lower address; [min_trades] defaults to
    {!default_min_trades}. *)
val rank : ?min_trades:int -> now_ms:int -> Dataset.t -> Entry.t list

(** [{"generated_at": ..., "formula": ..., "leaders": [...]}]. [scoring] adds a
    ["scoring"] object to the leaders it knows ({!Scoring.summary_json}); [universe] adds
    a ["scoring_universe"] object ({!Scoring.universe_json}: persistence, selection
    statistics, integrity counts). *)
val to_json
  :  ?scoring:(Address.t -> Yojson.Safe.t option)
  -> ?universe:Yojson.Safe.t
  -> generated_at:Time_ns.t
  -> Entry.t list
  -> Yojson.Safe.t
