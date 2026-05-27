# Unified Bonus Results

Branch: `codex-bonus-integrated-ppa-skeleton`

This file records evidence for the unified bonus branch rebuilt on top of the PPA-passing
baseline. Raw simulator outputs under `sim_build/` remain ignored by Git, so this tracked
summary is updated after each bonus item is ported and rerun on this branch.

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

- Bonus 3, configurable sequence length: compile-time `S_LEN` is verified through independent top E2E smoke cases with S=64 and S=128.
- Bonus 4, padding mask: `VALID_LEN <= S_LEN` masks invalid K/V tokens and zeroes invalid output rows. Default `VALID_LEN=S_LEN` preserves baseline behavior.
- Bonus 5, additional fixed-point formats: Q6.10 and Q4.12 smoke regressions reuse the same AXI-Lite/DMA flow through parameterized testbench/checker paths. They do not change default Q8.8 baseline behavior.
- Bonus 9, lightweight task queue: `TASK_COUNT` and `TASK_STRIDE` registers chain multiple independent tensor regions through the same top-level DMA/control path. Default `TASK_COUNT=1` should preserve the single-task baseline path.

## Top Smoke Results

Command:

```bash
./sim/run_top_compile.sh
./sim/run_top_e2e_smoke.sh
```

Latest local result after porting Bonus 4, Bonus 5, and Bonus 9:

| Case | Shape | Config | Result | Cycles | RD_BYTES | WR_BYTES | FP32 MAE | FP32 MaxE |
|---|---:|---|---|---:|---:|---:|---:|---:|
| AXI-Lite control regression | register-only | START, SOFT_RESET, IRQ_EN, DONE W1C, VALID_LEN | PASS | n/a | n/a | n/a | n/a | n/a |
| Q8.8 small top E2E | S=8,D=8,BK=4,BQ=16 | VALID_LEN=8 | PASS | 456 | 384 | 128 | 0.000183 | 0.003906 |
| Padding mask top E2E | S=16,D=8,BK=4,BQ=4 | VALID_LEN=5 | PASS | 827 | 1152 | 256 | 0.000092 | 0.003906 |
| Q6.10 fixed-format top E2E | S=16,D=8,BK=4,BQ=4 | FRAC_W=10, VALID_LEN=16 | PASS | 1388 | 1536 | 256 | 0.000046 | 0.000977 |
| Q4.12 fixed-format top E2E | S=16,D=8,BK=4,BQ=4 | FRAC_W=12, VALID_LEN=16 | PASS | 1388 | 1536 | 256 | 0.000053 | 0.000244 |
| Q8.8 medium top E2E | S=32,D=16,BK=8,BQ=8 | VALID_LEN=32 | PASS | 4780 | 6144 | 1024 | 0.000038 | 0.003906 |

Default Q8.8 small/medium cycle counts match the PPA skeleton after task queue was added.

## Configurable Sequence Results

Command:

```bash
bash ./sim/run_bonus_sequence_smoke.sh
```

Latest local result after porting Bonus 3:

| Case | Shape | Config | Result | Cycles | RD_BYTES | WR_BYTES | FP32 MAE | FP32 MaxE |
|---|---:|---|---|---:|---:|---:|---:|---:|
| Configurable S smoke | S=64,D=16,BK=8,BQ=16 | VALID_LEN=64 | PASS | 15152 | 12288 | 2048 | 0.000031 | 0.003906 |
| Configurable S smoke | S=128,D=16,BK=8,BQ=16 | VALID_LEN=128 | PASS | 53920 | 40960 | 4096 | 0.000017 | 0.003906 |

This supports the Bonus 3 claim as compile-time configurable `S_LEN`; it does not claim a
full S=512,D=64 run.

## Task Queue Results

Command:

```bash
bash ./sim/run_bonus_task_queue_smoke.sh
```

Latest local result after porting Bonus 9:

| Case | Shape | Config | Result | Cycles | RD_BYTES | WR_BYTES |
|---|---:|---|---|---:|---:|---:|
| Task queue smoke | S=8,D=8,BK=4,BQ=4 | TASK_COUNT=2, TASK_STRIDE_BYTES=128 | PASS | 934 | 1024 | 256 |

The single-task default path is still covered by `run_top_e2e_smoke.sh`, where Q8.8
`S=8` remains 456 cycles and `S=32` remains 4780 cycles.
