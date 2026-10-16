# hl-leaderboard

Leader discovery for the copy-trading platform: collects the Hyperliquid leaderboard and,
for the top traders, their fill history, account state and portfolio curves; ranks them
with the shared score from `hl-copy-core`; and serves the ranking as JSON for the API and
the frontend.

Read-only. It sends `GET` requests to the stats host and `POST /info` requests; it holds no
keys and never signs or sends an exchange action, so pulling from mainnet is safe.

## Commands

```sh
# Collect: leaderboard, then fills, clearinghouseState and portfolio of the candidates
hl-leaderboard collect -out data/ [-network mainnet|testnet|local] [-base-url URL] \
  [-top 20] [-windows day,week,month,allTime] [-min-account-value 10000] \
  [-include-roles user] [-lookback-days 30] [-max-pages 5] [-weight-per-minute 1200]

# Rank: score every collected leader, write the ranking, print the top 10
hl-leaderboard rank -in data/ -out data/leaders.json [-min-trades 5]

# Serve /leaders and /leaders/<address>
hl-leaderboard serve -port 8090 -dir data/ [-leaders data/leaders.json]
```

`-network local` targets hl-sim on `http://localhost:3000`, which serves the leaderboard
and `userRole` as `/info` requests; `-base-url` and `-leaderboard-url` point anywhere else.

### collect

1. Fetches the leaderboard (`https://stats-data.hyperliquid.xyz/Mainnet/leaderboard`,
   about 40 MB and 47k rows) and picks the candidates: the top `-top` rows by pnl in each
   window, at least `-min-account-value`, without duplicates, whose `userRole` is in
   `-include-roles` (default `user`; also `agent`, `vault`, `subAccount`, `missing`).
   The leaderboard lists vaults (HLP is 8th by all-time pnl), sub-accounts and API
   wallets next to traders; a skipped row makes room for the next one in that window, so
   each window still yields `-top` candidates. Roles are asked only for the rows the
   walk reaches, once per address. A row whose role cannot be read (the request still
   fails after its retries) is skipped on every network.
2. For each candidate: `userFillsByTime` from `-lookback-days` ago, paged forward
   (`Fill_pages`: at most 2000 fills per page, the next page starts at the newest time of
   the previous one and repeats are dropped by `(tid, oid)`), at most `-max-pages` pages;
   then one `clearinghouseState`, one `portfolio` and the `userFunding` pages since the
   newest payment logged (the last two optional; hl-sim has neither).
3. For the copy-cost estimate: one `l2Book` for each of the 25 coins the candidates
   trade most by notional, and one `metaAndAssetCtxs` for open interest (optional).
4. Rebuilds `leaders.parquet` and `fills.parquet` from the raw logs.

Every response is appended to the raw logs as it arrives, in market-recorder's line
format (`<recv_ts> <body>`, ISO 8601 UTC with microseconds). The candidate list is fixed
in `_manifest/progress.sexp` when a run starts and each address is marked when done, so
an interrupted run resumes with the remaining addresses, and each fill walk resumes after
the newest fill already logged. A finished run starts over with a fresh leaderboard.

```text
data/
  raw/leaderboard/<YYYY-MM-DD>T<HH>-<MM>.ndjson  one file per leaderboard fetch
  raw/fills/<address>.ndjson                     one line per userFillsByTime page
  raw/state/<address>.ndjson                     one line per clearinghouseState
  raw/portfolio/<address>.ndjson                 one line per portfolio
  raw/role/<address>.ndjson                      one line per userRole, skipped rows too
  raw/funding/<address>.ndjson                   one line per userFunding page
  raw/books/<coin>.ndjson                        one line per l2Book
  raw/market/meta_and_asset_ctxs.ndjson          one line per metaAndAssetCtxs
  reports/<address>.json                         leader-scoring report, written by rank
  _manifest/progress.sexp                        candidates and addresses done
  _manifest/candidates.json                      the candidates' leaderboard rows
  leaders.parquet                                one row per candidate, with its role
  fills.parquet                                  every fill of every candidate
```

