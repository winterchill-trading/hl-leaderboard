(** Raw response logs in the Tardis line format used by market-recorder: one line per
    response, [<recv_ts> <body>], with [recv_ts] in ISO 8601 UTC with microseconds
    ([2026-10-13T06:25:07.123456Z]). Bodies are written verbatim except that newlines
    become spaces (JSON allows that outside strings, and JSON strings cannot hold a raw
    newline), so every line is one response. Lines are read back with
    {!Market_data.Raw_minute.Line.parse}. *)

open! Core
open! Async

(** [2026-10-13T06:25:07.123456Z] *)
val format_ts : Time_ns.t -> string

(** The line for one response, with its trailing newline. *)
val line : recv_ts:Time_ns.t -> string -> string

(** Appends one line to [path], creating the file and its parent directories. *)
val append : string -> recv_ts:Time_ns.t -> string -> unit Deferred.t

module Entry : sig
  type t =
    { recv_ts : Time_ns.t
    ; body : string
    }
  [@@deriving sexp_of]
end

(** Every response in [path], in file order; [[]] if the file does not exist. Empty
    (disconnect) lines are skipped. A truncated last line (a crash mid-write) is dropped;
    any other malformed line is an error. *)
val read : string -> Entry.t list Or_error.t Deferred.t
