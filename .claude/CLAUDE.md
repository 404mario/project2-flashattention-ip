# CLAUDE.md

Repository: `404mario/project2-flashattention-ip` — 课程 Project 2 FlashAttention 硬件加速器 IP。

## 现在在哪（一句话）
v2 流式架构（II=1 `dot_stream` + `softmax_combine`）已 **bit-exact 验证通过**，已**修好 Genus
TUI-234**。当前阶段：在 Cadence Genus 上**冲 5ns clean**。功能/精度/cycles 不再动。

## 5ns 进度（2026-06-19，读这里先了解现状）
- **第二次 5ns 综合已完成**（RTL `b56628d`）：slack **−602.7ps**、违例 **638**、cell area **10.19M µm²
  （212.5 万门，超 200 万限 6.3%）**、cycles 109414。比第一次(−4967/5650/11.18M)大幅改善但**两项硬指标仍差一步**。
  报告归档 `synth/reports_ispatial_5.000ns_b56628d_PIPELINED/`，分析 `docs/synth_5ns_analysis_2026-06-19.md`。
- 关键路径整条在 `u_combine` 的 **exp_w 那一拍**；**面积超标几乎全是时序虚胖**（不在关键路径的
  DMA/AXI 失败时 3.35M，8ns-clean 时仅 1.76M）→ 闭合时序同时解决频率(软分)+面积(硬限)。
- **已 push E-split（提交 `9199ccb`）**：把 exp_w 那拍劈成 4 级流水 `E1|E2|X|A`，算术**逐位不变**、
  flash_core/TB 不改、II=1、cycles 109414→109446。**本地全绿**（单元 TB + 全规模 S=256 改前/改后逐字节相同）。
  → **下一步：在 EDA 服务器跑第三次 5ns**（`./synth/run_genus.sh`，medium），判读见 `synth/SYNTHESIS_STATUS.md`。
- 最新进度/判读口径/兜底阶梯**以 `synth/SYNTHESIS_STATUS.md` 为准**（每次综合后回填）。

## 分支布局（2026-06 重命名后，共 5 个）
| 分支 | 角色 |
|---|---|
| `main` | 主干 |
| **`baseline-v2-synthopt`** ★当前工作分支 | baseline 的 v2 流式优化版（dma-prefetch + synthopt）。已 bit-exact、已修 TUI-234，目标 5ns |
| `8nsclean-baseline` | **唯一完整综合过**的 baseline：8ns clean、slack +2ps、cell area 7.84M（≈163.5 万门 / 限 200 万）。5ns 预估的基准参考 |
| `bonus-v2-synthopt` | bonus 的 v2 优化版 |
| `8nsclean-bonus` | bonus 的 8ns 综合版 |

> 注：旧分支名（`codex-baseline-core-pipeline-fmax`、`codex-baseline-v2-dma-prefetch-synthopt` 等）
> 文档里若仍出现，按上表换算。删除的实验分支已打 `archive/` tag 备份。

## Hard constraints（不可违反）
- 外部 Q/K/V/O = signed **Q8.8 16-bit**；不得把 AXI/DMA/top 外部 payload 改成 Q16.16。
- Q16.16 或更宽仅允许在 softmax / reciprocal / normalization / Python golden 内部。
- Baseline 形状：单 batch、单 head、**S=256, D=64**。FlashAttention 式 tiling + online softmax，**不得存完整 S×S** 注意力矩阵。
- AXI4-Lite：START/BUSY/DONE/ERROR + base addr / stride / scale / neg_large / CYCLES。AXI Master/DMA 读 Q/K/V、写 O。
- 正确性目标：**MAE ≤ 0.03、MaxE ≤ 0.10** vs FP32 golden。

## 综合（在校内 EDA 服务器；本机 WSL 无 Genus/PDK）
```bash
./synth/run_genus.sh          # module load + genus -f synth/genus_ispatial.tcl，默认 5.000ns
cat synth/reports_ispatial_5.000ns/10_qor.rpt   # 看 Slack / Violating Paths(=0才clean) / Cell Area
./synth/run_sweep.sh 8 6 5    # 扫频找 fmax
```
- **只有 `genus_ispatial.tcl` 一个综合脚本**（冗余的 `genus.tcl` 已删）。
- TUI-234 根因与修复：见 `docs/genus_synthesis_troubleshooting.md`。
- 5ns 瓶颈是 `softmax_combine` 的 exp 链：第一次综合是单拍 exp×MAC（已流水成 E|X|A，`b56628d`），
  第二次综合关键路径只剩 exp_w 那拍（已再劈成 E1|E2，`9199ccb`，本地逐位验证通过，待第三次综合确认）。

## 仿真验证（本机 WSL，iverilog）
```bash
iverilog -g2012 -o sim_build/tb_softmax_combine.vvp rtl/core/softmax_combine.sv tb/sv/tb_softmax_combine.sv && vvp sim_build/tb_softmax_combine.vvp   # 单元 bit-exact
bash sim/run_top_compile.sh                    # 顶层编译
bash sim/run_top_e2e_smoke.sh                  # 小/中规模 E2E
RUN_VECTORS=1 bash sim/run_top_e2e_smoke.sh    # 全规模 S=256 向量（需 numpy）
```
全规模基准：**109,410 cycles**，对 `tb/vectors/golden_o.hex` 逐字节一致。

## 脚本规范（WSL/Linux）
- 一律用 Bash `.sh`，不直接跑 `.ps1`。只有 `.ps1` 时先读懂再翻译成 `.sh`，编译 flag 不要猜。

## 关键文档
- `docs/genus_synthesis_troubleshooting.md` — TUI-234 根因 + RTL 治本（三 log 复盘）
- `docs/project2_requirements.md` — 官方评分口径
- `docs/v2_streaming_architecture.md` / `docs/dma_prefetch_architecture.md` — v2 架构
- `reports/v2_evidence.md` — 仿真证据（功能/精度/cycles）
- `synth/HOWTO_synthesis.md` — 综合流程踩坑记录
