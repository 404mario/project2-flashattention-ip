# 5ns 综合分析（2026-06-20）：第三次 5ns（E-split）——时序闭合，但「面积虚胖会自愈」被证伪

> 分支 `baseline-v2-synthopt`。本文分析**第三次 5ns 综合**（功能 RTL = `9199ccb`，`softmax_combine`
> exp 链劈成 `E1|E2` 4 级流水；HEAD `d1990c0` 仅 docs，`9199ccb..d1990c0` 无 RTL 改动）。
> 报告归档于 `synth/reports_ispatial_5.000ns_9199ccb_ESPLIT/`（含原始 tar + 8 份 .rpt + README）。

## TL;DR

- **好消息：5ns 时序第一次闭合了。** E-split 把关键路径从 `exp_w`（5584ps）转移到 `m_tile` 16 路 max，
  并**刚好 MET +1 ps、0 违例**。频率软分从此可拿满 200MHz。
- **坏消息：06-19 那篇的核心论点「面积超标几乎全是时序虚胖、闭合后自动回落到 ~8.6M」被本次数据证伪。**
  实测 0 违例下面积**不降反微升**：10.19M → **10.285M**，仍超 9.59M 硬限 **7.2%**。非核心 DMA/AXI 维持 3.35M、
  **没有**回收到预言的 1.76M。
- **修正后的路线：面积不会自愈，必须从结构上砍；且唯一能保 5ns 的 RTL 杠杆是 `BQ`（不是 06-19 误列的 `DOT_LANES`，那是死参数）。**

## 一、三项指标的当前状态

| 指标 | 三次 `9199ccb` @5ns | 赛题要求 | 性质 | 状态 |
|---|---|---|---|---|
| 主频 / slack | **+1 ps（0 违例）** | 越高越好 | **软分** | ✅ **clean @5ns** |
| 等效门数 | 2,144,839（10.285M µm²） | ≤ 2,000,000（9.59M） | **硬限** | ❌ 超 7.2%（+14.5 万门） |
| Cycles | 109,446 | < 300,000 | **硬限** | ✅ 仅 36.5% |

> 现在**只剩面积一项卡提交**。时序已不再是问题。

## 二、E-split 生效：关键路径转移并压线 MET

| | 二次 `b56628d` | 三次 `9199ccb`（E-split） |
|---|---|---|
| Worst slack | −602.7 ps | **+1 ps（MET）** |
| Violating Paths | 638 | **0** |
| 关键路径 | `exp_w` 那一拍（5584ps） | `m_tile` 16 路 max（`gt_265_50_*` 比较链）|
| 触发器数 | 140,736 | 143,156（E-split +2.4k） |

`exp_w` 劈成 `E1|E2` 后退出关键路径，新瓶颈正是二次 README 预判的「`m_tile` 16 路 max 单拍」——
本次它 **MET（+1ps）**，无需再补流水。**时序收敛这条线到此结束。**

## 三、被证伪的论点（本文最重要的一节）

06-19 分析（`synth_5ns_analysis_2026-06-19.md` 第 57–75 行）论证：非核心 DMA/AXI 因全局违例被
Genus「追时序」普涨到 ~2 倍，0 违例后 `syn_opt` 会回收到 ~1.76M，总面积落到 ~8.6M。**本次清零违例后实测：**

| 非核心 = top − u_flash_core − u_axi_lite_regs − u_axi_master_read | 值 |
|---|---|
| 一次失败 5ns（5650 违例） | 3.36M |
| 二次失败 5ns（638 违例） | 3.35M |
| **三次 clean 5ns（0 违例 +1ps）** | **3.35M ← 没有回收** |
| v2work 真实 8ns clean | 1.76M |

**为什么预测错了**：1.76M（8ns）→3.35M（5ns）的 +1.59M **不是违例引起的「追时序虚胖」，而是这套
DMA/AXI 在 5ns 周期下的真实实现代价**。即便它不在关键路径，Genus 仍须让其**每一条 reg-to-reg**
都满足 5ns，于是普遍升驱动 / 复制寄存器 / 加缓冲。8ns 时这些路径有 3ns+ 余量、可用最小单元；
5ns 一缩，余量没了，单元就回不去——**与全局违例数无关**。所以 0 违例也救不了面积。

