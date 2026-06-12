# Project2 FlashAttention IP — Bonus 提交版本

> **本分支 (`codex-bonus-integrated-static-scale-fmax`) 是 Bonus（加分项）的正式提交版本。**
> 它在 Baseline (`codex-baseline-core-pipeline-fmax`, commit `9d1d4d8`) 之上**重建**，
> 集成赛题全部 9 个 Bonus 项，并保持默认参数下与 Baseline 完全一致的 Q8.8 行为与频率目标。
>
> **Baseline 仍在 `codex-baseline-core-pipeline-fmax` 分支独立提交与评测，不受本分支影响。**

---

## 1. 这一版是什么

- 默认参数下 = Baseline（Q8.8、S=256、d=64、单 head），结果与 Baseline 分支一致：
  full-size **233,312 cycles**，FP32 **MAE 0.000015 / MaxE 0.003906**。
- 全部 9 个 Bonus 通过参数 / AXI-Lite 寄存器**单独开启**，互不破坏默认路径。
- 综合 (Genus iSpatial, `bonus_6.6`, 8 ns) **clean**：slack **+1.3 ps**，TNS 0，违例 0 条；
  等效门数 **≈ 165.1 万**（占 200 万上限 82.6%）✅。

证据索引：[`reports/submission_evidence.md`](reports/submission_evidence.md)、
完整跑批记录：[`reports/full_evidence_run_2026-06-07.md`](reports/full_evidence_run_2026-06-07.md)、
完成度矩阵：[`reports/bonus_completion_matrix.md`](reports/bonus_completion_matrix.md)。

---

## 2. Bonus 完成度矩阵

| # | 加分项 | 状态 | 开启方式 / 证据 |
|---:|---|---|---|
| 1 | BF16/FP16 | **探索性** | `BF16_IO_MODE`：外部 Q/K/V/O 以 BF16 存储，DMA 边界转换，内部核仍为已验证的 Q8.8。属 I/O 格式探索，非全 FP16 softmax 数据通路 |
| 2 | 多 head | ✅ 已移植 | `HEAD_COUNT` / `HEAD_STRIDE_BYTES`，顺序跑 H=4 / H=8，逐 head RTL 镜像校验 |
| 3 | 更长/可配序列 | ✅ 已移植 | 编译期 `S_LEN`，S=64 / S=128 端到端 smoke 通过 |
| 4 | Padding mask | ✅ 已移植 | AXI-Lite `VALID_LEN`，无效 K/V 置 -inf、无效输出行清零，含 causal corner |
| 5 | 其他定点格式 | ✅ 已移植 | Q6.10 / Q4.12 端到端 smoke + checker |
| 6 | Dropout（训练） | ✅ 已移植 | 确定性 mask + 阈值 + seed + 反向 scale，寄存器可编程，可复现 |
| 7 | 更低精度 INT8/FP8 | ✅ 已移植 | INT8/Q4.4 与 FP8/E4M3，DMA 边界转换；full-size 直跑 VVP 证据 |
| 8 | AXI4-Stream | ✅ 已移植 | `flash_attn_axis_top` 包一层 Q/KV 输入流 + O 输出流，保留原 AXI 顶层 |
| 9 | DMA/任务队列 | ✅ 已移植 | `TASK_COUNT` / `TASK_STRIDE_BYTES`，单次 START 链式跑多块张量 |

> 默认 `STATIC_SCALE_MODE=1`、`ENABLE_DROPOUT=0`、`BF16_IO_MODE=0`、`FP8_E4M3_MODE=0`，
> 即等价 Baseline。各 Bonus 仅在显式开启时生效。

---

## 3. Full-size 结果（S=256, d=64, causal；源 `reports/full_evidence_run_2026-06-07.md`）

| 用例 | 配置 | Cycles | RD_BYTES | WR_BYTES | FP32 MAE | FP32 MaxE | 备注 |
|---|---|---:|---:|---:|---:|---:|---|
| Q8.8 默认 | baseline 路径 | 233,312 | 589,824 | 32,768 | 0.000015 | 0.003906 | 与 Baseline 一致 ✅ |
| Q8.8 随机向量 | RUN_VECTORS=1 | 233,312 | 589,824 | 32,768 | 0.000097 | 0.054688 | ✅（MaxE<0.10） |
| BF16 I/O | BF16_IO_MODE=1 | 233,312 | 589,824 | 32,768 | 0.000015 | 0.003906 | ✅ |
| FP8/E4M3 | FP8_E4M3_MODE=1 | 196,320 | 294,912 | 16,384 | 0.000043 | 0.011719 | ✅ 外部带宽减半 |
| INT8/Q4.4 | DATA_W=8,FRAC_W=4 | 196,320 | 294,912 | 16,384 | 0.005238 | **0.187500** | ⚠️ 有损：MaxE>0.10，定位为带宽/精度权衡，**不替代** Q8.8 |

