(** leader-scoring over a collection directory: per leader, a track record rebuilt from
    the raw logs (fills with liquidation flags, funding, every [clearinghouseState] taken,
    the [portfolio] month curve), its metrics, the composite score and percentile across
    the collected leaders, the learned model's prediction, a capacity curve from the
    collected order books and open interest, and alerts. The formulas are in the
    leader-scoring README.

    Read-only over [dir]; {!write_reports} writes [reports/<address>.json]. *)

open! Core
open! Async
open Hl_protocol

(** The history of one leader from the raw logs. *)
val history : dir:string -> Address.t -> Leader_scoring.History.t Or_error.t Deferred.t

(** The latest book per coin in [raw/books/] and the latest open interest. *)
val market
  :  dir:string
  -> (Leader_scoring.Copyability.Book.t String.Map.t * float String.Map.t) Deferred.t

module Scored : sig
  type t =
    { address : Address.t
    ; report : Leader_scoring.Report.t
    ; ranked : Leader_scoring.Score.Ranked.t
    }
end

(** Reports for every leader of the dataset, ranked together (leaders whose history cannot
    be read are left out and logged). *)
val score_all : dir:string -> Dataset.t -> Scored.t list Deferred.t

(** The short form a leaderboard row carries: composite score, rank and percentile,
    eligibility, the model's prediction, capacity, alert count and worst severity, and a
    few headline metrics. *)
val summary_json : Scored.t -> Yojson.Safe.t

(** Writes [Layout.report dir address] for each leader ({!Leader_scoring.Report.to_json}),
    through a temporary file and a rename. *)
val write_reports : dir:string -> Scored.t list -> unit Deferred.t
