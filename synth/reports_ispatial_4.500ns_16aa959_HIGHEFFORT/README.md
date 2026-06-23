# 4.5ns 综合报告（分支 4ns-dma-rdpipe，rd_beat_pipe + dot-split，effort=high）

Genus iSpatial / sky130_fd_sc_hs TT / **CLK=4.500ns** / effort=high / retiming on / BQ=6 + ACC_W34.
（注：原 tar 内目录名为 reports_ispatial_5.000ns 是 TCL tag 默认值未跟随 SDC 的命名 bug，已在 genus_ispatial.tcl 修正为 4.500ns；报告内 Clock Period 实为 4500ps。）

## 两项硬约束全过 + Fmax 升一档
- **时钟**：Clock Period **4500ps**，Violating Paths **0**，最差 slack **+5.2ps MET**（30_timing.rpt：state_q → v_buf_reg）。
- **面积**：Total Cell Area = **7,785,818 µm² = 1,623,669 门当量 = 81.2%**（限 200万门，余 18.8%）——比 5ns baseline（82.1%）还**小 1.07%**。
- **Cycles**：260,420（causal，<300k；本地全规模 iverilog 实测，bit-exact md5=01697fe8）。

## 相对 5ns FROZEN baseline
- Fmax 5.0ns→4.5ns（+11%，软分↑一档）；面积 7.870M→7.786M（−84k µm²）；序列单元 107,713→109,843（+2,130 = rd_beat_pipe + dot-split 寄存器）。
- 面积反降原因：切短关键路径后，原 5ns 压线路径不再需要大驱动单元（drive-up），省下的 > 新增寄存器。

## 产生方式（方法未变）
- `./synth/run_genus.sh`（默认现在 = 4.500ns）。流程与 5ns 完全一致：iSpatial 物理 passes、TUI-234 dma ungroup + advstr 修复、retime high、全部 report/write 步骤。仅"目标"变了：SDC 默认周期 5.0→4.5、effort medium→high。
- RTL = baseline 5ns 核 + rd_beat_pipe（dma_controller.sv）+ dot-split（dot_stream.sv），两改本地全规模 bit-exact（md5=01697fe8，== baseline 逐字节）。
