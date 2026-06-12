# v2 重构架构：streaming / II=1 FlashAttention 核

分支：`codex-baseline-v2-streaming-arch`（基于 233,312-cycle / 8ns-clean 的 `codex-baseline-core-pipeline-fmax`）

目标：**同时**拿下高频(5ns) + 小面积 + 少cycles —— sweep 已证明调参做不到（互相打架），只能靠结构重构。

---

## 1. 现状瓶颈（sweep 实测 + RTL 分析的硬结论）

每个分数(score)平均 ~7 cycles（233,312 / 32,896 causal 分数对）。FSM 串行走：
`ST_PREP_KEY → ST_DOT_START → ST_DOT_WAIT(×2 chunk) → ST_SCORE_UPDATE → ST_ADVANCE_SCORE`。

实测因果（sweep）：
- 点积分块直接压在关键路径上：DOT_LANES 32→16 → +65,792 cycles（+2/分数）。**计算受限,不是内存受限。**
- BQ↑ 改善 cycles+带宽但 area↑↑(BQ32 ≈ +25万门)；BQ↓ 直接爆(调度 bug)。
- 没有任何单旋钮能同时降 area 和 cycles。

**根因 = 一条带乘法的 loop-carried 递归。** 对固定 query 行 i、逐个 key j：

```
s_j      = <Q_i, K_j> * scale            (再过 causal mask)
m_j      = max(m_{j-1}, s_j)
old_scale= (m 上升) ? exp(m_{j-1}-m_j) : 1
w_j      = exp(s_j - m_j)
l_j      = l_{j-1}*old_scale + w_j
acc_j[d] = acc_{j-1}[d]*old_scale + w_j*V_j[d]     ← 递归里有乘法！64 lane
```

`acc_j` 依赖 `acc_{j-1}` 且中间夹一个乘法(`acc*old_scale`)。这一条**同时**导致：
1. **cycles 多**：每分数都要等这条乘加链算完才能下一个 → 没法 II=1。
2. **5ns 过不了**：`old_scale_update → acc 乘加 → acc_work` 正是之前 5ns 实验的 -0.9ps 关键路径尾。

> 关键洞察：**把这个乘法移出 inner 递归,三个目标一起解。**

---

## 2. 重构思路：FlashAttention-2 式"tile 内最大值外提" + 流水

`s_j` 之间互相独立（只依赖 Q_i,K_j,不依赖状态）→ **点积可以完全流水,1 分数/拍。** 唯一的真递归是 softmax/acc 更新。把"求 max"从 inner loop 外提到 tile 粒度,inner 的 acc 递归就只剩**加法**（乘法变前馈）：

对每个 K/V tile（BK=16 个 key）分两小阶段，阶段内都 II=1：

**阶段 A — score（流水点积,1/拍）**
```
for j in tile:  s_j = mask(<Q_i,K_j>*scale);  存入 score buffer[ j ] (BK=16 项);  m_tile = max(m_tile, s_j)
```
点积树做成**全流水**（log2(64)=6 级寄存,1 结果/拍）。tile 内 16 个 key → ~16 拍。

**阶段 B — combine（MAC 累加,1/拍,递归里只有加法）**
```
for j in tile:  w_j = exp(s_j - m_tile);  l_part += w_j;  acc_inner[d] += w_j * V_j[d]   (64 并行 MAC)
```
`acc_inner[d] += w_j*V_j[d]`：`w_j*V_j[d]` 是**前馈乘法**,loop-carried 只有那个**加法器** → 关键路径短 → II=1 且 5ns 友好。

**阶段 C — tile 合并（每 tile 一次,不在 inner 路径上）**
```
m_new   = max(m_prev, m_tile)
corr    = exp(m_prev - m_new)             // 旧 acc 的修正系数
acc[d]  = acc[d]*corr + acc_inner[d]      // 64 lane,但 BK=16 倍稀疏发生
l       = l*corr + l_part
m       = m_new ;  acc_inner[d]=0 ; l_part=0
```
带乘法的 `acc*corr` 仍在,但**每 tile 才发生一次**（频率 ÷16）,不在 1/拍 inner 路径上 → 对 cycles 和 Fmax 都无伤。

阶段 A 和 阶段 B 还可**跨 tile 重叠**（combine 第 t 个 tile 时,score 第 t+1 个）。

---

## 3. cycle 模型（投影）

- inner 两阶段各 ~BK 拍,合并 ~常数。每 tile ≈ `2*BK + overhead` ≈ 35 拍（不重叠）/ ≈ 16-20 拍（重叠）。
- causal 下 tile 总数 ≈ S²/(2·BK) = 256²/(32) = 2048 个 tile。
- 计算：2048 × (16~35) ≈ **33K ~ 72K cycles** + 每行 normalize/emit（256 行 × ~70）≈ 18K。
- **总计 ≈ 50K ~ 90K cycles，对比现状 233K → 约 2.6×~4.6× 改善。** 余量充足，可再优化。

