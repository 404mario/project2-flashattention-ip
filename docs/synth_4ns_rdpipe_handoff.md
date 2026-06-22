# 4.x ns 攻坚交接说明（分支 `4ns-dma-rdpipe`，HEAD `bd4934e`）

> 目的：切掉冻结 5ns 核的关键路径，使时钟收敛到 **4.5ns（主目标）/ 4.0ns（上探）**；不动 `baseline-v2-synthopt` 冻结 tag、不动 `bonus-v2-5ns-core`。
> 诚实边界：本地 iverilog 只证 **bit-exact + cycles**；真实 **面积 / Fmax 必须 Genus**。

## 0. 当前分支状态 + 推荐综合配方（2026-06-22）

**分支 `bd4934e` = 两个 bit-exact RTL 改动叠加**，均全规模 S=256 causal 验过 md5==`01697fe8`（== baseline 逐字节）：
| 改动 | 文件 | 解决的墙 | cycles |
|---|---|---|---|
| rd_beat_pipe | `dma_controller.sv` | DMA 输入写 `m_axi_rvalid→v_buf2`（top-50 约 19 条） | +626 |
| dot-split | `dot_stream.sv` | 点积锥 `feed_idx→k_mux→multiply`（top-50 约 21 条） | +3 |
| **合计** | | **两道共限墙中的 40/50 条最差路径** | **260,420（+629，13.2% 余量到 300k）** |

**⚠️ 诚实预期（决定要不要继续）**：这两改解的是**最大的两道墙**，但 Path 2..50 里还剩 **~5 条内部锥未动**：
- `u_norm_s1_recip`（归一化倒数，4774ps，5ns +31ps）→ 4.5ns 约 **−469ps**
- `u_combine s2_prod`（softmax 乘，4764ps，5ns +34ps）→ 4.5ns 约 **−466ps**
- `s_axil_rdata`（AXI-lite 配置寄存器读，I/O 外部延迟约束）→ 非性能路径，**可用 SDC multicycle/放松 output_delay 消除**，不必动 RTL。

所以 **4.5ns 不靠 RTL 改完就保证过**：残余 ~470ps（~10%）要靠 **high effort 综合**补；补不上则把 norm / softmax 两锥各做一次同样的操作数/级拆分（技术同 dot-split，我可继续做）。

**推荐配方（按顺序）：**
1. EDA 机 fetch 本分支：`git fetch origin 4ns-dma-rdpipe && git checkout 4ns-dma-rdpipe`。
2. SDC 周期改 **4.500ns**（`input_delay` 维持 1500ps 同口径）。
3. **`set_db syn_generic_effort high` / `syn_map_effort high` / `syn_opt_effort high`**（tcl 注释原话："bump back to high only if a medium run leaves small slack" —— 现在正是这个情形；high 拿 18% 面积裕度换 ~10% 时序）。
4. `report_timing -max_paths 50 -nworst 1`：**预期点积锥 + DMA 路径已消失**。看残余：
   - WNS ≥ 0 → **4.5ns 成立**（high effort 补上了 norm/softmax）。
   - WNS ≈ −200~−470 且失败路径是 `u_norm_*` / `u_combine s2_prod` → 告诉我，我把这两锥也拆（本地可验 bit-exact）。
   - WNS ≈ −470 且失败路径是 `s_axil_rdata` → SDC 放松那条 I/O 约束即可（配置读非关键）。
5. **面积验收**：high effort 会推高面积，确认 `total_cell_area/4.7952` 仍 ≤ 9.59M（82.1% + 高 effort 膨胀，18% 裕度大概率扛得住）。
6. 4.0ns 上探：同上但 norm/softmax 几乎必须各切一刀（4ns 缺口 ~990ps）。

下面 §1-§7 是 rd_beat_pipe（第一道墙）的详细论证；dot-split（第二道墙）见 §8。

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

