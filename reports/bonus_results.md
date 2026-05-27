# Unified Bonus Results

Branch: `codex-bonus-integrated-ppa-skeleton`

This file records evidence for the unified bonus branch rebuilt on top of the PPA-passing baseline. Raw simulator outputs under `sim_build/` remain ignored by Git, so this tracked summary is updated after each bonus item is ported and rerun on this branch.

## Baseline Reference

| Case | Shape | Cycles | RD_BYTES | WR_BYTES | FP32 MAE | FP32 MaxE |
|---|---:|---:|---:|---:|---:|---:|
| AXI-Lite + AXI master/DMA top E2E | S=256,D=64,BK=16,BQ=16 | 269808 | 589824 | 32768 | 0.000097 | 0.054688 |

Acceptance thresholds:

| Metric | Requirement |
|---|---:|
| Mean absolute error | <= 0.03 |
| Max absolute error | <= 0.10 |
| Baseline cycles | < 300000 |
| Baseline equivalent gates | <= 2000000 |

## Ported Bonus Items

- Bonus 4, padding mask: `VALID_LEN <= S_LEN` masks invalid K/V tokens and zeroes invalid output rows. Default `VALID_LEN=S_LEN` preserves baseline behavior.
- Bonus 5, additional fixed-point formats: Q6.10 and Q4.12 smoke regressions reuse the same AXI-Lite/DMA flow through parameterized testbench/checker paths. They do not change default Q8.8 baseline behavior.

## Smoke Results On This Branch

Command:

```bash
./sim/run_top_compile.sh
./sim/run_top_e2e_smoke.sh
```

Latest local result after porting Bonus 4:

| Case | Shape | Config | Result | Cycles | RD_BYTES | WR_BYTES | FP32 MAE | FP32 MaxE |
|---|---:|---|---|---:|---:|---:|---:|---:|
| AXI-Lite control regression | register-only | START, SOFT_RESET, IRQ_EN, DONE W1C, VALID_LEN | PASS | n/a | n/a | n/a | n/a | n/a |
| Q8.8 small top E2E | S=8,D=8,BK=4,BQ=16 | VALID_LEN=8 | PASS | 456 | 384 | 128 | 0.000183 | 0.003906 |
| Padding mask top E2E | S=16,D=8,BK=4,BQ=4 | VALID_LEN=5 | PASS | 827 | 1152 | 256 | 0.000092 | 0.003906 |
| Q8.8 medium top E2E | S=32,D=16,BK=8,BQ=8 | VALID_LEN=32 | PASS | 4780 | 6144 | 1024 | 0.000038 | 0.003906 |

Fixed-format Q6.10/Q4.12 cases have been ported and must be rerun before their table rows are promoted from pending to evidence.

## Pending Bonus Evidence

Each remaining bonus item must add its command, shape, cycles, RD_BYTES/WR_BYTES if applicable, and FP32 error result here after being ported to this branch.

