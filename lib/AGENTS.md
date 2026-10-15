# lib/ (AGENTS.md)

The `hl_leaderboard` library: the collector (leaderboard, fills, `clearinghouseState`,
portfolio, funding, books and open interest, resumable), the ranking pipeline that calls
`Hl_copy_core.Score`, `Scoring` (leader-scoring reports per leader), the decoders for each
response, and the HTTP read API (`GET /leaders`, `GET /leaders/<address>`,
`GET /scoring/metrics`, `GET /health`).

Build from the repository root with
`opam exec --switch 5.2.0+ox -- dune build --root .. @hl-leaderboard/all`.

Rules that matter here:

- Decoders accept what the API really sends: check against `test/fixtures` before you
  loosen or tighten one.
- Pagination depends on the endpoint's order; state the order in a comment next to the cursor.
- Keep the collector's progress file readable after a restart; a resume must not refetch what
  it already stored.
