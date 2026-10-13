(** Token bucket for the Hyperliquid REST weight limit.

    Hyperliquid allows 1200 weight per minute per IP across [/info] and [/exchange]. The
    bucket starts full ([capacity] tokens) and refills continuously at
    [refill_per_minute]. Callers {!acquire} a request's weight before sending it; waiters
    are served in FIFO order, so a heavy request is not starved by light ones. *)

open! Core
open! Async

type t

(** [capacity] defaults to [refill_per_minute]. *)
val create
  :  ?time_source:Time_source.t
  -> ?capacity:int
  -> refill_per_minute:int
  -> unit
  -> t

(** 1200 weight per minute, the documented limit. *)
val hyperliquid : ?time_source:Time_source.t -> unit -> t

(** Waits until [weight] tokens are available and takes them. A weight above the capacity
    is charged as the capacity (it could never be served otherwise). *)
val acquire : t -> weight:int -> unit Deferred.t

(** Tokens available now (after refilling). *)
val available : t -> float

(** Total weight acquired so far. *)
val total_weight : t -> int

(** Total time callers spent waiting for tokens. *)
val total_wait : t -> Time_ns.Span.t

(** Request weights from the Hyperliquid docs (Rate limits and user limits):
    - most info requests: 20;
    - [l2Book], [allMids], [clearinghouseState], [orderStatus], [spotClearinghouseState],
      [exchangeStatus]: 2;
    - [userRole]: 60;
    - [userFills], [userFillsByTime], [historicalOrders], [fundingHistory], [userFunding],
      [recentTrades] and a few others: 20 plus 1 per 20 items returned.

    The stats-data leaderboard file is served from a CDN, outside the API limit. *)
module Weight : sig
  (** Weight charged up front for an [/info] request of this ["type"]. *)
  val info : string -> int

  (** Extra weight charged after the response, for request types billed per item returned:
      [items / 20], else 0. *)
  val per_items : string -> items:int -> int
end
