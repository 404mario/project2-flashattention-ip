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
    shift
    local log="${path%.vvp}.log"
    vvp "$path" "$@" 2>&1 | tee "$log"
    if grep -qE "FAIL|FATAL" "$log"; then
        echo "ERROR: Simulation reported FAIL/FATAL: $path" >&2
        exit 1
    fi
}

check_output() {
    local hex_path="$1"
    local s_len="$2"
    local d_model="$3"
    local bk="$4"
    local scale="$5"
    "$PYTHON_BIN" "$ROOT/model/check_top_e2e_output.py" \
        --hex "$hex_path" \
        --s-len "$s_len" \
        --d-model "$d_model" \
        --bk "$bk" \
        --scale-q8-8 "$scale" \
        --frac-w 8 \
        --softmax-frac 16 \
        --valid-len "$s_len" \
        --check-fp32
}

run_case() {
    local name="$1"
    local s_len="$2"
    local d_model="$3"
    local bk="$4"
    local bq="$5"
    local scale="$6"
    local timeout_cycles="$7"
    local max_cycles="$8"

    local out="$BUILD/tb_flash_attn_top_e2e_${name}.vvp"
    local hex="$BUILD/tb_flash_attn_top_e2e_${name}_o.hex"

    iverilog -g2012 -Wall \
        -I "$TB_INCLUDE" \
        -s tb_flash_attn_top_e2e_smoke \
        -P tb_flash_attn_top_e2e_smoke.S_LEN="$s_len" \
        -P tb_flash_attn_top_e2e_smoke.D_MODEL="$d_model" \
        -P tb_flash_attn_top_e2e_smoke.BK="$bk" \
        -P tb_flash_attn_top_e2e_smoke.BQ="$bq" \
        -P tb_flash_attn_top_e2e_smoke.SOFTMAX_FRAC=16 \
        -P tb_flash_attn_top_e2e_smoke.VALID_LEN="$s_len" \
        -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8="$scale" \
        -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT=0 \
        -P tb_flash_attn_top_e2e_smoke.TIMEOUT_CYCLES="$timeout_cycles" \
        -P tb_flash_attn_top_e2e_smoke.MAX_CYCLES="$max_cycles" \
        -P tb_flash_attn_top_e2e_smoke.PROGRESS_EVERY=100000 \
        -o "$out" \
        "${SOURCES[@]}"

    run_vvp "$out" "+OUT_HEX=$hex"
    check_output "$hex" "$s_len" "$d_model" "$bk" "$scale"
}

# Bonus 3: compile-time configurable sequence length smoke.
# These cases intentionally keep D_MODEL modest so the bonus regression stays quick.
run_case "bonus_s64_d16" 64 16 8 16 64 1200000 300000
run_case "bonus_s128_d16" 128 16 8 16 64 2500000 300000

echo "Bonus configurable sequence smoke checks passed."
