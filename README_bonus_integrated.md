# Integrated Bonus Branch On PPA Baseline

Branch: `codex-bonus-integrated-ppa-skeleton`

This branch is the unified bonus integration branch rebuilt from `codex-baseline-ppa-fix`,
the PPA-passing baseline. The goal is to preserve the baseline timing/area/performance path
while adding optional bonus modes behind registers, parameters, or separate wrappers.

## Claimed / Ported Items

| # | Bonus item | Current implementation |
|---:|---|---|
| 1 | BF16 attention | Exploratory BF16 external tensor mode: DMA converts BF16 Q/K/V/O at the memory boundary and reuses the validated Q8.8 core. |
| 2 | Multi-head support | Sequential head execution via `HEAD_COUNT` and `HEAD_STRIDE_BYTES`. |
| 3 | Longer/configurable sequence | Parametric `S_LEN` smoke cases for S=64 and S=128. |
| 4 | Padding mask | `VALID_LEN` masks invalid keys and zeroes invalid query rows. |
| 5 | Other fixed-point formats | Compile-time Q6.10 and Q4.12 test/checker variants. |
| 6 | Dropout | Deterministic post-softmax dropout with seed, threshold, and inverted scale registers. |
| 7 | INT8/FP8 lower precision | INT8/Q4.4 external-memory mode plus FP8/E4M3 DMA-boundary conversion mode. |
| 8 | AXI4-Stream interface | Additional `flash_attn_axis_top` wrapper; original DMA top remains available. |
| 9 | DMA/task queue | `TASK_COUNT` and `TASK_STRIDE_BYTES` run multiple tasks from one START. |

Item #1 is claimed only as a BF16 I/O mode, not as a full native floating-point datapath.

## Verification Entry Points

Quick integrated regression:

```bash
bash ./sim/run_bonus_all.sh
```

Individual quick checks:

```bash
./sim/run_top_compile.sh
./sim/run_top_e2e_smoke.sh
./sim/run_bonus_sequence_smoke.sh
./sim/run_bonus_task_queue_smoke.sh
./sim/run_bonus_axis_stream_smoke.sh
./sim/run_bonus_dropout_smoke.sh
./sim/run_bonus_multi_head_smoke.sh
./sim/run_bonus_lowprecision_int8_smoke.sh
./sim/run_bonus_bf16_smoke.sh
```

The default Q8.8 single-task path remains covered by `run_top_e2e_smoke.sh`; bonus modes are
programmed only when their registers or parameters are enabled.

See `reports/bonus_results.md` for cycles, bytes, and error evidence.
