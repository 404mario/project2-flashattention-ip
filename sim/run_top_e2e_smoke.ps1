$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$Build = Join-Path $Root "sim_build"
$TbInclude = Join-Path $Root "tb/sv"
New-Item -ItemType Directory -Force -Path $Build | Out-Null

function Assert-LastExit {
    param([string]$Step)
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE"
    }
}

function Invoke-CheckedVvp {
    param([string]$Path)
    $Output = & vvp $Path 2>&1
    $Output
    $Text = $Output | Out-String
    if (($LASTEXITCODE -ne 0) -or ($Text -match "FAIL|FATAL")) {
        throw "Simulation failed: $Path"
    }
}

$Sources = @(
    (Join-Path $Root "rtl/include/flash_attn_pkg.sv"),
    (Join-Path $Root "rtl/axi/axi_lite_regs.sv"),
    (Join-Path $Root "rtl/axi/axi_master_read.sv"),
    (Join-Path $Root "rtl/axi/axi_master_write.sv"),
    (Join-Path $Root "rtl/axi/dma_controller.sv"),
    (Join-Path $Root "rtl/core/tile_scheduler.sv"),
    (Join-Path $Root "rtl/mem/row_buffer.sv"),
    (Join-Path $Root "rtl/mem/tile_buffer.sv"),
    (Join-Path $Root "rtl/core/dot_product_engine.sv"),
    (Join-Path $Root "rtl/core/causal_mask_unit.sv"),
    (Join-Path $Root "rtl/core/online_softmax_engine.sv"),
    (Join-Path $Root "rtl/core/value_accumulator.sv"),
    (Join-Path $Root "rtl/core/quantize_saturate.sv"),
    (Join-Path $Root "rtl/core/normalizer.sv"),
    (Join-Path $Root "rtl/core/flash_core.sv"),
    (Join-Path $Root "rtl/top/flash_attn_top.sv"),
    (Join-Path $Root "tb/sv/tb_flash_attn_top_e2e_smoke.sv")
)

$SmallOut = Join-Path $Build "tb_flash_attn_top_e2e_small.vvp"
iverilog -g2012 -Wall `
    -I $TbInclude `
    -s tb_flash_attn_top_e2e_smoke `
    -P tb_flash_attn_top_e2e_smoke.S_LEN=8 `
    -P tb_flash_attn_top_e2e_smoke.D_MODEL=8 `
    -P tb_flash_attn_top_e2e_smoke.BK=4 `
    -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8=91 `
    -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT=1 `
    -P tb_flash_attn_top_e2e_smoke.TIMEOUT_CYCLES=200000 `
    -o $SmallOut `
    $Sources
Assert-LastExit "top e2e small compile"
Invoke-CheckedVvp $SmallOut

$FullOut = Join-Path $Build "tb_flash_attn_top_e2e_fullsize_smoke.vvp"
iverilog -g2012 -Wall `
    -I $TbInclude `
    -s tb_flash_attn_top_e2e_smoke `
    -P tb_flash_attn_top_e2e_smoke.S_LEN=256 `
    -P tb_flash_attn_top_e2e_smoke.D_MODEL=64 `
    -P tb_flash_attn_top_e2e_smoke.BK=16 `
    -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8=32 `
    -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT=0 `
    -P tb_flash_attn_top_e2e_smoke.TIMEOUT_CYCLES=8000000 `
    -o $FullOut `
    $Sources
Assert-LastExit "top e2e fullsize smoke compile"
Invoke-CheckedVvp $FullOut

Write-Host "Top end-to-end smoke checks passed."
