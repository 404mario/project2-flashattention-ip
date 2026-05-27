# Unified Bonus Completion Matrix

Branch: `codex-bonus-integrated-ppa-skeleton`

This branch is rebuilt from the PPA-passing baseline instead of directly editing the older
`codex-bonus-integrated` branch. Every bonus claim below must keep the default baseline path
available and rerunnable.

## Current Status

| # | Bonus item | Status | Evidence |
|---:|---|---|---|
| 1 | BF16/FP16 attention | Not claimed | No BF16/FP16 datapath is integrated. |
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
| S=256,D=64 cycles | 269808 |
| FP32 MAE | 0.000097 |
| FP32 MaxE | 0.054688 |
| Genus timing | 10 ns MET |
| Gate equivalent | 1913697 |

## Current Branch Evidence

| Evidence | Location |
|---|---|
| Bonus result summary | `reports/bonus_results.md` |
| AXI-Lite bonus registers | `rtl/axi/axi_lite_regs.sv` |
| DMA top bonus sequencing | `rtl/top/flash_attn_top.sv` |
| FP8 DMA conversion path | `rtl/axi/dma_controller_fp8.sv` |
| Dropout datapath | `rtl/core/flash_core.sv` |
| AXI4-Stream wrapper | `rtl/top/flash_attn_axis_top.sv` |
| Parametric top E2E testbench | `tb/sv/tb_flash_attn_top_e2e_smoke.sv` |
| Integrated quick checks | `sim/run_bonus_all.sh` |
| Low-precision quick checks | `sim/run_bonus_lowprecision_int8_smoke.sh` |

Default Q8.8 smoke after the bonus ports must remain at the PPA skeleton values
`S=8 -> 456 cycles` and `S=32 -> 4780 cycles`.
