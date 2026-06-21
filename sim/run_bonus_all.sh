#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== integrated bonus: inherited baseline compile ==="
./sim/run_top_compile.sh

echo "=== integrated bonus: inherited baseline/top smoke (small+medium+padding+formats) ==="
./sim/run_top_e2e_smoke.sh

echo "=== integrated bonus: FULL-SIZE random-vector default path (S=256, D=64) ==="
# full-size S=256 is gated behind RUN_VECTORS in run_top_e2e_smoke.sh; exercise it
# here so the suite is genuine full-size evidence, not just quick smoke.
RUN_VECTORS=1 ./sim/run_top_e2e_smoke.sh

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

echo "=== integrated bonus: low-precision smoke ==="
./sim/run_bonus_lowprecision_int8_smoke.sh

echo "=== integrated bonus: BF16 I/O smoke ==="
./sim/run_bonus_bf16_smoke.sh

echo "Integrated bonus quick checks passed."
"$ROOT/sim/run_bonus_window_smoke.sh"
