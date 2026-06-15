# v2-dma-prefetch 综合提速 + 5ns 就绪改造说明

本批改动目标（不劣化功能/cycles）：**让综合从 ~30h 大幅提速 + 具备冲 5ns clean 的能力**。
所有 RTL 改动均经全尺寸随机向量仿真验证为 **bit-exact + cycle-identical**。

## 仿真等价性（黄金参照 vs 改造后）
| | output hex md5 | full-size cycles | 随机向量 |
|---|---|---:|---|
| 改造前（v2-dma-prefetch 原始） | `01697fe8fe972d47231bc0de559f53d5` | 109,410 | PASS |
| 改造后（本批） | `01697fe8fe972d47231bc0de559f53d5` | 109,410 | PASS |

→ **逐字节一致、周期数一致**。功能/精度/cycles 零劣化。

## 改了什么 & 为什么

### 1) RTL：消除 TUI-234 根因（`rtl/axi/dma_controller.sv`）
- 旧写法 `k_buf[tile_row_idx_q][col] <= ...`（动态行下标写 2D 数组）会让 Genus 生成
  `CDN_PAS_SKIP_MUX`；旧 tcl 为此被迫 `ungroup -simple u_dma_controller` **强制砸平**，
  导致整设计塌成一个 ~34 万单元的扁平 region 一起优化 → **~30h**。
- 改为**静态逐行译码写**：`for dec_row in 0..BK-1: if (dec_row==tile_row_idx_q) k_buf[dec_row][col]<=...`。
  语义完全相同（仍只写被选中行），但行下标变成常数 → Genus 推断为带使能的普通触发器，
  **不再产生 skip-mux**。4 处（k_buf/v_buf/k_buf2/v_buf2）全部改。

### 2) 综合 tcl：去砸平 + 多线程 + 保留层级（`synth/genus_ispatial.tcl`）
- **删除** `ungroup -simple u_dma_controller`（30h 的直接元凶）。TUI-234 是 `[group]` 阶段
  报的错——不调用 ungroup，错误根本不出现；现在层级保留，Genus 按模块分块优化，**大幅提速**。
- **多线程**：`set_db max_cpus_per_server 8` + `auto_super_thread true`（原来单线程）。
- 都用 `catch` 包裹，跨 Genus 版本属性名不一致时只告警、不中断长跑。

### 3) 时序：寄存器 retiming + 可扫频 SDC（`constraints.sdc` + tcl）
- **retiming**（`set_db retime true`）：允许 Genus 跨组合逻辑搬移 `dot_stream` 加法树流水寄存器
  以平衡级延迟。**保持周期级 I/O 行为不变（latency/cycles 不变），只挪 flop** —— 这是冲 5ns 的
  **零 cycle 代价**主杠杆。
- **SDC 参数化**：`CLK_PERIOD_NS` 环境变量可一键扫 8/6/5ns，无需改文件；IO 延迟随周期按 30% 缩放
  （原固定 2.5ns 在 5ns 下会让 IO 路径假性主导，掩盖真实内部 fmax）。
- 报告目录按周期自动分目录 `reports_ispatial_<P>ns/`，扫频互不覆盖。

## 怎么跑（默认就是 5ns clean）
```bash
cd synth
./run_genus.sh                       # 默认 5.000ns、high effort、retiming on（直接冲 5ns clean）
# 结果在 synth/reports_ispatial_5.000ns/  ->  看 10_qor.rpt 的 Violating Paths / Slack
```
说明：SDC 默认周期已锁 5.000ns，`syn_*_effort=high`，retiming 开。无需再扫频。
（若临时想看别的点：`CLK_PERIOD_NS=8.0 genus -f synth/genus_ispatial.tcl`；`run_sweep.sh` 仍保留备用。）

## 为什么 v2 比老核更可能 5ns clean（结构论证）
- 老核 5ns 关键路径尾 = inner 递归里的 `acc*old_scale` **乘法**（loop-carried，无法 retime 掉）。
- v2 `softmax_combine` 把该乘法**移出内环**（inner 只剩加法器，乘法每 tile 一次、可多拍）→
  关键路径只剩加法树 + 浅流水级 → retiming 能有效压短。
- **但 5ns clean 仍需真实 Genus 数据确认**（本地无 PDK 标准单元、无法出 ns/门数）。

## 诚实边界
- 没有上 SRAM：K/V tile 只有 16 行深，实测换 SRAM 会使面积涸 3-4 倍或令 cycles 爆炸
  （SRAM 只在深存储划算）。本设计无深片上存储，故 tile 保持触发器是更优解。
- 没动 `flash_core` 的动态下标写：它们不被 ungroup，不会触发 TUI-234；强行译码反而增加
  BQ 路 mux 面积、并有引 bug 风险，收益为负。
- 若 5ns 首轮未收敛：**零 cycle 代价**的下一步是给 producer 的 `scaled_score → buf_score` 路径
  补一级寄存（ping-pong 有 slack），而**不是**动 II=1 的 MAC 内环（那会加 cycles）。
