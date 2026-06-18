# FlashAttention IP 时序/面积优化 — 调研报告（带引用）

> 目的：依据第一次 5ns 综合失败报告（`synth/reports_ispatial_5.000ns_FAILED_699bff9/`），
> 从架构/RTL 层面优化时序与面积，参考 FlashAttention 系列论文与公开 ASIC/FPGA 实现。
> 方法：多角度文献检索 → 抓取一手来源 → 对每条结论做对抗式三票验证（需 2/3 反驳才否决）。
> 统计：6 角度 / 22 一手来源 / 80 条候选结论 / 25 条验证（18 证实、7 否决）。
> **可迁移的是机制与定性结论；所有绝对数字来自 GPU/FP/16nm，不能外推到 sky130+Q8.8。**

## 0. 背景与失败现象（对应 commit `699bff9`）

- 工艺/工具：Cadence Genus iSpatial + sky130。硬约束：**等效门 ≤ 200 万**（cell area ≤ 9.59M µm²）；
  频率越高越好（软评分）；单次 attention(S=256,d=64,causal) **cycles < 300k（当前仅 ~109k，预算极宽松）**。Q8.8 定点。
- 失败：slack **−4967ps**（worst ~9.8ns、5650 违例）、cell area **11.18M µm² ≈ 233 万门**（超标 16.5%）。
- 根因：`softmax_combine` 的**单拍**链 `exp_w(LUT+插值,含小乘法) → 64 路 36×17 乘法 → 36 位累加`。
  面积超标几乎全是**时序未收敛导致的升驱动/克隆虚胖**（非核心区 1.79M→3.36M，对比 8ns-clean）。

## 1. 已采用且被文献背书的设计（无需再改）

| 本设计 | 文献依据 | 验证票 |
|---|---|---|
| **归一化延后到 epilogue**（`acc/l` 在末端 `normalizer` 才除，内环不做倒数/除法） | **FA2** 核心改动：`diag(l)⁻¹` 移出内层、循环末只做一次（arXiv 2307.08691, Alg.1 line10/12）；FA3 同（2407.08608, Alg.1 line24） | 3-0 ✓ |
| **乘法移出 loop-carried 路径**（递归只剩加法器 + rescale 校正乘） | online softmax 是 **exact** 递归（实数算术下代数恒等），切流水不改功能（FA 原论文 2205.14135） | 3-0 ✓ |
| **exp→乘→加 拆多级流水**（E\|X\|A，commit `b56628d`） | retiming：最小寄存器数下多项式最优流水（Leiserson-Saxe, Algorithmica 1991）；FA3 跨迭代缓冲流水、把一迭代的 exp 与另一迭代 GEMM 重叠（2407.08608 §3.2, Alg.2） | 3-0 ✓ |
| **判断"面积虚胖 = 时序未收敛"** | 一条相反 claim「即便 exp 降为 1 拍 ROM，softmax 路径仍卡 12.945ns」被 **0-3 反驳** → combine 路径非天生卡死，流水化确能拆开 | 反驳 ✓ |

动机佐证：在有专用 matmul 单元的硬件上，**非-matmul(exp/特殊函数) 每 FLOP 远比 matmul 贵**
（A100 matmul 312 vs 非-matmul 19.5 TFLOPS ≈ 16×；H100 FP16 matmul 989 vs exp 3.9 TFLOPS ≈ 256×，
FA2/FA3 自述，3-0 ✓）——把 exp 移出 MAC 关键路径、最小化 rescale 工作量是有据的。

## 2. 加码菜单（若 5ns 仍差 / 想冲更高频，按性价比×风险排序）

**先看实跑 5ns 报告再取用**；下列只在"还差几百 ps"或"干净但面积超"时按需启用。

### ① 纯 ROM exp，去掉插值乘法（提 fmax，缩 exp 级）— 中风险
现 `exp_w` = LUT + 线性插值（**内含一个小乘法**）。可换 **256-entry Q8.8 纯 ROM**：利用 score 已预移位到
`(score−running_max)≤0`、`exp(x<−8)≈0`，1 拍出结果、无乘法/插值。一手依据：sky130 取向的 FA 加速器
（github `szuwei-yeh/flashattn-accelerator`，`exp_lut.sv`）；SystolicAttention「复用 MAC 做分段线性 exp2，
slope/intercept 从阵列边流入、无独立特殊函数单元」（arXiv 2507.11331，3-0 ✓）。
- 收益：exp 级若是瓶颈，去掉内部乘法显著缩短 → 直接利于 4ns。
- 风险：**改了算术**，须本地重验 MAE/MaxE（现 MAE=0.0001 余量大，大概率仍 ≤0.03）。

### ② 累加器进位保留(CSA)，CPA 延后到末端（提 fmax，缩 A 级）— 中高风险
Parhami《Computer Arithmetic》Ch.8(CSA / Wallace-Dadda 树) + Ch.11.6(流水 tree/array 乘法器)：
36 位累加器保持 sum+carry 冗余形式、loop-carried 只留**单级 CSA**（无横向进位传播），最后再一次完整 CPA（3-0 ✓）。
- 风险：定点**饱和/舍入非结合**，重排部分和需 guard bits / 匹配饱和。

