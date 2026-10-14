# test/ (AGENTS.md)

Expect tests decode real mainnet responses saved in `test/fixtures/` (leaderboard rows,
fills, `clearinghouseState`, portfolio), then check scoring and the API shapes.

- Fixtures are captured responses, trimmed. Name each one after its source endpoint.
- Promote expect output with `dune promote` only after reading each diff.
- Run from the repository root with `opam exec --switch 5.2.0+ox -- dune build --root .. @hl-leaderboard/runtest`.
