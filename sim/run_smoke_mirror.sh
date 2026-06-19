#!/usr/bin/env bash
# Run the small (S=8) and medium (S=32) e2e configs on the CURRENT RTL and report
# each against the python fixed-point mirror (rtl_expected) WITHOUT aborting, so we
# can see both even if a small-config corner shows a sub-LSB mirror diff. The full
# accuracy gate is FP32 MAE<=0.03 / MaxE<=0.10 (checked here too).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/sim_build"; mkdir -p "$BUILD"

SOURCES=(
    "$ROOT/rtl/include/flash_attn_pkg.sv"
    "$ROOT/rtl/axi/axi_lite_regs.sv" "$ROOT/rtl/axi/axi_master_read.sv"
    "$ROOT/rtl/axi/axi_master_write.sv" "$ROOT/rtl/axi/dma_controller.sv"
    "$ROOT/rtl/core/tile_scheduler.sv" "$ROOT/rtl/mem/row_buffer.sv"
    "$ROOT/rtl/mem/tile_buffer.sv" "$ROOT/rtl/core/dot_product_engine.sv"
    "$ROOT/rtl/core/dot_stream.sv" "$ROOT/rtl/core/causal_mask_unit.sv"
    "$ROOT/rtl/core/online_softmax_engine.sv" "$ROOT/rtl/core/softmax_combine.sv"
    "$ROOT/rtl/core/value_accumulator.sv" "$ROOT/rtl/core/quantize_saturate.sv"
    "$ROOT/rtl/core/normalizer.sv" "$ROOT/rtl/core/flash_core.sv"
    "$ROOT/rtl/top/flash_attn_top.sv"
    "$ROOT/tb/sv/tb_flash_attn_top_e2e_smoke.sv"
)

run_one() { # label S D BK BQ SCALE
    local label="$1" S="$2" D="$3" BK="$4" BQ="$5" SCALE="$6"
    local out="$BUILD/sm_${label}.vvp" hex="$BUILD/sm_${label}_o.hex" log="$BUILD/sm_${label}.log"
    iverilog -g2012 -I "$ROOT/tb/sv" -s tb_flash_attn_top_e2e_smoke \
        -P tb_flash_attn_top_e2e_smoke.S_LEN=$S -P tb_flash_attn_top_e2e_smoke.D_MODEL=$D \
        -P tb_flash_attn_top_e2e_smoke.BK=$BK -P tb_flash_attn_top_e2e_smoke.BQ=$BQ \
        -P tb_flash_attn_top_e2e_smoke.SOFTMAX_FRAC=16 -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8=$SCALE \
        -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT=0 \
        -P tb_flash_attn_top_e2e_smoke.TIMEOUT_CYCLES=800000 -P tb_flash_attn_top_e2e_smoke.MAX_CYCLES=300000 \
        -o "$out" "${SOURCES[@]}" 2>"$BUILD/sm_${label}_build.log"
    vvp "$out" "+OUT_HEX=$hex" >"$log" 2>&1
    echo "==== [$label] S=$S D=$D BK=$BK BQ=$BQ ===="
    grep -E 'PASS|FAIL|cycles=' "$log" | tail -1
    python3 "$ROOT/model/check_top_e2e_output.py" --hex "$hex" \
        --s-len $S --d-model $D --bk $BK --scale-q8-8 $SCALE --softmax-frac 16 \
        --check-fp32 --max-mae 0.03 --max-maxe 0.10
    echo "  -> checker exit: $? (0 = mirror bit-exact AND FP32 within spec)"
}

run_one small  8  8 4 16 91
run_one medium 32 16 8 8 64
