# bin/ (AGENTS.md)

The `hl-leaderboard` executable with three commands: `collect -out DIR`, `rank -in DIR -out FILE`
and `serve -port P -dir DIR`. The flags, including `-network` and `-base-url`, are documented
in the root `README.md`.

Build and run from the repository root:
`opam exec --switch 5.2.0+ox -- dune exec hl-leaderboard -- collect -help`.

Rules that matter here:

- Target selection is by flag (`-network`, `-base-url`); the same code runs against `hl-sim`.
  Do not hard-code a host.
- A new command or flag gets a line in the README and a test of its parsing.
