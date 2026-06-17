# 综合状态：可综合，待跑 5ns（SYNTHESIZABLE — PENDING 5ns RUN）

> 本分支 `baseline-v2-synthopt` 的 RTL 已**修复 Genus TUI-234**（`syn_generic -physical`
> 不再中断，见 `docs/genus_synthesis_troubleshooting.md`），现可在 Cadence Genus iSpatial 上
> 完整综合。**尚未跑出本分支自己的 5ns 报告**——下一步在 EDA 服务器跑。

## 当前可信状态
- **功能 / 精度 / cycles**：已验证。全规模 S=256/D=64 = **109,410 cycles**，对 `tb/vectors/golden_o.hex`
  逐字节一致；单元/顶层改前改后 bit-exact。详见 `reports/v2_evidence.md`。
- **面积 / 时序 / 主频 / 功耗**：**本分支未知，待 Genus 综合后填入**。

## 5ns 可行性预估（基准 = `8nsclean-baseline` 分支的真实 8ns 综合）
- 8ns 参考：slack **+2ps**、cell area 7.84M（≈163.5 万门 / 限 200 万，81.8%），关键路径在
  `u_dot_product_csa_tree`（一拍算完 64 元素点积的进位保留加法树）。
- 本分支用 **`dot_stream`（II=1、加法树逐级寄存）** 替换该 CSA tree → 8ns 的瓶颈被架构性切断。
- 预估新瓶颈：`softmax_combine` 的 S_MAC 那拍（`exp_w` 插值乘法 → `mulP=mulA*w_cur` 串联）。
  **5ns 边缘可达**，retiming + high effort 已开。若该路径违例：给 `w_cur`/`mulP` 加一级流水
  （II 仍 = 1，仅 +1 cycle latency，对总 cycle 数可忽略）。

## 复现综合
```bash
./synth/run_genus.sh          # 默认 5.000ns；扫频用 ./synth/run_sweep.sh 8 6 5
```
综合完成后，用真实 `reports_ispatial_<period>ns/` 取代本文件的占位，并回填
`reports/synthesis_summary.md`。
