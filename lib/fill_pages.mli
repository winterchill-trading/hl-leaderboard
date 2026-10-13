(** Walks a [userFillsByTime] history forward.

    A page holds at most {!page_limit} fills, the oldest ones at or after [startTime],
    oldest first. The next page starts at the newest time of the previous page (inclusive,
    so fills sharing that millisecond are not lost), and fills already seen are dropped by
    [(tid, oid)]. A page with nothing new (every fill in one millisecond) moves the start
    one millisecond on. A short page ends the walk. *)

open! Core
open! Async
open Hl_protocol

val page_limit : int

(** Identity of a fill within one account's history. *)
val key : User_fill.t -> int * int

type next =
  | Done
  | Next of int
[@@deriving sexp_of]

(** [next ~start_time ~page ~fresh] decides the next start time after [page] (requested at
    [start_time]), of which [fresh] fills were not seen before. *)
val next : start_time:int -> page:User_fill.t list -> fresh:int -> next

type result =
  { fills : User_fill.t list (** without duplicates, oldest first *)
  ; pages : int
  ; complete : bool (** false when [max_pages] stopped the walk *)
  ; next_start : int (** where a later run should resume *)
  }
[@@deriving sexp_of]

(** [walk ~start_time ~fetch ~on_page] fetches pages until a short page or [max_pages]
    (default unlimited). [seen] are fills from an earlier run, used for de-duplication
    only. [on_page] gets every page as fetched (for the raw log). *)
val walk
  :  ?max_pages:int
  -> ?seen:User_fill.t list
  -> start_time:int
  -> fetch:(start_time:int -> ('raw * User_fill.t list) Or_error.t Deferred.t)
  -> on_page:('raw -> User_fill.t list -> unit Deferred.t)
  -> unit
  -> result Or_error.t Deferred.t