> **教训**：「不在关键路径」≠「面积可随时序闭合回收」。只要它仍须满足同一个周期，缩周期就要付面积。
> 要拿回这块，**只能放钟（6ns）或从结构上减少其逻辑/寄存器**；后者对这套已定型、共享、正确的 DMA/AXI 不现实。

## 四、面积分解与可削减点

| 区块 | Cell-Area | 占比 | 可削减性（保 5ns 前提） |
|---|---|---|---|
| `u_combine`(softmax_combine) | 2.15M | 21% | 低：64 路乘法**已是单份时分复用**；且在关键路径上，动它有破时序风险 |
| flash_core 其余（`dot_stream`+大寄存器阵列+控制） | 4.76M | 46% | **中：`BQ` 撑起的 `acc_block`/`q_block` 寄存器阵列是最大可削项** |
| 非核心（DMA+AXI写+glue） | 3.35M | 33% | **零（5ns 下 RTL 动不了，见第三节）** |
| 合计 | 10.285M | 100% | 需砍 ≥ 0.70M |

### ❌ 伪杠杆更正：`DOT_LANES 32→16`（06-19 第 89 行误列为结构杠杆）
`flash_core` 实际点积引擎是 **`dot_stream`**（`flash_core.sv:153`），**无 `DOT_LANES` 参数**，恒为满 64 路树。
吃 `DOT_LANES` 的 `dot_product_engine`（及 `online_softmax_engine`/`value_accumulator`）**全树无实例**，
是 `filelist.f` 里的死代码，综合面积贡献 0。→ **改 `DOT_LANES` 是 11h 空跑，已排除。**

## 五、下一步：保 5ns，`BQ 16→4`

`BQ`（query block 行数）撑起 flash_core 最大的两个寄存器阵列：
- `acc_block[BQ][D_MODEL][ACC_W]` = BQ×64×36b（BQ=16 时 36,864 flops）
- `q_block[BQ][D_MODEL][DATA_W]` = BQ×64×16b（BQ=16 时 16,384 flops）

`BQ 16→4` 砍掉约 **4 万个触发器**（含横跨 BQ 行的读写 mux），**估计省 1.4–1.8M → 落到 ~8.8M（余量约 0.8M）**。

- **正确性**：每个 query 行的注意力彼此独立，`BQ` 只改 K/V tile 复用度与行状态寄存器数，**不改数学 → 应 bit-exact**。
  （DMA/tile_buffer/tile_scheduler 均无 `BQ` 耦合，已 grep 确认。）
- **时序**：`u_combine`（关键路径）与 `BQ` 无关，寄存器更少→拥塞更低，5ns 应仍闭合。
- **代价（待本机全规模实测确认 < 300k）**：K/V 重载随 q-block 数（S/BQ）线性增加；因果掩码下尾部 q-block
  最重，cycles 上升明显——**这是 `BQ=4` 唯一的风险点，须先用本机 S=256 向量量出真值再决定**。若 `BQ=4`
  逼近/超 300k，则退 `BQ=8`（省得少但 cycles 更稳）或 `BQ=6`。
- **改动点**：仅 `rtl/top/flash_attn_top.sv:12`（synth `elaborate` 用顶层默认，tcl 不覆盖参数）；
  同步改 sim 脚本/TB 的 `BQ` 默认与综合一致。

## 六、兜底

- `BQ` 砍完面积仍 >9.59M，或 cycles 顶不住：`CLK_PERIOD_NS=6.0`。6ns 下非核心那 1.59M 虚胖自然回落，
  几乎必过、零 RTL 风险，仅损频率软分（200→167MHz）。
- 单次 5ns 综合 wall-clock ≈ 11.4h（本次 elapsed 40,881s）。**先在本机把 `BQ` 的 bit-exact + cycles 量准、
  确认 <300k 再上综合**，避免赌空。
- 判读：重跑后 `synth/reports_ispatial_5.000ns/10_qor.rpt`，`Violating Paths==0` 且
  `Total Cell Area ≤ 9,590,400 µm²` 即两项达标，回填本文件与 `synth/SYNTHESIS_STATUS.md`。
