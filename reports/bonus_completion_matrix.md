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
| 6 | Dropout training mode | Pending port | Deterministic seed, mask evidence, and dropout golden comparison. |
| 7 | INT8/FP8 lower precision | Pending design | Low-precision datapath or block-scaling evidence and error comparison. |
| 8 | AXI4-Stream interface | Pending port | Stream wrapper smoke and full-size random-vector verification. |
| 9 | DMA/task queue | Pending port | Multi-task START/DONE flow and per-task output verification. |
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
| Padding mask RTL control register | `rtl/axi/axi_lite_regs.sv`, register `0x54 VALID_LEN` |
| Padding mask top/core connection | `rtl/top/flash_attn_top.sv`, `rtl/core/flash_core.sv` |
| AXI-Lite register regression | `tb/sv/tb_axi_lite_regs_ctrl.sv` |
| Top E2E smoke including padding, Q6.10, Q4.12 | `sim/run_top_e2e_smoke.sh` |
| Bonus configurable S smoke | `sim/run_bonus_sequence_smoke.sh` |
| Configurable fixed-point checker | `model/check_top_e2e_output.py` |
| Parametric top E2E testbench | `tb/sv/tb_flash_attn_top_e2e_smoke.sv` |

Recent local checks:

```bash
./sim/run_top_compile.sh
./sim/run_top_e2e_smoke.sh
```

Both passed after porting Bonus 4 and Bonus 5. Default Q8.8 cycles remained
`S=8 -> 456` and `S=32 -> 4780`.

```bash
./sim/run_bonus_sequence_smoke.sh
```

Passed after porting Bonus 3 with `S=64 -> 15152 cycles` and
`S=128 -> 53920 cycles`.