The manifest lives under `_manifest/` because pyarrow and DuckDB globs skip `_` names.
Parquet files are written to `<path>.tmp` and renamed. Columns are listed in
`lib/parquet_out.mli`; for example:

```sh
duckdb -c "select address, count(*), sum(closed_pnl - fee) from 'data/fills.parquet' group by 1"
```

### Rate limits

Hyperliquid allows 1200 request weight per minute per IP. `Rate_limit` is a token bucket
(capacity and refill = `-weight-per-minute`, FIFO waiters) charged before each request
with the documented weights: 20 for most info requests, 2 for `clearinghouseState`, 60
for `userRole`, and for
`userFillsByTime` 20 up front plus 1 per 20 fills returned, charged after the response (a
full page costs 120). The stats host is a CDN and is not charged. HTTP 429, 5xx and
transport errors are retried with exponential backoff (0.5 s, 1 s, 2 s, ...), 5 attempts.
A 40-address run with full fill histories costs about 15k weight, 13 minutes at 1200;
the role checks add 60 per address reached (about 3k for 52 addresses, 2.5 minutes).

## Score

`rank` calls `Hl_copy_core.Score.compute` (formula and its invariants in the hl-copy-core
README):

```text
score = return * (1 - max_drawdown) * (0.5 + 0.5 * consistency) * min(1, trade_count / 20)
```

What this repository feeds it:

- **Fills**: perpetual fills only (spot pairs such as `@107` cannot be mirrored on a perp
  account). Round trips are found by tracking each coin's position from zero, but a
  fetched history usually starts with a position open; for those coins a synthetic
  opening fill of the first `startPosition` (no pnl, no fee, `tid = -1`) is put 1 ms
  before the first fill.
- **Equity curve**: the `month` window of `portfolio`: the account value at the window
  start plus the cumulative pnl, so deposits and withdrawals do not count as gains or
  drawdowns. Without a portfolio (hl-sim), the curve is walked back from the current
  account value through each fill's `closedPnl - fee` (`Equity_curve`), which misses
  unrealized pnl, funding and transfers.
- **Truncation**: Hyperliquid serves only the 10000 most recent fills, which is an hour or
  two for the most active accounts. `truncated` marks a leader with at least 2000 fills
  whose first fill is later than the start of the curve: its trade statistics cover only
  the end of the window.
- Leaders with fewer than `-min-trades` round trips are listed after the ranked ones,
  with `rank: null`.

## leader-scoring

`rank` also scores every collected leader with
[leader-scoring](https://github.com/winterchill-trading/leader-scoring) (`Scoring`, skip
with `-no-scoring`): a track record rebuilt from the raw logs (fills with their
liquidation flags, funding, every `clearinghouseState` taken, the `portfolio` month
curve), 34 metrics, a weighted percentile composite across the collected leaders, the
learned model's forecast of the next 30 days' Sharpe ratio, a capacity curve from the
collected books, and alerts. Each leader's full report goes to `reports/<address>.json`
(before `leaders.json`, so the server never sees a ranking without its reports), and
every ranking entry gains a `scoring` summary. The legacy score above, its `rank` and the
order of `leaders.json` are unchanged.

Across the collected leaders `rank` also runs leader-scoring's universe checks
(`Report.analyse`) and writes them to `leaders.json` as `scoring_universe`:

- **Persistence**: does the ranking in one window predict the next (rank correlation with
  a bootstrap interval, quintile transitions, decay, the top 10 against random picks).
  Bars and windows follow the records: daily bars and windows of a fifth of the median
  span (about six days on the month curves), minute bars on a simulator run
  (`Scoring.configs`). With a month of history this is a handful of windows; read it as a
  warning sign, not a proof.
- **Selection statistics**: PSR, DSR (the collected leaders are the trials) and the
  minimum track record per leader; PBO and SPA over the common window.
