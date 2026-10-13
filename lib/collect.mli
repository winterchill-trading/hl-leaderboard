(** [hl-leaderboard collect]: fetch the leaderboard, pick candidates (top [top_n] by pnl
    in each window among the accounts whose [userRole] is in [roles]), then for each
    candidate walk its [userFillsByTime] history and take one [clearinghouseState] and one
    [portfolio] (optional: a failure is logged and skipped). Every response goes to the
    raw logs ({!Layout}) as it arrives; the Parquet files are rebuilt from the raw logs at
    the end.

    Resumable: the candidate list is fixed in the progress manifest when a run starts, and
    an interrupted run continues with the addresses not yet collected, starting each fill
    walk after the newest fill already in that address's raw log. A finished run starts
    over (new leaderboard, new candidates) unless [resume_only]. *)

open! Core
open! Async

module Config : sig
  type t =
    { dir : string
    ; top_n : int
    ; windows : Board.Window.t list
    ; min_account_value : float
    ; lookback : Time_ns.Span.t (** first fill walk starts this far back *)
    ; max_pages : int (** per address and run; 5 pages is Hyperliquid's 10000 fills *)
    ; roles : string list
    (** [userRole] names that may become candidates ({!Roles}); others are skipped and the
        next row of the window takes their place *)
    }
  [@@deriving sexp_of]

  (** top 20 per window, all four windows, account value >= 10000, 30 days, 5 pages,
      ordinary accounts only ([Roles.default]). *)
  val default : dir:string -> t
end

module Summary : sig
  type t =
    { candidates : int
    ; excluded : int
    (** rows skipped for their role when this run started; 0 if resumed *)
    ; collected : int
    ; failed : int
    ; fills : int
    ; weight : int
    ; retries : int
    ; resumed : bool
    }
  [@@deriving sexp_of]
end

val run : ?now:(unit -> Time_ns.t) -> Api.t -> Config.t -> Summary.t Or_error.t Deferred.t
