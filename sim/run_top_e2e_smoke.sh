#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/sim_build"
TB_INCLUDE="$ROOT/tb/sv"
mkdir -p "$BUILD"

SOURCES=(
    "$ROOT/rtl/include/flash_attn_pkg.sv"
    "$ROOT/rtl/include/fp8_e4m3_pkg.sv"
    "$ROOT/rtl/axi/axi_lite_regs.sv"
    "$ROOT/rtl/axi/axi_master_read.sv"
    "$ROOT/rtl/axi/axi_master_write.sv"
    "$ROOT/rtl/axi/dma_controller.sv"
    "$ROOT/rtl/axi/dma_controller_fp8.sv"
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
    local softmax_frac="${6:-16}"
    local valid_len="${7:-$s_len}"
    local frac_w="${8:-8}"
    shift 8
    python "$ROOT/model/check_top_e2e_output.py" \
        --hex "$hex_path" \
        --s-len "$s_len" \
        --d-model "$d_model" \
        --bk "$bk" \
        --scale-q8-8 "$scale" \
        --frac-w "$frac_w" \
        --softmax-frac "$softmax_frac" \
        --valid-len "$valid_len" \
        --check-fp32 \
        --max-mae "${MAX_MAE:-0.03}" \
        --max-maxe "${MAX_MAXE:-0.10}" \
        "$@"
}

# --- AXI-Lite control/status register checks ---
REG_CTRL_OUT="$BUILD/tb_axi_lite_regs_ctrl.vvp"
iverilog -g2012 -Wall \
    -s tb_axi_lite_regs_ctrl \
    -o "$REG_CTRL_OUT" \
    "$ROOT/rtl/axi/axi_lite_regs.sv" \
    "$ROOT/tb/sv/tb_axi_lite_regs_ctrl.sv"

run_vvp "$REG_CTRL_OUT"

# --- Small smoke (S=8, D=8) ---
SMALL_OUT="$BUILD/tb_flash_attn_top_e2e_small.vvp"
iverilog -g2012 -Wall \
    -I "$TB_INCLUDE" \
    -s tb_flash_attn_top_e2e_smoke \
    -P tb_flash_attn_top_e2e_smoke.S_LEN=8 \
    -P tb_flash_attn_top_e2e_smoke.D_MODEL=8 \
    -P tb_flash_attn_top_e2e_smoke.BK=4 \
    -P tb_flash_attn_top_e2e_smoke.SOFTMAX_FRAC=16 \
    -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8=91 \
    -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT=0 \
    -P tb_flash_attn_top_e2e_smoke.TIMEOUT_CYCLES=200000 \
    -o "$SMALL_OUT" \
    "${SOURCES[@]}"

SMALL_HEX="$BUILD/tb_flash_attn_top_e2e_small_o.hex"
run_vvp "$SMALL_OUT" "+OUT_HEX=$SMALL_HEX"
check_output "$SMALL_HEX" 8 8 4 91 16 8 8

# --- Padding mask smoke (VALID_LEN < S_LEN) ---
PADDING_OUT="$BUILD/tb_flash_attn_top_e2e_padding.vvp"
iverilog -g2012 -Wall \
    -I "$TB_INCLUDE" \
    -s tb_flash_attn_top_e2e_smoke \
    -P tb_flash_attn_top_e2e_smoke.S_LEN=16 \
    -P tb_flash_attn_top_e2e_smoke.D_MODEL=8 \
    -P tb_flash_attn_top_e2e_smoke.BK=4 \
    -P tb_flash_attn_top_e2e_smoke.BQ=4 \
    -P tb_flash_attn_top_e2e_smoke.SOFTMAX_FRAC=16 \
    -P tb_flash_attn_top_e2e_smoke.VALID_LEN=5 \
    -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8=91 \
    -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT=0 \
    -P tb_flash_attn_top_e2e_smoke.TIMEOUT_CYCLES=300000 \
    -o "$PADDING_OUT" \
    "${SOURCES[@]}"

PADDING_HEX="$BUILD/tb_flash_attn_top_e2e_padding_o.hex"
run_vvp "$PADDING_OUT" "+OUT_HEX=$PADDING_HEX"
check_output "$PADDING_HEX" 16 8 4 91 16 5 8

