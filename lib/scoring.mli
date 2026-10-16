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

(** Best bid and ask of every [l2Book] logged in [raw/books/], at its receive time: the
    reference prices of the off-book check. *)
val quotes : dir:string -> Leader_scoring.Integrity.Quote.t list Deferred.t

(** The first point of the latest [portfolio]'s all-time curve: Hyperliquid publishes no
    account creation time, so this stands in for it in the creation-burst check. *)
val first_seen : dir:string -> Address.t -> Time_ns.t option Deferred.t

(** Persistence and selection-statistics settings for a set of records: bars from
    {!Leader_scoring.Metrics.auto_bar} of the median span (days for the month curves,
    minutes for a simulator run), windows of a fifth of that span (at least three bars),
    and a common window of up to 90 bars. *)
val configs
  :  Leader_scoring.Track_record.t list
  -> Leader_scoring.Persistence.Config.t * Leader_scoring.Leader_stats.Config.t

(** Reports for every leader of the dataset, ranked together (leaders whose history cannot
    be read are left out and logged), and the universe checks
    ({!Leader_scoring.Report.analyse}: persistence, PSR/DSR/PBO/SPA, and integrity flags
    from the fills, the logged books and the first-seen times). Leaders the default
    integrity policy excludes are scored but not ranked. The universe is [None] when no
    leader could be scored. *)
val score_all
  :  dir:string
  -> Dataset.t
  -> (Scored.t list * Leader_scoring.Report.Universe.t option) Deferred.t

(** {!Leader_scoring.Report.Universe.to_json}. *)
val universe_json : Leader_scoring.Report.Universe.t -> Yojson.Safe.t

(** The short form a leaderboard row carries: composite score, rank and percentile,
    eligibility, the model's prediction, capacity, alert count and worst severity, a few
    headline metrics, the integrity flag kinds and whether they exclude the leader, the
    leader's mean persistence percentile, PSR and DSR. *)
val summary_json : Scored.t -> Yojson.Safe.t

(** Writes [Layout.report dir address] for each leader ({!Leader_scoring.Report.to_json}),
    through a temporary file and a rename. *)
val write_reports : dir:string -> Scored.t list -> unit Deferred.t
