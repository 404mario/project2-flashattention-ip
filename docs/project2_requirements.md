# Project 2 官方要求（FlashAttention 高性能硬件加速器 IP）

> 本文档摘自课程《Project 2 补充说明》PDF（FlashAttention 赛题部分），作为本仓库
> 评分口径的权威参照。提交、综合、报告均以此为准。
> 通用评分：**总分 60 分**，基本要求 **75%** + 附加要求 **25%**。提交截止
> **6 月 14 日 23:59**，逾期补交扣分。

---

## 一、基本要求（75%）

1. **算法定义**：实现 SDPA / FlashAttention-style attention。对每个 query 位置 `i`，
   完成 `O = softmax((Q_i Kᵀ)/sqrt(d) + M) V` 的等价或近似等价计算。
2. **FlashAttention-style 计算约束**（强制）：
   - 必须体现 FlashAttention 关键思想，**禁止显式存储完整注意力矩阵**；
   - 必须使用 **online softmax**；
   - 必须采用 **tiling** 方式处理 K/V。
3. **固定输入规模**：Baseline 固定为单 batch、单 head，`S=256`、`d=64`，
   Q/K/V/O 形状均为 `[256, 64]`。
4. **数据格式**：
   - 输入 Q/K/V：**Q8.8**（16-bit 有符号定点）；
   - Dot-product 累加：至少 **32-bit**，建议 **40-bit 以上**降低溢出风险；
   - Softmax 路径：允许更高位宽或分段缩放；
   - 输出 O：**Q8.8**（16-bit 有符号定点）。
5. **接口要求**：
   - **AXI4-Lite 控制接口**：主机写寄存器（基地址/参数），经 `CTRL.START` 启动，
     读 `STATUS` 查询完成；
   - **AXI4 Master + DMA 数据接口**：启动后从内存读 Q/K/V，算完把 O 写回内存。
6. **必需寄存器**：

   | 偏移 | 名称 | 权限 | 说明 |
   |---|---|---|---|
   | `0x00` | `CTRL` | R/W | bit0 `START`，bit1 `SOFT_RESET`，bit2 `IRQ_EN` |
   | `0x04` | `STATUS` | R | bit0 `BUSY`，bit1 `DONE`（写 1 清），bit2 `ERROR` |
   | `0x08` | `CFG` | R/W | bit0 `CAUSAL_EN`（Baseline 必须支持），bit1 `RESERVED` |
   | `0x14/0x18` | `Q_BASE_L/H` | R/W | Q 基地址 低/高 32 位 |
   | `0x1C/0x20` | `K_BASE_L/H` | R/W | K 基地址 低/高 32 位 |
   | `0x24/0x28` | `V_BASE_L/H` | R/W | V 基地址 低/高 32 位 |
   | `0x2C/0x30` | `O_BASE_L/H` | R/W | O 基地址 低/高 32 位 |
   | `0x34` | `STRIDE_BYTES` | R/W | 行 stride，默认 `d * 2` bytes |
   | `0x38` | `NEG_LARGE` | R/W | `-inf` 近似值（Q8.8） |
   | `0x3C` | `SCALE` | R/W | 缩放常数 |
   | `0x40` | `CYCLES` | R | 本次执行周期数 |

7. **存储与资源约束**：禁止存储 score/p 全矩阵；片上中间 buffer 仅允许缓存小块 K/V tile，
   以及每行维护的 `m/l/acc` 和必要流水寄存器。若选择片上缓存全量 K/V，需在报告中
   量化带宽收益与 SRAM 代价。
8. **正确性验收**：随机种子生成的 Q/K/V（Q8.8）与 **FP32 golden** 对比，满足
   **mean_abs_error ≤ 0.03、max_abs_error ≤ 0.10**。采用不同 exp/倒数近似需在文档说明
   误差来源；**不要求 bit-exact**。
9. **测试验证**：SystemVerilog + UVM 或 Python + cocotb，必须包含：
   - AXI4-Lite 寄存器读写与启动/完成流程；
   - 随机 Q/K/V 端到端验证；
   - Causal mask corner case（如 `i=0` 行只能看 `j=0`）。
