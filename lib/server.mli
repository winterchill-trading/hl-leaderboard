(** [hl-leaderboard serve]: a read-only JSON API over a collection directory and the
    ranking written by [rank].

    - [GET /leaders]: the ranking file as written
      ([{"generated_at", "formula", "leaders": [...]}]); re-read when its modification
      time changes. [?limit=N] keeps the first [N] leaders.
    - [GET /leaders/<address>]:
      [{"address", "entry" (the ranking entry or null), "fills" (newest first, at most [?limit=N], default 500), "fill_count", "equity_curve" ([[time_ms, equity], ...]), "curve_source" (["portfolio_month"] or ["fills"], see {!Rank}), "positions" (from the latest clearinghouseState, or []), "report" (the leader-scoring report written by [rank]: metrics, composite score and its components, the model's prediction, equity curve, capacity curve and alerts; null before the first ranking with it)}].
      An address that is not [0x] and 40 hex digits is a 400; one with nothing collected
      a 404.
    - [GET /scoring/metrics]: every leader-scoring metric with its label, unit, direction
      and formula.
    - [GET /health]: ["ok"].

    Responses carry [Access-Control-Allow-Origin: *] so a browser frontend on another
    origin can read them. *)

open! Core
open! Async

type t

(** [port] 0 picks a free port. *)
val start : dir:string -> leaders:string -> port:int -> t Deferred.t

val port : t -> int
val close : t -> unit Deferred.t

(** The JSON for [GET /leaders/<address>]; [None] when nothing was collected for it. *)
val leader_json
  :  dir:string
  -> ranking:Yojson.Safe.t option
  -> limit:int
  -> now_ms:int
  -> Hl_protocol.Address.t
  -> Yojson.Safe.t option Or_error.t Deferred.t
