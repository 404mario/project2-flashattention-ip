# 第二次 5ns 综合报告（流水化后）— 对应 `b56628d`（HEAD `1ea3b2b`，RTL 同 `b56628d`）

> **进度里程碑，尚未 clean。** 这是把 `softmax_combine` 从单拍重写成 3 级流水（`b56628d`）之后的
> **第一份**真实 5ns 报告。相比第一次（旧代码 `699bff9`，见 `../reports_ispatial_5.000ns_FAILED_699bff9/`）
> 时序/面积都大幅改善，但**两项硬指标都还差一步**：仍有 638 条违例、面积超 6.3%。
> 引用本目录任何数字前先核对 commit。

## 报告 ↔ 代码 commit 对应

| 项 | 值 |
|---|---|
| **产生本报告的 RTL** | **`b56628d`**（`synth+rtl: pipeline softmax_combine exp→mul→acc`），3 级流水 `MODE_MAC/OLD/NEW` |
| 实际 checkout 的 HEAD | `1ea3b2b`（其后只有 docs / 归档提交，**`b56628d..1ea3b2b` 内 0 个 RTL 文件改动**，RTL 与 `b56628d` 完全相同） |
| `rtl/core/softmax_combine.sv` md5 | `a42e083dabd71de8c53ba29e5ac8a1d5`（流水化版） |
| 综合时间 / 工具 | 2026-06-19 ~00:56，Genus 25.12 iSpatial，**medium** effort，retiming on（high），5.000ns |
| 报告原始出处 | `D:\reports_ispatial_5.000ns (1).tar.gz`（原始 tar 一并存为本目录 `reports_ispatial_5.000ns_b56628d.tar.gz`；解包的 `*.rpt` 用 `git add -f` 入库，因 `.gitignore` 默认忽略 `*.rpt`） |

## 三方对比（同口径，越往右越好）

| 指标 | 第一次 `699bff9`（单拍） | **本次 `b56628d`（3 级流水）** | 赛题要求 | 参照 `8nsclean`(v2work, clean) |
|---|---|---|---|---|
| Worst slack @5ns | −4967.2 ps | **−602.7 ps** | ≥0（软分，越高越好） | +1.7 ps @8ns |
| Violating Paths | 5650 | **638** | **=0** | 0 |
| TNS | −20,204,296 ps | **−118,575 ps**（↓170×） | — | 0 |
| **Total Cell Area** | 11,175,303 µm² | **10,190,460 µm²** | **≤ 9,590,400（200 万门）硬限** | 7,841,248 @8ns |
| 等效门（/4.7952） | ≈ 2,330,519（**超 16.5%**） | **≈ 2,125,138（超 6.3%，+12.5 万门）** | ≤ 2,000,000 | ≈ 1,635,000（81.8%） |
| Leaf / Seq / Comb | 794,593 / 134,935 / 659,658 | **614,137 / 140,736 / 473,401** | — | 416,835 / 94,419 / 322,416 |
| Cycles（S=256 causal） | 109,414 | 109,414 | **< 300k 硬限** | — |
| Total Power | — | 3.975 W | — | — |

> 流水化一举见效：组合单元 −18.6 万、u_combine 面积 −34%（3.27M→2.14M），代价仅 +5.8k 流水触发器。

## 关键路径（`30_timing.rpt` Path 1，slack −602.7 ps）

整条都落在 `u_flash_core/u_combine`（softmax_combine）的 **E 级 = `exp_w` 那一拍**：

```
startpoint  u_combine/m_tile_q_reg[30]/CLK          (running max，S_MAC 期间稳定)
   → (score_cur_in − m_tile_q) 减法
   → exp_w：64 项 LUT 译码 (gt_246_36 比较链)
   → 插值乘法 csa_tree_exp_w_247_25_add_156_60 (Wallace CSA + full-adder 链)
endpoint    u_combine/s1_w_reg[15]/D                (E→X 流水寄存器)
data path = 5584 ps   required = 4786 ps   slack = −603 ps
```

对比第一次 `699bff9` 的关键路径是**完整单拍** `m_tile→exp→64 路 36×17 乘→36 位累加 = 9780 ps`；
流水化已切掉乘法与累加，**现在只剩 `exp_w` 单函数本身就 5584 ps** —— 这一拍需要再劈一刀。

## 为什么面积超标几乎全是「时序虚胖」（硬证据）

比对**不在关键路径上**的 DMA/AXI 子系统（各分支同一份 RTL，apples-to-apples）：

| 非核心区域 = top − u_flash_core − u_axi_lite_regs − u_axi_master_read | 值 |
|---|---|
| 本次失败 5ns（`b56628d`） | **3.35M µm²** |
| 第一次失败 5ns（`699bff9`） | 3.36M µm² |
| **v2work 真实 8ns clean**（slack +1.7ps，0 违例，同套 DMA/AXI） | **1.76M µm²** |

DMA/AXI 明明不在关键路径，却因为全局 638 条违例、Genus 全程「追时序」模式被普涨驱动到 **~2 倍**。
一旦 0 违例，`syn_opt` 面积回收会把它降回 ~1.76M：

```
10.19M − (3.35M − 1.76M) ≈ 8.60M µm² ≈ 179 万门  →  低于 9.59M 限值，余量约 21 万门
```

即便保守假设 5ns-clean 比 8ns-clean 多留驱动、非核心只回落到 2.2M，总面积 ≈9.0M 仍在限内。
**所以「闭合时序」这一件事同时解决软分(频率)与硬限(面积)。**

## 下一步（已在做）：给 `exp_w` 再加一级流水（E-split → E1|E2）

`exp_w` 是纯前馈组合锥（`m_tile_q` 在 MAC 期间稳定），可自由切而不破 II=1、bit-exact：
- **E1**：`score − m_tile` 减法 + `abs` + LUT 索引 + 取 `y0/y1`（两次 64 项 LUT 查表）→ 寄存
- **E2**：插值乘 `y_diff*lut_rem` + 拼成权重 → `s1_w`

cycle 代价 = 每个 tile-merge 多 1 拍 drain ≈ 109,414 → ~111.5k，仍只占 300k 的 37%。
算术逐位不变、端口/`vreq` 协议不变（flash_core/TB 不改）。

## 判读口径（重跑后看 `synth/reports_ispatial_5.000ns/10_qor.rpt`）

**`Violating Paths == 0` 且 `Total Cell Area ≤ 9,590,400 µm²`（=200 万门 × 4.7952）即两项达标。**
若仍少量违例：再给 `m_tile` 的 16 路 max 补一级。若干净但面积 >9.59M：`CLK_PERIOD_NS=6.0` 取既干净又达标的最快周期。
