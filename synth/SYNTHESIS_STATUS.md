# ✅ 综合状态：第四次 5ns 两项硬约束全过 —— 5ns 基线已冻结（提交版）

> **2026-06-21 第四次 5ns 综合（`f185b97` = BQ6 + ACC_W34 + max树）两项全过，作为提交基线冻结。**
> 报告归档：`synth/reports_ispatial_5.000ns_f185b97_FROZEN/`（8 份真实 .rpt）。
>
> | 指标 | 实测 | 要求 | 判定 |
> |---|---|---|---|
> | Total Cell Area | **7,870,282 µm² = 1,641,283 门当量（82.1%）** | ≤9.59M µm²（200万门） | ✅ 余 17.9% |
> | Violating Paths | **0**（最差 slack **+5ps MET**） | =0 | ✅ |
> | Cycles（causal） | **259,791** | <300k | ✅ |
>
> 关键路径已离开 softmax，转到 DMA 的 KV 预取影子缓冲 `m_axi_rvalid → v_buf2_reg`（证实 max树把瓶颈挪走了）。
> **冻结理由**：flop 域可抠的面积都是 <0.05% 小钱；SRAM 实测对本设计是负优化（大 2.6×，见 `docs/synth_4ns_research_2026-06-21.md` §5）；
> 面积大头是 DMA/AXI 时序驱动的真实驱动膨胀，RTL 拿不回。故 82.1% 即 v2 面积实际下限区。
> **4ns 冲刺**：结构性方案已调研 + 本地 bit-exact 验证（`docs/synth_4ns_research_2026-06-21.md`），作为**免费上行赌注**——
> 不动已冻结的 5ns RTL；4ns 真实时序/面积需 Genus 跑出才算数。

---

# （历史）第三次 5ns 时序已闭合，面积差一步；已切 BQ=6 待第四次综合

> 分支 `baseline-v2-synthopt`。进度：(1) 修 Genus TUI-234；(2) `softmax_combine` 流水化 3 级（`b56628d`）；
> (3) `exp_w` E-split 4 级（`9199ccb`）；(4) **2026-06-20 第三次 5ns：时序第一次闭合（0 违例 +1ps），
> 但面积仍超 7.2%**；(5) **已切 `BQ 16→6`（本提交）砍 flash_core 寄存器阵列，本地已验 bit-exact + cycles<300k，待第四次综合**。

## 四方对比（同口径）

| 指标 | 一次 `699bff9`(单拍) | 二次 `b56628d`(3级) | **三次 `9199ccb`(E-split)** | 赛题要求 | `8nsclean`(v2work) |
|---|---|---|---|---|---|
| Worst slack @5ns | −4967 ps | −602.7 ps | **+1 ps（MET）** | ≥0（软分） | +1.7 ps @8ns |
| Violating Paths | 5650 | 638 | **0 ✅** | **=0** | 0 |
| Total Cell Area | 11.18M（超16.5%） | 10.19M（超6.3%） | **10.285M（≈214.5万门，超 7.2%）❌** | **≤9.59M（200万门）** | 7.84M（81.8%） |
| Cycles（causal） | 109,414 | 109,414 | **109,446** | **<300k** | — |
| Total Power | — | 3.975 W | **3.935 W** | — | — |

报告归档：
- **第三次（最新）**：`synth/reports_ispatial_5.000ns_9199ccb_ESPLIT/`（原始 tar + 8 .rpt + README）；分析 `docs/synth_5ns_analysis_2026-06-20.md`
- 第二次：`synth/reports_ispatial_5.000ns_b56628d_PIPELINED/`；第一次 FAILED：`synth/reports_ispatial_5.000ns_FAILED_699bff9/`

## 时序已收敛（E-split 生效）

关键路径从 `exp_w`（5584ps）转移到 `u_combine/m_tile_q` 的 16 路 max 比较链，**MET +1ps**，无需再补流水。
**时序这条线到此为止**——剩下纯粹是面积问题。

## ⚠️ 两点关键更正（被第三次实测推翻/排除）

