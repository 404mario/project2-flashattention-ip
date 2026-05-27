#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/sim_build"
TB_INCLUDE="$ROOT/tb/sv"
mkdir -p "$BUILD"

SOURCES=(
    "$ROOT/rtl/include/flash_attn_pkg.sv"
    "$ROOT/rtl/axi/axi_lite_regs.sv"
    "$ROOT/rtl/axi/axi_master_read.sv"
    "$ROOT/rtl/axi/axi_master_write.sv"
    "$ROOT/rtl/axi/dma_controller.sv"
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
    "$ROOT/rtl/top/flash_attn_top.sv"
    "$ROOT/tb/sv/tb_flash_attn_top_e2e_smoke.sv"
)

OUT="$BUILD/tb_flash_attn_top_e2e_task_queue.vvp"
HEX="$BUILD/tb_flash_attn_top_e2e_task_queue_o.hex"
S_LEN=8
D_MODEL=8
BK=4
BQ=4
TASK_COUNT=2
TASK_STRIDE_BYTES=$((S_LEN * D_MODEL * 2))
ELEMS=$((S_LEN * D_MODEL))

iverilog -g2012 -Wall \
    -I "$TB_INCLUDE" \
    -s tb_flash_attn_top_e2e_smoke \
    -P tb_flash_attn_top_e2e_smoke.S_LEN="$S_LEN" \
    -P tb_flash_attn_top_e2e_smoke.D_MODEL="$D_MODEL" \
    -P tb_flash_attn_top_e2e_smoke.BK="$BK" \
    -P tb_flash_attn_top_e2e_smoke.BQ="$BQ" \
    -P tb_flash_attn_top_e2e_smoke.SOFTMAX_FRAC=16 \
    -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8=91 \
    -P tb_flash_attn_top_e2e_smoke.TASK_COUNT="$TASK_COUNT" \
    -P tb_flash_attn_top_e2e_smoke.TASK_STRIDE_BYTES="$TASK_STRIDE_BYTES" \
    -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT=0 \
    -P tb_flash_attn_top_e2e_smoke.TIMEOUT_CYCLES=500000 \
    -o "$OUT" \
    "${SOURCES[@]}"

vvp "$OUT" "+OUT_HEX=$HEX" 2>&1 | tee "${OUT%.vvp}.log"
if grep -qE "FAIL|FATAL" "${OUT%.vvp}.log"; then
    echo "ERROR: task queue smoke reported FAIL/FATAL" >&2
    exit 1
fi

for ((task = 0; task < TASK_COUNT; task++)); do
    python "$ROOT/model/check_top_e2e_output.py" \
        --hex "$HEX" \
        --hex-offset "$((task * ELEMS))" \
        --s-len "$S_LEN" \
        --d-model "$D_MODEL" \
        --bk "$BK" \
        --scale-q8-8 91 \
        --frac-w 8 \
        --softmax-frac 16 \
        --valid-len "$S_LEN" \
        --task-index "$task" \
        --check-fp32
done

echo "Bonus task queue smoke passed."
