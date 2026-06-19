# 综合状态：第二次 5ns 已跑（流水化生效），待 E-split 再冲 clean

> 分支 `baseline-v2-synthopt`。进度：(1) 修复 Genus TUI-234；(2) 把 `softmax_combine` 单拍
> `exp→乘→加` 重写成 3 级流水（`b56628d`）；(3) **2026-06-19 跑了第二次 5ns**——时序/面积大幅
> 改善但**两项硬指标仍差一步**；(4) 正在做 `exp_w` E-split（E1|E2）再冲 clean。

## 三方对比（同口径）

| 指标 | 第一次 `699bff9`（单拍，FAILED） | **第二次 `b56628d`（3 级流水）** | 赛题要求 | `8nsclean`(v2work) |
|---|---|---|---|---|
| Worst slack @5ns | −4967 ps | **−602.7 ps** | ≥0（软分） | +1.7 ps @8ns |
| Violating Paths | 5650 | **638** | **=0** | 0 |
| Total Cell Area | 11.18M µm²（233 万门，超 16.5%） | **10.19M µm²（212.5 万门，超 6.3%）** | **≤9.59M（200 万门）** | 7.84M（163.5 万门，81.8%） |
| Cycles | 109,414 | 109,414 | **<300k** | — |
| Total Power | — | 3.975 W | — | — |

报告归档：
- 第二次（本次）：`synth/reports_ispatial_5.000ns_b56628d_PIPELINED/`（含原始 tar + provenance README）
- 第一次（FAILED）：`synth/reports_ispatial_5.000ns_FAILED_699bff9/`
- 详细分析：`docs/synth_5ns_analysis_2026-06-19.md`

## 瓶颈：关键路径整条在 `exp_w` 那一拍（E 级）

`30_timing.rpt` Path 1（slack −602.7 ps，data 5584 ps）：
`m_tile_q_reg[30]` →（`score−m_tile` 减法）→ `exp_w` 64 项 LUT 译码 → 插值乘 `csa_tree_exp_w_247_25` → `s1_w_reg[15]`。
即第一次的单拍 9780ps 链已被切成 E|X|A 三级，**现在只剩 `exp_w` 单函数本身就 5584ps**，需再劈一刀。

## 面积超标 = 时序虚胖（硬证据）

不在关键路径上的 DMA/AXI（各分支同一份 RTL）：失败 5ns 时 **3.35M µm²**，v2work 8ns **clean 时仅 1.76M**。
闭合时序后 `syn_opt` 面积回收：`10.19M − (3.35M−1.76M) ≈ 8.60M ≈ 179 万门`（达标，余 ~21 万门）。
→ **闭合时序同时解决软分(频率)与硬限(面积)。**

## 已实现并本地验证：`exp_w` E-split（4 级流水 E1|E2|X|A）

把关键路径那拍 `exp_w` 再劈一刀（`softmax_combine.sv`，本提交）：
- **E1**：选 delta（MAC/OLD/NEW）+ `m_new=max` + `abs` + LUT 索引 + 读 `y0/y1` → `p1` 寄存；
  **E2**：`exp_finish` 做插值乘 `y_diff*rem` + 拼权重 → `s1_w`。`exp_finish(exp_prep(d)) ≡ exp_w(d)` 逐位。
- 纯前馈锥，算术**逐位不变**、端口/`vreq` 协议不变（**flash_core/TB 不改**）、II=1；仅每个 drain 组多 1 拍。
- 综合 effort **仍 medium**，retiming 保持开。

**本地验证（全绿，2026-06-19）**：
| 测试 | 结果 |
|---|---|
| 单元 TB `tb_softmax_combine` | MAE=0.000672 / MaxE=0.001272（与改前**完全一致**） |
| medium S=32（改前 GOLD vs 改后） | 输出**逐字节相同**（`cmp` IDENTICAL） |
| **全规模 S=256 causal（改前 GOLD vs 改后）** | 输出**逐字节相同**，md5 `01697fe8…`；TB PASS |
| Cycles（S=256） | 109,414 → **109,446**（+32，占 300k 的 36.5%） |

> 复用脚本：`sim/run_fullsize_vectors.sh <label>`（全规模 vs golden + 改前/改后 md5）、
> `sim/run_smoke_mirror.sh`（small+medium，不被 small 的镜像 1-LSB 伪差中断）。
> 注：small/medium 对 Python 定点镜像有 1-LSB 伪差（改前 GOLD 也有，小配置舍入角，非 bug）；
> 全规模 S=256 下 RTL 与镜像 max_abs_int=**0**，vs FP32 golden MaxE=0.0547<0.10、MAE=0.000097<0.03（合规）。

## 预期与判读（下一次 5ns 综合）

- E1≈2.95ns（含 m_new 的 16 路 max 前缀）、E2≈2.6ns，均 < 4.79ns required（~1.8ns 裕量）→ 预期 5ns clean。
- 面积：闭合时序后非核心 DMA/AXI 由 3.35M 回落 ~1.76M → 总 ≈8.6M ≈179 万门（达标，余 ~21 万门）。

## 复现综合 / 判读
```bash
./synth/run_genus.sh          # 默认 5.000ns（effort=medium，retiming on）
cat synth/reports_ispatial_5.000ns/10_qor.rpt   # Violating Paths==0 且 Total Cell Area ≤ 9,590,400 µm² 即两项达标
```
- 若仍少量违例：给 `m_tile_q<=max_comb` 的 16 路 max 补一级流水后重跑。
- 若干净但面积 >9.59M：`CLK_PERIOD_NS=6.0 ./synth/run_genus.sh`，选**既干净又 ≤9.59M 的最快周期**（频率软评分）。
- 真·结构换面积（cycles 还有 63% 可烧）：`dot_stream` `DOT_LANES 32→16`；或 combine 的 64 路乘法时分复用。
- 综合完成后用真实 `reports_ispatial_<period>ns/` 回填本文件与 `docs/synth_5ns_analysis_2026-06-19.md`。
