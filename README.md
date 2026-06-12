# Project2 FlashAttention IP — v2 流式/全流水重构（实验候选）

> **本分支 (`codex-baseline-v2-streaming-arch`) 是 baseline 的架构重构实验：FlashAttention-2 式流式、II=1 全流水核。**
> 目标：同时拿下 **少 cycles + 高频 + 小面积**（sweep 已证明调参做不到，必须重构）。
> 功能/精度已用 iverilog 全量仿真验证；**面积/时序需在 Cadence Genus 上确认**（本地无法跑）。
>
> 稳妥提交版仍是 8ns-clean 的 `codex-baseline-core-pipeline-fmax`（233,312 cycles）。本分支跑赢且综合证据齐全后才替换。

---

## 1. 这一版是什么 / 已验证结果

把 baseline 的"每分数 ~7 cycle、串行多周期 FSM、且乘法压在 loop-carried 递归里"的内核，
重构成 **FlashAttention-2 流式数据通路**：
- `dot_stream`：全流水点积，**1 分数/拍**（II=1 前端）。
- `softmax_combine`：tile 内求 max → 每-key MAC 累加（**inner 递归只剩加法，乘法前馈**）→ 跨-tile 合并（`acc*corr` 每 tile 一次，移出内环）。
- 生产者/消费者 **ping-pong 流水**：第 r+1 行打分与第 r 行 combine 重叠。
- 复用 baseline 的 DMA / normalizer / emit / BQ-block K/V 复用。

**随机向量全量仿真**（`RUN_VECTORS=1`, S=256, 供给随机 Q/K/V）对 FP32 golden：

| 版本 | cycles | vs baseline | MAE | MaxE | 随机向量全量 |
|---|---:|---:|---:|---:|---|
| baseline (`core-pipeline-fmax`, 8ns clean) | 233,312 | — | 0.000097 | 0.054688 | PASS |
| v2 非重叠 | 193,528 | −17% | 0.000097 | 0.054688 | PASS |
| **v2 重叠流水 + 乘法器共享（本分支）** | **154,904** | **−34%** | **0.000097** | **0.054688** | **PASS** |

精度与 baseline **完全一致**（复用同一 exp/recip LUT 与定点格式）。小/中规模亦 PASS：S=8→340，S=32→3064（< baseline 3528）。

证据：`reports/v2_evidence.md`（本分支），仿真自检 + `model/compare_hex.py` 对 `tb/vectors/golden_o.hex`。

---

## 2. 为什么这能三赢（设计核心）

baseline 慢且 5ns 难，根因是一条带乘法的 loop-carried 递归：
```
acc_j[d] = acc_{j-1}[d] * old_scale + w_j * V_j[d]      ← 递归里有乘法
```
v2 用 FA-2 把 max 外提到 tile 级，inner 变成：
```
acc_inner[d] += w_j * V_j[d]      ← 递归只剩加法器；w_j*V_j 前馈
acc[d] = acc[d]*corr + acc_inner[d]   ← 乘法仅每 tile 一次（÷BK 频率、可多拍）
```
- **cycles ↓**：点积全流水 1/拍 + 行间重叠 → ~1.8–2.5 cyc/score（baseline ~7）。
- **5ns 更易**：旧 5ns 关键路径正是 inner 的 `acc*old_scale` 乘法；v2 把它移出内环 → 关键路径只剩加法器 + 浅流水级。
- **面积 ≤ baseline**：v2 共 128 乘法器（dot 64 + combine 64 时分复用）< baseline 160（dot 32 + value_accumulator 128）。

详见 `docs/v2_streaming_architecture.md`。

---

## 3. cycle 拆解与进一步空间（诚实）

154,904 ≈ 计算 ~60K（已 II=1 + 重叠）+ **DMA 串行 ~74K（≈48%）** + normalize/emit ~20K。

