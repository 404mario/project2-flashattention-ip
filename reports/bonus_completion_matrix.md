# Unified Bonus Completion Matrix

Branch: `codex-bonus-integrated-static-scale-fmax`

This branch is rebuilt from `codex-baseline-core-pipeline-fmax` commit `9d1d4d8` instead of
directly editing the older `codex-bonus-integrated` branch. Every bonus claim below must keep
the default baseline path available and rerunnable.

## Current Status

| # | Bonus item | Status | Evidence |
|---:|---|---|---|
| 1 | BF16/FP16 attention | Exploratory | BF16 external Q/K/V/O tensor mode through `BF16_IO_MODE`; DMA converts at the memory boundary and the core remains Q8.8. |
| 2 | Multi-head support | Ported | H=4 and H=8 sequential-head smoke with per-head RTL mirror checks. |
| 3 | Longer/configurable sequence | Ported | S=64 and S=128 top E2E smoke through `sim/run_bonus_sequence_smoke.sh`. |
| 4 | Padding mask | Ported | AXI-Lite `VALID_LEN`, causal corner cases, and invalid-row zeroing. |
| 5 | Other fixed-point formats | Ported | Q6.10/Q4.12 top E2E smoke with checker support. |
| 6 | Dropout training mode | Ported | Deterministic mask, dropout scale, RTL mirror, and FP32 checker evidence. |
| 7 | INT8/FP8 lower precision | Ported | INT8/Q4.4 and FP8/E4M3 top E2E smoke; FP8 converts at DMA boundary while default Q8.8 remains unchanged. |
| 8 | AXI4-Stream interface | Ported | Stream wrapper smoke through `sim/run_bonus_axis_stream_smoke.sh`. |
| 9 | DMA/task queue | Ported | `TASK_COUNT=2` smoke verifies chained START/DONE flow and per-task writes. |
| 10 | Other optimization | Not claimed | Baseline optimization is not counted as a separate optional bonus. |

## Baseline Non-Regression Evidence

Inherited from `codex-baseline-ppa-fix`:

| Check | Result |
|---|---:|
| S=256,D=64 cycles | 233312 |
| FP32 MAE | 0.000015 |
| FP32 MaxE | 0.003906 |
| Genus timing | pending fresh bonus synthesis |
| Gate equivalent | pending fresh bonus synthesis |

## Current Branch Evidence

| Evidence | Location |
|---|---|
| Bonus result summary | `reports/bonus_results.md` |
| Submission evidence index | `reports/submission_evidence.md` |
| Tracked waveform files | `reports/waves/*.vcd` |
| AXI-Lite bonus registers | `rtl/axi/axi_lite_regs.sv` |
| DMA top bonus sequencing | `rtl/top/flash_attn_top.sv` |
| FP8 DMA conversion path | `rtl/axi/dma_controller_fp8.sv` |
| Dropout datapath | `rtl/core/flash_core.sv` |
| AXI4-Stream wrapper | `rtl/top/flash_attn_axis_top.sv` |
| Parametric top E2E testbench | `tb/sv/tb_flash_attn_top_e2e_smoke.sv` |
| Integrated quick checks | `sim/run_bonus_all.sh` |
| Low-precision quick checks | `sim/run_bonus_lowprecision_int8_smoke.sh` |
| BF16 I/O quick checks | `sim/run_bonus_bf16_smoke.sh` |
| Synthesis-friendly full-size random-vector check | `sim/run_bonus_synth_timing_smoke.sh` |

Default Q8.8 smoke after the bonus ports must remain at the static-scale skeleton values
`S=8 -> 335 cycles` and `S=32 -> 3528 cycles`.

For re-synthesis after the integrated bonus area/timing report, keep the direct top-level
defaults or explicitly set `STATIC_SCALE_MODE=1`, `STATIC_SCALE_Q8_8=32`, and
`ENABLE_DROPOUT=0`. This trims runtime scale multiplication and dropout-only logic from the
default production datapath while preserving those bonus modes as parameter-enabled RTL.
