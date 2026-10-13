(** Candidate selection over the Hyperliquid leaderboard ({!Hl_protocol.Leaderboard}), as
    served by [https://stats-data.hyperliquid.xyz/Mainnet/leaderboard] (a static JSON
    file, about 40 MB and 47k rows on mainnet in October 2026). *)

open! Core
open Hl_protocol

module Window : sig
  type t = Leaderboard.Window.t [@@deriving sexp_of]

  (** [Day; Week; Month; All_time] *)
  val all : t list

  (** The wire names: ["day"], ["week"], ["month"], ["allTime"]. *)
  val of_string : string -> t Or_error.t

  val to_string : t -> string
  val arg_type : t Command.Arg_type.t
end

module Row = Leaderboard.Row

type t = Row.t list [@@deriving sexp_of]

(** Decodes a whole response body ([{"leaderboardRows": [...]}]). *)
val of_string : string -> t Or_error.t

val to_json : t -> Yojson.Safe.t

(** [top t ~window ~n] is the [n] rows with the highest [pnl] over [window], highest
    first; ties go to the lower address. Rows without that window, and rows whose
    [account_value] is below [min_account_value] (default 0), are skipped. *)
val top : ?min_account_value:float -> t -> window:Window.t -> n:int -> Row.t list

(** [candidates t ~n ~windows] is the union of [top ~n] over [windows], without
    duplicates, in order of first appearance (windows in the order given). *)
val candidates
  :  ?min_account_value:float
  -> t
  -> n:int
  -> windows:Window.t list
  -> Row.t list
