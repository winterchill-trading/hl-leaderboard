(** A stand-in for the stats host and [/info] on a local port: serves a leaderboard file,
    synthetic fill histories (2000 per page, oldest first, like Hyperliquid), a fixed
    clearinghouse state and a [userRole] answer for every address. *)

open! Core
open! Async
open Hl_protocol

type t

(** [portfolio], when given, answers every [portfolio] request; without it they get HTTP
    400, as from hl-sim. [roles] answers [userRole] with the body listed for the address,
    [{"role":"user"}] for the others. [roles_down] makes every [userRole] get HTTP 400
    instead, as from a server without the request. *)
val start
  :  ?portfolio:string
  -> ?roles:(Address.t * string) list
  -> ?roles_down:bool
  -> leaderboard:string
  -> fills:(Address.t * User_fill.t list) list
  -> state:string
  -> unit
  -> t Deferred.t

val port : t -> int
val base_url : t -> Uri.t
val leaderboard_url : t -> Uri.t

(** Requests seen, as ["<type> <user>"] or ["GET <path>"]. *)
val requests : t -> string list

(** Answer [clearinghouseState] for [address] with HTTP 500 until cleared. *)
val fail_state : t -> Address.t -> bool -> unit

(** Answer the next [n] [/info] requests with HTTP 429. *)
val throttle_next : t -> int -> unit

val close : t -> unit Deferred.t
