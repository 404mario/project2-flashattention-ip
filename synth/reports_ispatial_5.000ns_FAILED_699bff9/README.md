# ⚠️ 第一次 5ns 综合报告（失败）— 对应旧代码 `699bff9`，与当前版本不符，需核对

> **这份报告不是当前代码产生的。** 它对应**流水化之前**的 RTL。引用本目录任何数字前，
> 务必先核对 commit；当前分支代码已变更，必须**重新综合**才能得到与现版本匹配的 PPA。

## 报告 ↔ 代码 commit 对应

| 项 | 值 |
|---|---|
| **产生本报告的 commit** | **`699bff9`**（`docs: add official gate-equivalent area formula`） |
| 该 commit 的 `rtl/core/softmax_combine.sv` md5 | `cf83d273cfc4c72e8125eba42dd6b82b`（**单拍** `S_MOLD/S_MNEW` 版本） |
| 综合时间 / 工具 | 2026-06-18 ~04:15，Genus 25.12 iSpatial，**high** effort，retiming on，5.000ns |
| 报告原始出处 | `D:\reports_ispatial_5.000ns.tar.gz`（本目录是其解包归档，*.rpt 用 `git add -f` 强制入库，因 `.gitignore` 默认忽略 `*.rpt`） |

## ⚠️ 与当前代码不符 — 必须核对

| | 本报告（失败） | 当前分支 HEAD |
|---|---|---|
| commit | `699bff9`（父提交） | `b56628d` 及之后（修复提交） |
| `softmax_combine.sv` md5 | `cf83d273…` 单拍 `exp→乘→加` | `a42e083d…` **3 级流水** `MODE_MAC/OLD/NEW` |
| 关键路径 | **单拍 9.78ns** `exp_w插值乘 → 64路36×17乘 → 36位加`（`u_combine`） | 已拆 E\|X\|A 三级，每级 <5ns（待综合确认） |
| 综合状态 | 见下（**失败**） | **尚未综合** |

→ 本目录数字**仅描述 `699bff9` 旧版**。`b56628d` 起的代码已把那条单拍链流水化，
**预期不再复现这些数字**；要拿当前版本的真实 PPA，必须重跑 `./synth/run_genus.sh`
（现 effort=medium），结果会写到 `synth/reports_ispatial_5.000ns/`（注意目录名不同）。

## 本报告的失败结论（仅对应 `699bff9`）

- **时序**：`clk` 周期 5000ps，WNS **slack = −4967.2 ps**（worst data path 9780ps），
  TNS −20,204,296 ps，**Violating Paths = 5650**。→ 严重违例（约需 ~10ns 才干净）。
- **面积**：Total Cell Area **11,175,303 µm²** → 等效门 = 11,175,303 / 4.7952 ≈ **2,330,519 门**，
  **超 200 万门硬约束 16.5%**。（Leaf 794,593；Sequential 134,935。）
- **关键路径**（`30_timing.rpt` Path 1）：
  `u_combine/m_tile_q_reg[5]` → … → `u_combine/acc_state_q_reg[2][34]/D`，即
  `exp_w 插值乘法 → mul_246_33（64 路 36×17） → add_308_58（36 位累加）` 单拍串联。
- **面积分布**（`20_area.rpt`）：`u_combine`(softmax_combine) 3.27M / `u_flash_core` 7.82M / 顶层 11.18M。
  非核心区(DMA/AXI/buffer) = 11.18M−7.82M ≈ 3.36M，对比 `8nsclean-baseline` 干净时的 ~1.79M，
  **+1.57M ≈ 整个超标量 = 时序不收敛导致的升驱动/克隆虚胖**（非真实门数）。

## 根因与修复（已在 `b56628d`）

根因 = 上面那条 `exp→乘→加` **单拍组合链**（S_MAC 内环 + S_MOLD/S_MNEW 合并同形）。
修复 = 把 `softmax_combine` 重写成 **3 级流水 E\|X\|A**（exp \| 64 路乘法 \| 累加），
MAC 与合并共用同一条流水+共用乘法器，**算术逐位不变**、II=1、仅 +drain 周期；
综合脚本 effort high→medium。本地 iverilog 全规模 S=256 输出**逐字节相同**、cycles 109410→109414。
详见仓库根的 `synth/SYNTHESIS_STATUS.md` 与提交 `b56628d`。

## 下一份报告（当前版本）判读口径

重跑后看 `synth/reports_ispatial_5.000ns/10_qor.rpt`：
**`Violating Paths == 0` 且 `Total Cell Area ≤ 9,590,400 µm²`（=200 万门 × 4.7952）即两项达标。**
