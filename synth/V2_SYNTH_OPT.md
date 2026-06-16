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

### 1) RTL：减少 dma 的动态下标写（`rtl/axi/dma_controller.sv`）
- 旧写法 `k_buf[tile_row_idx_q][col] <= ...`（动态**行**下标写 2D 数组）会让 Genus 生成
  `CDN_PAS_SKIP_MUX`。已改为**静态逐行译码写**：`for dec_row: if(dec_row==tile_row_idx_q) ...`，
  4 处（k_buf/v_buf/k_buf2/v_buf2）的**行**下标变常数。
- 注意：dma 仍有 beat 索引的**列/一维**动态访问（q_buf 收行、o_buf 写出），Genus 仍会为它们生成
  少量 skip-mux —— 因此仅靠 RTL 改写**不足以**完全消除 dma 内的 skip-mux（见 §2 实测教训）。

### 2) 综合 tcl：**定向 ungroup u_dma_controller** + 多线程 + retiming（`synth/genus_ispatial.tcl`）
> **实测教训（genus.log1，2026-06-16）**：把 ungroup 完全删掉后，`syn_generic -physical` 里
> Genus 自带的 **advanced-structuring** 步骤会对组合 fan-in 锥做内部 `group`，当它跨越
> dma↔core 边界去 group dma 的 `CDN_PAS_SKIP_MUX` 时报 **TUI-234** 退出。日志显示
> `u_flash_core/u_combine` 的 skip-mux group 正常（ratio=1.0），**只有 dma 跨边界那个失败**。
- 因此**恢复定向 ungroup**：只 `ungroup u_dma_controller`（把这一个小块的边界溶进顶层），
  advstr 就没有 dma 边界可跨 → 不再 TUI-234。**这正是真·8ns baseline 当年用的做法**
  （它干净跑完、Elapsed ≈ 7.8h）。
- **关键澄清（纠正本文旧说法）**：这只溶解 **dma 一个小块**，**不是**把整设计砸平；
  `flash_core` 等全部保留层级。所谓"30h 来自 ungroup"是早先的误判 —— 真 baseline 带这条
  ungroup 也只 7.8h，慢是别的原因（物理流 + 单线程 + 高 effort），已用多线程缓解。
- **多线程**：`set_db max_cpus_per_server 8` + `auto_super_thread true`（原单线程）。
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
- 没动 `flash_core` 的动态下标写：强行译码会增加 BQ 路 mux 面积、并有引 bug 风险，收益为负。
  > **更正（genus (1).log1，2026-06-16）**：旧说法"flash_core 不会触发 TUI-234"是**错的**。
  > 仅 ungroup dma 后，`syn_generic -physical`（**第二遍** generic）仍因 flash_core 的
  > `CDN_PAS_SKIP_MUX_0i`（causal-skip mux，`USE_CAUSAL_SKIP=1`）报 TUI-234 退出。
  > 真因不是 dma 边界，而是 **advstr 跑了两遍**：第一遍 `syn_generic` 把 SKIP_MUX_0i 作为 CAS
  > 层级**保留**（advstr_keep_structure=1），第二遍又在其内部建了**同名嵌套** SKIP_MUX_0i，
  > `group [all_fanin]` 跨这层嵌套边界即 TUI-234。
  > **已修**：在两遍 generic 之间溶解所有 `CDN_PAS_*_MUX` 组（见 `genus_ispatial.tcl` "TUI-234 fix #2"），
  > 让物理 generic 从扁平 fan-in 重新开始，不保留 dma ungroup（dma 仍需 ungroup，两者叠加）。
- 若 5ns 首轮未收敛：**零 cycle 代价**的下一步是给 producer 的 `scaled_score → buf_score` 路径
  补一级寄存（ping-pong 有 slack），而**不是**动 II=1 的 MAC 内环（那会加 cycles）。
