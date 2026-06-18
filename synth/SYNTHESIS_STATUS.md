# 综合状态：softmax_combine 已流水化，待重跑 5ns（PIPELINED — PENDING 5ns RERUN）

> 本分支 `baseline-v2-synthopt` 已：(1) 修复 Genus TUI-234；(2) **2026-06-18 把
> `softmax_combine` 的 `exp→乘→加` 单拍关键路径流水化**（见下）。上一次 5ns 综合失败
> （slack −4967ps、面积 11.18M µm²/233 万门超标），根因就是那条 ~9.8ns 单拍链；现已流水化，
> 待在 EDA 服务器**重跑 5ns**。

## 上一次 5ns 综合（失败，2026-06-18，high effort）
- Slack **−4967 ps**（worst path ~9.8ns，**5650 条违例**）；Cell Area **11.18M µm² ≈ 233 万门**（超 200 万硬限 16.5%）。
- 关键路径 = `u_flash_core/u_combine`（softmax_combine）的**单拍**：
  `exp_w 插值乘法 → 64 路 36×17 乘法阵列 → 36 位累加器`。
- 面积超标几乎全是**时序虚胖**：非核心区(DMA/AXI/buffer) 1.79M(8ns-clean) → 3.36M(失败 5ns)，+1.57M ≈ 整个超标量；
  u_combine 满是 buf_16/inv_16 升驱动 + `_dup` 克隆。→ 时序闭合后面积应回落到 ~8–8.5M（达标）。

## 修法（2026-06-18，已本地逐位验证）
把 `softmax_combine` 重写成 **3 级流水 E|X|A**（exp | 64 路乘法 | 累加），MAC 键与跨 tile 合并
（OLD/NEW）共用同一条流水、共用那 64 路乘法器（面积不增）；**算术逐位不变**，II=1 不变，仅 +drain 周期。
- 端口/function/`exp_w`/`scale_l`/参数/`max_comb`/`vreq` 协议**全不变** → `flash_core.sv` 与 TB 不需改。
- 综合脚本 effort 从 high 改 **medium**（路径已可行，medium 收敛更快、避免 high 的升驱动虚胖；
  真实 8ns baseline 也是 medium 干净通过）。retiming 仍开（可再平衡这 3 级）。

## 当前可信状态（本地 iverilog，逐位等价）
- **功能 / 精度 / cycles**：全规模 S=256/D=64 causal = **109,414 cycles**（改前 109,410，+4，<300k 预算）；
  改前/改后输出**逐字节相同**；单元 TB MAE=0.000672/MaxE=0.001272 与改前一致。
- **面积 / 时序 / 主频 / 功耗**：**待 Genus 重跑后填入**。

## 5ns 预算与每级延迟预估
- exp_w 单级 ~3.3ns（含内部插值乘）/ 64 路乘法 ~2.2ns / 加法 ~1.0ns → 都 <5ns 有裕量；瓶颈 exp 级，fmax 约 3.5–4ns。
- 基准 `8nsclean-baseline`：slack +2ps、7.84M µm²（163.5 万门，81.8%）。

## 复现综合 / 判读
```bash
./synth/run_genus.sh          # 默认 5.000ns（effort=medium）
cat synth/reports_ispatial_5.000ns/10_qor.rpt   # Violating Paths==0 且 Total Cell Area ≤ 9,590,400 µm²(=200万门) 即达标
```
- 若仍有少量违例：大概率是 `m_tile_q<=max_comb` 的 16 路 max 单拍 → 给 m_tile 补一级流水后重跑。
- 若干净但面积 >9.59M：`CLK_PERIOD_NS=6.0 ./synth/run_genus.sh`（或 `./synth/run_sweep.sh 6 5`），
  选**既干净又 ≤9.59M 的最快周期**（频率软评分，6ns 干净也是有效提交）。
- 综合完成后用真实 `reports_ispatial_<period>ns/` 回填本文件与 `reports/synthesis_summary.md`。
