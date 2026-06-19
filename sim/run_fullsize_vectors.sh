#!/usr/bin/env bash
# Full-size S=256/D=64 causal vector run ONLY (bypasses the small/medium smoke
# gate that strict-compares against the python fixed-point mirror). Produces the
# RTL output hex, byte-compares it to tb/vectors/golden_o.hex, and prints CYCLES.
# Usage: bash sim/run_fullsize_vectors.sh <out_hex_label>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/sim_build"; mkdir -p "$BUILD"
LABEL="${1:-fullsize}"

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

OUT="$BUILD/vec_${LABEL}.vvp"
HEX="$BUILD/vec_${LABEL}_o.hex"
LOG="$BUILD/vec_${LABEL}.log"

iverilog -g2012 -Wall -I "$ROOT/tb/sv" -s tb_flash_attn_top_e2e_smoke \
    -P tb_flash_attn_top_e2e_smoke.S_LEN=256 \
    -P tb_flash_attn_top_e2e_smoke.D_MODEL=64 \
    -P tb_flash_attn_top_e2e_smoke.BK=16 \
    -P tb_flash_attn_top_e2e_smoke.BQ=16 \
    -P tb_flash_attn_top_e2e_smoke.SOFTMAX_FRAC=16 \
    -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8=32 \
    -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT=0 \
    -P tb_flash_attn_top_e2e_smoke.TIMEOUT_CYCLES=2000000 \
    -P tb_flash_attn_top_e2e_smoke.MAX_CYCLES=300000 \
    -P tb_flash_attn_top_e2e_smoke.PROGRESS_EVERY=20000 \
    -o "$OUT" "${SOURCES[@]}"

vvp "$OUT" +USE_VECTOR_FILES=1 \
    "+Q_HEX=$ROOT/tb/vectors/input_q.hex" \
    "+K_HEX=$ROOT/tb/vectors/input_k.hex" \
    "+V_HEX=$ROOT/tb/vectors/input_v.hex" \
    "+OUT_HEX=$HEX" 2>&1 | tee "$LOG"

echo "================ FULL-SIZE RESULT ($LABEL) ================"
grep -E 'PASS|FAIL|FATAL|cycles=' "$LOG" | tail -3
echo "---- byte-compare RTL output vs tb/vectors/golden_o.hex ----"
if cmp -s "$HEX" "$ROOT/tb/vectors/golden_o.hex"; then
    echo "BYTE-EXACT vs golden_o.hex: YES  (md5=$(md5sum "$HEX" | cut -d' ' -f1))"
else
    echo "BYTE-EXACT vs golden_o.hex: NO"; cmp "$HEX" "$ROOT/tb/vectors/golden_o.hex" | head
fi