10. **语言要求**：使用 Verilog/SystemVerilog 开发 RTL。

---

## 二、附加要求（25%）

### 优先完成 — ASIC 后端与性能评估

- **主频**：频率越高越好，基于 **Cadence Genus 物理综合报告**说明，鼓励进一步 P&R 收敛。
- **面积**：等效逻辑门数 **≤ 200 万门**（含存储器折算，按 Genus 报告 2-input NAND 等效口径）。
- **延迟**：单次 attention（S=256、d=64、causal）执行周期数 **< 300k cycles**。
- **带宽**：给出 `RD_BYTES / WR_BYTES` 统计与优化分析（tile 缓存、数据复用等）。

### 可选加分项（Bonus）

1. BF16/FP16 版本（硬件化 softmax/exp/倒数，给误差与性能对比）。
2. 多 Head 支持（head=4 或 8，接口增加 head 维度与地址/stride 管理）。
3. 更长序列（S=512 或可配置 S，仍不存 S×S 中间矩阵）。
4. Padding mask（有效长度 L ≤ S，无效 token 置 `-inf`）。
5. 其他定点格式（Q6.10、Q4.12 等，给误差与性能对比）。
6. Dropout（训练模式，明确随机数产生方式与可复现种子）。
7. 更低精度探索（参考 FA-3，INT8/FP8 块量化或分块缩放）。
8. AXI4-Stream 数据接口（便于与其他 IP 级联）。
9. DMA/任务队列（多次 attention 连续执行）。
10. 其他优化（需在文档说明）。

### Bonus 注意事项（强制）

1. **所有 Bonus 必须在 Baseline 通过后开展。**
2. **必须基于 Baseline 新建独立项目/版本**（新目录或新工程），单独开发、验证、提交。
3. **不得修改或影响 Baseline 版本的代码与评估结果**（Baseline 仍按原要求独立评测）。
4. 所有可选项可在同一个 Bonus 项目中集中实现，但该 Bonus 项目必须基于 Baseline
   另行开发、作为独立版本单独评估（重新仿真/综合/统计指标）。
   → **完成 Baseline 后需及时冻结 Baseline 版本，再开发 Bonus。**

---

## 三、提交要求

- **RTL 代码**：完整 Verilog/SystemVerilog 源码。
- **验证代码**：UVM/cocotb 验证环境、测试用例、测试向量和仿真脚本。
- **Cadence 工具文件**：Cadence 工具脚本和 SDC 约束文件。
- **设计文档**：整体架构图、SDPA/FlashAttention 计算流程、分块策略、online softmax
  实现方式、存储组织、寄存器设计与 AXI/DMA 接口说明。
- **测评报告**：正确性误差结果 + 与 FP32 golden 的对比；完成 ASIC 后端的需补充相应说明。
- **仿真与波形文件**：关键仿真报告和必要波形，便于复核启动流程、DMA 搬运、Causal mask
  与 online softmax 行为。
- **附加要求完成情况**：逐条说明 + 证据（截图/日志/报告引用）。
- **其他补充材料**（可选）。

---

## 四、注意事项

功能实现可适当参考开源项目的设计思路，但**必须进行差异化改进，并在报告中说明**。

---

## 本仓库对照状态

| 要求 | 状态 | 证据 |
|---|---|---|
| 功能 / 精度（MAE≤0.03, MaxE≤0.10）/ cycles | 见仿真证据 | `reports/v2_evidence.md` |
| ASIC 综合：主频 / 面积 / 功耗 | **待 Genus 综合**（曾因 TUI-234 中断） | `synth/SYNTHESIS_STATUS.md`、[综合排错](./genus_synthesis_troubleshooting.md) |

> 综合曾在 `syn_generic -physical` 阶段因 **TUI-234** 中途中断，根因与修复见
> [`docs/genus_synthesis_troubleshooting.md`](./genus_synthesis_troubleshooting.md)。
