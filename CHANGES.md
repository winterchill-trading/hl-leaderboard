# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- `rank` runs leader-scoring's universe checks (`Report.analyse`): rank persistence with a
  random-pick baseline, PSR/DSR/PBO/SPA, and integrity flags from fills, logged books and
  first-seen times. `leaders.json` gains `scoring_universe`; each report gains
  `persistence`, `stats` and `integrity`; each `scoring` summary `integrity_flags`,
  `excluded`, `persistence_percentile`, `psr` and `dsr`. Leaders excluded by the default
  integrity policy are scored but not ranked.
- `Scoring.quotes`, `Scoring.first_seen`, `Scoring.configs`, `Scoring.universe_json`;
  `Rank.to_json ?universe`.

### Changed

- `Scoring.score_all` returns the universe checks next to the scored leaders.
- CI pins `backtest-stats`, which leader-scoring now needs.
