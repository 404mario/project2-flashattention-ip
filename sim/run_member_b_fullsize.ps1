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

$CoreSources = @(
    (Join-Path $Root "rtl/include/flash_attn_pkg.sv"),
    (Join-Path $Root "rtl/core/tile_scheduler.sv"),
    (Join-Path $Root "rtl/mem/row_buffer.sv"),
    (Join-Path $Root "rtl/mem/tile_buffer.sv"),
    (Join-Path $Root "rtl/core/dot_product_engine.sv"),
    (Join-Path $Root "rtl/core/causal_mask_unit.sv"),
    (Join-Path $Root "rtl/core/online_softmax_engine.sv"),
    (Join-Path $Root "rtl/core/value_accumulator.sv"),
    (Join-Path $Root "rtl/core/quantize_saturate.sv"),
    (Join-Path $Root "rtl/core/normalizer.sv"),
    (Join-Path $Root "rtl/core/flash_core.sv")
)

$FullsizeOut = Join-Path $Build "tb_flash_core_fullsize_smoke.vvp"
iverilog -g2012 -Wall `
    -I $TbInclude `
    -o $FullsizeOut `
    $CoreSources `
    (Join-Path $Root "tb/sv/tb_flash_core_fullsize_smoke.sv")
Assert-LastExit "flash_core fullsize smoke compile"
Invoke-CheckedVvp $FullsizeOut

Write-Host "Member B full-size core smoke passed."
