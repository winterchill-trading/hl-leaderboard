(** Files of a collection directory:

    {v
    <dir>/raw/leaderboard.ndjson          one line per leaderboard fetch
    <dir>/raw/fills/<address>.ndjson      one line per userFillsByTime page
    <dir>/raw/state/<address>.ndjson      one line per clearinghouseState response
    <dir>/_manifest/progress.sexp         candidates and addresses already collected
    <dir>/leaders.parquet                 one row per candidate
    <dir>/fills.parquet                   every fill of every candidate
    v}

    The raw files are the system of record; the Parquet files are rebuilt from them at the
    end of every [collect]. The manifest sits under [_manifest/] because pyarrow and
    DuckDB globs skip [_]-prefixed names. *)

open! Core
open Hl_protocol

val leaderboard : string -> string
val fills : string -> Address.t -> string
val state : string -> Address.t -> string
val progress : string -> string
val leaders_parquet : string -> string
val fills_parquet : string -> string