| 版本 | cycles | 周期 | 延迟(ns) |
|---|---:|---:|---:|
| 现状 baseline | 233,312 | 8ns | 1.87ms |
| v2 (保守) | ~90,000 | 8ns | 0.72ms |
| v2 + 5ns | ~90,000 | 5ns | **0.45ms** (≈ 4× vs 现状) |
| v2 激进重叠 + 5ns | ~55,000 | 5ns | **0.28ms** (≈ 6.7×) |

---

## 4. 面积与频率影响

**面积（方向,需综合确认）：大致持平,可能略降。**
- 全流水点积树：64 个乘法器(DOT_LANES=64) + 6 级流水寄存。比现状 32 多 32 个乘法器,但省掉 chunk 累加 FSM。
- value 累加：inner 只需 64 个 `w*V` 乘法器；`acc*corr` 的 64 乘法器**每 tile 用一次**,可时分复用 inner 的乘法器阵列（合并阶段借用）→ 乘法器总数 ≈ 现状的 128 或更少。
- 新增：score buffer（16×ACC_W,小）、acc_inner（64×ACC_W 一行,小）。
- 净面积预期：±少量,关键看综合。**不会像 BQ↑ 那样 +25万门。**

**频率（5ns）：明显更易收敛。**
- 旧 5ns 关键路径 = inner 递归里的 `acc*old_scale`。v2 把它移出 inner（只在阶段 C,÷16 频率,且可多拍）。
- inner 递归只剩加法器 → 关键路径短。
- 点积树全流水 → 每级路径短。
- → v2 收 5ns 的难度远低于现在硬抠 tail。

---

## 5. 数值等价性与精度风险

- FA-1（running max）与 FA-2（tile max 后合并）**对 softmax 都是数学精确的**,只是中间表示不同。
- 定点下,两者舍入路径不同 → MaxE/MAE 会有细微差异,**必须重验**（目标仍 MAE≤0.03 / MaxE≤0.10）。
- 复用现有 `exp` LUT、`normalizer`（已是干净 3 级流水）、`scale` 常数 → 近似源不变,风险可控。
- 风险点：`m_tile` 外提后 `s_j - m_tile` 的动态范围;`acc_inner` 在 tile 内不 rescale → 需确认 ACC_W=36 不溢出（BK=16 个 `w*V` 累加,w≤1 Q0.8,V Q8.8,16 项 → 余量足）。

---

## 6. 分阶段实现 + 验证计划（绝不 big-bang）

每阶段都用现有 SV 自检 testbench（`tb_flash_attn_top_e2e_smoke.sv`,iverilog,不需 numpy）验功能 + 量 cycles；保底版 `codex-baseline-core-pipeline-fmax` 永不动。

1. **Stage 0 — 黄金参考（Python/行为模型）**：先写 FA-2 定点参考模型,确认 MAE/MaxE 达标,作为 RTL 的预言。
2. **Stage 1 — 全流水点积前端**：把 `dot_product_engine` 改成 II=1 流水树（或新模块 `dot_stream`）。单元 TB 验 1 结果/拍 + 数值对齐。
3. **Stage 2 — combine 引擎**：新 `softmax_combine`（阶段 B+C）：score buffer + max + exp + 64 MAC + tile 合并。单元 TB。
4. **Stage 3 — 新 FSM 集成**：重写 `flash_core` 控制为 tile 流水（A→B→C,跨 tile 重叠）。跑 small/medium/fullsize smoke,量 cycles。
5. **Stage 4 — 收敛**：精度多 seed 验证;综合跑 8ns→5ns,看 WNS/面积/cycles 三个数。
6. **Stage 5 — 决策**：三赢则升为新提交候选;否则回保底。

**回滚保证**：v2 全程独立分支;任何阶段卡住,提交版仍是 8ns baseline。

---

## 6b. Stage 3 详细集成规格（flash_core_v2 FSM）

Stage 0/1/2 已验证（黄金模型 + `dot_stream` + `softmax_combine`）。Stage 3 = 把它们装进
新的 `flash_core` 控制，保留 baseline 的 DMA/AXI/tile-buffer/normalizer/emit（复用,不重写）。

**保留 BQ-block 复用**（否则带宽爆,见 sweep 的 BQ4/BQ8）：一个 Q-block 装 BQ 行,每个 K/V tile
载入一次、被 block 内所有（causal 允许的）行消费,再换下一个 tile。

每行状态：`m_block[BQ]`、`l_block[BQ]`、`acc_block[BQ][D]`（仍是触发器,SRAM 不划算见 sram doc）。

**FSM 状态（每个 Q-block）：**
```
ST_LOAD_Q      : DMA 载入 BQ 行 Q 到 q_block[BQ][D]
ST_REQ_KV      : 请求当前 tile 的 K/V (kv_start)
ST_WAIT_KV     : 等 tile 数据进 k_tile/v_tile buffer
  (对 block 内每个 causal 有效行 r:)
  ST_SCORE     : 把 tile 的 BK 个 key 经 dot_stream 流式打分(1/拍),
                 scale+mask 后写入 score_buf[0..BK-1]; 跳过 j>i 的 key(causal)
  ST_SCORE_DRAIN: 等 dot_stream 流水排空(LATENCY=7)后 score_buf 齐
  ST_COMBINE   : 脉冲 softmax_combine(score_buf, v_tile, m/l/acc[r], row_first=该行首个tile)
  ST_COMBINE_WAIT: 等 done; 写回 m/l/acc[r]
  (行循环结束 → 下一 tile; tile 循环结束 → normalize)
ST_NORMALIZE   : 对每行 acc[r][d]/l[r] 过 normalizer(复用,3级流水), D 拍/行
ST_EMIT        : DMA 写回 O 行
ST_NEXT_BLOCK  : 推进到下一 Q-block
```

