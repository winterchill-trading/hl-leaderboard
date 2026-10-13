(** [leaders.parquet] and [fills.parquet], rebuilt from a {!Dataset.t}. Both are written
    to [<path>.tmp] and renamed, so a glob never sees a partial file. Amounts are DOUBLE:
    the files are for analysis (DuckDB, pyarrow), the raw logs keep the exact decimals.

    [leaders.parquet]: [address], [display_name] ([""] when none), [role] (the [userRole]
    name, [""] when unknown), [account_value], [<window>_pnl], [<window>_roi],
    [<window>_vlm] for [day], [week], [month], [all_time] (0 when missing), [fills],
    [first_fill] and [last_fill] (TIMESTAMP_NS, the epoch when there are none),
    [has_state], [state_time], [state_account_value], [positions].

    [fills.parquet]: [address], [time] (TIMESTAMP_NS), [coin], [side] (["B"] or ["A"]),
    [px], [sz], [start_position], [dir], [closed_pnl], [fee], [fee_token], [crossed],
    [oid], [tid], [hash]. *)

open! Core

val write_leaders : string -> Dataset.Leader.t list -> unit
val write_fills : string -> Dataset.Leader.t list -> unit

(** Both files under [dir], at their {!Layout} paths. Returns the number of fill rows. *)
val write : dir:string -> Dataset.t -> int
