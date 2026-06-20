# 第三次 5ns 综合报告（E-split 后）— 对应 `9199ccb`（HEAD `d1990c0`，RTL 同 `9199ccb`）

> **里程碑：时序第一次在 5ns 闭合了**（0 违例、worst slack **+1 ps**），但**面积硬限仍超 7.2%**，
> 因此按「两项同时达标」口径**仍未 clean**。这是把 `softmax_combine` 的 `exp_w` 那一拍再劈成
> `E1|E2`（4 级流水，`9199ccb`）之后的**第一份**真实 5ns 报告。引用本目录任何数字前先核对 commit。

## 报告 ↔ 代码 commit 对应（务必先看）

| 项 | 值 |
|---|---|
| **产生本报告的功能 RTL** | **`9199ccb`**（`rtl: split softmax_combine exp stage into E1\|E2 (4-stage pipe)`），exp 链 `E1\|E2\|X\|A` |
| 实际 checkout 的 HEAD | `d1990c0`（仅 docs：CLAUDE.md ×2；**`9199ccb..d1990c0` 在 `rtl/`、`synth/` 下 0 处改动**，被综合 RTL 与 `9199ccb` 完全相同） |
| `rtl/core/softmax_combine.sv` md5 @`9199ccb` | `2da6bcecb4aa167105df385bbbddf5f4`（E1\|E2 4 级流水版） |
| 综合时间 / 工具 | 2026-06-20 03:14:39，Genus 25.12-s067_1 iSpatial，**medium** effort，retiming high，5.000ns，sky130_fd_sc_hs tt_025C_1v80 |
| Runtime / 内存 | CPU 21,373s（≈5.9h），wall-clock **40,881s（≈11.4h）**；Genus peak 15.2GB，Innovus peak 8.1GB |
| 报告原始出处 | `D:\reports_ispatial_5.000ns (2).tar.gz`（原始 tar 一并存为本目录 `reports_ispatial_5.000ns_9199ccb.tar.gz`；解包 `*.rpt` 用 `git add -f` 入库，因 `.gitignore` 忽略 `*.rpt`） |

## 四方对比（同口径，越往右越新）

| 指标 | 一次 `699bff9`(单拍) | 二次 `b56628d`(3级流水) | **三次 `9199ccb`(E-split)** | 赛题要求 | 参照 `8nsclean`(v2work) |
|---|---|---|---|---|---|
| Worst slack @5ns | −4967.2 ps | −602.7 ps | **+1 ps（MET）** | ≥0（软分，越高越好） | +1.7 ps @8ns |
| **Violating Paths** | 5650 | 638 | **0 ✅** | **=0** | 0 |
| TNS | −20,204,296 | −118,575 | **0** | — | 0 |
| **Total Cell Area** | 11,175,303 | 10,190,460 | **10,285,157 µm² ❌** | **≤ 9,590,400 硬限** | 7,841,248 @8ns |
| 等效门（/4.7952） | ≈2,330,519（超16.5%） | ≈2,125,138（超6.3%） | **≈2,144,839（超 7.2%，+14.5万门）** | ≤2,000,000 | ≈1,635,000 |
| Leaf / Seq / Comb | 794,593 / 134,935 / 659,658 | 614,137 / 140,736 / 473,401 | **613,448 / 143,156 / 470,292** | — | 416,835 / 94,419 / 322,416 |
| Cycles（S=256 causal） | 109,414 | 109,414 | **109,446**（E-split +32） | < 300k 硬限 | — |
| Total Power | — | 3.975 W | **3.935 W** | — | — |

> **时序结论**：E-split 一刀见效——把 `exp_w` 劈成 `E1\|E2` 后，关键路径转移到 `m_tile` 的 16 路 max
> 那拍并**刚好压线 MET（+1 ps）**，无需再给 `m_tile` 补流水。从 638 违例直接打到 0。

## 关键路径（`30_timing.rpt` Path 1，MET +1 ps）

```
startpoint  u_flash_core/cons_buf_q_reg/CLK
   → ... → u_combine 内 gt_265_50_*（score 比较 / 16 路 max 求 m_new 的比较链）
endpoint    u_flash_core/u_combine/m_tile_q_reg[31]/D
data path = 5054 ps   required = 4813 ps（5000 − setup124 − uncert62 + launch242 net）   slack = +1 ps
```

这正是二次报告 README 预判的「下一个瓶颈 = `m_tile` 16 路 max 单拍」。本次它 MET，说明 exp 链已不再是关键路径。

## ⚠️ 重要更正：二次报告「面积是时序虚胖、闭合后会回收到 ~8.6M」的预测被本次数据**证伪**

二次 README（`../reports_ispatial_5.000ns_b56628d_PIPELINED/README.md` 第 49–67 行）曾论证：非核心
DMA/AXI 因全局违例被「追时序」普涨到 ~2 倍，一旦 0 违例 `syn_opt` 会把它回收到 ~1.76M，总面积落到 ~8.6M。
**本次 0 违例（+1 ps clean）实测推翻了这一点：**

