(** The Hyperliquid leaderboard, as served by the stats endpoint
    [https://stats-data.hyperliquid.xyz/Mainnet/leaderboard] (a static JSON file, about 40
    MB and 47k rows in October 2026):

    {v
    {"leaderboardRows": [
      {"ethAddress": "0x85ec...", "accountValue": "61849871.23",
       "windowPerformances": [["day", {"pnl": "-764341.83", "roi": "-0.0128", "vlm": "1418590361.70"}],
                              ["week", {...}], ["month", {...}], ["allTime", {...}]],
       "prize": 0, "displayName": null}]}
    v}

    Amounts are decimal strings and are kept as floats here: this is ranking input, and
    volumes (2.3e11 with ten decimals) do not fit the fixed-point types. *)

open! Core
open Hl_protocol

module Window : sig
  type t =
    | Day
    | Week
    | Month
    | All_time
  [@@deriving sexp, compare, equal, hash, enumerate]

  (** The wire name: ["day"], ["week"], ["month"], ["allTime"]. *)
  val to_string : t -> string

  val of_string : string -> t Or_error.t
end

module Performance : sig
  type t =
    { pnl : float
    ; roi : float
    ; vlm : float
    }
  [@@deriving sexp, compare, equal]
end

module Row : sig
  type t =
    { address : Address.t
    ; account_value : float
    ; windows : (Window.t * Performance.t) list (** in the order received *)
    ; display_name : string option
    }
  [@@deriving sexp, compare, equal]

  (** The performance over [window], if the row has it. *)
  val performance : t -> Window.t -> Performance.t option

  val to_json : t -> Yojson.Safe.t
  val of_json : Yojson.Safe.t -> t Or_error.t
end

type t = Row.t list [@@deriving sexp_of]

(** Decodes a whole response body ([{"leaderboardRows": [...]}]). One malformed row fails
    the whole decode, with the row index in the error. *)
val of_json : Yojson.Safe.t -> t Or_error.t

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