# --- Bonus fixed-point format smoke: Q6.10 and Q4.12 ---
for FIXED_FRAC in 10 12; do
    if [[ "$FIXED_FRAC" == "10" ]]; then
        FIXED_SCALE=362
        FIXED_NAME="q6_10"
    else
        FIXED_SCALE=1448
        FIXED_NAME="q4_12"
    fi

    FIXED_OUT="$BUILD/tb_flash_attn_top_e2e_${FIXED_NAME}.vvp"
    iverilog -g2012 -Wall \
        -I "$TB_INCLUDE" \
        -s tb_flash_attn_top_e2e_smoke \
        -P tb_flash_attn_top_e2e_smoke.S_LEN=16 \
        -P tb_flash_attn_top_e2e_smoke.D_MODEL=8 \
        -P tb_flash_attn_top_e2e_smoke.BK=4 \
        -P tb_flash_attn_top_e2e_smoke.BQ=4 \
        -P tb_flash_attn_top_e2e_smoke.FRAC_W="$FIXED_FRAC" \
        -P tb_flash_attn_top_e2e_smoke.SOFTMAX_FRAC=16 \
        -P tb_flash_attn_top_e2e_smoke.VALID_LEN=16 \
        -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8="$FIXED_SCALE" \
        -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT=0 \
        -P tb_flash_attn_top_e2e_smoke.TIMEOUT_CYCLES=300000 \
        -o "$FIXED_OUT" \
        "${SOURCES[@]}"

    FIXED_HEX="$BUILD/tb_flash_attn_top_e2e_${FIXED_NAME}_o.hex"
    run_vvp "$FIXED_OUT" "+OUT_HEX=$FIXED_HEX"
    check_output "$FIXED_HEX" 16 8 4 "$FIXED_SCALE" 16 16 "$FIXED_FRAC"
done

# --- Medium smoke (fast optimized path sanity, S=32, D=16) ---
MEDIUM_OUT="$BUILD/tb_flash_attn_top_e2e_medium.vvp"
iverilog -g2012 -Wall \
    -I "$TB_INCLUDE" \
    -s tb_flash_attn_top_e2e_smoke \
    -P tb_flash_attn_top_e2e_smoke.S_LEN=32 \
    -P tb_flash_attn_top_e2e_smoke.D_MODEL=16 \
    -P tb_flash_attn_top_e2e_smoke.BK=8 \
    -P tb_flash_attn_top_e2e_smoke.BQ=8 \
    -P tb_flash_attn_top_e2e_smoke.SOFTMAX_FRAC=16 \
    -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8=64 \
    -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT=0 \
    -P tb_flash_attn_top_e2e_smoke.TIMEOUT_CYCLES=800000 \
    -P tb_flash_attn_top_e2e_smoke.MAX_CYCLES=120000 \
    -P tb_flash_attn_top_e2e_smoke.PROGRESS_EVERY=50000 \
    -o "$MEDIUM_OUT" \
    "${SOURCES[@]}"

MEDIUM_HEX="$BUILD/tb_flash_attn_top_e2e_medium_o.hex"
run_vvp "$MEDIUM_OUT" "+OUT_HEX=$MEDIUM_HEX"
check_output "$MEDIUM_HEX" 32 16 8 64 16 32 8

# --- Vector-backed full-size smoke (S=256, D=64) ---
if [[ "${RUN_VECTORS:-0}" == "1" ]]; then
    VECTOR_OUT="$BUILD/tb_flash_attn_top_e2e_vectors.vvp"
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
        -o "$VECTOR_OUT" \
        "${SOURCES[@]}"

    VECTOR_HEX="$BUILD/tb_flash_attn_top_e2e_vectors_o.hex"
    run_vvp "$VECTOR_OUT" \
        "+USE_VECTOR_FILES=1" \
        "+Q_HEX=$ROOT/tb/vectors/input_q.hex" \
        "+K_HEX=$ROOT/tb/vectors/input_k.hex" \
        "+V_HEX=$ROOT/tb/vectors/input_v.hex" \
        "+OUT_HEX=$VECTOR_HEX"
    check_output "$VECTOR_HEX" 256 64 16 32 16 256 8 \
        --q-hex "$ROOT/tb/vectors/input_q.hex" \
        --k-hex "$ROOT/tb/vectors/input_k.hex" \
        --v-hex "$ROOT/tb/vectors/input_v.hex" \
        --golden-hex "$ROOT/tb/vectors/golden_o.hex"
else
    echo "Skipping vector-backed smoke; run with RUN_VECTORS=1 for tb/vectors full-size input."
fi

# --- Full-size smoke (S=256, D=64) ---
if [[ "${RUN_FULL:-0}" == "1" ]]; then
    FULL_OUT="$BUILD/tb_flash_attn_top_e2e_fullsize_smoke.vvp"
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
        -o "$FULL_OUT" \
        "${SOURCES[@]}"

    FULL_HEX="$BUILD/tb_flash_attn_top_e2e_fullsize_o.hex"
    run_vvp "$FULL_OUT" "+OUT_HEX=$FULL_HEX"
    check_output "$FULL_HEX" 256 64 16 32 16 256 8
else
    echo "Skipping full-size smoke; run with RUN_FULL=1 for S=256,D=64."
fi

echo "Top end-to-end smoke checks passed."
