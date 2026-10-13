(** A collection directory read back from its raw logs and manifest: the candidates in
    leaderboard order, each with its de-duplicated fills and latest account state. *)

open! Core
open! Async
open Hl_protocol

module Leader : sig
  type t =
    { address : Address.t
    ; row : Board.Row.t option (** the leaderboard row when the run started *)
    ; fills : User_fill.t list (** oldest first, without duplicates *)
    ; state : (Time_ns.t * Clearinghouse_state.t) option (** the latest one *)
    ; portfolio : Portfolio.t option (** the latest one *)
    }
  [@@deriving sexp_of]
end

type t =
  { started : Time_ns.t option
  ; leaders : Leader.t list
  }
[@@deriving sexp_of]

(** All fills in [Layout.fills dir address], de-duplicated by {!Fill_pages.key}, oldest
    first. Pages that fail to decode are an error. *)
val load_fills : string -> Address.t -> User_fill.t list Or_error.t Deferred.t

(** The last state in [Layout.state dir address] that decodes. *)
val load_state
  :  string
  -> Address.t
  -> (Time_ns.t * Clearinghouse_state.t) option Or_error.t Deferred.t

(** The last portfolio in [Layout.portfolio dir address] that decodes. *)
val load_portfolio : string -> Address.t -> Portfolio.t option Or_error.t Deferred.t

(** The candidates' rows saved by {!Collect} ([[]] if missing). *)
val load_candidates : string -> Board.Row.t list Or_error.t Deferred.t

val save_candidates : string -> Board.Row.t list -> unit Deferred.t

(** Every candidate of the progress manifest (or of the candidates file when there is no
    manifest), collected or not. *)
val load : string -> t Or_error.t Deferred.t

(** One leader, also when not a candidate (any address with a raw fills log). *)
val load_leader : string -> Address.t -> Leader.t Or_error.t Deferred.t
