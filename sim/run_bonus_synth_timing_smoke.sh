#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="sim_build"
TB_INCLUDE="$ROOT/tb/sv"
source "$ROOT/sim/common.sh"
mkdir -p "$BUILD"

SOURCES=(
    "$ROOT/rtl/include/flash_attn_pkg.sv"
    "$ROOT/rtl/include/fp8_e4m3_pkg.sv"
    "$ROOT/rtl/include/bf16_pkg.sv"
    "$ROOT/rtl/axi/axi_lite_regs.sv"
    "$ROOT/rtl/axi/axi_master_read.sv"
    "$ROOT/rtl/axi/axi_master_write.sv"
    "$ROOT/rtl/axi/dma_controller.sv"
    "$ROOT/rtl/axi/dma_controller_fp8.sv"
    "$ROOT/rtl/axi/dma_controller_bf16.sv"
    "$ROOT/rtl/core/tile_scheduler.sv"
    "$ROOT/rtl/mem/row_buffer.sv"
    "$ROOT/rtl/mem/tile_buffer.sv"
    "$ROOT/rtl/core/dot_product_engine.sv"
    "$ROOT/rtl/core/dot_stream.sv"
    "$ROOT/rtl/core/softmax_combine.sv"
    "$ROOT/rtl/core/causal_mask_unit.sv"
    "$ROOT/rtl/core/online_softmax_engine.sv"
    "$ROOT/rtl/core/value_accumulator.sv"
    "$ROOT/rtl/core/quantize_saturate.sv"
    "$ROOT/rtl/core/normalizer.sv"
    "$ROOT/rtl/core/flash_core.sv"
    "$ROOT/rtl/top/flash_attn_top.sv"
    "$ROOT/tb/sv/tb_flash_attn_top_e2e_smoke.sv"
)

OUT="$BUILD/tb_flash_attn_top_e2e_synth_timing_vectors.vvp"
HEX="$BUILD/tb_flash_attn_top_e2e_synth_timing_vectors_o.hex"
LOG="${OUT%.vvp}.log"

iverilog -g2012 -Wall \
    -I "$TB_INCLUDE" \
    -s tb_flash_attn_top_e2e_smoke \
    -P tb_flash_attn_top_e2e_smoke.S_LEN=256 \
    -P tb_flash_attn_top_e2e_smoke.D_MODEL=64 \
    -P tb_flash_attn_top_e2e_smoke.BK=16 \
    -P tb_flash_attn_top_e2e_smoke.BQ=16 \
    -P tb_flash_attn_top_e2e_smoke.SOFTMAX_FRAC=16 \
    -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8=32 \
    -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT=0 \
    -P tb_flash_attn_top_e2e_smoke.TIMEOUT_CYCLES=2000000 \
    -P tb_flash_attn_top_e2e_smoke.MAX_CYCLES=300000 \
    -P tb_flash_attn_top_e2e_smoke.PROGRESS_EVERY=10000 \
    -P tb_flash_attn_top_e2e_smoke.STATIC_SCALE_MODE=1 \
    -P tb_flash_attn_top_e2e_smoke.STATIC_SCALE_Q8_8=32 \
    -P tb_flash_attn_top_e2e_smoke.ENABLE_DROPOUT=0 \
    -o "$OUT" \
    "${SOURCES[@]}"

vvp "$OUT" \
    "+USE_VECTOR_FILES=1" \
    "+Q_HEX=$ROOT/tb/vectors/input_q.hex" \
    "+K_HEX=$ROOT/tb/vectors/input_k.hex" \
    "+V_HEX=$ROOT/tb/vectors/input_v.hex" \
    "+OUT_HEX=$HEX" 2>&1 | tee "$LOG"
if grep -qE "FAIL|FATAL" "$LOG"; then
    echo "ERROR: Synth timing vector smoke reported FAIL/FATAL" >&2
    exit 1
fi

"$PYTHON_BIN" "$ROOT/model/check_top_e2e_output.py" \
    --hex "$HEX" \
    --s-len 256 \
    --d-model 64 \
    --bk 16 \
    --scale-q8-8 32 \
    --frac-w 8 \
    --softmax-frac 16 \
    --valid-len 256 \
    --check-fp32 \
    --max-mae "${MAX_MAE:-0.03}" \
    --max-maxe "${MAX_MAXE:-0.10}" \
    --q-hex "$ROOT/tb/vectors/input_q.hex" \
    --k-hex "$ROOT/tb/vectors/input_k.hex" \
    --v-hex "$ROOT/tb/vectors/input_v.hex" \
    --golden-hex "$ROOT/tb/vectors/golden_o.hex"

echo "Bonus synthesis-timing optimized random full-size vector smoke passed."
