open! Core
open Hl_protocol

let leaderboard dir time =
  let date, ofday = Time_ns.to_date_ofday time ~zone:Time_float.Zone.utc in
  let p = Time_ns.Span.to_parts (Time_ns.Ofday.to_span_since_start_of_day ofday) in
  dir
  ^/ "raw"
  ^/ "leaderboard"
  ^/ sprintf "%sT%02d-%02d.ndjson" (Date.to_string date) p.hr p.min
;;

let candidates dir = dir ^/ "_manifest" ^/ "candidates.json"
let fills dir address = dir ^/ "raw" ^/ "fills" ^/ Address.to_string address ^ ".ndjson"
let state dir address = dir ^/ "raw" ^/ "state" ^/ Address.to_string address ^ ".ndjson"

let portfolio dir address =
  dir ^/ "raw" ^/ "portfolio" ^/ Address.to_string address ^ ".ndjson"
;;

let role dir address = dir ^/ "raw" ^/ "role" ^/ Address.to_string address ^ ".ndjson"

let funding dir address =
  dir ^/ "raw" ^/ "funding" ^/ Address.to_string address ^ ".ndjson"
;;

(* Coin names can hold "/" (spot pairs) and ":" (builder perps); keep them out of paths. *)
let book dir coin =
  let safe =
    String.map coin ~f:(fun c ->
      if Char.is_alphanum c || Char.equal c '-' then c else '_')
  in
  dir ^/ "raw" ^/ "books" ^/ safe ^ ".ndjson"
;;

let market dir = dir ^/ "raw" ^/ "market" ^/ "meta_and_asset_ctxs.ndjson"
let report dir address = dir ^/ "reports" ^/ Address.to_string address ^ ".json"
let progress dir = dir ^/ "_manifest" ^/ "progress.sexp"
let leaders_parquet dir = dir ^/ "leaders.parquet"
let fills_parquet dir = dir ^/ "fills.parquet"
