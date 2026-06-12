# Project2 FlashAttention IP — Baseline 提交版本

> **本分支 (`codex-baseline-core-pipeline-fmax`) 是 Baseline 的正式提交版本。**
> 单 batch、单 head、`S=256`、`d=64`、Q8.8 定点。功能、仿真、综合证据均已随分支提交，
> 可独立复现，不依赖任何 bonus 分支。
>
> Bonus（加分项）在独立分支 `codex-bonus-integrated-static-scale-fmax` 中单独实现与评测，
> 不影响本 Baseline 的代码与结果。各分支用途见文末「版本与分支说明」。

---

## 1. 这一版是什么 / 提交结论

| 维度 | 结果 | 赛题门限 | 是否达标 |
|---|---|---|---|
| 功能正确性 (FP32 golden) | MAE = **0.000015**，MaxE = **0.003906** | MAE ≤ 0.03，MaxE ≤ 0.10 | ✅ |
| 功能正确性 (RTL 定点镜像) | MAE = 0，MaxE = 0（bit 级一致） | — | ✅ |
| 延迟 (full-size S=256, d=64, causal) | **233,312 cycles** | < 300,000 cycles | ✅ |
| 时序 | 8 ns 时钟 **clean**：slack +1.7 ps，TNS 0，违例 0 条 | 老师要求 10 ns clean | ✅（更严，8 ns） |
| 面积 | Cell Area 7,841,248.5；Total Area 13,587,677.7（详见下，等效门数换算见注） | 等效门数 ≤ 200 万 | ⚠️ 见 §6 注 |
| 功耗 | 2.06683 W | — | 报告齐 |
| 带宽 | RD_BYTES = 589,824；WR_BYTES = 32,768 | 需统计 | ✅ |

证据汇总索引：[`reports/submission_evidence.md`](reports/submission_evidence.md)

---

## 2. Baseline 实际配置（以 RTL 为准）

顶层 `rtl/top/flash_attn_top.sv` 的实际参数默认值：

```text
S_LEN   = 256          D_MODEL = 64           batch = 1, head = 1
BK      = 16           BQ      = 16           # K tile=16 行, Q block=16 行
DATA_W  = 16 (Q8.8)    FRAC_W  = 8            # Q/K/V/O 均为 16-bit signed Q8.8
ACC_W   = 36           # dot-product / 累加器位宽（≥32 满足赛题，见 §6 注）
SOFTMAX_FRAC = 16      # online softmax 内部 Q*.16 精度
USE_DOT_TREE = 1, DOT_LANES = 32             # 点积用加法树缩短关键路径
USE_CAUSAL_SKIP = 1                          # causal 下跳过 j>i 的 tile
STATIC_SCALE_MODE = 1, STATIC_SCALE_Q8_8 = 32 # scale=1/8 静态常数移位，省运行时乘法器
```

> 说明：早期规划稿曾写 `ACC_W=48 / BQ=1`，那是设计前的草案。**当前提交以上表为准**：
> `ACC_W=36`、`BQ=16`。`rtl/include/flash_attn_pkg.sv` 中的 `ACC_W=48` 是包默认值，
> 顶层例化时已显式覆盖为 36，综合/仿真实际生效的是 36。

核心计算流程（FlashAttention-style，不显式存储 S×S 矩阵）：

```text
for each Q block (BQ 行):
    load Q rows
    每行初始化 online-softmax 状态 m, l 与累加器 acc[0:63]
    for each K/V tile (BK 行):
        score = Q·Kᵀ          (dot_product_engine, 加法树)
        score = score * scale (静态移位) 后过 causal mask
        online softmax 更新 m, l，得到 old_scale / new_weight
        acc = acc*old_scale + new_weight*V   (value_accumulator)
    O = acc / l               (normalizer, 倒数 LUT)
    write O 行回外部 memory
```

片上只保存：当前 K/V tile（≈4 KB）+ 每行 m/l/acc + 必要流水寄存器；**全程不构造 S×S 分数矩阵**。

---

## 3. 目录结构（与实际仓库一致）

