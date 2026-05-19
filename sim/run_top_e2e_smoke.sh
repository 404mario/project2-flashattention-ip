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

run_vvp() {
    local path="$1"
    local output
    output="$(vvp "$path" 2>&1)"
    echo "$output"
    if echo "$output" | grep -qE "FAIL|FATAL"; then
        echo "ERROR: Simulation reported FAIL/FATAL: $path" >&2
        exit 1
    fi
}

# --- Small smoke (S=8, D=8) ---
SMALL_OUT="$BUILD/tb_flash_attn_top_e2e_small.vvp"
iverilog -g2012 -Wall \
    -I "$TB_INCLUDE" \
    -s tb_flash_attn_top_e2e_smoke \
    -P tb_flash_attn_top_e2e_smoke.S_LEN=8 \
    -P tb_flash_attn_top_e2e_smoke.D_MODEL=8 \
    -P tb_flash_attn_top_e2e_smoke.BK=4 \
    -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8=91 \
    -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT=1 \
    -P tb_flash_attn_top_e2e_smoke.TIMEOUT_CYCLES=200000 \
    -o "$SMALL_OUT" \
    "${SOURCES[@]}"

run_vvp "$SMALL_OUT"

# --- Full-size smoke (S=256, D=64) ---
FULL_OUT="$BUILD/tb_flash_attn_top_e2e_fullsize_smoke.vvp"
iverilog -g2012 -Wall \
    -I "$TB_INCLUDE" \
    -s tb_flash_attn_top_e2e_smoke \
    -P tb_flash_attn_top_e2e_smoke.S_LEN=256 \
    -P tb_flash_attn_top_e2e_smoke.D_MODEL=64 \
    -P tb_flash_attn_top_e2e_smoke.BK=16 \
    -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8=32 \
    -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT=0 \
    -P tb_flash_attn_top_e2e_smoke.TIMEOUT_CYCLES=8000000 \
    -o "$FULL_OUT" \
    "${SOURCES[@]}"

run_vvp "$FULL_OUT"

echo "Top end-to-end smoke checks passed."
