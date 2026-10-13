open! Core
open Hl_protocol

let leaderboard dir = dir ^/ "raw" ^/ "leaderboard.ndjson"
let fills dir address = dir ^/ "raw" ^/ "fills" ^/ Address.to_string address ^ ".ndjson"
let state dir address = dir ^/ "raw" ^/ "state" ^/ Address.to_string address ^ ".ndjson"
let progress dir = dir ^/ "_manifest" ^/ "progress.sexp"
let leaders_parquet dir = dir ^/ "leaders.parquet"
let fills_parquet dir = dir ^/ "fills.parquet"
