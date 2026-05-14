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

$DotOut = Join-Path $Build "tb_dot_product_engine.vvp"
iverilog -g2012 -Wall `
    -o $DotOut `
    (Join-Path $Root "rtl/core/dot_product_engine.sv") `
    (Join-Path $Root "tb/sv/tb_dot_product_engine.sv")
Assert-LastExit "dot_product_engine compile"
Invoke-CheckedVvp $DotOut

$SchedulerOut = Join-Path $Build "tb_tile_scheduler_bitexact.vvp"
iverilog -g2012 -Wall `
    -o $SchedulerOut `
    (Join-Path $Root "rtl/core/tile_scheduler.sv") `
    (Join-Path $Root "tb/sv/tb_tile_scheduler_bitexact.sv")
Assert-LastExit "tile_scheduler bit-exact compile"
Invoke-CheckedVvp $SchedulerOut

$BufferOut = Join-Path $Build "tb_buffers_bitexact.vvp"
iverilog -g2012 -Wall `
    -o $BufferOut `
    (Join-Path $Root "rtl/mem/row_buffer.sv") `
    (Join-Path $Root "rtl/mem/tile_buffer.sv") `
    (Join-Path $Root "tb/sv/tb_buffers_bitexact.sv")
Assert-LastExit "buffer bit-exact compile"
Invoke-CheckedVvp $BufferOut

$CoreOut = Join-Path $Build "tb_flash_core_smoke.vvp"
iverilog -g2012 -Wall `
    -I $TbInclude `
    -o $CoreOut `
    (Join-Path $Root "rtl/include/flash_attn_pkg.sv") `
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
    (Join-Path $Root "tb/sv/tb_flash_core_smoke.sv")
Assert-LastExit "flash_core smoke compile"
Invoke-CheckedVvp $CoreOut

$Matrix16Out = Join-Path $Build "tb_flash_core_matrix16_bitexact.vvp"
iverilog -g2012 -Wall `
    -I $TbInclude `
    -o $Matrix16Out `
    (Join-Path $Root "rtl/include/flash_attn_pkg.sv") `
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
    (Join-Path $Root "tb/sv/tb_flash_core_matrix16_bitexact.sv")
Assert-LastExit "flash_core matrix16 bit-exact compile"
Invoke-CheckedVvp $Matrix16Out

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

$BackpressureOut = Join-Path $Build "tb_flash_core_backpressure_bitexact.vvp"
iverilog -g2012 -Wall `
    -I $TbInclude `
    -o $BackpressureOut `
    $CoreSources `
    (Join-Path $Root "tb/sv/tb_flash_core_backpressure_bitexact.sv")
Assert-LastExit "flash_core backpressure bit-exact compile"
Invoke-CheckedVvp $BackpressureOut

$ParamTests = @(
    @{
        Name = "tb_flash_core_param_s5_d3_b8_causal"
        Params = @(
            "tb_flash_core_param_bitexact.S_LEN=5",
            "tb_flash_core_param_bitexact.D_MODEL=3",
            "tb_flash_core_param_bitexact.BK=8",
            "tb_flash_core_param_bitexact.CAUSAL_EN=1",
            "tb_flash_core_param_bitexact.SCALE_Q8_8=256"
        )
    },
    @{
        Name = "tb_flash_core_param_s7_d8_b3_causal"
        Params = @(
            "tb_flash_core_param_bitexact.S_LEN=7",
            "tb_flash_core_param_bitexact.D_MODEL=8",
            "tb_flash_core_param_bitexact.BK=3",
            "tb_flash_core_param_bitexact.CAUSAL_EN=1",
            "tb_flash_core_param_bitexact.SCALE_Q8_8=384"
        )
    },
    @{
        Name = "tb_flash_core_param_s9_d5_b4_noncausal"
        Params = @(
            "tb_flash_core_param_bitexact.S_LEN=9",
            "tb_flash_core_param_bitexact.D_MODEL=5",
            "tb_flash_core_param_bitexact.BK=4",
            "tb_flash_core_param_bitexact.CAUSAL_EN=0",
            "tb_flash_core_param_bitexact.SCALE_Q8_8=512"
        )
    },
    @{
        Name = "tb_flash_core_param_s13_d12_b5_causal"
        Params = @(
            "tb_flash_core_param_bitexact.S_LEN=13",
            "tb_flash_core_param_bitexact.D_MODEL=12",
            "tb_flash_core_param_bitexact.BK=5",
            "tb_flash_core_param_bitexact.CAUSAL_EN=1",
            "tb_flash_core_param_bitexact.SCALE_Q8_8=320"
        )
    }
)

foreach ($Test in $ParamTests) {
    $ParamOut = Join-Path $Build ($Test.Name + ".vvp")
    $IverilogArgs = @("-g2012", "-Wall", "-I", $TbInclude, "-o", $ParamOut)
    foreach ($Param in $Test.Params) {
        $IverilogArgs += "-P"
        $IverilogArgs += $Param
    }
    $IverilogArgs += $CoreSources
    $IverilogArgs += (Join-Path $Root "tb/sv/tb_flash_core_param_bitexact.sv")

    & iverilog @IverilogArgs
    Assert-LastExit "$($Test.Name) compile"
    Invoke-CheckedVvp $ParamOut
}

Write-Host "Member B core RTL checks passed."
