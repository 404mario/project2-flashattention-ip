$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$Build = Join-Path $Root "sim_build"
New-Item -ItemType Directory -Force -Path $Build | Out-Null

$Out = Join-Path $Build "flash_attn_top_compile.vvp"

iverilog -g2012 -Wall `
    -s flash_attn_top `
    -o $Out `
    (Join-Path $Root "rtl/include/flash_attn_pkg.sv") `
    (Join-Path $Root "rtl/axi/axi_lite_regs.sv") `
    (Join-Path $Root "rtl/axi/axi_master_read.sv") `
    (Join-Path $Root "rtl/axi/axi_master_write.sv") `
    (Join-Path $Root "rtl/axi/dma_controller.sv") `
    (Join-Path $Root "rtl/core/tile_scheduler.sv") `
    (Join-Path $Root "rtl/mem/row_buffer.sv") `
    (Join-Path $Root "rtl/mem/tile_buffer.sv") `
    (Join-Path $Root "rtl/core/dot_product_engine.sv") `
    (Join-Path $Root "rtl/core/causal_mask_unit.sv") `
    (Join-Path $Root "rtl/core/online_softmax_engine.sv") `
    (Join-Path $Root "rtl/core/value_accumulator.sv") `
    (Join-Path $Root "rtl/core/quantize_saturate.sv") `
    (Join-Path $Root "rtl/core/normalizer.sv") `
    (Join-Path $Root "rtl/core/flash_core.sv") `
    (Join-Path $Root "rtl/top/flash_attn_top.sv")

if ($LASTEXITCODE -ne 0) {
    throw "flash_attn_top compile failed with exit code $LASTEXITCODE"
}

Write-Host "flash_attn_top compile passed: $Out"
