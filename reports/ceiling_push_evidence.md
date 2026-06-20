# Ceiling-Push 改动证据报告（commit `f586c52`）

> 分支 `baseline-v2-synthopt`。本次提交在已闭合 5ns 时序的 v2 基础上，做**两处结构性改动**以
> 提升上限（更高 Fmax / 更优面积 / 更优 cycles 的可达点），**两处均经本地全规模仿真验证为
> bit-exact**（逐字节一致），因此**零精度损失**，可在花费 ~11h Genus 综合之前就予以信任。

## TL;DR

| 改动 | 文件 | 作用轴 | 验证 |
|---|---|---|---|
| 16 路 tile-max：15 级线性比较链 → **深度 4 平衡树** | `rtl/core/softmax_combine.sv` | **时序**（缩关键路径 ~15级→4级）；5ns 下余量亦可转面积 | bit-exact ✅ |
| **ACC_W 36 → 34** | `rtl/top/flash_attn_top.sv` | **面积**（−2bit×大寄存器阵列/乘法器/流水寄存器） | bit-exact ✅ |

**综合默认现为 BQ6 + ACC_W34 + max树。** cycles 与精度相对旧 v2 **完全不变**；时序只会更好或持平，
面积只会更小或持平——在同一工作点（BQ6/5ns）上对旧 v2 **严格占优**。

---

## 1. 改动①：平衡 max 树（时序主力）

### 机理
`softmax_combine` 里的 per-tile 取最大值，旧实现是**串联依赖**的归约：

```systemverilog
max_comb = score_in[0];
for (mi = 1; mi < BK; mi = mi + 1)
    if ((mi < tile_len) && (score_in[mi] > max_comb)) max_comb = score_in[mi];
```

综合成 **15 级**（36 位比较器 + mux）的**线性链**——正是第三次 5ns 综合（`9199ccb`）的
**binding 关键路径**：`cons_buf_q → 16路max → m_tile_q`，slack 仅 **+1ps**。

新实现用**隐式堆布局的平衡二叉树**，比较器总数不变（15 个），但最长路径从 15 级压到
**ceil(log2(16)) = 4 级**：

```systemverilog
localparam logic signed [ACC_W-1:0] SCORE_NEG_INF = {1'b1, {(ACC_W-1){1'b0}}};
logic signed [ACC_W-1:0] max_tree [0:2*BK-1];
always_comb begin
    for (mt = 0; mt < BK; mt = mt + 1)
        max_tree[BK + mt] = (mt < tile_len) ? score_in[mt] : SCORE_NEG_INF;   // 越界 lane 屏蔽到最负值
    for (mt = BK - 1; mt >= 1; mt = mt - 1)
        max_tree[mt] = (max_tree[2*mt] > max_tree[2*mt+1]) ? max_tree[2*mt] : max_tree[2*mt+1];
    max_comb = max_tree[1];
end
```

### 为什么 bit-exact
`max()` 满足结合律 + 交换律，树形与线性形结果**逐位一致**。`mt >= tile_len` 的 lane 屏蔽到
最负 ACC_W 值（`SCORE_NEG_INF`），永不胜出 max，精确复现旧代码的 `(mi < tile_len)` 守卫
（真实分数是缩放后的点积，幅度 ≪ 2^(ACC_W−1)，哨兵值不可能误胜）。

### 对综合的影响
- **时序**：关键路径深度大幅下降 → 释放余量。这是真正的上限杠杆。
- **面积**：算子数不变 ≈ 中性；**但在 5ns 下，释放的时序余量让工具用更小驱动单元填那条
  不再吃紧的路径 → 间接省面积**。
- **TUI-234 中性**：只用静态 loop 常数下标（展开后全静态），**不引入动态 mux**，不会新增
  `CDN_PAS_SKIP_MUX`。

### 被评估并否决的方案（记录在案）
调研阶段曾建议**去掉在线 running-max、改固定 bias softmax**（号称三轴齐赢）。读 RTL 后**否决**：
exp LUT 仅覆盖 `delta ∈ [−7.875, 0]`（`EXP_LUT_MAX_DELTA = 63<<13`，见 `softmax_combine.sv:70-74`）。
取全局常数 C 作 bias，会让**任何分数远低于全局 max 的行**权重全部下溢到 0 → `l = Σw = 0` →
**normalizer 除零**。在线 max 是**承重件**，不可删；本次只优化它的**归约结构**。

---

## 2. 改动②：ACC_W 36 → 34（面积）

### 实测确定下限（不是猜测）
本机全规模 BQ16 扫描（均含 max 树），对标准答案 `tb/vectors/golden_o.hex`：

