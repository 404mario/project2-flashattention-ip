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

check_bf16_output() {
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
        --data-w 16 \
        --frac-w 8 \
        --softmax-frac 16 \
        --valid-len "$s_len" \
        --bf16-io \
        --check-fp32 \
        --max-mae "${MAX_MAE:-0.03}" \
        --max-maxe "${MAX_MAXE:-0.10}"
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

    local out="$BUILD/tb_flash_attn_top_e2e_bf16_${name}.vvp"
    local hex="$BUILD/tb_flash_attn_top_e2e_bf16_${name}_o.hex"

    iverilog -g2012 -Wall \
        -I "$TB_INCLUDE" \
        -s tb_flash_attn_top_e2e_smoke \
        -P tb_flash_attn_top_e2e_smoke.S_LEN="$s_len" \
        -P tb_flash_attn_top_e2e_smoke.D_MODEL="$d_model" \
        -P tb_flash_attn_top_e2e_smoke.BK="$bk" \
        -P tb_flash_attn_top_e2e_smoke.BQ="$bq" \
        -P tb_flash_attn_top_e2e_smoke.DATA_W=16 \
        -P tb_flash_attn_top_e2e_smoke.FRAC_W=8 \
        -P tb_flash_attn_top_e2e_smoke.SOFTMAX_FRAC=16 \
        -P tb_flash_attn_top_e2e_smoke.BF16_IO_MODE=1 \
        -P tb_flash_attn_top_e2e_smoke.VALID_LEN="$s_len" \
        -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8="$scale" \
        -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT=0 \
        -P tb_flash_attn_top_e2e_smoke.TIMEOUT_CYCLES="$timeout_cycles" \
        -P tb_flash_attn_top_e2e_smoke.MAX_CYCLES="$max_cycles" \
        -P tb_flash_attn_top_e2e_smoke.PROGRESS_EVERY=50000 \
        -o "$out" \
        "${SOURCES[@]}"

    run_vvp "$out" "+OUT_HEX=$hex"
    check_bf16_output "$hex" "$s_len" "$d_model" "$bk" "$scale"
}

run_case "s8_d8" 8 8 4 4 91 200000 80000
run_case "s32_d16" 32 16 8 8 64 800000 120000

if [[ "${RUN_FULL:-0}" == "1" ]]; then
    run_case "s256_d64" 256 64 16 16 32 2500000 300000
else
    echo "Skipping full-size BF16 smoke; rerun with RUN_FULL=1 for S=256,D=64."
fi

echo "Bonus BF16 I/O smoke checks passed."
