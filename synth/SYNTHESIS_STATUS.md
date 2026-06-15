# ⏳ 综合状态：待综合（PENDING SYNTHESIS）

> 本分支的 RTL **尚未在 Cadence Genus 上真正综合过**。
> 历史上 `synth/reports_ispatial/` 与 `reports/synthesis_summary.md` 里的数据
> 是从 `codex-baseline-core-pipeline-fmax`（或 bonus 基线）**复制**过来的旧 baseline 核报告，
> **与本分支 RTL 不符**，已删除以免误导评测。

## 当前可信状态
- **功能 / 精度 / cycles**：以 `reports/v2_evidence.md`（iverilog 随机向量全量仿真）为准。
- **面积 / 时序 / 主频 / 功耗**：**未知，待 Genus 综合后填入**。

## 复现综合
```bash
cd synth && ./run_genus.sh        # 8ns；冲刺 5ns 时改 constraints.sdc 的 CLK_PERIOD
```
综合完成后，本文件应被真实的 `reports_ispatial/` + `synthesis_summary.md` 取代。
