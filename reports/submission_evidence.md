# Submission Evidence Index

Branch: `codex-bonus-integrated-static-scale-fmax`  
Commit: current branch head
Baseline parent: `codex-baseline-core-pipeline-fmax` commit `9d1d4d8`

This file is the submission evidence index for the integrated bonus branch. It maps the
course handout requirements to tracked RTL, verification, report, image, waveform, and
Genus synthesis artifacts in this branch.

## Handout Requirement Map

| Required item | Evidence in this branch |
|---|---|
| Complete RTL source | `rtl/include/`, `rtl/core/`, `rtl/axi/`, `rtl/top/` |
| Runnable testbench and cases | `tb/sv/`, `tb/vectors/`, `sim/run_*.sh` |
| Cadence scripts and SDC | `synth/genus.tcl`, `synth/constraints.sdc`, `synth/filelist.f`, `synth/run_genus.sh` |
| Genus physical synthesis reports | `synth/reports_ispatial/*.rpt`, `reports/synthesis_summary.md` |
| Design and bonus documentation | `README_bonus_integrated.md`, `README_bonus_axi_stream.md`, `README_bonus_dropout.md` |
| Correctness report vs FP32 golden | `reports/bonus_results.md` |
| Bonus item completion evidence | `reports/bonus_completion_matrix.md` |
| Report-ready screenshots | `reports/*.png` |
| Key waveform files | `reports/waves/*.vcd` |

## Latest Run Evidence

The latest integrated branch was verified on 2026-06-07 after merging all bonus features onto
the static-scale baseline skeleton. The quick-suite wrapper was also rerun after adding a
portable Python resolver for Git Bash/Windows shells.

| Command | Coverage | Result |
|---|---|---|
| `./sim/run_top_compile.sh` | RTL compile for baseline and top-level test targets | PASS |
| `./sim/run_bonus_all.sh` | Integrated quick bonus suite | PASS |
| `RUN_FULL=1 ./sim/run_top_e2e_smoke.sh` | Full-size S=256,D=64,BK=16,BQ=16 default Q8.8 E2E | PASS |
| `RUN_VECTORS=1 ./sim/run_top_e2e_smoke.sh` | Full-size S=256,D=64,BK=16,BQ=16 supplied random-vector E2E | PASS |
| `RUN_FULL=1 ./sim/run_bonus_bf16_smoke.sh` | Full-size S=256,D=64,BK=16,BQ=16 BF16 I/O E2E | PASS |
| Direct low-precision full-size VVP | Full-size S=256,D=64,BK=16,BQ=16 INT8/Q4.4 and FP8/E4M3 | PASS |

Full-size result from the latest run:

| Shape | Cycles | RD_BYTES | WR_BYTES | RTL MAE | RTL MaxE | FP32 MAE | FP32 MaxE |
|---|---:|---:|---:|---:|---:|---:|---:|
| Default generated tensors, S=256,D=64,BK=16,BQ=16 | 233312 | 589824 | 32768 | 0.000000 | 0.000000 | 0.000015 | 0.003906 |
| Supplied random vectors, S=256,D=64,BK=16,BQ=16 | 233312 | 589824 | 32768 | 0.000000 | 0.000000 | 0.000097 | 0.054688 |
| BF16 I/O tensors, S=256,D=64,BK=16,BQ=16 | 233312 | 589824 | 32768 | 0.000000 | 0.000000 | 0.000015 | 0.003906 |
| INT8/Q4.4 tensors, S=256,D=64,BK=16,BQ=16 | 196320 | 294912 | 16384 | 0.000000 | 0.000000 | 0.005238 | 0.187500 |
| FP8/E4M3 tensors, S=256,D=64,BK=16,BQ=16 | 196320 | 294912 | 16384 | 0.000000 | 0.000000 | 0.000043 | 0.011719 |

Acceptance reference from the handout:

| Metric | Required | Latest result |
|---|---:|---:|
| Mean absolute error | <= 0.03 | 0.000015 |
| Max absolute error | <= 0.10 | 0.003906 |
| Full-size latency | < 300000 cycles | 233312 cycles |

## Synthesis Evidence

The `bonus_6.6` Genus iSpatial run uses an 8 ns clock and is timing clean. The synthesis
run was made at commit `f6ded9a`; later branch commits only add evidence files and script
portability, not RTL changes.

| Metric | Result |
|---|---:|
| Clock period | 8 ns |
| Critical path slack | +1.3 ps |
| TNS | 0.0 |
| Violating paths | 0 |
| Cell area | 7918810.862 |
| Net area | 6315329.605 |
| Total area | 14234140.467 |
| Total power | 2.10594 W |

Primary reports:

| File | Purpose |
|---|---|
| `synth/reports_ispatial/10_qor.rpt` | Clock period, slack, TNS, violating paths, area summary |
| `synth/reports_ispatial/20_area.rpt` | Hierarchical area report |
| `synth/reports_ispatial/30_timing.rpt` | Critical path timing report |
| `synth/reports_ispatial/40_power.rpt` | Power report |
| `synth/reports_ispatial/50_check_design_post_synth.rpt` | Post-synthesis design checks |
| `synth/reports_ispatial/60_check_timing_post_synth.rpt` | Post-synthesis timing lint checks |

## Bonus Evidence Map

