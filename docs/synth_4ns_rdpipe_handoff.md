# 4ns 攻坚 — DMA rd-beat 流水化交接说明（分支 `4ns-dma-rdpipe`）

> 目的：把冻结 5ns 核的关键路径切一刀，使时钟有望收敛到 4ns；不动 `baseline-v2-synthopt` 冻结 tag。
> 诚实边界：本地 iverilog 只证 **bit-exact + cycles**；真实 **面积 / Fmax 必须 Genus**。

## 1. 为什么改这里（真 Genus 证据）

冻结 5ns 报告 `synth/reports_ispatial_5.000ns_f185b97_FROZEN/30_timing.rpt` 的 Path 1：

```
Startpoint: m_axi_rvalid          Endpoint: v_buf2_reg[9][57][9]/D
Clock Edge 5000 - Setup 68 - Uncertainty 62 - Input Delay 1500 = Required 3370
Data Path 3365ps   Slack +5ps
```

- 路径 = `m_axi_rvalid` →(`axi_master_read` 组合直通)→ DMA `S_PF_V_RECV` 的 **16:1 行写译码 mux** → `v_buf2` flop。
- 4ns（period=4000ps）下：数据路径预算 = `4000 − 68 − 62 − 1500 = 2370ps`。当前 3365ps **超 ~1000ps** → 必须在该路径插寄存器。
- 后段延迟分布（30_timing.rpt 明细）：尾部两级 `nand2_1`(780ps, fanout 12) + `inv_2`(705ps, fanout 22) 是**写使能/数据广播进 flop 阵列**，扇出/布线主导 → 在写 mux 正前方打拍最有效。

## 2. 改了什么（仅 `rtl/axi/dma_controller.sv`）

在 AXI 读 beat 进入 `*_buf` 写译码**之前打一拍**：
- 新增 commit 级寄存器 `beat_vld_q / beat_data_q / beat_dst_q / beat_row_q / beat_bidx_q`。
- 5 个 RECV 态（Q/K/V/PF_K/PF_V）不再当拍写 buffer，而是**寄存 beat + 译码上下文**；FSM 的 beat_idx/state 推进逻辑原样保留。
- 新增 commit 级：下一拍用寄存的上下文做**静态行译码写**进对应 buffer。
- 路径被切成两段：`输入→寄存器`(~151ps，余量极大) 与 `寄存器→flop 阵列`(~3314ps，内部 flop-to-flop，<4ns 预算 3870ps，还余 ~556ps；Genus 还能寄存器复制进一步松)。

## 3. 为什么仍 bit-exact（设计论证）

均匀延迟 buffer 写一拍，输出数据值不变，只 cycle 数可能微动。两处"同沿读"用 1 拍 drain 闸消除竞争：
- **Q 路径**：`flash_core` 的 `ST_WAIT_Q`（flash_core.sv:332）在 `q_data_valid` 当拍组合读取全部 `q_data` → `q_present_drain_q` 让 `S_Q_PRESENT` 推迟 1 拍，使 valid 与最后一拍 commit 对齐。
- **预取提升**：`S_IDLE` prefetch-hit 提升（dma_controller.sv:264-268）同拍读 `v_buf2` → `pf_drain_q` 让 `pf_valid_q` 推迟 1 拍，使提升读到已落的 `v_buf2`。
- **KV 直读无需 drain**：`ST_WAIT_KV`（flash_core.sv:339）当拍只切 FSM、不读 tile 数据；tile 经 `v_row_q` 寄存消费、`k_tile[feed_idx]` 从 0 递增读取，最后写的高行很多拍后才被读。

## 4. 本地验证结果（bit-exact oracle）

命令：`bash sim/run_fullsize_vectors.sh rdpipe`（真实输入向量，S=256/D=64/BK=16/BQ=6 causal）。

```
TB           : tb_flash_attn_top_e2e_smoke PASS  (analytic golden, 容差内)
output md5   : 01697fe8fe972d47231bc0de559f53d5   == 权威定点 oracle ✅ (BIT-EXACT)
cycles       : 260,417   (baseline 259,791;  delta = +626 = +0.24%,  远 <300,000 ✅)
```

**bit-exact 判据说明（重要）**：判据是 `md5(output) == 01697fe8…`（仓库 6+ 处文档引用的权威定点镜像 /
baseline 实测输出 md5）。`run_fullsize_vectors.sh` 内置的 `cmp vs tb/vectors/golden_o.hex` 会报 NO，
但那是**误报**：`golden_o.hex` 是大写格式 + analytic-TB 生成（含已知单行 1-LSB 舍入差，md5 07a401f9，
仓库无处当 oracle 引用），对**未改的 baseline 同样报 NO**。已交叉验证：pristine baseline 与本分支输出
**逐字节相同**（两者 md5 均 01697fe8）。drain 代价来源：每次 Q-load + 每次 prefetch 完成各 +1 cyc。