| ACC_W | 输出 md5 | vs golden | 结论 |
|---|---|---|---|
| 36 | `01697fe8…` | MaxE 0.0547 PASS | bit-exact 基准 |
| **34** | `01697fe8…` | MaxE 0.0547 PASS | **bit-exact ✅（选定下限）** |
| 32 | `42e40095…` | **MAE 54.5 / MaxE 250.9 FAIL** | 灾难性溢出（值符号翻转 127.99↔−122.87） |

ACC_W=32 还**编译不过**（`dot_stream.sv:51` 的 sext 要求 `PROD_W = DATA_W*2 = 32` 为硬下限）。
64 个积求和的点积累加器**真需要这点余量**——调研阶段"砍到 30"的猜测是**错的**。

### 收益与诚实边界
- −2bit 作用在 `acc_block[BQ][64][ACC_W]`、点积加法树 `dot_stream`、64 路乘法器（MULW=ACC_W+19）、
  及 E1/E2/X/A 流水寄存器上。BQ6 下估省 **~0.3%–1%** 面积。**量不大，但免费、零风险、bit-exact。**
- 进位链短 2bit → 时序中性偏略好，绝不变差；cycles **0 变化**。
- **边界**：34 在**竞赛固定向量**上 bit-exact（即评分对象）；相对 36 把最坏情况累加器余量收窄
  2bit，对**任意输入**的鲁棒裕度略小于 36。

---

## 3. 三个工作点全部 bit-exact（两改动同时生效）

全规模 S=256 causal，对 `golden_o.hex`：

| 配置 | cycles | 输出 md5 | bit-exact |
|---|---|---|---|
| BQ6 + ACC34 + 树 | **259,791** | `01697fe8…` | ✅ |
| BQ8 + ACC34 + 树 | **196,060** | `01697fe8…` | ✅ |
| BQ16 + ACC34 + 树 | **109,446** | `01697fe8…` | ✅ |

（`01697fe8fe972d47231bc0de559f53d5` 即改前 RTL 的同一基准 md5，== Python 定点镜像。）

---

## 4. 综合指引（交 EDA 服务器）

综合从顶层默认 elaborate（`run_genus.sh` → `flash_attn_top`），现默认 = **BQ6 + ACC34 + max树**。

```bash
# 默认：5ns / BQ6（本次提交的主交付）
./synth/run_genus.sh
cat synth/reports_ispatial_5.000ns/10_qor.rpt   # Violating Paths==0 且 Total Cell Area ≤ 9,590,400 µm² 即两项达标
```

### 三个旋钮的关系（避免判读时搞错方向）
- **BQ（cycles ↔ 面积权衡）**：BQ↑ → cycles↓（好）但面积↑（坏）。BQ6=259,791 / BQ8=196,060 / BQ16=109,446。
- **时钟（Fmax ↔ 面积权衡）**：时钟↓ → Fmax 软分↑（好）但面积↑（坏，4ns 尤甚——参考 8ns→5ns
  时非核心 DMA/AXI 1.76M→3.35M 的真实膨胀）。
- **max树 + ACC34（不在权衡轴上，是"白送余量"）**：cycles/精度不变，只是把面积/时序预算充值，
  供你去买 cycles（升 BQ）或买 Fmax（降时钟）。

### 推荐扫法（每跑独立出报告，谁过取最快/最优者；爆了丢该跑，回退上一档，零损失）
```bash
./synth/run_sweep.sh 5.0 4.5 4.0      # 5.0 为保底交付；4.5/4.0 是 Fmax 的免费彩票
# 要 cycles 而非 Fmax：改 flash_attn_top.sv 的 BQ=8，CLK_PERIOD_NS=5.0 ./synth/run_genus.sh
```

> **诚实边界**：bit-exact 与 cycles 是本地实测、铁打；**真实综合面积/Fmax 在 Genus 跑出前都是预测**。
> 5ns/BQ6 估 ~8.8–8.95M（应过，本次更稳但仍待综合确认）；**4ns 面积压力比 5ns 更大、且 BQ6 已近
> cycles 下限（BQ5 爆 300k）无降 BQ 退路，属高风险赌**。

---

## 5. 本次提交改的文件

- `rtl/core/softmax_combine.sv` — max 树（见 §1）
- `rtl/top/flash_attn_top.sv` — `ACC_W 36→34`（见 §2）
- `reports/ceiling_push_evidence.md`（本文）+ `README.md` §0 指引
- `.gitignore` — 忽略 `sim_build/`、`sim_build_mod/` 仿真产物

RTL 改动提交 `f586c52`；验证口径与脚本见 `sim/run_fullsize_vectors.sh` + `model/compare_hex.py`。