1. **「面积超标=时序虚胖、闭合后回收到 ~8.6M」被证伪。** 第三次 0 违例（+1ps clean）下，非核心
   DMA/AXI 仍 **3.35M**（未回落到 8ns 时的 1.76M），总面积不降反微升 10.19M→10.285M。
   那 1.59M 是**这套 DMA/AXI 在 5ns 下的真实代价**（每条 reg-to-reg 都得满足 5ns→普遍升驱动），
   **与违例数无关，不会随时序闭合自愈**。要拿回只能放钟或从结构减寄存器。
2. **`DOT_LANES 32→16` 是死参数。** flash_core 实际点积引擎是 `dot_stream`（`flash_core.sv:153`，无
   `DOT_LANES`，恒满 64 路树）；吃 `DOT_LANES` 的 `dot_product_engine`（及 `online_softmax_engine`/
   `value_accumulator`）**全树无实例**，是 `filelist.f` 死代码，综合面积贡献 0。改它对面积零影响，已排除。

## 面积分解（第三次 `20_area.rpt`，Cell-Area）

| 区块 | Cell-Area | 占比 | 可削减性（保 5ns） |
|---|---|---|---|
| `u_combine`(softmax_combine) | 2.15M | 21% | 低（64 路乘法已单份时分复用 + 在关键路径上） |
| flash_core 其余（`dot_stream`+大寄存器阵列+控制+norm） | 4.76M | 46% | **中：`BQ` 撑起的 `acc_block`/`q_block` 是最大可削项** |
| 非核心（DMA+AXI写+glue） | 3.35M | 33% | 零（5ns 下 RTL 动不了） |

## 已实施并本地验证：`BQ 16→6`（本提交）

`BQ`（query block 行数）撑起 flash_core 两个最大寄存器阵列 `acc_block[BQ][64][36b]`、`q_block[BQ][64][16b]`。
`BQ 16→6` 砍掉约 3.4 万触发器 + 相关 BQ:1 读写 mux，**估省 ~1.3M → 面积约 8.95M（余 ~0.64M）**。
改动点：`rtl/top/flash_attn_top.sv:12`（synth `elaborate` 用顶层默认，tcl 不覆盖参数）+ 全规模验证脚本 `-P BQ` 同步。

**为什么是 6**（本机全规模 S=256 causal 实测，bit-exact md5 全部 == BQ16 基准 `01697fe8`）：

| BQ | cycles（causal，准确） | <300k? | bit-exact | 估面积 |
|---|---|---|---|---|
| 16（改前） | 109,446 | ✅ | 基准 | 10.285M ❌ |
| 8 | 196,060 | ✅ +104k | ✅ | ~9.2M |
| **6（选定）** | **259,791** | ✅ **+40k（13%）** | ✅ | **~8.95M（最稳）** |
| 5（外推） | ~323k | ❌ 爆 | — | — |
| 4 | ~420k | ❌ 爆 | — | ~8.7M |

> `BQ=6` 是**满足 cycles<300k 的最小 BQ**；cycles 是准确测量值（非综合变量），唯一由综合决定的是面积，
> 故最小可行 BQ = 面积最稳的单次赌注。正确性：每个 query 行注意力独立，`BQ` 只改 K/V tile 复用度，**不改数学**。
> 评分 cycles 口径 = **causal** S=256/d=64（需求文档 §延迟，line 72）；非 causal 无 cycles 预算，故 causal 数即准。

## 复现综合 / 判读（第四次 5ns）
```bash
./synth/run_genus.sh          # 默认 5.000ns（effort=medium，retiming on），用 BQ=6 顶层默认
cat synth/reports_ispatial_5.000ns/10_qor.rpt   # Violating Paths==0 且 Total Cell Area ≤ 9,590,400 µm² 即两项达标
```
- **预期**：时序仍 clean（`u_combine` 关键路径与 BQ 无关，寄存器更少→拥塞更低）；面积 ~8.95M ≤ 9.59M。
- **若面积仍 >9.59M**（估偏乐观）：退 `BQ=8` 已无用（面积更大），直接 `CLK_PERIOD_NS=6.0`（非核心 1.59M 虚胖回落，几乎必过，仅损频率软分）。
- **若意外回到违例**：基本不会（BQ 不碰关键路径）；真出现则查 `acc_block` 读写 mux 是否成新瓶颈。
- 综合完成后用真实 `reports_ispatial_5.000ns/` 回填本文件 + `docs/synth_5ns_analysis_2026-06-20.md`，并归档报告（带 commit 对应）。
