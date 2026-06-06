# Integrated Bonus Branch On PPA Baseline

Branch: `codex-bonus-integrated-static-scale-fmax`

This branch is the unified bonus integration branch rebuilt from
`codex-baseline-core-pipeline-fmax` commit `9d1d4d8`, the latest optimized baseline skeleton.
The goal is to preserve the baseline timing/area/performance path while adding optional
bonus modes behind registers, parameters, or separate wrappers.

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

## Synthesis-Friendly Timing Configuration

`flash_attn_top` now defaults to the performance configuration used for re-synthesis:

- `STATIC_SCALE_MODE=1`
- `STATIC_SCALE_Q8_8=32`
- `ENABLE_DROPOUT=0`

This lets synthesis constant-fold the default full-size scale factor and trim dropout-only
logic from the timing-critical production datapath. The dynamic scale and dropout RTL remain
available by parameter override; the main testbench explicitly overrides back to
`STATIC_SCALE_MODE=0` and `ENABLE_DROPOUT=1` for functional bonus regressions.

Full-size random-vector smoke for the synthesis-friendly configuration:

```bash
bash ./sim/run_bonus_synth_timing_smoke.sh
```

See `reports/bonus_results.md` for cycles, bytes, and error evidence. See
`reports/submission_evidence.md` for the submission evidence index, waveform list, and
handout requirement mapping.