**关键连线：**
- `dot_stream`: q_vec=q_block[r], k_vec=k_tile[j], in_valid 在 ST_SCORE 每拍(非跳过 key)拉高;
  out_valid 后 LATENCY 拍把 dot 经 scale+causal_mask → score_buf[j]。
- `softmax_combine`: score_in=score_buf, v_tile=v_tile, m/l/acc_in=该行状态, row_first=该行是否首 tile;
  done 后 m/l/acc_out 写回 m_block/l_block/acc_block[r]。
- `normalizer`: 复用,acc/l 逐元素喂入。

**cycle 模型（每 (row,tile) 对）：** ST_SCORE(~有效key数) + DRAIN(7) + COMBINE(~tile_len) + 握手(~3)
≈ 2·BK + 12 ≈ 44 拍（BK=16,无重叠,保守）。causal (row,tile) 对 ≈ 2048 →
≈ 90K + normalize/emit(256行×~75) ≈ **~110K cycles 保守**。重叠 score/combine 后可压到 ~60-70K。

**优化（后续）：** 跨 (row,tile) 重叠 score-pass 与 combine（双 score_buf）；tile 内 score 与
combine 流水重叠。先做无重叠版跑通,再加重叠。

**验证顺序（迭代快）：** 先 small smoke(S=8,秒级)抓功能 bug → medium(S=32) → 一次 fullsize(S=256)
量 cycles + 确认 MAE/MaxE。全程对比 baseline 自检 testbench。

**风险：** dot_stream 流水 fill/drain 与 score_buf 时序;causal 跳过 key 时的 valid/索引;
ACC_W=36 在 tile 内 BK=16 累加的溢出（§5,BK=16 恰好够,若调大 BK 需加宽或 tile 内分段）。

## 6c. 实测结果（已实现 + 验证，iverilog）

所有 Stage 完成并验证。随机向量全量仿真（RUN_VECTORS=1, S=256, 供给的随机 Q/K/V）对 FP32 golden：

| 版本 | cycles | vs baseline | MAE | MaxE | 随机向量全量 |
|---|---:|---:|---:|---:|---|
| baseline (`core-pipeline-fmax`) | 233,312 | — | 0.000097 | 0.054688 | PASS |
| v2 非重叠（Stage 3 首版） | 193,528 | −17% | 0.000097 | 0.054688 | PASS |
| **v2 重叠流水（当前）** | **154,784** | **−34%** | **0.000097** | **0.054688** | **PASS** |

精度与 baseline 完全一致（同一 exp/recip LUT）。小/中规模也 PASS：S=8 → 340，S=32 → 3064（< baseline 3528）。

**cycle 拆解（154,784）：** 计算 ~81K（流水后 ~1.85 cyc/score，已 II=1 + 行间重叠）+ DMA 串行 ~74K（≈48%，K/V 每 Q-block 重取）+ normalize/emit ~20K（部分重叠）。

**下一杠杆（已规划，未实现）：DMA/计算重叠**（核内 2-deep tile 双缓冲，预取 tile t+1 于计算 tile t）→ 把 ~74K DMA 藏到计算后 → 预期 **~88K cycles（≈2.65× vs baseline）**。代价：+~8KB tile 缓冲触发器（≈+8万门，仍在 200万 预算内）。注：实际收益依赖评测 AXI 时延模型；本 TB 为 1 beat/cycle 理想读。

**面积/时序（需 Genus 确认，本地无法跑 Cadence）：**
- v2 与 baseline 共用顶层端口 + SDC + filelist（已加 `dot_stream`/`softmax_combine`），可直接综合。
- Verilator lint：仅与 baseline 同源的良性 WIDTH 警告，无 latch/comb-loop（新模块干净）。
- **时序预期更优**：旧 5ns 关键路径是 inner 递归里的 `acc*old_scale` 乘法；v2 把它移到每-tile 合并（÷BK 频率、可多拍），inner 递归只剩加法器 + 点积树全流水 → 关键路径更短，5ns 更易收敛。
- **面积预期大致持平**：点积 64 lane（vs 32，+乘法器）但省 chunk FSM；combine 复用 inner 乘法器阵列。最终以 Genus `10_qor.rpt` 为准。

## 7. 开放问题
- BK 是否调大（如 32）以减少 tile 数 / 合并次数？需平衡 score buffer 与 tile buffer 面积。
- 阶段 A/B 重叠的具体流水深度（II=1 是否需要 V tile 双缓冲）。
- `acc*corr` 乘法器是否与 inner `w*V` 阵列时分复用（省面积 vs 控制复杂度）。