```text
rtl/
  include/flash_attn_pkg.sv      全局参数包
  top/flash_attn_top.sv          顶层：AXI4-Lite + AXI Master/DMA + flash_core + cycle/byte 计数
  core/
    flash_core.sv                计算核心主控状态机
    tile_scheduler.sv            tile 调度（row / kv_start / kv_len）
    dot_product_engine.sv        Q·Kᵀ 点积（加法树）
    causal_mask_unit.sv          causal mask（j>i → NEG_LARGE）
    online_softmax_engine.sv     online softmax（exp LUT，维护 m/l）
    value_accumulator.sv         acc = acc*old_scale + w*V
    normalizer.sv                O = acc / l（倒数 LUT + 插值）
    quantize_saturate.sv         结果饱和量化回 Q8.8
  axi/
    axi_lite_regs.sv             控制/状态寄存器
    axi_master_read.sv           AXI4 读通道（Q/K/V）
    axi_master_write.sv          AXI4 写通道（O）
    dma_controller.sv            base/stride → AXI 读写请求
  mem/{tile_buffer.sv,row_buffer.sv}

model/                           Python 参考与向量
  model_fp32.py                  FP32 golden（验收基准）
  model_fixed.py / model_rtl_q08.py  定点 / RTL 镜像模型
  gen_vectors.py, gen_lut.py     测试向量 / LUT 生成
  compare_models.py, check_top_e2e_output.py  误差检查（MAE/MaxE）
  config.py                      规模与定点参数

tb/
  cocotb/  test_axi_lite.py, test_flash_core.py, test_end_to_end.py + common/(axi_driver, axi_ram)
  sv/      tb_flash_attn_top_e2e_smoke.sv, tb_axi_lite_regs_ctrl.sv,
           tb_flash_core_*_bitexact.sv（含 backpressure）, tb_dot_product_engine.sv 等
  vectors/ input_q/k/v.hex, golden_o.hex

sim/   run_top_compile.sh, run_top_e2e_smoke.sh（+ .ps1 / Makefile）
synth/ constraints.sdc(8ns), filelist.f, genus_ispatial.tcl, run_genus.sh,
       reports_ispatial/*.rpt（综合后 QoR/area/timing/power/check 报告）
reports/ submission_evidence.md（证据索引）, synthesis_summary.md,
         full-size 仿真 log/hex, waves/*.vcd（波形证据）
docs/  architecture.md, interface_spec.md, core_integration_contract.md, 验证计划等
```

---

## 4. AXI4-Lite 寄存器表（与 `rtl/axi/axi_lite_regs.sv` 一致）

| 地址 | 名称 | 类型 | 说明 |
|---:|---|---|---|
| `0x00` | CTRL | R/W | bit0 START，bit1 SOFT_RESET，bit2 IRQ_EN |
| `0x04` | STATUS | R | bit0 BUSY，bit1 DONE（写 1 清），bit2 ERROR |
| `0x08` | CFG | R/W | bit0 CAUSAL_EN |
| `0x14/0x18` | Q_BASE_L/H | R/W | Q 基地址 低/高 32 |
| `0x1C/0x20` | K_BASE_L/H | R/W | K 基地址 低/高 32 |
| `0x24/0x28` | V_BASE_L/H | R/W | V 基地址 低/高 32 |
| `0x2C/0x30` | O_BASE_L/H | R/W | O 基地址 低/高 32 |
| `0x34` | STRIDE_BYTES | R/W | 行 stride，默认 `D_MODEL*2 = 128` |
| `0x38` | NEG_LARGE | R/W | mask 用 -inf 近似（默认 -32768） |
| `0x3C` | SCALE | R/W | 1/√d 近似（默认 32 = 0.125 Q8.8） |
| `0x40` | CYCLES | R | 本次任务周期数 |
| `0x44/0x48` | RD_BYTES_L/H | R | 本次 AXI 读字节数（带宽统计） |
| `0x4C/0x50` | WR_BYTES_L/H | R | 本次 AXI 写字节数（带宽统计） |

