#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/sim_build"
mkdir -p "$BUILD"

OUT="$BUILD/flash_attn_top_compile.vvp"

iverilog -g2012 -Wall \
    -s flash_attn_top \
    -o "$OUT" \
    "$ROOT/rtl/include/flash_attn_pkg.sv" \
    "$ROOT/rtl/include/fp8_e4m3_pkg.sv" \
    "$ROOT/rtl/include/bf16_pkg.sv" \
    "$ROOT/rtl/axi/axi_lite_regs.sv" \
    "$ROOT/rtl/axi/axi_master_read.sv" \
    "$ROOT/rtl/axi/axi_master_write.sv" \
    "$ROOT/rtl/axi/dma_controller.sv" \
    "$ROOT/rtl/axi/dma_controller_fp8.sv" \
    "$ROOT/rtl/axi/dma_controller_bf16.sv" \
    "$ROOT/rtl/core/tile_scheduler.sv" \
    "$ROOT/rtl/mem/row_buffer.sv" \
    "$ROOT/rtl/mem/tile_buffer.sv" \
    "$ROOT/rtl/core/dot_product_engine.sv" \
    "$ROOT/rtl/core/causal_mask_unit.sv" \
    "$ROOT/rtl/core/online_softmax_engine.sv" \
    "$ROOT/rtl/core/value_accumulator.sv" \
    "$ROOT/rtl/core/quantize_saturate.sv" \
    "$ROOT/rtl/core/normalizer.sv" \
    "$ROOT/rtl/core/flash_core.sv" \
    "$ROOT/rtl/top/flash_attn_top.sv"

echo "flash_attn_top compile passed: $OUT"