| Bonus item | Implementation | Primary evidence |
|---:|---|---|
| 1 BF16/FP16 | BF16 external tensor mode through DMA-boundary conversion; internal datapath reuses validated Q8.8 core | `sim/run_bonus_bf16_smoke.sh`, `reports/bonus_bf16_summary.png`, `reports/waves/wave_bf16_s8_d8.vcd` |
| 2 Multi-head | Sequential head execution via `HEAD_COUNT` and `HEAD_STRIDE_BYTES` | `sim/run_bonus_multi_head_smoke.sh`, `reports/bonus_results.md` |
| 3 Longer/configurable sequence | Parametric `S_LEN` top E2E cases for S=64 and S=128 | `sim/run_bonus_sequence_smoke.sh`, `reports/bonus_results.md` |
| 4 Padding mask | `VALID_LEN` masks invalid K/V tokens and invalid output rows | `sim/run_top_e2e_smoke.sh`, `reports/bonus_results.md` |
| 5 Other fixed-point formats | Q6.10 and Q4.12 checker/testbench modes | `sim/run_top_e2e_smoke.sh`, `model/check_top_e2e_output.py` |
| 6 Dropout | Deterministic post-softmax dropout with seed, threshold, and inverted scaling | `sim/run_bonus_dropout_smoke.sh`, `README_bonus_dropout.md` |
| 7 Lower precision | INT8/Q4.4 and FP8/E4M3 external-memory modes | `sim/run_bonus_lowprecision_int8_smoke.sh`, `reports/waves/wave_int8_q4_4_s8_d8.vcd`, `reports/wave_lowprecision_s8_d8_preview.png` |
| 8 AXI4-Stream | Additional `flash_attn_axis_top` wrapper | `sim/run_bonus_axis_stream_smoke.sh`, `rtl/top/flash_attn_axis_top.sv` |
| 9 DMA/task queue | `TASK_COUNT` and `TASK_STRIDE_BYTES` chain multiple attention tasks from one START | `sim/run_bonus_task_queue_smoke.sh`, `rtl/top/flash_attn_top.sv` |

## Waveform Files

The following VCDs are tracked intentionally because the course handout asks for key waveform
files. They are small S=8 representative runs and can be opened directly in GTKWave.

| Waveform | Purpose | Preview image |
|---|---|---|
| `reports/waves/wave_q8_s8_d8_control_dma_softmax.vcd` | AXI-Lite start/status, DMA read/write, causal mask, online-softmax state | `reports/wave_q8_control_dma_preview.png`, `reports/wave_q8_causal_softmax_preview.png` |
| `reports/waves/wave_bf16_s8_d8.vcd` | BF16 I/O mode control, DMA conversion, core handshake | `reports/wave_bf16_s8_d8_preview.png` |
| `reports/waves/wave_int8_q4_4_s8_d8.vcd` | INT8/Q4.4 lower-precision data path and reduced external bytes | `reports/wave_lowprecision_s8_d8_preview.png` |

Regeneration commands:

```bash
vvp sim_build/tb_flash_attn_top_e2e_small.vvp \
  +OUT_HEX=sim_build/wave_q8_s8_d8_o.hex \
  +DUMP_VCD=1 \
  +VCD_PATH=reports/waves/wave_q8_s8_d8_control_dma_softmax.vcd

vvp sim_build/tb_flash_attn_top_e2e_bf16_s8_d8.vvp \
  +OUT_HEX=sim_build/wave_bf16_s8_d8_o.hex \
  +DUMP_VCD=1 \
  +VCD_PATH=reports/waves/wave_bf16_s8_d8.vcd

vvp sim_build/tb_flash_attn_top_e2e_lowprecision_s8_d8.vvp \
  +OUT_HEX=sim_build/wave_int8_q4_4_s8_d8_o.hex \
  +DUMP_VCD=1 \
  +VCD_PATH=reports/waves/wave_int8_q4_4_s8_d8.vcd
```

## Report-Ready Images

| Image | Use in report |
|---|---|
| `reports/bonus_fullsize_summary.png` | Full-size correctness/performance summary |
| `reports/random_fullsize_verification.png` | Random-vector full-size verification summary |
| `reports/bonus_bf16_summary.png` | BF16 I/O bonus summary |
| `reports/wave_q8_control_dma_preview.png` | Control/DMA waveform screenshot |
| `reports/wave_q8_causal_softmax_preview.png` | Causal mask and online-softmax waveform screenshot |
| `reports/wave_bf16_s8_d8_preview.png` | BF16 waveform screenshot |
| `reports/wave_lowprecision_s8_d8_preview.png` | Lower-precision waveform screenshot |

## Reproduction Checklist

1. Checkout `codex-bonus-integrated-static-scale-fmax`.
2. Run `./sim/run_top_compile.sh`.
3. Run `./sim/run_bonus_all.sh`.
4. Run `RUN_FULL=1 ./sim/run_top_e2e_smoke.sh` for default full-size evidence.
5. Run `RUN_VECTORS=1 ./sim/run_top_e2e_smoke.sh` for supplied random-vector full-size evidence.
6. Run `RUN_FULL=1 ./sim/run_bonus_bf16_smoke.sh` for BF16 I/O full-size evidence.
7. Run the direct low-precision VVP cases recorded in `reports/full_evidence_run_2026-06-07.md`.
8. Open the tracked VCD files under `reports/waves/` for waveform review.
9. Attach fresh Genus reports separately after synthesis.

## Refresh Notes

Current-branch low-precision quick checks, tracked low-precision waveform, and direct
low-precision full-size VVP cases pass. The combined low-precision script can still be slow
or awkward under Windows shell pipelines, so the full-size evidence uses direct single-case
VVP commands for reproducibility.