> ### ⚠️ 2026-06-22 Path 2..50 实测结论（已在冻结 .db 上 report_timing -max_paths 50 跑出）——4ns 被计算核挡住，rd_beat_pipe 单独不够
>
> Top-50 路径分两类：
> - **A 类（DMA 输入写）**：`m_axi_rvalid → v_buf2`，data 3365ps + 输入延迟 1500ps，+5~+32ps。rd_beat_pipe 能切。
> - **B 类（内部 reg→reg 计算，约 20+/50 条）**：`feed_idx → u_dot_node_q`（点积树，data **4778ps**，+13ps）、
>   `emit_index → u_norm_s1_recip`（归一化倒数，**4774ps**，+31ps）、`u_combine s1_w → s2_prod`（softmax 乘，**4764ps**，+34ps）。
>
> **设计是"双重共限"的 5ns 墙**：A 类 `1500+3365+130≈4995ps`、B 类 `4778+209≈4987ps`，两者都卡 ~5.0ns。
> rd_beat_pipe 只拆 A；拆完新关键路径立即变成 B 类 Path 6（点积树 ≈4.99ns）→ **Fmax 几乎零提升**。
> B 类 4ns slack ≈ 5ns slack − 1000ps = **全部 −960~−990ps**。
>
> **⇒ 4ns 需把点积树 + 归一化 + softmax 三个独立深逻辑锥各砍 ~1000ps（21%）= 多模块插流水重构**，
> 后果：cycles 涨（吃 40k/15% 裕度）+ 面积涨（吃 18% 裕度）+ bit-exact 重验 ×3 + retiming 已到极限。
> **可达性下修到 ~10-15%、高风险。结论：5ns 是本核频率上限，提交 `bonus-v2-5ns-core`（5ns+bonus）；
> rd_beat_pipe 已验证存档，但单独无软分价值，仅在愿意配套重构计算核时才用。**
> 若仍要冲 4ns：先动主导项 **点积树 `dot_stream`**（占 top-50 约 20 条），再 norm、combine。

**（历史保留）Step 0（秒级）——重报现有冻结网表的 Path 2..N，不用重综合：**
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
- 分支 `4ns-dma-rdpipe`（off `baseline-v2-synthopt` `e95c391`），rd_beat_pipe=`8791dbb`，dot-split=`bd4934e`。
- **不动** `baseline-v2-synthopt`（冻结提交核）、`bonus-v2-5ns-core`（bonus 分支）。
- D: 备份 `4ns-dma-rdpipe.bundle`。

## 8. dot-split（第二道墙，`dot_stream.sv`，commit `bd4934e`）

**证据（Path 6 逐元件，冻结 .db）**：`feed_idx_q →[k_tile 16:1 行 mux + 长布线 ~1535ps]→ dot_k_vec →[16×16 乘法 ~2950ps]→ node_q[0]`，二者**塞在同一拍** = 4778ps，5ns +13ps。这是 top-50 里约 21 条的同构锥（点积树前端），是 4ns/4.5ns 的主导内部闸。

**改法**：在 `dot_stream` 里新增一级**操作数寄存器** `q_op_q/k_op_q`——先寄存选出的 q/k 操作数，下一拍再乘。于是 k_tile mux（~1.5ns）与乘法（~2.95ns）落在**两拍**，点积锥关键路径降到 ~max(1.5, 2.95)+setup ≈ 3.2ns，clears 4.5ns 与 4.0ns。`LATENCY` 由 `LEVELS+1`→`LEVELS+2`，`vpipe_q` 自动跟随。

**为何 bit-exact**：消费方 `flash_core.sv:317/394` 按 `dot_out_valid` 计数收点积、PS_FEED 收满 `prod_vcnt` 才退出 = **延迟无关**；加一级纯流水只改时序不改数值。q_vec 在一次 feed 内恒定、k_vec 同延一拍 → q[d]·k[d] 对齐不变。

**实测**：全规模 md5==`01697fe8`（== baseline 逐字节），cycles `260417→260420`（**dot-split 单独仅 +3**，排空被 producer/consumer ping-pong 吞掉）。

**残余（4.5ns 仍需处理）**：`u_norm_s1_recip`（4774ps）、`u_combine s2_prod`（4764ps）两锥未动 → 4.5ns 约 −470ps，靠 high effort 补；补不上则同法各拆一级（操作数/中间值寄存）。