- 进一步降 cycles 的唯一大杠杆是 **DMA/计算重叠**（tile 双缓冲，预取 t+1）→ 投影 ~95–100K。
  但双缓冲要 +1 份 tile 触发器（≈+30万门），**与"面积好"冲突**。故 154K 是
  **不牺牲面积** 的 cycle/area 甜点；要再快需接受面积上升或减小 BQ/带宽权衡。
- DMA 实际占比依赖评测 AXI 时延模型（本 TB 为 1 beat/cycle 理想读）。

---

## 4. 面积 / 时序（本地证据 + 待 Genus 定数）

本地无 sky130 标准单元 PDK、无网络 → 精确 ns/门数只能在 Genus 出；但已用 **yosys 技术无关综合 A/B** + 结构论证给出方向（详见 `reports/v2_evidence.md`）：

- **面积（乘法器是大头）**：v2 共 **128 个乘法器**（`dot_stream` 64 + `softmax_combine` 共享 64）
  vs baseline **160 个**（dot 32 + `value_accumulator` 128）→ **v2 乘法器更少**。
  baseline 是 163.5万门（81.8%）@8ns clean，故 v2 应**舒适落在 200万 以内**。
  （`softmax_combine` 最初被 yosys 测出含 192 乘法器 → 已用**时分复用**降到 64，+1 cycle/tile。）
- **时序**：baseline 的 5ns 关键路径尾 = inner 递归里的 `acc*old_scale` 乘法；v2 把它移出内环
  （inner 只剩加法器，乘法在每-tile 合并、可多拍）→ **5ns 应比 baseline 更易收敛**。
- v2 与 baseline **共用顶层端口 + SDC + filelist**（已加两模块）→ 可直接综合；Verilator 无 latch/comb-loop。
- **需 Genus 定数**：WNS/TNS/违例、Cell Area→等效门数、功耗。脚本已就绪。

跑法：
```bash
# 仿真
./sim/run_top_compile.sh
RUN_VECTORS=1 ./sim/run_top_e2e_smoke.sh    # 随机向量全量（需 numpy 跑 FP32 checker）
# 或无 numpy：用 model/compare_hex.py 对比 OUT_HEX 与 tb/vectors/golden_o.hex
# 综合
cd synth && ./run_genus.sh                  # 8ns；调 constraints.sdc 至 5ns 冲刺
```

---

## 5. 新增 / 改动文件
```
rtl/core/dot_stream.sv         全流水 II=1 点积前端           (单元测试 tb/sv/tb_dot_stream.sv PASS)
rtl/core/softmax_combine.sv    FA-2 combine 后端              (单元测试 tb/sv/tb_softmax_combine.sv PASS)
rtl/core/flash_core.sv         重写为流式 + 生产者/消费者重叠流水
model/model_fa2_fixed.py       FA-2 定点黄金模型（Stage 0 数值证明）
model/compare_hex.py           无 numpy 的 Q8.8 hex MAE/MaxE 对比
docs/v2_streaming_architecture.md  完整设计 + 实测
synth/filelist.f               += dot_stream, softmax_combine
```
baseline 的 `dot_product_engine`/`online_softmax_engine`/`value_accumulator` 保留在树中但顶层不再例化（Genus 会 prune）。

---

## 6. 分支说明
| 分支 | 角色 |
|---|---|
| `codex-baseline-core-pipeline-fmax` | **稳妥提交 baseline**（8ns clean, 233,312 cycles） |
| `codex-bonus-integrated-static-scale-fmax` | 稳妥提交 bonus |
| **`codex-baseline-v2-streaming-arch`** | 本分支：v2 重构实验，−34% cycles，随机向量全量 PASS，**待 Genus 确认 PPA** |
| `codex-baseline-5ns-acc-pipeline-experiment` | 旧 5ns 时序实验（已被本分支思路取代） |

> 替换 baseline 的条件：Genus 上 **时序 ≤ baseline 且 clean、等效门数 ≤ 200万、cycles < 300k、随机向量全量 PASS** 四者同时满足。