### ③ 折叠 64 路乘法阵列（省面积、吃 cycle）— 仅当面积仍超
SystolicAttention 量化：两个 matmul + softmax 全折进单权重固定阵列，阵列逻辑面积仅 +~12%
（16nm/1.5GHz/128×128，2507.11331 Table4，3-0 ✓）。**⚠ 折叠不是免费的**：相关 claim
「tile 任意小不影响正确性 → 可随意收窄阵列」被 **0-3 反驳**、「d=64 折 4 块不清累加器」被 **1-2 反驳**
→ 折叠须小心处理累加器初始化/校正施加时机。这正是本次**未**做它（保 one-shot 综合成功率）的理由。

### ④ 流水化 Wallace/Dadda 乘法器 — 基本自动
我们已把乘法器的输入/输出都寄存（E\|X\|A），且综合脚本 `retime=true`。Genus 在门级会对
36×17 乘法做树形流水/重定时；这条多为工具自动完成，无需手改 RTL。

## 3. 必须诚实的边界

- **绝对数字不可外推**：8kGE、+12% 面积、16×/256× 等来自 GPU(A100/H100) 与 FP/BF16 16nm，
  非 sky130+Q8.8。真实门数/ns 只有 Genus 实跑能给。
- **被否决的相邻主张**（勿当依据）：单阵列 mux 复用两 matmul 省一半面积(1-2)、折叠不清累加器(1-2)、
  tile 任意收窄不影响正确性(0-3)、两条更强的 retiming 表述(各 1-2)。
- **延后归一化的定点影响**：未归一化的 O 累加值动态范围更大，理论上可能要加宽累加器位宽——
  本设计已是该结构且 36 位累加 + S=256 实测无溢出，但若改标度需复核。

## 4. "能到 4ns 吗" 的工程判断

把失败报告 9.78ns 单拍按子段拆（数值为高效综合下的近似上界，实际流水后会更短）：
`16 路 max→m_tile ~2.5–3ns` · `exp_w(LUT+插值乘) ~3–3.5ns` · `64 路 36×17 乘 ~2–2.5ns` · `36 位加 ~1ns`。

- **5ns**：当前 3 级流水每级都有裕量 → **高置信干净**。
- **4ns（budget ~3.8ns）**：**瓶颈在 exp 级（~3–3.5ns）与 16 路 max 级**，处于边缘。当前 RTL 直接冲 4ns
  有风险（可能差几百 ps）。**可达，但通常需要再拆**：把 `exp_w` 拆成 2 级（LUT/index | 插值乘+加，
  寄存器开销很小）、必要时把 16 路 max 拆 2 级；配合 `retime_effort_level high`。这样 4ns 现实可达，
  甚至 3ns 有机会。或直接上 §2① 纯 ROM exp（exp 变 1 拍 ROM → 4ns 轻松）。
- **代价权衡**：频率是软评分、**面积是硬约束**。冲 4ns 会增加流水寄存器 + 更高驱动 → **面积上升**。
  若 5ns 已逼近 9.59M，4ns 可能威胁面积红线。**正确次序：先拿 5ns 干净 + 面积余量 → 余量够再冲 4ns**。
- **cycle 不是障碍**：多拆几级流水仅 +几千 cycle（远 <300k）。

> 结论：**4ns 不是免费但够得着**，主要是"再拆 exp/max 两级 + 看面积余量"。最稳的是先用实跑 5ns 报告
> 读出每级真实 slack，再据此决定拆哪级、拆几级——而非现在凭估算押 ns。

## 来源（一手 = primary）

- FA1 *FlashAttention* — arXiv 2205.14135（exact 递归、tiling、O(S²)→O(S)）
- FA2 *FlashAttention-2* — arXiv 2307.08691（延后归一化、非-matmul 昂贵、内环只留 max 校正乘）
- FA3 *FlashAttention-3* — arXiv 2407.08608（跨迭代流水缓冲、epilogue 归一化、异步重叠）
- *SystolicAttention (FSA)* — arXiv 2507.11331（整条 attention 融进单阵列、阵列内 softmax、复用 MAC 做 PWL exp2、+12% 面积）
- *VEXP* — arXiv 2504.11227（exp 两级流水 Schraudolph、~8kGE/2.3%）
- *FLAT* — arXiv 2107.06419（融合 attention dataflow、内存 O(N²)→O(N)）
- `szuwei-yeh/flashattn-accelerator`（sky130 取向、256-entry Q8.8 单拍 ROM exp，无插值）
- Parhami *Computer Arithmetic*（Ch.8 CSA/Wallace-Dadda、Ch.11.6 流水乘法器、Ch.25 高吞吐算术）
- Leiserson & Saxe *Retiming Synchronous Circuitry*, Algorithmica 1991（最小寄存器数多项式最优流水）

*调研由多 agent 工作流执行并经对抗式验证；部分检索在本环境退化为模型知识，关键事实以 PDF/RTL 直读为准。*
