#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== integrated bonus: inherited baseline compile ==="
./sim/run_top_compile.sh

echo "=== integrated bonus: inherited baseline/top smoke ==="
./sim/run_top_e2e_smoke.sh

echo "=== integrated bonus: configurable sequence smoke ==="
./sim/run_bonus_sequence_smoke.sh

echo "=== integrated bonus: task queue smoke ==="
./sim/run_bonus_task_queue_smoke.sh

echo "=== integrated bonus: AXI4-Stream smoke ==="
./sim/run_bonus_axis_stream_smoke.sh

echo "=== integrated bonus: dropout smoke ==="
./sim/run_bonus_dropout_smoke.sh

echo "=== integrated bonus: multi-head smoke ==="
./sim/run_bonus_multi_head_smoke.sh

echo "Integrated bonus quick checks passed."
