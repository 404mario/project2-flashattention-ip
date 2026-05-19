# 2026-05-19 集成调整与本周计划

## 结论

`Project 2补充说明.pdf` 规定的 baseline 不是端到端 Q16.16。baseline 对外接口应保持：

- Q/K/V 输入：signed Q8.8，16-bit
- O 输出：signed Q8.8，16-bit
- dot-product accumulator：至少 32-bit，建议 40-bit 以上
- softmax 路径：允许使用更高内部位宽或分段缩放

所以，Member C 把模型内部 softmax/倒数路径做成 Q16.16 是合理的精度方案，但不能把 baseline 的内存格式、寄存器格式、core I/O 改成 Q16.16。当前仓库里有两套数值契约：

- `rtl/core/*`：Q8.8 I/O，online softmax 权重和 denominator 是 Q0.8。
- `model/model_fixed.py`：Q8.8 I/O，但内部 exp/denominator/reciprocal 是 Q16.16。

这意味着 `model_fixed.py` 目前更像“高精度候选模型”，还不是当前 RTL 的精确镜像。它可以通过 FP32 golden 误差，但当前 RTL 的 Q0.8 近似仍可能不通过同一误差门槛。

## 2026-05-19 已确认状态

- core-only SystemVerilog 检查通过：`sim/run_member_b_week1.ps1`。
- core full-size smoke 通过：`sim/run_member_b_fullsize.ps1`。
- full-size core smoke 数据：`cycles=4404224`，`q_requests=256`，`kv_requests=4096`，`output_rows=256`。
- Python `model_fixed.py` 对 FP32 golden 通过：`MAE=0.000167`，`MaxE=0.070312`。
- 当前 RTL Q0.8 算术镜像对 FP32 golden 未通过 MaxE：`MAE=0.002541`，`MaxE=1.078125`。
- `flash_attn_top` 顶层已能被 Icarus 编译；修掉了 `axi_lite_regs.sv` 中函数返回值直接取 bit 的兼容性问题。
- 本环境缺少 `cocotb` 和 `make`，所以还不能在这里实际跑 cocotb 端到端测试。

## 我们是否已经集成完毕，只剩测试？

还不能这么说。现在状态应定义为“core 已比较稳，top/AXI/DMA 已能一起编译，但 baseline 集成尚未被证明跑通”。

还缺少这些证据：

- top-level AXI-Lite + DMA + core + AXI RAM 端到端仿真
- full-size O memory 写回验证
- full-size 对 FP32 golden 的误差报告
- 多 seed 误差报告
- top-level cycles / RD_BYTES / WR_BYTES 统计，而不只是 core-only smoke cycles

因此，2026-05-19 到 2026-05-24 这周不应只做“跑测试”，还要做接口收敛、数值模型对齐和 top 级闭环 debug。

## 需要冻结的接口判断

1. baseline 对外数据格式保持 Q8.8。
2. baseline 尺寸保持 `S_LEN=256`、`D_MODEL=64`、`BK=16`。
3. AXI-Lite 寄存器表按补充说明保留：`CTRL`、`STATUS`、`CFG`、`Q/K/V/O_BASE`、`STRIDE_BYTES`、`NEG_LARGE`、`SCALE`、`CYCLES`。
4. `SCALE` 在软件可见寄存器中保持 Q8.8。若内部改 Q16.16，应在 core 内部转换，不改变寄存器契约。
5. Q16.16 不应暴露到 baseline memory/register/core I/O，除非另开优化或 bonus 分支。

## 各模块调整建议

### `model/`

- 保留 `model_fixed.py` 作为 Q16.16 内部高精度候选模型。
- 使用 `model/model_rtl_q08.py` 估算当前 RTL Q0.8 softmax 路径的误差风险。
- 后续如果 RTL softmax 升级到 Q16.16，需要同步更新一个新的 RTL-exact model。
- C 同学本周至少跑 3 个 seed，不要只跑当前这一组向量。
- 当前 `TEST_SCALE=50.0` 容易让输入大量饱和，建议补充中等幅度 Q8.8 随机输入，避免 hidden tests 下误差表现突变。

### `rtl/core/`

- 为了满足 `mean_abs_error <= 0.03`、`max_abs_error <= 0.10`，下一步需要二选一：
  - 把 RTL online softmax / normalizer 升级到接近 `model_fixed.py` 的 Q16.16 内部路径；
  - 或者继续保留 Q0.8，但扩大 LUT / 改插值 / 改 denominator，使 MaxE 降到 0.10 以下。
