(** The [portfolio] info request: per window, the account value and the cumulative pnl
    sampled over time, as the Hyperliquid web app plots them.

    {v
    [["day", {"accountValueHistory": [[1791787800006, "51619594.12"], ...],
              "pnlHistory": [[1791787800006, "0.0"], ...], "vlm": "0.0"}],
     ["week", {...}], ["month", {...}], ["allTime", {...}],
     ["perpDay", {...}], ["perpWeek", {...}], ["perpMonth", {...}], ["perpAllTime", {...}]]
    v}

    Not in hl-protocol yet; the shape was read from a mainnet response on 2026-10-13 (13
    to 128 points per window, times in epoch ms, amounts as decimal strings and [vlm] as a
    JSON number). [pnlHistory] excludes deposits and withdrawals, which is why the score's
    equity curve is built from it when it is there. *)

open! Core

module Series : sig
  type t =
    { account_value : (int * float) list (** [(time_ms, value)], oldest first *)
    ; pnl : (int * float) list (** cumulative from the window's start, oldest first *)
    ; vlm : float
    }
  [@@deriving sexp_of]
end

type t = (string * Series.t) list [@@deriving sexp_of]

val of_string : string -> t Or_error.t
val find : t -> string -> Series.t option

(** Request body: [{"type": "portfolio", "user": ...}]. *)
val request : Hl_protocol.Address.t -> Yojson.Safe.t

(** An equity curve without deposits and withdrawals: the window's first account value
    plus the cumulative pnl at each point, [None] when the window is missing, has no
    points, or starts at a non-positive account value. *)
val equity_curve : Series.t -> Equity_curve.t option
