(** What a [collect] run has done so far, so an interrupted run resumes where it stopped.
    Written atomically (temp file and rename) after every address. *)

open! Core
open! Async
open Hl_protocol

type t =
  { started : Time_ns.t
  ; candidates : Address.t list (** fixed when the run starts *)
  ; collected : Address.t list (** fills and state done, in order *)
  }
[@@deriving sexp, compare, equal]

val load : string -> t option Or_error.t Deferred.t
val save : string -> t -> unit Deferred.t
val pending : t -> Address.t list
