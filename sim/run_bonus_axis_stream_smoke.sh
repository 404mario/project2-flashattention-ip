#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="sim_build"
TB_INCLUDE="$ROOT/tb/sv"
source "$ROOT/sim/common.sh"
mkdir -p "$BUILD"

OUT="$BUILD/tb_flash_attn_axis_top_smoke.vvp"
HEX="$BUILD/tb_flash_attn_axis_top_smoke_o.hex"
LOG="${OUT%.vvp}.log"

SOURCES=(
    "$ROOT/rtl/include/flash_attn_pkg.sv"
    "$ROOT/rtl/core/tile_scheduler.sv"
    "$ROOT/rtl/mem/row_buffer.sv"
    "$ROOT/rtl/mem/tile_buffer.sv"
    "$ROOT/rtl/core/dot_product_engine.sv"
    "$ROOT/rtl/core/causal_mask_unit.sv"
    "$ROOT/rtl/core/online_softmax_engine.sv"
    "$ROOT/rtl/core/value_accumulator.sv"
    "$ROOT/rtl/core/quantize_saturate.sv"
    "$ROOT/rtl/core/normalizer.sv"
    "$ROOT/rtl/core/flash_core.sv"
    "$ROOT/rtl/top/flash_attn_axis_top.sv"
    "$ROOT/tb/sv/tb_flash_attn_axis_top_smoke.sv"
)

iverilog -g2012 -Wall \
    -I "$TB_INCLUDE" \
    -s tb_flash_attn_axis_top_smoke \
    -o "$OUT" \
    "${SOURCES[@]}"

vvp "$OUT" "+OUT_HEX=$HEX" 2>&1 | tee "$LOG"
if grep -qE "FAIL|FATAL" "$LOG"; then
    echo "ERROR: AXI4-Stream smoke reported FAIL/FATAL" >&2
    exit 1
fi

"$PYTHON_BIN" "$ROOT/model/check_top_e2e_output.py" \
    --hex "$HEX" \
    --s-len 8 \
    --d-model 8 \
    --bk 4 \
    --scale-q8-8 91 \
    --frac-w 8 \
    --softmax-frac 16 \
    --valid-len 8 \
    --check-fp32

echo "Bonus AXI4-Stream smoke passed."
