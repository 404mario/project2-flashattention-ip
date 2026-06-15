# Baseline Submission Evidence

Branch: `codex-baseline-core-pipeline-fmax`
Synthesis package: `baseline_6.5`
Synthesis commit: `9d1d4d8`

This index maps the FlashAttention course handout requirements to files tracked in this
baseline branch.

## Requirement Map

| Handout item | Evidence |
|---|---|
| Complete RTL source | `rtl/include/`, `rtl/core/`, `rtl/axi/`, `rtl/top/` |
| Verilog/SystemVerilog implementation | `rtl/**/*.sv`, `tb/sv/*.sv` |
| AXI4-Lite control interface | `rtl/axi/axi_lite_regs.sv`, `tb/sv/tb_axi_lite_regs_ctrl.sv` |
| AXI4 master + DMA data interface | `rtl/axi/axi_master_read.sv`, `rtl/axi/axi_master_write.sv`, `rtl/axi/dma_controller.sv` |
| Required control/status registers | `rtl/axi/axi_lite_regs.sv`, `docs/interface_spec.md` |
| FlashAttention-style tiling | `rtl/core/tile_scheduler.sv`, `rtl/core/flash_core.sv` |
| Online softmax without full score matrix | `rtl/core/online_softmax_engine.sv`, `rtl/core/flash_core.sv` |
| Q8.8 input/output and fixed-point datapath | `rtl/core/flash_core.sv`, `rtl/core/dot_product_engine.sv`, `rtl/core/normalizer.sv` |
| Causal mask | `rtl/core/causal_mask_unit.sv` |
| Testbenches, vectors, and scripts | `tb/sv/`, `tb/vectors/`, `sim/run_top_compile.sh`, `sim/run_top_e2e_smoke.sh` |
| Cadence scripts and constraints | `synth/constraints.sdc`, `synth/filelist.f`, `synth/genus_ispatial.tcl`, `synth/run_genus.sh` |
| Genus physical synthesis reports | `synth/reports_ispatial/*.rpt` |
| Architecture and interface documentation | `README.md`, `docs/architecture.md`, `docs/interface_spec.md` |
| Key waveform evidence | `reports/waves/baseline_q8_s8_d8_control_dma_softmax.vcd` |

## RTL Simulation Evidence

| Case | Shape | Result | Cycles | RD_BYTES | WR_BYTES |
|---|---|---|---:|---:|---:|
| Q8.8 control/DMA/causal small waveform | S=8,D=8,BK=4,BQ=16 | PASS | 335 | 384 | 128 |
| Q8.8 full-size baseline | S=256,D=64,BK=16,BQ=16 | PASS | 233312 | 589824 | 32768 |

Full-size checker result:

| Comparison | MAE | MaxE |
|---|---:|---:|
| RTL fixed-point mirror | 0.000000 | 0.000000 |
| FP32 softmax golden | 0.000015 | 0.003906 |

Primary logs:

| File | Purpose |
|---|---|
| `reports/baseline_wave_s8_d8.log` | Small representative E2E waveform run |
| `reports/baseline_fullsize_s256_d64.log` | Full-size S=256,D=64 E2E run |
| `reports/baseline_fullsize_s256_d64_check.log` | FP32 golden checker output |
| `reports/baseline_fullsize_s256_d64_o.hex` | Full-size RTL output dump |
| `reports/waves/baseline_q8_s8_d8_control_dma_softmax.vcd` | AXI-Lite start/status, DMA traffic, causal/softmax/core state waveform |

## Synthesis Evidence

> ⏳ **待综合（PENDING）**：本分支 v2 流式核尚未在 Genus 上真正综合。原先此处的综合数据是从 baseline 核报告复制的、与本分支 RTL 不符，已删除。面积/时序/主频/功耗以将来真实 `reports_ispatial/` 为准；功能/cycles 见 `reports/v2_evidence.md`。


## Reproduction

```bash
./sim/run_top_compile.sh
./sim/run_top_e2e_smoke.sh
RUN_FULL=1 ./sim/run_top_e2e_smoke.sh
cd synth && ./run_genus.sh
```

The baseline branch is intentionally independent from the bonus branch so the baseline
evaluation result remains reproducible.
