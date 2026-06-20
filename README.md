# Project2 FlashAttention Hardware Accelerator IP

本项目为课程 Project2 的 **FlashAttention-style 硬件加速器 IP** 设计。

项目目标是使用 **Verilog/SystemVerilog** 实现一个可验证、可综合、可扩展的 FlashAttention 加速器。Baseline 固定为单 batch、单 head，`S = 256`，`d = 64`，输入输出数据格式为 **Q8.8 定点数**。

---

## Table of Contents

- [0. 关键文档（评分口径 / 综合排错）](#0-关键文档评分口径--综合排错)
- [1. Project Overview](#1-project-overview)
- [2. Baseline Configuration](#2-baseline-configuration)
- [3. Directory Structure and File Responsibilities](#3-directory-structure-and-file-responsibilities)
- [4. Interface Specification](#4-interface-specification)
- [5. Memory Layout](#5-memory-layout)
- [6. Data Format Convention](#6-data-format-convention)
- [7. Team Division](#7-team-division)
- [8. Collaboration Workflow](#8-collaboration-workflow)
- [9. Interface Change Rule](#9-interface-change-rule)
- [10. Minimum Integration Contract](#10-minimum-integration-contract)
- [11. Final Submission Checklist](#11-final-submission-checklist)

---

## 0. 关键文档（评分口径 / 综合排错）

- 🚀 **[Ceiling-Push 改动证据（commit `f586c52`，本次）](reports/ceiling_push_evidence.md)** — 在已闭合
  5ns 时序的 v2 上做两处 **bit-exact** 结构改动以提升上限：(1) `softmax_combine` 的 16 路 tile-max
  由 **15 级线性比较链 → 深度 4 平衡树**（缩短 +1ps 的 binding 关键路径，释放时序余量）；
  (2) **`ACC_W 36→34`**（实测下限，−2bit 省面积）。两者全规模仿真 **md5 == `01697fe8` 逐字节一致**，
  **cycles/精度不变**；同工作点（BQ6/5ns）对旧 v2 **严格占优**。综合默认现为 BQ6+ACC34+max树。
- 📋 **[Project 2 官方要求](docs/project2_requirements.md)** — 摘自课程《Project 2 补充说明》
  PDF（FlashAttention 赛题），基本要求 75% + 附加要求 25% 的权威评分口径、必需寄存器表、
  正确性验收阈值（MAE≤0.03 / MaxE≤0.10）、ASIC 后端指标（面积 ≤200 万门、延迟 <300k cycles）。
- 🛠 **[Genus 综合中断（TUI-234）排错](docs/genus_synthesis_troubleshooting.md)** — `syn_generic
  -physical` 第二遍 generic 因 advstr 跨层级 group flash_core 的 `CDN_PAS_SKIP_MUX_0i` 而中断，
  根因分析与已落地修复（修复在 `baseline-v2-synthopt` 分支）。

---

## 1. Project Overview

本项目重点包括：

- FlashAttention-style attention 计算
- online softmax
- K/V tiling
- causal mask 支持
- AXI4-Lite 控制接口
- AXI4 Master / DMA 数据搬运
- RTL 仿真验证
- FP32 golden model 对比
- 综合脚本与设计报告

整体目标不是一开始追求最高性能，而是先完成一个 **正确、可验证、可提交、可扩展** 的 baseline 版本。

---

## 2. Baseline Configuration

当前 baseline 配置如下：

```text
S = 256
D = 64
Batch = 1
Head = 1
BQ = 1
BK = 16
Q/K/V/O = Q8.8 signed fixed-point
Dot-product accumulator = 40-bit 或 48-bit
支持 causal mask
禁止存储完整 attention score/probability matrix
```

核心计算流程：

```text
for each query row i:
    load Q_i

    initialize m, l, acc[0:63]

    for each K/V tile:
        load K_tile and V_tile
        compute score_tile = Q_i dot K_tile
        apply scale and causal mask
        update online softmax state
        update value accumulator

    normalize acc / l
    write O_i back to memory
```

---

## 3. Directory Structure and File Responsibilities

本项目采用模块化目录结构，按照 **文档、RTL、算法模型、测试平台、仿真脚本、综合脚本、辅助脚本** 进行划分。

设计原则：

1. `model/` 负责给出正确答案。
2. `rtl/core/` 负责实现 FlashAttention 计算核心。
3. `rtl/axi/` 负责 AXI4-Lite、AXI Master 和 DMA。
4. `rtl/top/` 负责系统集成。
5. `tb/` 负责验证所有模块是否正确。
6. `docs/` 负责沉淀接口、架构、验证和报告材料。
7. `sim/` 和 `synth/` 负责工程运行脚本。

---

### 3.1 Full Project Tree

```text
project2-flashattention-ip/
├── README.md
│   └── 项目总说明，包含目标、目录结构、分工、接口约定、开发流程和提交 checklist
│
├── .gitignore
│   └── 忽略仿真中间文件、波形文件、综合输出、Python 缓存和编辑器临时文件
│
├── docs/
│   ├── architecture.md
│   │   └── 整体架构说明，描述 top、AXI/DMA、core、buffer、online softmax 数据流
│   │
│   ├── interface_spec.md
│   │   └── 接口说明文档，记录顶层端口、core handshake、DMA 接口、寄存器表和地址规则
│   │
│   ├── verification_plan.md
│   │   └── 验证计划，记录单元测试、端到端测试、随机测试、误差指标和 corner case
│   │
│   └── report_assets/
│       └── 存放报告图片、架构图、波形截图、误差统计图、综合报告截图等材料
│
├── rtl/
│   ├── include/
│   │   └── flash_attn_pkg.sv
│   │       └── 全局参数包，定义 S_LEN、D_MODEL、BK、DATA_W、ACC_W、地址宽度等
│   │
│   ├── top/
│   │   └── flash_attn_top.sv
│   │       └── 顶层模块，连接 AXI4-Lite、AXI Master/DMA、flash_core 和状态寄存器
│   │
│   ├── core/
│   │   ├── flash_core.sv
│   │   │   └── FlashAttention 计算核心总控，负责一行 Q 与所有 K/V tile 的完整计算流程
│   │   │
│   │   ├── tile_scheduler.sv
│   │   │   └── tile 调度状态机，控制 query row index 和 kv tile index
│   │   │
│   │   ├── dot_product_engine.sv
│   │   │   └── 点积计算模块，计算 Q_i 与 K_j 的 dot product
│   │   │
│   │   ├── causal_mask_unit.sv
│   │   │   └── causal mask 模块，当 j > i 时将 score 置为 NEG_LARGE
│   │   │
│   │   ├── online_softmax_engine.sv
│   │   │   └── online softmax 模块，维护当前行的 m、l，并输出当前 tile 的 softmax 权重
│   │   │
│   │   ├── value_accumulator.sv
│   │   │   └── V 累加模块，计算 acc[d] = sum softmax(score_j) * V_j[d]
│   │   │
│   │   ├── normalizer.sv
│   │   │   └── 归一化模块，计算 O_i[d] = acc[d] / l
│   │   │
│   │   └── quantize_saturate.sv
│   │       └── 输出量化模块，将高位宽结果饱和并量化回 Q8.8
│   │
│   ├── axi/
│   │   ├── axi_lite_regs.sv
│   │   │   └── AXI4-Lite 寄存器模块，负责 CTRL、STATUS、CFG、BASE、SCALE、CYCLES 等寄存器
│   │   │
│   │   ├── axi_master_read.sv
│   │   │   └── AXI Master 读通道模块，负责从外部 memory 读取 Q/K/V 数据
│   │   │
│   │   ├── axi_master_write.sv
│   │   │   └── AXI Master 写通道模块，负责将 O 数据写回外部 memory
│   │   │
│   │   └── dma_controller.sv
│   │       └── DMA 控制器，负责根据 base address 和 stride 生成 Q/K/V/O 读写请求
│   │
│   └── mem/
│       ├── tile_buffer.sv
│       │   └── tile 缓冲模块，用于缓存 K_tile 和 V_tile
│       │
│       └── row_buffer.sv
│           └── 行缓冲模块，用于缓存当前 Q_i 或输出 O_i
│
├── model/
│   ├── model_fp32.py
│   │   └── FP32 golden model，实现标准 attention，用作最终正确性参考
│   │
│   ├── model_fixed.py
│   │   └── fixed-point model，模拟 RTL 中 Q8.8、dot accumulator、softmax 近似和输出量化
│   │
│   ├── gen_vectors.py
│   │   └── 测试向量生成脚本，生成 Q/K/V 输入和 golden O 输出
│   │
│   ├── gen_lut.py
│   │   └── LUT 生成脚本，用于生成 exp、reciprocal 或其他近似表
│   │
│   └── check_error.py
│       └── 误差检查脚本，比较 RTL 输出和 golden 输出，计算 mean_abs_error 和 max_abs_error
│
├── tb/
│   ├── cocotb/
│   │   ├── test_axi_lite.py
│   │   │   └── AXI4-Lite 寄存器读写测试，包括 CTRL、STATUS、CFG、BASE 等
│   │   │
│   │   ├── test_flash_core.py
│   │   │   └── flash_core 单元测试，不经过 AXI/DMA，直接验证计算核心
│   │   │
│   │   ├── test_end_to_end.py
│   │   │   └── top 级端到端测试，模拟主机配置寄存器、启动加速器、等待 DONE、读取输出
│   │   │
│   │   └── common/
│   │       └── 公共 cocotb 工具，包括 AXI driver、memory model、数据读写工具、误差检查工具
│   │
│   ├── sv/
│   │   └── tb_flash_attn_top.sv
│   │       └── SystemVerilog testbench，可用于基础波形仿真和工具兼容验证
│   │
│   └── vectors/
│       ├── input_q.hex
│       │   └── Q 输入测试向量，形状为 [256, 64]，格式为 Q8.8
│       │
│       ├── input_k.hex
│       │   └── K 输入测试向量，形状为 [256, 64]，格式为 Q8.8
│       │
│       ├── input_v.hex
│       │   └── V 输入测试向量，形状为 [256, 64]，格式为 Q8.8
│       │
│       └── golden_o.hex
│           └── golden 输出向量，形状为 [256, 64]，用于和 RTL 输出比较
│
├── sim/
│   ├── Makefile
│   │   └── cocotb 或 RTL 仿真的统一入口
│   │
│   ├── run_core.sh
│   │   └── 运行 flash_core 级别仿真
│   │
│   ├── run_top.sh
│   │   └── 运行 flash_attn_top 级别端到端仿真
│   │
│   └── clean.sh
│       └── 清理 sim_build、vcd/fst、log、临时文件等仿真输出
│
├── synth/
│   ├── genus.tcl
│   │   └── Cadence Genus 综合脚本，读取 RTL、设置约束、综合并输出报告
│   │
│   ├── constraints.sdc
│   │   └── SDC 约束文件，定义 clock、reset、input delay、output delay 等
│   │
│   └── reports/
│       └── 存放综合报告，包括 timing、area、power、resource 等
│
└── scripts/
    ├── lint.sh
    │   └── 运行 RTL lint 检查
    │
    ├── format.sh
    │   └── 统一代码格式
    │
    └── clean.sh
        └── 清理整个工程中的中间文件
```

---

## 4. Interface Specification

本节定义项目中各模块之间的接口约定。

所有成员在开发前必须先对齐接口，避免后期集成时互相改端口。

---

### 4.1 Global Parameters

全局参数统一放在：

```text
rtl/include/flash_attn_pkg.sv
```

建议定义如下：

```systemverilog
package flash_attn_pkg;

    parameter int S_LEN      = 256;
    parameter int D_MODEL    = 64;
    parameter int BK         = 16;

    parameter int DATA_W     = 16;   // Q8.8 input / output
    parameter int FRAC_W     = 8;
    parameter int DOT_W      = 48;
    parameter int ACC_W      = 48;
    parameter int SOFTMAX_W  = 32;

    parameter int ADDR_W     = 64;
    parameter int AXI_DATA_W = 64;
    parameter int AXI_STRB_W = AXI_DATA_W / 8;

endpackage
```

所有 RTL 文件都应引用该 package，而不是在各自文件中重复写 magic number。

---

### 4.2 Top Module Interface

文件：

```text
rtl/top/flash_attn_top.sv
```

`flash_attn_top` 是整个 IP 的顶层模块，向外暴露 AXI4-Lite 控制接口和 AXI Master 数据接口，内部连接寄存器、DMA 和计算核心。

顶层接口建议包括：

- `clk`
- `rst_n`
- AXI4-Lite slave control interface
- AXI4 master read interface
- AXI4 master write interface
- `irq`

建议接口草稿：

```systemverilog
module flash_attn_top #(
    parameter int ADDR_W     = 64,
    parameter int AXI_DATA_W = 64
)(
    input  logic clk,
    input  logic rst_n,

    // AXI4-Lite slave control interface
    input  logic [31:0] s_axil_awaddr,
    input  logic        s_axil_awvalid,
    output logic        s_axil_awready,

    input  logic [31:0] s_axil_wdata,
    input  logic [3:0]  s_axil_wstrb,
    input  logic        s_axil_wvalid,
    output logic        s_axil_wready,

    output logic [1:0]  s_axil_bresp,
    output logic        s_axil_bvalid,
    input  logic        s_axil_bready,

    input  logic [31:0] s_axil_araddr,
    input  logic        s_axil_arvalid,
    output logic        s_axil_arready,

    output logic [31:0] s_axil_rdata,
    output logic [1:0]  s_axil_rresp,
    output logic        s_axil_rvalid,
    input  logic        s_axil_rready,

    // AXI4 master read address channel
    output logic [ADDR_W-1:0] m_axi_araddr,
    output logic [7:0]        m_axi_arlen,
    output logic [2:0]        m_axi_arsize,
    output logic [1:0]        m_axi_arburst,
    output logic              m_axi_arvalid,
    input  logic              m_axi_arready,

    // AXI4 master read data channel
    input  logic [AXI_DATA_W-1:0] m_axi_rdata,
    input  logic [1:0]            m_axi_rresp,
    input  logic                  m_axi_rlast,
    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready,

    // AXI4 master write address channel
    output logic [ADDR_W-1:0] m_axi_awaddr,
    output logic [7:0]        m_axi_awlen,
    output logic [2:0]        m_axi_awsize,
    output logic [1:0]        m_axi_awburst,
    output logic              m_axi_awvalid,
    input  logic              m_axi_awready,

    // AXI4 master write data channel
    output logic [AXI_DATA_W-1:0]   m_axi_wdata,
    output logic [AXI_DATA_W/8-1:0] m_axi_wstrb,
    output logic                    m_axi_wlast,
    output logic                    m_axi_wvalid,
    input  logic                    m_axi_wready,

    // AXI4 master write response channel
    input  logic [1:0] m_axi_bresp,
    input  logic       m_axi_bvalid,
    output logic       m_axi_bready,

    output logic irq
);
```

---

### 4.3 AXI4-Lite Register Map

文件：

```text
rtl/axi/axi_lite_regs.sv
```

AXI4-Lite 寄存器用于主机配置加速器、启动任务和读取状态。

| 地址 | 名称 | 类型 | 说明 |
|---:|---|---|---|
| `0x00` | `CTRL` | R/W | bit0 `START`，bit1 `SOFT_RESET`，bit2 `IRQ_EN` |
| `0x04` | `STATUS` | R | bit0 `BUSY`，bit1 `DONE`，bit2 `ERROR` |
| `0x08` | `CFG` | R/W | bit0 `CAUSAL_EN` |
| `0x14` | `Q_BASE_L` | R/W | Q base address 低 32 位 |
| `0x18` | `Q_BASE_H` | R/W | Q base address 高 32 位 |
| `0x1C` | `K_BASE_L` | R/W | K base address 低 32 位 |
| `0x20` | `K_BASE_H` | R/W | K base address 高 32 位 |
| `0x24` | `V_BASE_L` | R/W | V base address 低 32 位 |
| `0x28` | `V_BASE_H` | R/W | V base address 高 32 位 |
| `0x2C` | `O_BASE_L` | R/W | O base address 低 32 位 |
| `0x30` | `O_BASE_H` | R/W | O base address 高 32 位 |
| `0x34` | `STRIDE_BYTES` | R/W | 每行 stride，默认 `D_MODEL * 2` bytes |
| `0x38` | `NEG_LARGE` | R/W | softmax mask 使用的负大数，近似 `-inf` |
| `0x3C` | `SCALE` | R/W | attention scale，近似 `1 / sqrt(D_MODEL)` |
| `0x40` | `CYCLES` | R | 本次任务运行周期数 |

#### CTRL Register

| bit | 名称 | 行为 |
|---:|---|---|
| 0 | `START` | 主机写 1 启动一次 attention 计算，硬件接收后自动清零或产生 start pulse |
| 1 | `SOFT_RESET` | 软件复位内部状态机和状态寄存器 |
| 2 | `IRQ_EN` | 任务完成后允许产生中断 |

#### STATUS Register

| bit | 名称 | 行为 |
|---:|---|---|
| 0 | `BUSY` | 任务运行中为 1 |
| 1 | `DONE` | 任务完成后置 1，建议主机写 1 清除 |
| 2 | `ERROR` | AXI 错误或非法状态时置 1 |

---

### 4.4 Register Module Internal Interface

`axi_lite_regs.sv` 对内输出配置寄存器，对外连接 AXI4-Lite。

建议对内接口：

```systemverilog
output logic        start_pulse,
output logic        soft_reset,
output logic        irq_en,
output logic        causal_en,

output logic [63:0] q_base,
output logic [63:0] k_base,
output logic [63:0] v_base,
output logic [63:0] o_base,

output logic [31:0] stride_bytes,
output logic [31:0] neg_large,
output logic [31:0] scale,

input  logic        busy,
input  logic        done,
input  logic        error,
input  logic [31:0] cycles
```

约定：

1. `start_pulse` 只保持一个 clock cycle。
2. `busy`、`done`、`error` 由 top 或 DMA/core 状态机产生。
3. `cycles` 在 `start_pulse` 后清零，在 `busy = 1` 时递增。

---

### 4.5 Flash Core Interface

文件：

```text
rtl/core/flash_core.sv
```

`flash_core` 不直接处理 AXI。它只和 DMA/buffer 交互，专心做计算。

建议接口如下：

```systemverilog
module flash_core #(
    parameter int S_LEN   = 256,
    parameter int D_MODEL = 64,
    parameter int BK      = 16,
    parameter int DATA_W  = 16,
    parameter int ACC_W   = 48
)(
    input  logic clk,
    input  logic rst_n,

    input  logic start,
    output logic busy,
    output logic done,
    output logic error,

    input  logic causal_en,
    input  logic signed [31:0] neg_large,
    input  logic signed [31:0] scale,

    // request Q row
    output logic q_req_valid,
    output logic [$clog2(S_LEN)-1:0] q_req_row,
    input  logic q_req_ready,

    input  logic q_data_valid,
    input  logic signed [DATA_W-1:0] q_data [D_MODEL],
    output logic q_data_ready,

    // request K/V tile
    output logic kv_req_valid,
    output logic [$clog2(S_LEN)-1:0] kv_req_start,
    output logic [$clog2(BK+1)-1:0]  kv_req_len,
    input  logic kv_req_ready,

    input  logic kv_data_valid,
    input  logic signed [DATA_W-1:0] k_tile [BK][D_MODEL],
    input  logic signed [DATA_W-1:0] v_tile [BK][D_MODEL],
    output logic kv_data_ready,

    // output O row
    output logic o_valid,
    output logic [$clog2(S_LEN)-1:0] o_row,
    output logic signed [DATA_W-1:0] o_data [D_MODEL],
    input  logic o_ready
);
```

#### Core Handshake Convention

| 信号 | 方向 | 说明 |
|---|---|---|
| `start` | input | 计算开始，保持 1 个 cycle |
| `busy` | output | core 正在运行 |
| `done` | output | 所有 256 行计算完成 |
| `q_req_valid` | output | 请求 DMA 提供一行 Q |
| `q_req_row` | output | 请求的 Q 行号 |
| `q_data_valid` | input | Q 行数据有效 |
| `kv_req_valid` | output | 请求一个 K/V tile |
| `kv_req_start` | output | 当前 tile 起始行 |
| `kv_req_len` | output | 当前 tile 长度，通常为 BK |
| `kv_data_valid` | input | K/V tile 数据有效 |
| `o_valid` | output | 当前 O 行输出有效 |
| `o_row` | output | 输出 O 的行号 |
| `o_ready` | input | 下游 DMA 可以接收 O 行 |

---

### 4.6 DMA Controller Interface

文件：

```text
rtl/axi/dma_controller.sv
```

DMA 负责把 core 的行/tile 请求转换成 AXI 读写请求。

建议接口如下：

```systemverilog
module dma_controller #(
    parameter int ADDR_W  = 64,
    parameter int DATA_W  = 16,
    parameter int D_MODEL = 64,
    parameter int BK      = 16
)(
    input  logic clk,
    input  logic rst_n,

    input  logic start,
    output logic busy,
    output logic done,
    output logic error,

    input  logic [63:0] q_base,
    input  logic [63:0] k_base,
    input  logic [63:0] v_base,
    input  logic [63:0] o_base,
    input  logic [31:0] stride_bytes,

    // interface to flash_core
    input  logic q_req_valid,
    input  logic [$clog2(256)-1:0] q_req_row,
    output logic q_req_ready,

    output logic q_data_valid,
    output logic signed [DATA_W-1:0] q_data [D_MODEL],
    input  logic q_data_ready,

    input  logic kv_req_valid,
    input  logic [$clog2(256)-1:0] kv_req_start,
    input  logic [$clog2(BK+1)-1:0] kv_req_len,
    output logic kv_req_ready,

    output logic kv_data_valid,
    output logic signed [DATA_W-1:0] k_tile [BK][D_MODEL],
    output logic signed [DATA_W-1:0] v_tile [BK][D_MODEL],
    input  logic kv_data_ready,

    input  logic o_valid,
    input  logic [$clog2(256)-1:0] o_row,
    input  logic signed [DATA_W-1:0] o_data [D_MODEL],
    output logic o_ready,

    // interface to AXI master read/write modules
    output logic rd_req_valid,
    output logic [ADDR_W-1:0] rd_req_addr,
    output logic [31:0] rd_req_bytes,
    input  logic rd_req_ready,

    input  logic rd_data_valid,
    input  logic [63:0] rd_data,
    input  logic rd_last,
    output logic rd_data_ready,

    output logic wr_req_valid,
    output logic [ADDR_W-1:0] wr_req_addr,
    output logic [31:0] wr_req_bytes,
    input  logic wr_req_ready,

    output logic wr_data_valid,
    output logic [63:0] wr_data,
    output logic wr_last,
    input  logic wr_data_ready
);
```

---

## 5. Memory Layout

外部 memory 中的数据按 row-major 排列。

每个元素为 Q8.8，16-bit，即 2 bytes。

一行长度：

```text
D_MODEL * 2 = 64 * 2 = 128 bytes
```

默认：

```text
STRIDE_BYTES = 128
```

地址计算规则：

```text
Q[i][d] address = Q_BASE + i * STRIDE_BYTES + d * 2
K[j][d] address = K_BASE + j * STRIDE_BYTES + d * 2
V[j][d] address = V_BASE + j * STRIDE_BYTES + d * 2
O[i][d] address = O_BASE + i * STRIDE_BYTES + d * 2
```

K/V tile 地址：

```text
K_tile start address = K_BASE + kv_start * STRIDE_BYTES
V_tile start address = V_BASE + kv_start * STRIDE_BYTES
```

---

## 6. Data Format Convention

### 6.1 Q/K/V/O Format

```text
Q/K/V input: signed Q8.8, 16-bit
O output:    signed Q8.8, 16-bit
```

Q8.8 表示：

```text
real_value = int16_value / 256.0
```

---

### 6.2 Dot Product

```text
score_j = sum over d: Q_i[d] * K_j[d]
```

建议 accumulator：

```text
DOT_W = 48
```

原因：

1. Q8.8 乘 Q8.8 后得到 Q16.16。
2. 64 项累加需要更高位宽。
3. 48-bit 比 32-bit 更安全。

---

### 6.3 Scale

attention scale：

```text
scale = 1 / sqrt(D_MODEL)
```

当 `D_MODEL = 64`：

```text
scale = 1 / 8 = 0.125
```

硬件中可以用定点常数近似。

---

### 6.4 Causal Mask

当 causal enable 时：

```text
if key_index > query_index:
    score = NEG_LARGE
```

示例：

```text
i = 0 时，只允许 j = 0
i = 1 时，只允许 j = 0, 1
i = 255 时，允许 j = 0 ... 255
```

---

## 7. Team Division

| 模块 / 文件 | 负责人 | 说明 |
|---|---|---|
| `model/*` | Member C | 算法模型、定点模型、测试向量、误差检查 |
| `rtl/core/*` | Member B | FlashAttention 计算核心 |
| `rtl/mem/*` | Member B | tile buffer、row buffer |
| `rtl/axi/*` | Member A | AXI4-Lite、AXI Master、DMA |
| `rtl/top/*` | Member A | 顶层集成 |
| `tb/*` | Member C，A 协助 | testbench、memory model、端到端测试 |
| `docs/architecture.md` | 全员 | 每个人补自己负责的架构说明 |
| `docs/interface_spec.md` | Member C 主维护 | 所有接口修改必须同步更新 |
| `docs/verification_plan.md` | Member A + C | 测试计划和误差验证 |
| `synth/*` | Member C | 综合脚本、SDC、报告 |

---

## 8. Collaboration Workflow

当前分支布局（2026-06 整理后，共 5 个）：

```text
main                  主干
baseline-v2-synthopt  ★当前主力：baseline 的 v2 流式优化版（II=1 dot_stream + softmax_combine）
                      已 bit-exact 验证、已修 Genus TUI-234，目标 5ns clean
8nsclean-baseline     唯一完整综合过的 baseline：8ns clean / slack +2ps / 7.84M cell area（≈163.5万门）
bonus-v2-synthopt     bonus 的 v2 优化版
8nsclean-bonus        bonus 的 8ns 综合版
```

> 已删除的实验分支（旧 `codex-*` 命名）均已打 `archive/` tag 备份，可按需找回。
> 文档中若仍出现旧分支名，对照 `CLAUDE.md` 的分支表换算。

开发流程：

```text
1. 从对应主力分支拉取最新代码
2. 改动后用 sim/ 下的脚本做 bit-exact 回归（见 §11 / CLAUDE.md）
3. 综合用 ./synth/run_genus.sh（EDA 服务器）
4. commit + push；评测以 8nsclean-* 与 *-v2-synthopt 为准
```

常用命令：

```bash
git checkout dev
git pull

git checkout -b feature/xxx

git add .
git commit -m "feat: describe your change"
git push -u origin feature/xxx
```

---

## 9. Interface Change Rule

为了避免集成混乱，所有接口变更必须遵守以下规则：

1. 不允许直接在 `dev` 或 `main` 上修改接口。
2. 修改接口前，先更新 `docs/interface_spec.md`。
3. 修改接口后，必须同步更新相关 testbench。
4. 涉及跨成员模块的接口修改，必须在 Pull Request 中说明。
5. PR 描述中必须写清楚：
   - 修改了哪些端口
   - 哪些模块受影响
   - 如何测试
   - 是否需要其他成员同步修改
6. `main` 分支上的接口应保持稳定。
7. baseline 冻结后，接口不再随意修改。

---

## 10. Minimum Integration Contract

为了让三个人可以并行开发，先约定最小集成边界。

---

### 10.1 Member A 向 RTL 提供

```text
tb/vectors/input_q.hex
tb/vectors/input_k.hex
tb/vectors/input_v.hex
tb/vectors/golden_o.hex
```

同时提供：

```text
Q/K/V 数据格式说明
golden 输出说明
误差计算脚本
fixed-point 中间参考数据
```

---

### 10.2 Member B 向集成提供

```text
flash_core.sv
```

并保证：

```text
1. start 后可以开始计算
2. busy 表示正在计算
3. done 表示计算完成
4. 通过 q_req / kv_req 请求输入数据
5. 通过 o_valid / o_data 输出结果
6. 不直接访问 AXI
```

---

### 10.3 Member C 向 Core 提供

```text
1. Q row 数据
2. K/V tile 数据
3. O row 接收 ready
4. start / reset / config
```

并保证：

```text
1. AXI4-Lite 寄存器可配置
2. DMA 可从 memory 读取 Q/K/V
3. DMA 可将 O 写回 memory
4. top-level testbench 能完成端到端验证
```

---

## 11. Final Submission Checklist

最终提交前检查：

```text
[ ] RTL 源码完整
[ ] Testbench 可运行
[ ] Python golden model 可运行
[ ] 随机测试通过
[ ] causal mask 测试通过
[ ] AXI4-Lite 测试通过
[ ] START / BUSY / DONE 流程通过
[ ] 误差统计满足要求
[ ] 综合脚本和 SDC 文件完整
[ ] 设计文档完整
[ ] 测评报告完整
[ ] README 说明清楚
[ ] baseline 版本已冻结
```
