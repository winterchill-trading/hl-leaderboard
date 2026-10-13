(** Read-only access to the Hyperliquid endpoints the collector needs, returning raw
    bodies (for the raw logs) next to decoded values. Nothing here signs or sends an
    exchange action.

    Every [/info] request first takes its weight from the {!Rate_limit.t}; requests billed
    per item returned are charged the extra weight after the response. HTTP 429 and 5xx
    responses and transport errors are retried with exponential backoff (0.5 s, 1 s, 2 s,
    ...) up to [max_attempts]. *)

open! Core
open! Async
open Hl_protocol

module Network : sig
  type t =
    | Mainnet
    | Testnet
    | Local (** hl-sim; the leaderboard comes from [POST /info {"type":"leaderboard"}] *)
  [@@deriving sexp, compare, equal, enumerate]

  val of_string : string -> t
  val to_string : t -> string
  val arg_type : t Command.Arg_type.t
end

type t

(** [base_url] overrides the network's API root ([https://api.hyperliquid.xyz],
    [https://api.hyperliquid-testnet.xyz], [http://localhost:3000]); [leaderboard_url]
    overrides where the leaderboard is fetched from with a [GET] (for [Local] the default
    is a [POST /info] on [base_url]). [max_attempts] defaults to 5. *)
val create
  :  ?base_url:Uri.t
  -> ?leaderboard_url:Uri.t
  -> ?rate_limit:Rate_limit.t
  -> ?max_attempts:int
  -> ?time_source:Time_source.t
  -> Network.t
  -> t

val network : t -> Network.t
val info_uri : t -> Uri.t
val rate_limit : t -> Rate_limit.t

(** Number of requests retried after a 429, a 5xx or a transport error. *)
val retries : t -> int

module Raw : sig
  type t =
    { recv_ts : Time_ns.t
    ; body : string
    }
end

(** The whole leaderboard. *)
val leaderboard : t -> (Raw.t * Board.t) Or_error.t Deferred.t

(** [POST /info] with an arbitrary body ([{"type": ...}]), rate limited and retried. *)
val info : t -> Yojson.Safe.t -> Raw.t Or_error.t Deferred.t

(** The page of at most 2000 fills of [user] at or after [start_time] (ms), oldest first.
    Hyperliquid keeps only the 10000 most recent fills per account. *)
val user_fills_by_time
  :  t
  -> user:Address.t
  -> start_time:int
  -> (Raw.t * User_fill.t list) Or_error.t Deferred.t

val clearinghouse_state
  :  t
  -> user:Address.t
  -> (Raw.t * Clearinghouse_state.t) Or_error.t Deferred.t

(** [portfolio] ({!Portfolio}). *)
val portfolio : t -> user:Address.t -> (Raw.t * Portfolio.t) Or_error.t Deferred.t

(** Decodes a [userFills]/[userFillsByTime] body. *)
val decode_fills : string -> User_fill.t list Or_error.t

val decode_clearinghouse_state : string -> Clearinghouse_state.t Or_error.t
