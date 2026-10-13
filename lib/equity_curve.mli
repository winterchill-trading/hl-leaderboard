(** An approximate equity curve rebuilt from a fill history and the current account value:
    walking back from [account_value] at [now], each fill's realized result
    ([closedPnl - fee]) is taken off. So [equity t = account_value - realized after t].

    What it leaves out, and why it is still useful for ranking: unrealized PnL of open
    positions (it appears as one step at [now]), funding payments, deposits and
    withdrawals (none are in [userFills]). Accounts that move money in and out a lot get a
    distorted drawdown; the leaderboard's own [roi] is shown next to the score for that
    reason. *)

open! Core
open Hl_protocol

module Point : sig
  type t =
    { time_ms : int
    ; equity : float
    }
  [@@deriving sexp, compare, equal]
end

type t = Point.t list [@@deriving sexp_of]

(** One point before the first fill, one per closing fill (non-zero [closedPnl]) or fee,
    and a last point at [now_ms] with [account_value]. Oldest first. *)
val of_fills : account_value:float -> now_ms:int -> User_fill.t list -> t

(** Realized result of a fill: [closedPnl - fee]. *)
val realized : User_fill.t -> float