- **Integrity**: flags from the leaders' fills (self and wash trades, trades between
  collected accounts, co-trading clusters), the logged books (fills more than 50 bps off
  the recorded quotes or the other leaders' fills at that time) and first-seen times (the
  first point of the all-time `portfolio` curve stands in for account creation). The
  default policy takes every warning or critical flag out of the composite ranking: the
  leader is still scored, with the reasons. Front-running needs a trade flow, which
  collection does not record yet.

Each report gains `persistence`, `stats` and `integrity`, and each `scoring` summary
`integrity_flags`, `excluded`, `persistence_percentile`, `psr` and `dsr`.

On a mainnet collection of 34 leaders (146,761 fills, month curves, read only,
collected 2026-10-13), `rank` gave: 6-day windows of daily bars, 3 periods, rank
correlation 0.26 [0.04, 0.44], the top 10 at the 97th percentile of random picks
(p 0.034), so `persistent` is true, on three periods only; PSR at least 0.95 for 3
leaders, DSR at least 0.95 for 1; PBO 0.00 and SPA p 0.00 over 17 leaders sharing 29
days. Integrity: three accounts first seen within 40 minutes of each other (info, not
excluded), nothing else. A first run with a 50 bps off-book threshold and a 2 s reference
window flagged one leader whose STRK sell sweep filled 70 to 82 bps below another
leader's prints; the defaults are now 200 bps and 0.5 s. On the simulator (43 accounts
that only trade with each other) the first thresholds excluded everyone as counterparties
and co-traders; chance is now measured inside the observed span and against random
matching, and no simulator account is excluded.

On the local copy stack (hl-sim with three leaders and 40 noise traders, 2026-10-16):
`collect -top 10` took 3 minutes (63k fills, 5005 weight), `rank` 1.8 s for 10 leaders
including the reports.

## API

| Request | Response |
| --- | --- |
| `GET /leaders[?limit=N]` | The ranking file: `generated_at`, `formula`, `leaders` (rank, address, display name, `role` (`userRole` name or null), account value, leaderboard windows, fill counts, `curve_source`, `truncated`, `score`, `components` and `scoring`: composite score, rank, percentile, eligibility, forecast, capacity, alert count and worst severity, headline metrics, integrity flag kinds, exclusion, persistence percentile, PSR, DSR) and `scoring_universe` (persistence, selection statistics, integrity counts); re-read when the file changes |
| `GET /leaders/<address>[?limit=N]` | `entry` (the ranking entry or null), `fill_count`, `fills` (newest first, default 500), `equity_curve` (`[[time_ms, equity], ...]`), `curve_source`, `positions` (latest `clearinghouseState`), `report` (the leader-scoring report: metrics, score components, forecast, equity curve, capacity curve, alerts, persistence row, selection statistics, integrity flags with evidence; null before a ranking with it) |
| `GET /scoring/metrics` | Every leader-scoring metric with label, unit, direction and formula |
| `GET /health` | `"ok"` |

A malformed address is a 400, an address with nothing collected a 404. Every response has
`Access-Control-Allow-Origin: *`.

## Library

| Module | Purpose |
| --- | --- |
| `Board` | Candidate selection over `Hl_protocol.Leaderboard` rows (`top`, `candidates`) |
| `Roles` | `userRole` filter over the candidate walk (`-include-roles`) |
| `Api` | Rate-limited, retried read-only client returning raw bodies and decoded values |
| `Rate_limit` | Token bucket and the documented request weights |
| `Fill_pages` | Forward walk over `userFillsByTime` pages with de-duplication |
| `Portfolio` | `portfolio` decoding and the deposit-free equity curve |
| `Equity_curve` | Fallback curve rebuilt from fills |
| `Raw_log`, `Layout`, `Progress` | Raw response logs, directory layout, resumable manifest |
| `Collect` | The `collect` run |
| `Dataset` | A collection directory read back from the raw logs |
| `Parquet_out` | `leaders.parquet` and `fills.parquet` |
| `Rank` | Score input, ranking and its JSON |
| `Scoring` | leader-scoring reports from the raw logs, the universe checks (persistence, selection statistics, integrity), summaries for the ranking |
| `Server` | The JSON API |