> 0x44–0x50 为带宽统计计数器，超出赛题必需寄存器之外、为评测口径而加。

**性能统计口径**：`CYCLES` 在 `START` 后清零、`BUSY` 期间递增，到 core 计算完成且
DMA 读写全部排空后 `DONE` 置位 —— 即「**从配置寄存器 START 到 DONE 全流程**」，与老师答复一致。

---

## 5. 复现方法

```bash
# 仿真（iverilog/cocotb）
./sim/run_top_compile.sh                 # 编译 smoke
./sim/run_top_e2e_smoke.sh               # 小规模端到端 smoke
RUN_FULL=1 ./sim/run_top_e2e_smoke.sh    # full-size S=256,d=64 端到端

# 综合（Cadence Genus iSpatial）
cd synth && ./run_genus.sh               # 读 filelist.f + constraints.sdc(8ns)，输出 reports_ispatial/
```

---

## 6. 证据与报告

| 类别 | 文件 |
|---|---|
| 证据总索引 | `reports/submission_evidence.md` |
| full-size 仿真 log | `reports/baseline_fullsize_s256_d64.log` |
| FP32 误差检查 log | `reports/baseline_fullsize_s256_d64_check.log` |
| RTL 输出 dump | `reports/baseline_fullsize_s256_d64_o.hex` |
| 波形证据 (VCD) | `reports/waves/baseline_q8_s8_d8_control_dma_softmax.vcd` |
| 综合 QoR / 面积 / 时序 / 功耗 | `synth/reports_ispatial/{10_qor,20_area,30_timing,40_power}.rpt` |
| 综合摘要 | `reports/synthesis_summary.md` |

**综合 (Genus iSpatial, `baseline_6.5`, 8 ns) 关键数据**（源：`synth/reports_ispatial/10_qor.rpt`）：

```text
Clock Period        8.000 ns        Critical Path Slack  +1.7 ps   TNS 0.0   Violating Paths 0
Leaf Instance Count 416,835         (Sequential 94,419 / Combinational 322,416)
Cell Area           7,841,248.502   Net Area 5,746,429.191   Total Area 13,587,677.693
Total Power         2.06683 W
关键路径：u_flash_core 点积加法树 → dot_reg[35]
```

> **§6 注 — 等效门数**：赛题面积门限是「2-input NAND 等效门数 ≤ 200 万」，需用工艺库的 NAND2
> 单元面积去折算 Cell Area（7,841,248.5）。该折算系数取决于评测工艺库，本仓库报告未直接给出
> 等效门数列。提交报告时应在 `reports/synthesis_summary.md` 补一行：
> `等效门数 = Cell Area / NAND2_area`，并注明所用库与单元面积。这是当前唯一待补的口径项。

---

## 7. 版本与分支说明

| 分支 | 角色 | 说明 |
|---|---|---|
| **`codex-baseline-core-pipeline-fmax`** | **Baseline 正式提交** | 本分支。8 ns clean，证据齐全 |
| **`codex-bonus-integrated-static-scale-fmax`** | **Bonus 正式提交** | 9 项加分集成，基于本 Baseline 重建、独立评测 |
| `main` | 历史主线 | 早期 baseline 集成，未含本分支的 fmax 收敛与证据 |
| `codex-baseline-5ns-*-experiment` | 实验（未提交） | 冲刺 5 ns 的尝试，时序未收敛（WNS≈-352 ps），仅供参考 |
| `codex-bonus-{multihead,dropout,padding-mask,axi-stream,...}` | bonus 开发分支 | 单项加分的开发/历史快照，已并入上面的 bonus 提交分支 |
| `feature/core-rtl`, `codex-top-e2e-integration-fixes` | 历史 bring-up | 早期开发分支，已被 main / 提交分支取代 |

> 关键约束：Baseline 与 Bonus 互不影响、各自独立综合与评测。Bonus 分支在默认参数下保留
> 与本 Baseline 一致的 Q8.8 行为与频率目标，加分功能均可通过参数/寄存器单独开启。