- `flash_core` 的 ready-valid handshake 不要随意改端口。
- 在 full-size top 级正确性没有证明前，不建议先做 4-lane dot-product 优化。

### `rtl/axi/`

- `axi_lite_regs.sv` 已做 Icarus 编译兼容修复。
- 建议补一个 AXI-Lite / top smoke，至少覆盖 START、BUSY、DONE、W1C DONE。
- `dma_controller.done` 当前对 top 不是关键，因为 top 用 busy drain 判断完成；但为了观测清晰，可以后续补成真实一拍 pulse。
- RD_BYTES / WR_BYTES 计数器可以做，但应放在端到端正确性通过之后。

### `rtl/top/`

- 新增 `sim/run_top_compile.ps1`，作为最小顶层集成编译门禁。
- 下一个必须证明的是：主机写寄存器、START、DMA 读 Q/K/V、core 计算、DMA 写 O、STATUS.DONE 置位。
- DONE 语义继续保持“core 完成且 DMA/read/write 全部 drain”。

### `tb/`

- `tb/cocotb/test_end_to_end.py` 方向是对的，但 C 同学机器上需要先装好或确认 cocotb 运行环境。
- 如果 cocotb 暂时跑不起来，先补一个 SystemVerilog top smoke 作为临时闭环。
- 本周必须覆盖：
  - AXI-Lite 寄存器读写和 W1C DONE
  - 小规模 top end-to-end，例如 S=8/D=8
  - full-size S=256/D=64 top end-to-end
  - causal corner：第 0 行只能看第 0 行，`O[0]` 应接近 `V[0]`
  - 多 seed FP32 golden 误差报告

## 本周计划

### 2026-05-19 周二

- 冻结 baseline 外部 Q8.8 契约。
- 跑以下命令：
  - `powershell -ExecutionPolicy Bypass -File .\sim\run_member_b_week1.ps1`
  - `powershell -ExecutionPolicy Bypass -File .\sim\run_member_b_fullsize.ps1`
  - `powershell -ExecutionPolicy Bypass -File .\sim\run_top_compile.ps1`
  - `python model\compare_models.py`
  - `python model\model_rtl_q08.py`
- 根据 `model_rtl_q08.py` 的 MaxE 结果，决定 RTL softmax 是否向 Q16.16 内部实现靠齐。

### 2026-05-20 周三

- C：让 cocotb 或等价 SV top test 在本机能运行。
- A：检查 DMA row/stride 地址生成和 AXI read/write handshake。
- B：为小规模 debug 暴露或记录 `m`、`l`、`new_weight`、`old_scale`、若干 `acc` lane。

### 2026-05-21 周四

- 跑小规模 top end-to-end。
- 对比 O memory、FP32 golden、当前 RTL/定点模型。
- 如果失败，先修 ready-valid、DMA 写回和 DONE，不碰性能优化。

### 2026-05-22 周五

- 跑 full-size top end-to-end。
- 如果 MaxE 不达标，优先修 softmax 精度 / LUT / normalizer 对齐。
- 如果 DONE 或写回失败，优先修 DMA/top handshake。

### 2026-05-23 周六

- 至少跑 3 个 seed。
- 形成表格：`seed`、`MAE`、`MaxE`、`cycles`、`RD_BYTES`、`WR_BYTES`。
- 只有正确性稳定后才开始 4-lane dot 或 AXI burst。

### 2026-05-24 周日

- 只有 top-level end-to-end 通过后，才打 `baseline-functional-v0.1`。
- 如果只有 core 通过，不要叫 baseline-functional；应记录为 `core-functional`，继续集成。

## C 同学本周立即可跑 checklist

- 确认 `python model\compare_models.py` 不再因 Windows 输出编码失败。
- 跑 `python model\model_rtl_q08.py`；当前预期是 MaxE fail，用它确认 RTL 精度风险。
- 跑 `powershell -ExecutionPolicy Bypass -File .\sim\run_top_compile.ps1`。
- 让 `tb/cocotb/test_end_to_end.py` 或等价 SV top test 跑起来。
- 第一轮失败请归类为：
  - compile/interface
  - AXI-Lite register flow
  - DMA read/writeback
  - core numerical mismatch
  - timeout/performance