| 非核心区域 = top − u_flash_core − u_axi_lite_regs − u_axi_master_read | 值 |
|---|---|
| 一次失败 5ns（`699bff9`） | 3.36M µm² |
| 二次失败 5ns（`b56628d`，638 违例） | 3.35M µm² |
| **三次 clean 5ns（`9199ccb`，0 违例 +1ps）** | **3.35M µm²（没有回落！）** |
| v2work 真实 8ns clean（同套 DMA/AXI RTL） | 1.76M µm² |

**结论修正**：那 1.79M→3.35M 的差（+1.59M）**不是可被时序闭合回收的虚胖，而是这套 DMA/AXI 在 5ns 下的真实代价**——
即便它不在关键路径，Genus 仍须让其每条 reg-to-reg 都满足 5ns，于是普遍升驱动/复制寄存器。8ns 时这些路径有 3ns+ 余量
所以用小单元；5ns 时就回不去了。**面积不会自己掉，要么放钟、要么从结构上砍。**

## 面积分解（本次 `20_area.rpt`，Cell-Area）

| 区块 | Cell-Area | 占比 | 说明 |
|---|---|---|---|
| `flash_attn_top` 总 | 10,285,157 | 100% | 超 9.59M 限 7.2% |
| ├ `u_flash_core` | 6,907,057 | 67% | |
| │  ├ `u_combine`(softmax_combine) | 2,147,559 | 21% | exp LUT + 64 路乘法(已时分复用单份) + 64×36b 累加 |
| │  └ flash_core 其余 | 4,759,498 | 46% | `dot_stream`(满 64 路树) + 大寄存器阵列 `acc_block[BQ][64][36b]`/`q_block[BQ][64][16b]` + 控制 + normalizer |
| └ 非核心(DMA + AXI写 + tile_buffer + glue) | 3,348,594 | 33% | 5ns 真实代价，RTL 动不了（见上节）|
| 　（其中 u_axi_lite_regs / u_axi_master_read） | 25,992 / 3,515 | <0.3% | 极小 |

> **要达标需砍 ≥ 0.70M（10.285M − 9.590M）。** 由于 33% 的非核心在 5ns 下 RTL 无法削减，
> 保 5ns 的削减必须全部来自 `flash_core`（6.91M）。

## ❌ 已排除的伪杠杆：`DOT_LANES 32→16`（死参数）

排查确认：`flash_core` 的点积引擎实例化的是 **`dot_stream`**（`flash_core.sv:153`），而 `dot_stream`
**没有 `DOT_LANES` 参数**，永远是满 64 路加法树。真正吃 `DOT_LANES` 的 `dot_product_engine`
（连同 `online_softmax_engine`/`value_accumulator`）在 active 设计里**没有任何实例**，是 `filelist.f`
里的死代码，Genus 读入后丢弃、面积贡献为 0。**故改 `DOT_LANES` 对综合后面积零影响。**

## 下一步：保 5ns，`BQ 16→6`（本机全规模实测后选定）

`BQ`（query block 行数）撑起 flash_core 两个最大寄存器阵列：`acc_block[BQ][64][36b]` + `q_block[BQ][64][16b]`。
`BQ` 越小越省面积，但 K/V tile 重载随 q-block 数（S/BQ）增加 → cycles 越大。**本机全规模 S=256 causal 实测**
（bit-exact md5 全部 == BQ16 基准 `01697fe8`）定出可行域：

| BQ | cycles（causal，准确） | <300k? | 估面积 | 结论 |
|---|---|---|---|---|
| 16（改前） | 109,446 | ✅ | 10.285M | 面积超 7.2% |
| 8 | 196,060 | ✅ +104k | ~9.2M | 可行但面积更贴线 |
| **6（选定）** | **259,791** | ✅ **+40k** | **~8.95M** | **最稳** |
| 5（外推） | ~323k | ❌ 爆 | — | 出局 |
| 4 | ~420k | ❌ 爆 | ~8.7M | 出局（cycles） |

cycles 是准确测量值、非综合变量，唯一由 11h 综合决定的是面积 → 取**满足 cycles<300k 的最小 BQ = 6**，面积最稳。
正确性：query 行注意力独立，`BQ` 只改 K/V 复用度，**不改数学**，全规模 bit-exact 已证。
改动点：`rtl/top/flash_attn_top.sv:12`（synth `elaborate` 用顶层默认）+ 全规模验证脚本 `-P BQ` 同步为 6。
（说明：本 README 随 run-3 归档提交 `f11c318`；`BQ 16→6` 决策于其后定稿，本段为后续更新。）

## 判读口径（重跑后看 `synth/reports_ispatial_5.000ns/10_qor.rpt`）

**`Violating Paths == 0` 且 `Total Cell Area ≤ 9,590,400 µm²`（=200 万门 × 4.7952）即两项达标。**
本次时序已达标、仅面积差一步。若 `BQ=6` 后面积仍 >9.59M：兜底 `CLK_PERIOD_NS=6.0`（6ns 干净几乎必过，仅损频率软分）。
