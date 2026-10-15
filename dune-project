(lang dune 3.17)

(name hl-leaderboard)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/hl-leaderboard))

(package
 (name hl-leaderboard)
 (synopsis
  "Hyperliquid leader discovery: leaderboard, fill history and account state collector, ranking and a small JSON API")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  async
  async_ssl
  cohttp
  cohttp-async
  http
  uri
  yojson
  ppx_jane
  ppx_yojson_conv
  parquet
  market-data
  hl-protocol
  venue-net
  hl-client
  hl-copy-core
  leader-scoring
  leader-scoring-hl))