**交叉验证铁证（同环境同向量，iverilog 全 RTL）**：
| | output md5 | cycles |
|---|---|---|
| pristine baseline（未改 dma_controller） | `01697fe8…` | 259,791 |
| rd_beat_pipe（本分支） | `01697fe8…` | 260,417 |
| 两份输出 `cmp` | **IDENTICAL byte-for-byte** | Δ +626 |
⇒ 输出零改变，rd_beat_pipe 对外完全等价于 baseline。

## 5. Genus 跑法 + 验收点（交给 EDA 机）

> **关于第二关键路径**：冻结归档 `30_timing.rpt` 只导出了 Path 1（`-max_paths 1`），`10_qor.rpt`
> 只给全局 `Critical Slack +4.8ps / TNS 0 / 违例 0`——**正 slack 的分布没存**，故第二、三路径的 slack
> 从现有报告**读不出**。架构推断：Path 2 极可能是 `softmax_combine` 的 16 路 max 比较链（上次综合
> `9199ccb` E-split 时它就是 Path 1，MET 仅 +1ps；这次才让位给 DMA 写路径）。它在 5ns 的 slack 只知
> ≥+5ps，很可能在低几百 ps —— **这才可能是真正的 4ns 闸门**。

**Step 0（秒级、最便宜、决定要不要往下跑）——重报现有冻结网表的 Path 2..N，不用重综合：**
```tcl
# 在 EDA 机上 restore 冻结网表（或综合后立即报），5ns 约束不变：
report_timing -max_paths 100 -nworst 100 -path_type full_clock   ;# 看 Path 2..100 的真实 slack
report_timing -slack_histogram                                   ;# 或直接看 slack 分布直方图
```
判读：把每条 reg-to-reg 路径的 5ns slack 减 1000ps ≈ 它的 4ns slack。
- Path 2 的 5ns slack **≥ +1500ps** → 4ns 基本稳，直接跑 4ns 综合。
- 在 **+200~+1000ps** → 4ns 需要先给 Path 2 加流水（再做一次 E-split / max 树加深）。
- **< +200ps** → 不加流水别想 4ns。
**这一步比盲跑一次 4ns 综合便宜几个数量级，应先做。**

**正式综合：**
1. filelist / SDC / tcl 取 baseline 同一套（本分支只改 `dma_controller.sv`）：
   `synth/filelist.f` + `synth/constraints.sdc` + `synth/genus_ispatial.tcl`（含 TUI-234 ungroup/advstr 修复）。
2. **先按 5ns 重综合一遍**做 sanity（应仍 ~82% 面积 / 0 违例；确认改动没引入新问题）。
3. **再把 SDC period 改 4.000ns**（input_delay 维持 1500ps 同口径）综合；务必 `report_timing -max_paths 100`。
4. 验收点：
   - **WNS/TNS**：原 Path 1（`m_axi_rvalid → v_buf2`）应消失或大幅松弛。
   - **新 top path**：预期转到 `softmax_combine` 的 E2-split / `normalizer` / dot 累加；记录新关键路径起止。
   - **面积**：`total_cell_area/4.7952` 是否仍 ≤ 9.59M µm²（rd-beat 寄存器仅加 ~一排 FF，预期涨幅可忽略；4ns 重映射可能让综合换更大单元，重点看这条）。
   - 0 违例则 4ns 成立；Fmax 软分提升。

## 6. 若 4ns 仍不收敛 — 回退梯队

1. **Genus 寄存器复制 / retiming** 后段（`set_optimize_registers` / 高 effort）——后段还有 556ps 余量+大扇出，复制驱动应能再松。
2. **已实测 AXI R skid**（`docs/synth_4ns_research_2026-06-21.md`）：+5088 cycles → 273k<300k，+~67FF。但只切路径前端、v_buf2 写 mux 尾巴还在，可能不够——作最后回退。
3. 退守 **5ns**（已冻结、两项全过）——Fmax 是软分，5ns 是无下行风险的保底。

## 7. 落地
- 分支 `4ns-dma-rdpipe`（off `baseline-v2-synthopt` `e95c391`），commit `8791dbb`。
- **不动** `baseline-v2-synthopt`（冻结提交核）、`bonus-v2-5ns-core`（bonus 分支）。
- D: 备份 `4ns-dma-rdpipe.bundle`。
