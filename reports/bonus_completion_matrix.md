# Unified Bonus Completion Matrix

Branch: `codex-bonus-integrated-ppa-skeleton`

This branch is rebuilt from the PPA-passing baseline instead of directly editing the older
`codex-bonus-integrated` branch. The older branch remains a source for bonus patches, but
each claim must be ported and rerun here before final submission.

## Current Status

| # | Bonus item | Status | Evidence before final claim |
|---:|---|---|---|
| 1 | BF16/FP16 attention | Not claimed | Separate RTL datapath and error/performance comparison. |
| 2 | Multi-head support | Not claimed | Head dimension registers/addressing and full E2E verification. |
| 3 | Longer/configurable sequence | Ported | S=64 and S=128 top E2E runs through `sim/run_bonus_sequence_smoke.sh`. |
| 4 | Padding mask | Ported | AXI-Lite `VALID_LEN`, causal corner cases, and invalid-row zeroing. |
| 5 | Other fixed-point formats | Ported | Q6.10/Q4.12 top E2E smoke with checker support. |
| 6 | Dropout training mode | Ported, full long-run pending | Deterministic mask, dropout scale, RTL mirror, and FP32 checker evidence for small/medium. |
| 7 | INT8/FP8 lower precision | Pending design | Low-precision datapath or block-scaling evidence and error comparison. |
| 8 | AXI4-Stream interface | Ported | Stream wrapper smoke plus RTL-vs-mirror and FP32 checker evidence. |
| 9 | DMA/task queue | Ported | `TASK_COUNT=2` smoke verifies chained START/DONE flow and per-task output writes. |
| 10 | Other optimization | Not claimed | Only claim if a measured performance/power/area improvement is documented. |

## Baseline Non-Regression Evidence

Inherited from `codex-baseline-ppa-fix`:

| Check | Result |
|---|---:|
| S=256,D=64 cycles | 269808 |
| FP32 MAE | 0.000097 |
| FP32 MaxE | 0.054688 |
| Genus timing | 10 ns MET |
| Gate equivalent | 1913697 |

The integrated bonus branch must keep this path available and rerunnable.

## Current Branch Evidence

| Evidence | Location |
|---|---|
| Bonus result summary | `reports/bonus_results.md` |
| Dropout README | `README_bonus_dropout.md` |
| AXI4-Stream README | `README_bonus_axi_stream.md` |
| AXI4-Stream wrapper and testbench | `rtl/top/flash_attn_axis_top.sv`, `tb/sv/tb_flash_attn_axis_top_smoke.sv` |
| Padding mask RTL control register | `rtl/axi/axi_lite_regs.sv`, register `0x54 VALID_LEN` |
| Task queue control registers | `rtl/axi/axi_lite_regs.sv`, registers `0x58 TASK_COUNT` and `0x5c TASK_STRIDE` |
| Dropout control registers | `rtl/axi/axi_lite_regs.sv`, registers `0x60` through `0x68` |
| Padding mask, task queue, and dropout top/core connection | `rtl/top/flash_attn_top.sv`, `rtl/core/flash_core.sv` |
| AXI-Lite register regression | `tb/sv/tb_axi_lite_regs_ctrl.sv` |
| Top E2E smoke including padding, Q6.10, Q4.12 | `sim/run_top_e2e_smoke.sh` |
| Bonus configurable S smoke | `sim/run_bonus_sequence_smoke.sh` |
| Bonus task queue smoke | `sim/run_bonus_task_queue_smoke.sh` |
| Bonus AXI4-Stream smoke | `sim/run_bonus_axis_stream_smoke.sh` |
| Bonus dropout smoke | `sim/run_bonus_dropout_smoke.sh` |
| Configurable fixed-point/dropout checker | `model/check_top_e2e_output.py` |
| Parametric top E2E testbench | `tb/sv/tb_flash_attn_top_e2e_smoke.sv` |

Recent local checks:

```bash
./sim/run_top_compile.sh
./sim/run_top_e2e_smoke.sh
./sim/run_bonus_sequence_smoke.sh
./sim/run_bonus_task_queue_smoke.sh
./sim/run_bonus_axis_stream_smoke.sh
./sim/run_bonus_dropout_smoke.sh
```

These passed after porting Bonus 3, Bonus 4, Bonus 5, Bonus 6, Bonus 8, and Bonus 9.
Default Q8.8 cycles remained `S=8 -> 456` and `S=32 -> 4780` after dropout was added
with `DROPOUT_EN=0`.
