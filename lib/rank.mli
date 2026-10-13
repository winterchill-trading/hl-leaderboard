(** [hl-leaderboard rank]: score every collected leader with {!Hl_copy_core.Score} and
    order them, best first.

    Score input, per leader:
    - fills: perpetual fills only (spot pairs, [@107] or [PURR/USDC], cannot be mirrored
      on a perp account), and per coin only from the first fill that opens from a flat
      position ([startPosition = 0]): the history is cut at 10000 fills, and a round trip
      that started before the cut would be counted wrong;
    - equity: {!Equity_curve.of_fills} from the latest [clearinghouseState] account value
      (the leaderboard's when there is no state).

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
    ; account_value : float
    ; leaderboard : (Board.Window.t * Leaderboard.Performance.t) list
    ; fills : int (** all fills collected *)
    ; scored_fills : int (** after the perp-only, from-flat filter *)
    ; first_fill_ms : int option
    ; last_fill_ms : int option
    ; positions : int
    ; score : Hl_copy_core.Score.t
    }
  [@@deriving sexp_of]

  val to_json : t -> Yojson.Safe.t
end

(** The fills given to the score (see above), oldest first. *)
val scored_fills : User_fill.t list -> User_fill.t list

val to_copy_fill : User_fill.t -> Hl_copy_core.Fill.t
val score_leader : now_ms:int -> Dataset.Leader.t -> Entry.t

(** Best score first, ties to the lower address; [min_trades] defaults to 5. *)
val rank : ?min_trades:int -> now_ms:int -> Dataset.t -> Entry.t list

(** [{"generated_at": ..., "formula": ..., "leaders": [...]}] *)
val to_json : generated_at:Time_ns.t -> Entry.t list -> Yojson.Safe.t
