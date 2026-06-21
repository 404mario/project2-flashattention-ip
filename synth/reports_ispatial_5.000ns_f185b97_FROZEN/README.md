# 第四次 5ns 综合报告（commit f185b97，FROZEN 提交基线）

Genus iSpatial / sky130_fd_sc_hs TT / CLK=5.000ns / effort=medium / retiming on / BQ=6 + ACC_W34 + max树。

## 两项硬约束全过
- **面积**：Total Cell Area = 7,870,282 µm² = 1,641,283 门当量（÷4.7952）= **82.1%**（限 200万门，余 17.9%）。
- **时序**：Violating Paths = **0**，最差 slack **+5ps MET**（30_timing.rpt：m_axi_rvalid → v_buf2_reg）。
- **Cycles**：259,791（causal，<300k）。

8 份 .rpt：00 check_design / 01 check_timing(pre) / 10 qor / 20 area / 30 timing / 40 power /
50 check_design(post) / 60 check_timing(post)。原始 tar 一并归档。

判读口径见 docs/project2_requirements.md；4ns 冲刺与 SRAM 否决见 docs/synth_4ns_research_2026-06-21.md。
