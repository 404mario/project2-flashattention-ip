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
- Bonus 1, BF16 exploratory mode: `BF16_IO_MODE` stores external Q/K/V/O tensors as BF16 while the internal attention datapath stays on the validated Q8.8 core.

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
| BF16 I/O smoke | S=8,D=8,BK=4,BQ=4 | BF16_IO_MODE=1 | PASS | 466 | 512 | 128 | 0.000183 | 0.003906 |
| BF16 I/O smoke | S=32,D=16,BK=8,BQ=8 | BF16_IO_MODE=1 | PASS | 4780 | 6144 | 1024 | 0.000038 | 0.003906 |

Default Q8.8 small/medium cycle counts match the PPA skeleton after the bonus ports.
Low-precision rows have zero error against the integer RTL mirror. INT8/Q4.4 is a lossy
bandwidth trade-off against FP32; FP8/E4M3 keeps the quick-smoke FP32 MaxE below the
baseline acceptance threshold while halving external tensor bytes.
BF16 rows use BF16 storage at the AXI memory boundary; this is intentionally documented as
an I/O-format exploration rather than a full FP16/BF16 floating-point softmax datapath.

## Full-Size Evidence

Full-size S=256,D=64 simulations were rerun from the integrated branch after adding the
low-precision modes. The raw logs are under `sim_build/` and the report-ready summary image
is `reports/bonus_fullsize_summary.png`.

| Case | Shape | Config | Result | Cycles | RD_BYTES | WR_BYTES | RTL MaxE | FP32 MAE | FP32 MaxE |
|---|---:|---|---|---:|---:|---:|---:|---:|---:|
| Q8.8 baseline full-size | S=256,D=64,BK=16,BQ=16 | default | PASS | 269808 | 589824 | 32768 | 0.000000 | 0.000015 | 0.003906 |
| Q8.8 random-vector full-size | S=256,D=64,BK=16,BQ=16 | RUN_VECTORS=1, supplied random Q/K/V | PASS | 269808 | 589824 | 32768 | 0.000000 | 0.000097 | 0.054688 |
| BF16 I/O full-size | S=256,D=64,BK=16,BQ=16 | BF16_IO_MODE=1 | PASS | 269808 | 589824 | 32768 | 0.000000 | 0.000015 | 0.003906 |
| INT8/Q4.4 low-precision full-size | S=256,D=64,BK=16,BQ=16 | DATA_W=8,FRAC_W=4 | PASS | 232816 | 294912 | 16384 | 0.000000 | 0.005238 | 0.187500 |
| FP8/E4M3 low-precision full-size | S=256,D=64,BK=16,BQ=16 | FP8_E4M3_MODE=1 | PASS | 232816 | 294912 | 16384 | 0.000000 | 0.000043 | 0.011719 |

The VCD-enabled smoke run is available as `sim_build/wave_lowprecision_s8_d8.vcd`; a compact
preview image is `reports/wave_lowprecision_s8_d8_preview.png`.

Additional report-ready evidence images:

- `reports/bonus_bf16_summary.png`: BF16 I/O quick/full-size correctness and performance summary.
- `reports/wave_bf16_s8_d8_preview.png`: BF16 I/O control, DMA, and core handshake waveform preview.
- `reports/random_fullsize_verification.png`: random-vector full-size correctness summary.
- `reports/wave_q8_control_dma_preview.png`: AXI-Lite start/status, AXI master read, core stream, and writeback waveform.
- `reports/wave_q8_causal_softmax_preview.png`: causal masking and online-softmax internal state waveform.

The raw Q8.8 waveform for the two waveform previews is
`sim_build/wave_q8_small_control_dma_softmax.vcd`.
The raw BF16 I/O waveform is `sim_build/wave_bf16_s8_d8.vcd`.
