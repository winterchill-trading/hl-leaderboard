#!/usr/bin/env bash
# End-to-end run against a local hl-sim: start the simulator with noise traders, let
# them trade, then collect (leaderboard over POST /info, userFillsByTime,
# clearinghouseState), rank, serve, and check the API answers.
#
#   HL_SIM=path/to/hl-sim HL_LEADERBOARD=path/to/hl-leaderboard scripts/sim-e2e.sh
#
# Without the variables both binaries are run through `dune exec` from the dune
# workspace that holds this repository and hl-sim.
set -euo pipefail

SIM_PORT=${SIM_PORT:-3019}
API_PORT=${API_PORT:-8099}
TRADE_SECONDS=${TRADE_SECONDS:-20}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/hl-leaderboard-e2e.XXXXXX")

sim() { if [ -n "${HL_SIM:-}" ]; then "$HL_SIM" "$@"; else dune exec hl-sim -- "$@"; fi; }
lb() { if [ -n "${HL_LEADERBOARD:-}" ]; then "$HL_LEADERBOARD" "$@"; else dune exec hl-leaderboard -- "$@"; fi; }

pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

sim -port "$SIM_PORT" -noise-traders 6 -seed 7 >"$OUT/sim.log" 2>&1 &
pids+=($!)
for _ in $(seq 50); do
  curl -sf -X POST "localhost:$SIM_PORT/info" -d '{"type":"allMids"}' >/dev/null && break
  sleep 0.2
done
echo "simulator up on $SIM_PORT; trading for ${TRADE_SECONDS}s"
sleep "$TRADE_SECONDS"

lb collect -out "$OUT/data" -network local -base-url "http://127.0.0.1:$SIM_PORT" \
  -min-account-value 0 -top 3 -lookback-days 1 2>"$OUT/collect.log"
lb rank -in "$OUT/data" -out "$OUT/data/leaders.json" -min-trades 1 2>>"$OUT/collect.log"

lb serve -port "$API_PORT" -dir "$OUT/data" 2>"$OUT/serve.log" &
pids+=($!)
for _ in $(seq 50); do curl -sf "localhost:$API_PORT/health" >/dev/null && break; sleep 0.2; done

leaders=$(curl -sf "localhost:$API_PORT/leaders")
first=$(printf '%s' "$leaders" | python3 -c 'import json,sys; print(json.load(sys.stdin)["leaders"][0]["address"])')
detail=$(curl -sf "localhost:$API_PORT/leaders/$first?limit=3")
printf '%s' "$detail" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["fill_count"] > 0, "no fills collected"
assert len(d["fills"]) <= 3
assert len(d["equity_curve"]) >= 1
print("leader", d["address"], "fills", d["fill_count"], "curve points", len(d["equity_curve"]))
'
echo "ok: $OUT"