所有用例对 RTL 定点镜像均 MAE=MaxE=0（bit 级一致）；除 INT8/Q4.4 外均满足赛题 FP32 门限。

---

## 4. 综合（Genus iSpatial, `bonus_6.6`, commit `f6ded9a`；源 `reports/synthesis_summary.md` + `synth/reports_ispatial/10_qor.rpt`）

```text
Clock Period        8.000 ns       Critical Path Slack  +1.3 ps   TNS 0.0   Violating Paths 0
Leaf Instance Count 422,051        (Sequential 94,804 / Combinational 327,247)
Cell Area           7,918,810.862  Net Area 6,315,329.605   Total Area 14,234,140.467
Total Power         2.10594 W
关键路径：u_flash_core/q_proc_index_q → l_update_q（data path 7778 ps，MET）
```

**等效门数（赛题面积口径）**：

```text
等效门数 = Cell Area / area(NAND2_X1) = 7,918,810.862 / 4.7952 ≈ 1,651,404  (≈ 165.1 万)
门限 200 万 → 占用 82.6%  ✅ 达标
```

> 老师要求 10 ns clean，本集成 Bonus 综合在 8 ns 即 clean。
> `synth/constraints.sdc` 默认写 `CLK_PERIOD 10.000`（提交基准），归档报告为 8 ns 跑批结果。
> 折算口径：2-input NAND（`NAND2_X1`，4.7952 µm²）去除标准单元 Cell Area（不含布线）；
> 比 Baseline（163.5 万）多约 1.6 万门，即全部 9 项 Bonus 逻辑的增量。若评测库 NAND2 面积不同，按同式替换分母。

---

## 5. RTL 与脚本（相对 Baseline 的新增）

```text
rtl/include/  bf16_pkg.sv, fp8_e4m3_pkg.sv          BF16 / FP8 格式包
rtl/axi/      dma_controller_bf16.sv, dma_controller_fp8.sv   低精度 DMA 边界转换
rtl/top/      flash_attn_axis_top.sv                AXI4-Stream 顶层（Bonus 8）
rtl/core/     flash_core.sv 等含 dropout / VALID_LEN / 多head / 任务队列 控制扩展

sim/run_bonus_all.sh                 整体快速 Bonus 套件
sim/run_bonus_{bf16,dropout,multi_head,sequence,task_queue,axis_stream}_smoke.sh
sim/run_bonus_lowprecision_int8_smoke.sh
sim/run_bonus_synth_timing_smoke.sh  综合友好 full-size（静态 scale + dropout 旁路）
```

复现：

```bash
./sim/run_top_compile.sh
./sim/run_bonus_all.sh                       # Bonus 快速套件
RUN_FULL=1 ./sim/run_top_e2e_smoke.sh        # 默认 Q8.8 full-size（= baseline 行为）
RUN_FULL=1 ./sim/run_bonus_bf16_smoke.sh     # BF16 I/O full-size
cd synth && ./run_genus.sh                   # 综合（10ns 约束，归档为 8ns 结果）
```

---

## 6. 证据文件

| 类别 | 文件 |
|---|---|
| 证据索引 | `reports/submission_evidence.md` |
| 完整跑批记录 | `reports/full_evidence_run_2026-06-07.md` |
| Bonus 完成度矩阵 | `reports/bonus_completion_matrix.md` |
| 各项 Bonus 仿真结果 | `reports/bonus_results.md` |
| 综合摘要 | `reports/synthesis_summary.md` |
| 综合报告 | `synth/reports_ispatial/{10_qor,20_area,30_timing,40_power}.rpt` |
| 波形 (VCD) | `reports/waves/{wave_q8_s8_d8_control_dma_softmax,wave_bf16_s8_d8,wave_int8_q4_4_s8_d8}.vcd` |
| 波形 / 结果截图 | `reports/*.png` |

---

## 7. 版本与分支说明

| 分支 | 角色 | 说明 |
|---|---|---|
| **`codex-bonus-integrated-static-scale-fmax`** | **Bonus 正式提交** | 本分支。9 项集成，8 ns clean，证据齐全 |
| **`codex-baseline-core-pipeline-fmax`** | **Baseline 正式提交** | 评测基准，独立提交，不受本分支影响 |
| `codex-bonus-integrated-fmax` / `-ppa-skeleton` / `-integrated` | bonus 集成历史 | 早期集成快照，已被本分支取代 |
| `codex-bonus-{multihead,dropout,padding-mask,axi-stream,3-4-5-9-stable}` | bonus 单项开发 | 各 Bonus 的开发/历史分支，已并入本分支 |
| `main` | 历史主线 | 早期 baseline，未含 fmax 收敛与本分支集成 |

> 隔离原则：本 Bonus 分支基于 Baseline 重建，默认参数即 Baseline 行为；所有加分功能均为
> 可选开启，确保 Baseline 评测结果可独立复现、互不影响。
