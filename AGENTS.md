# AGENTS.md (hl-leaderboard)

## Purpose

Leader discovery for the copy-trading platform: it reads the public Hyperliquid leaderboard
and each candidate's fills, account state and portfolio curves (no keys, read only), scores
them with `hl-copy-core`, and serves the ranked list as JSON.

Workspace-wide rules, the repository map and the CI model are in
`../oxcaml-claude-skills/AGENTS.md`. Read that first.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | The `hl_leaderboard` library: collection, the rank pipeline, the HTTP read API, the response decoders ([lib/AGENTS.md](lib/AGENTS.md)) |
| `bin/` | The `hl-leaderboard` executable with the `collect`, `rank` and `serve` commands |
| `test/` | Expect tests on real mainnet responses, and `test/fixtures/` ([test/AGENTS.md](test/AGENTS.md)) |
| `scripts/` | `sim-e2e.sh`, collection and ranking against a running `hl-sim` |
| `.github/` | CI workflow ([.github/AGENTS.md](.github/AGENTS.md)) |
| `README.md` | Commands, rate limits, the score, the API, a sample ranking |

## Build and test

From this repository, inside the workspace:

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @hl-leaderboard/all @hl-leaderboard/runtest
```

For parallel work give the build its own directory, relative to the workspace root:
`DUNE_BUILD_DIR=_build-hl-leaderboard` in front of the same command.

Standalone, with the published dependencies:

```sh
opam repo add winterchill https://github.com/winterchill-trading/opam-repository.git
opam install . --deps-only --with-test
dune build && dune test
```

Format only this repository, after the tests pass:
`dune build --root .. @hl-leaderboard/fmt --auto-promote`. Never run `dune fmt` at the workspace root.

## Conventions

- Core style: `open! Core`, an `.mli` for every module, labelled arguments, expect tests and
  Base_quickcheck properties.
- The scoring lives in `hl-copy-core` (`Score`) and `leader-scoring` (metrics, composite,
  forecast, capacity, alerts). This repository does not reimplement either; it feeds them
  (`Rank`, `Scoring`) and serves the result.
- Requests are read only. No code path here signs or sends an exchange action.
- Collection is resumable through `_manifest/progress.sexp`; a change to its format needs a
  migration note in the README.
- Odoc on every public value; comments at every pinned limit, saying what it protects.

## Dependencies and dependents

- Depends on `hl-copy-core`, `leader-scoring` and `leader-scoring-hl` (one repository,
  `../leader-scoring`, which needs `backtest-stats` pinned before it), `hl-client`, `hl-protocol`, `market-data`, `parquet`, `venue-net`,
  `exchange-core` and `fixed-decimal`. The pin order is in `.github/workflows/ci.yml`;
  dependents that build this repository (`../hl-copy-api`, `../hl-copy-core`'s backtest
  job) pin `leader-scoring` before it.
- Used by `../hl-copy-api` (proxies `GET /leaders` to `serve`) and by `../hl-copy-core`'s
  backtest, which reads the collection directory.
- Spec: `../specs/repos/hl-leaderboard.md`; the platform design is in `../specs/design/copytrading.md`.

## CI

`.github/workflows/ci.yml` has two jobs. `build` runs the `ox-setup` action (the switch and
the pinned siblings, cached on the pins), then `dune build` and `dune test`. `obj-magic`
calls the shared reusable workflow from `infra`.

Check a run with one `gh run list --limit 1` and at most one
`gh run watch <id> --exit-status`. Never poll in a loop.

## Pitfalls

- Most top traders never go flat inside the 10,000-fill window. Insert a synthetic opening
  fill for positions held at the start of history, or their pnl reads zero.
- `userFillsByTime` returns the oldest 2000 fills at or after `startTime`, oldest first;
  `userFills` returns the newest first. Paging code must use the one that matches its cursor.
- Use the portfolio `month` series as the equity curve. `perpMonth` omits spot collateral.
- Fill histories include spot coins (`@210`) and builder perps (`xyz:NVDA`); the decoders
  must accept both.
- A role lookup costs 60 weight per address and returns `missing` for unseen addresses. The
  collector skips such rows instead of retrying them.
- `rank` writes `reports/<address>.json` before `leaders.json`; keep that order, the server
  reads reports when the ranking file changes.
- The universe checks (persistence, selection statistics, integrity) run once over every
  scored leader in `Scoring.score_all`; their settings follow the records' span
  (`Scoring.configs`). A simulator run of seconds has no complete window and too few bars:
  `persistence` and `stats` are then absent, which is expected.
- Every leader in a simulator is a counterparty of every other; integrity thresholds were
  calibrated so none is excluded (`scripts/e2e-stack.sh` in hl-copy-api checks it). A
  change that excludes simulator accounts is a regression.
- A whole collection run can cost over ten thousand weight. Respect `-weight-per-minute`
  and the README's rate-limit section when you change pagination.

## Where to read more

- `README.md`, `../specs/repos/hl-leaderboard.md`, `../specs/design/copytrading.md`
- `../oxcaml-claude-skills/AGENTS.md`, `../oxcaml-claude-skills/GOTCHAS.md`
- Skill: `../oxcaml-claude-skills/skills/async-http-websocket` for the HTTP read API

## Never do

- Install or upgrade opam packages that change the compiler, `core`, `base`, `async` or
  `ppx_jane` on the shared switch. Dry-run first: `opam install --switch 5.2.0+ox --dry-run <pkg>`.
- Add a request that signs or submits anything.
- Publish, tag or release.
- Commit credentials. Values come from the environment only.
- Print secrets or account data you collected.