`Hl_client.Leaderboard.fetch`, `Hl_client.Info.user_fills_by_time` and
`Hl_client.Info.user_role` cover the same requests; this repository keeps its own `Api` because the collector stores every raw body
and paces requests through one shared bucket.

## Tests

```sh
dune build @all @runtest
```

Expect tests decode real mainnet responses (`test/fixtures/`: six leaderboard rows with
one display name replaced, six fills from a 2000-fill page, one `clearinghouseState`, one
`portfolio`), run the rate limiter on a synthetic clock, walk fill pages across
millisecond boundaries, and run `collect`, `rank` and `serve` end to end against a local
stand-in for the stats host and `/info` (`test/fake_hl.ml`), including a 429 retry, a
failed address, a resumed run, a restart, and a vault and a sub-account skipped for the
next rows.

`scripts/sim-e2e.sh` runs the same flow against a real hl-sim with noise traders (its
`leaderboard`, `userFillsByTime` and `clearinghouseState` info requests):

```sh
HL_SIM=path/to/hl-sim HL_LEADERBOARD=path/to/hl-leaderboard scripts/sim-e2e.sh
```

## Sample ranking (mainnet)

A read-only pull on 2026-10-13 (07:24 to 07:34 UTC):

```sh
hl-leaderboard collect -out data -top 15 -windows week,month,allTime \
  -min-account-value 100000 -max-pages 5 -weight-per-minute 900
hl-leaderboard rank -in data -out data/leaders.json
```

- Leaderboard: 47,245 rows; 34 candidates (top 15 by pnl in three windows, overlapping).
- 154,965 fills over 10,436 weight in 10.6 minutes, no retries; raw logs 82 MB (the
  leaderboard file is 38 MB of it), `fills.parquet` 7.4 MB; `rank` takes 1 s.
- Every candidate had a `portfolio` curve; 17 of 34 have a truncated fill history (the
  10000-fill cap reached within the month); 15 had no fill in the last 30 days.
- Only 5 of 34 reach the default 5 round trips: the largest accounts rarely go flat in a
  coin, so their trips are few even with thousands of fills. The rest are listed
  unranked.

| Rank | Address | Score | Pnl (fills) | Return | Max drawdown | Win rate | Trips | Avg hold (h) | Consistency | Truncated |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `0x880ac484a1743862989a441d6d867238c7aa311c` | 0.0087 | 230936 | 0.048 | 0.425 | 0.60 | 10 | 40.6 | 0.25 | yes |
| 2 | `0xfc27136e42af1732ddc9ce2605ea9bff1b959d9d` | 0.0012 | 441435 | 0.013 | 0.635 | 0.62 | 8 | 0.9 | 0.25 | yes |
| 3 | `0x77375a8c9d13bf79afb2a87f1b0ac1dfd5f5bf66` | 0.0000 | 681 | 0.000 | 0.134 | 0.33 | 6 | 139.5 | 0.50 | no |
| 4 | `0xbdfa4f4492dd7b7cf211209c4791af8d52bf5c50` | -0.0000 | -2995 | -0.000 | 0.173 | 0.40 | 35 | 0.2 | 0.00 | yes |
| 5 | `0xecb63caa47c7c4e77f60f1ce858cf28dc2b82b00` | -0.0001 | -72853 | -0.001 | 0.214 | 0.29 | 7 | 0.6 | 0.00 | yes |

`Return` is the fills' realized pnl over the month curve's starting equity, so for a
truncated history it covers only the last hours of the month; read it next to the
leaderboard's own `roi` per window, which `/leaders` carries for each leader.
