# Unified Bonus Results

Branch: `codex-bonus-integrated-ppa-skeleton`

This file records tracked simulation evidence for the integrated bonus branch rebuilt on top
of the PPA-passing baseline. Raw simulator outputs under `sim_build/` remain ignored by Git.

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

- Bonus 2, multi-head support: sequential `HEAD_COUNT` runs advance Q/K/V/O addresses by `HEAD_STRIDE_BYTES`.
- Bonus 3, configurable sequence length: compile-time `S_LEN` is verified with S=64 and S=128 top E2E smoke cases.
- Bonus 4, padding mask: `VALID_LEN <= S_LEN` masks invalid K/V tokens and zeroes invalid output rows.
- Bonus 5, additional fixed-point formats: Q6.10 and Q4.12 smoke regressions reuse the same AXI-Lite/DMA flow.
- Bonus 6, dropout training mode: deterministic mask, threshold, seed, and inverted scale are runtime programmable.
- Bonus 7, lower precision: INT8/Q4.4 external tensors and FP8/E4M3 tensors are verified through the top E2E flow.
- Bonus 8, AXI4-Stream interface: `flash_attn_axis_top` wraps the shared core with Q/KV input streams and O output stream.
- Bonus 9, lightweight task queue: `TASK_COUNT` and `TASK_STRIDE_BYTES` chain multiple tensor regions through one START.

## Latest Quick Evidence

The table below is updated after running the quick scripts on this branch.

| Case | Shape | Config | Result | Cycles | RD_BYTES | WR_BYTES | FP32 MAE | FP32 MaxE |
|---|---:|---|---|---:|---:|---:|---:|---:|
| Q8.8 small top E2E | S=8,D=8,BK=4,BQ=16 | default | PASS | 456 | 384 | 128 | 0.000183 | 0.003906 |
| Padding mask top E2E | S=16,D=8,BK=4,BQ=4 | VALID_LEN=5 | PASS | 827 | 1152 | 256 | 0.000092 | 0.003906 |
| Q6.10 fixed-format top E2E | S=16,D=8,BK=4,BQ=4 | FRAC_W=10 | PASS | 1388 | 1536 | 256 | 0.000046 | 0.000977 |
| Q4.12 fixed-format top E2E | S=16,D=8,BK=4,BQ=4 | FRAC_W=12 | PASS | 1388 | 1536 | 256 | 0.000053 | 0.000244 |
| Q8.8 medium top E2E | S=32,D=16,BK=8,BQ=8 | default | PASS | 4780 | 6144 | 1024 | 0.000038 | 0.003906 |
| Configurable S smoke | S=64,D=16,BK=8,BQ=16 | VALID_LEN=64 | PASS | 15152 | 12288 | 2048 | 0.000031 | 0.003906 |
| Configurable S smoke | S=128,D=16,BK=8,BQ=16 | VALID_LEN=128 | PASS | 53920 | 40960 | 4096 | 0.000017 | 0.003906 |
| Task queue smoke | S=8,D=8,BK=4,BQ=4 | TASK_COUNT=2 | PASS | 934 | 1024 | 256 | <= 0.000183 | 0.003906 |
| AXI4-Stream smoke | S=8,D=8,BK=4 | stream wrapper | PASS | wait=587 | n/a | n/a | 0.000183 | 0.003906 |
| Dropout small smoke | S=8,D=8,BK=4,BQ=4 | DROPOUT_EN=1 | PASS | 466 | 512 | 128 | 0.001404 | 0.007812 |
| Dropout medium smoke | S=32,D=16,BK=8,BQ=8 | DROPOUT_EN=1 | PASS | 4780 | 6144 | 1024 | 0.000053 | 0.003906 |
| Multi-head smoke | S=8,D=8,BK=4,BQ=4 | H=4 | PASS | 1870 | 2048 | 512 | <= 0.000183 | 0.003906 |
| Multi-head smoke | S=8,D=8,BK=4,BQ=4 | H=8 | PASS | 3742 | 4096 | 1024 | <= 0.000183 | 0.003906 |
| INT8/Q4.4 low-precision smoke | S=8,D=8,BK=4,BQ=4 | DATA_W=8,FRAC_W=4 | PASS | 432 | 256 | 64 | 0.084961 | 0.250000 |
| INT8/Q4.4 low-precision smoke | S=32,D=16,BK=8,BQ=8 | DATA_W=8,FRAC_W=4 | PASS | 4388 | 3072 | 512 | 0.046997 | 0.187500 |
| FP8/E4M3 low-precision smoke | S=8,D=8,BK=4,BQ=4 | FP8_E4M3_MODE=1 | PASS | 432 | 256 | 64 | 0.001038 | 0.011719 |
| FP8/E4M3 low-precision smoke | S=32,D=16,BK=8,BQ=8 | FP8_E4M3_MODE=1 | PASS | 4388 | 3072 | 512 | 0.000259 | 0.011719 |

Default Q8.8 small/medium cycle counts match the PPA skeleton after the bonus ports.
Low-precision rows have zero error against the integer RTL mirror. INT8/Q4.4 is a lossy
bandwidth trade-off against FP32; FP8/E4M3 keeps the quick-smoke FP32 MaxE below the
baseline acceptance threshold while halving external tensor bytes.
