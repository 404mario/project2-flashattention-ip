#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== unified bonus skeleton: inherited baseline compile ==="
./sim/run_top_compile.sh

echo "=== unified bonus skeleton: inherited baseline smoke ==="
./sim/run_top_e2e_smoke.sh

cat <<'MSG'
=== unified bonus skeleton status ===
Bonus feature ports are intentionally pending on this clean PPA-baseline branch.
Port one bonus feature at a time, then extend this script with its regression.
MSG

