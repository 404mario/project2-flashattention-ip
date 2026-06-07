#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="sim_build"
TB_INCLUDE="$ROOT/tb/sv"
source "$ROOT/sim/common.sh"
mkdir -p "$BUILD"

DROPOUT_THRESHOLD=16384
DROPOUT_SEED=0x1234
DROPOUT_SCALE_Q8_8=341

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

check_dropout_output() {
    local hex_path="$1"
    local s_len="$2"
    local d_model="$3"
    local bk="$4"
    local scale="$5"
    local softmax_frac="$6"
    local valid_len="$7"
    local frac_w="$8"
    shift 8

    "$PYTHON_BIN" "$ROOT/model/check_top_e2e_output.py" \
        --hex "$hex_path" \
        --s-len "$s_len" \
        --d-model "$d_model" \
        --bk "$bk" \
        --scale-q8-8 "$scale" \
        --frac-w "$frac_w" \
        --softmax-frac "$softmax_frac" \
        --valid-len "$valid_len" \
        --check-fp32 \
        --max-mae 0.03 \
        --max-maxe 0.10 \
        --dropout-en \
        --dropout-threshold "$DROPOUT_THRESHOLD" \
        --dropout-seed "$DROPOUT_SEED" \
        --dropout-scale-q8-8 "$DROPOUT_SCALE_Q8_8" \
        "$@"
}

run_case() {
    local name="$1"
    local s_len="$2"
    local d_model="$3"
    local bk="$4"
    local bq="$5"
    local frac_w="$6"
    local softmax_frac="$7"
    local scale="$8"
    local check_bitexact="$9"
    local timeout_cycles="${10}"
    local max_cycles="${11}"
    shift 11

    local out="$BUILD/tb_flash_attn_top_e2e_${name}.vvp"
    local hex="$BUILD/tb_flash_attn_top_e2e_${name}_o.hex"

    echo "=== bonus dropout: $name S=$s_len D=$d_model BK=$bk BQ=$bq FRAC_W=$frac_w SOFTMAX_FRAC=$softmax_frac ==="
    iverilog -g2012 -Wall \
        -I "$TB_INCLUDE" \
        -s tb_flash_attn_top_e2e_smoke \
        -P tb_flash_attn_top_e2e_smoke.S_LEN="$s_len" \
        -P tb_flash_attn_top_e2e_smoke.D_MODEL="$d_model" \
        -P tb_flash_attn_top_e2e_smoke.BK="$bk" \
        -P tb_flash_attn_top_e2e_smoke.BQ="$bq" \
        -P tb_flash_attn_top_e2e_smoke.FRAC_W="$frac_w" \
        -P tb_flash_attn_top_e2e_smoke.SOFTMAX_FRAC="$softmax_frac" \
        -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8="$scale" \
        -P tb_flash_attn_top_e2e_smoke.DROPOUT_EN=1 \
        -P tb_flash_attn_top_e2e_smoke.DROPOUT_THRESHOLD="$DROPOUT_THRESHOLD" \
        -P tb_flash_attn_top_e2e_smoke.DROPOUT_SEED="$DROPOUT_SEED" \
        -P tb_flash_attn_top_e2e_smoke.DROPOUT_SCALE_Q8_8="$DROPOUT_SCALE_Q8_8" \
        -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT="$check_bitexact" \
        -P tb_flash_attn_top_e2e_smoke.TIMEOUT_CYCLES="$timeout_cycles" \
        -P tb_flash_attn_top_e2e_smoke.MAX_CYCLES="$max_cycles" \
        -P tb_flash_attn_top_e2e_smoke.PROGRESS_EVERY=100000 \
        -o "$out" \
        "${SOURCES[@]}"

    run_vvp "$out" "+OUT_HEX=$hex" "$@"
    check_dropout_output "$hex" "$s_len" "$d_model" "$bk" "$scale" "$softmax_frac" "$s_len" "$frac_w"
}

# Small case uses SOFTMAX_FRAC=8 because the SV testbench's compact reference
# LUT is Q0.8. Bit-exact output checking is delegated to the Python RTL mirror,
# which matches the PPA baseline normalizer.
run_case "bonus_dropout_small" 8 8 4 4 8 8 91 0 200000 0

# Medium optimized-path case exercises the production SOFTMAX_FRAC=16 path.
run_case "bonus_dropout_medium" 32 16 8 8 8 16 64 0 800000 120000

if [[ "${RUN_FULL:-0}" == "1" ]]; then
    run_case "bonus_dropout_vectors_s256_d64" 256 64 16 16 8 16 32 0 2000000 300000 \
        "+USE_VECTOR_FILES=1" \
        "+Q_HEX=$ROOT/tb/vectors/input_q.hex" \
        "+K_HEX=$ROOT/tb/vectors/input_k.hex" \
        "+V_HEX=$ROOT/tb/vectors/input_v.hex"
else
    echo "Skipping full-size random-vector dropout; run with RUN_FULL=1 for S=256,D=64."
fi

echo "Bonus dropout checks passed."
