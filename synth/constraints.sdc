# constraints.sdc
# Target: flash_attn_top, sky130_fd_sc_hs TT 25C 1.80V
# Default clock target: 125 MHz = 8 ns
# 1. 基础时钟
set CLK_PERIOD 8.000
create_clock -name clk -period $CLK_PERIOD [get_ports clk]

# 0.1ns 余量
set_clock_uncertainty 0.1 [get_clocks clk]
set_clock_transition  0.1 [get_clocks clk]

# 2. 端口分类
set INPUT_PORTS  [remove_from_collection [all_inputs]  [get_ports {clk rst_n}]]
set OUTPUT_PORTS [all_outputs]

# 3. 复位网络处理
set_ideal_network [get_ports rst_n]

# 4. IO 延迟
set_input_delay  2.5 -clock [get_clocks clk] $INPUT_PORTS
set_output_delay 2.5 -clock [get_clocks clk] $OUTPUT_PORTS

# 5. 基础物理约束
set_input_transition 0.2 $INPUT_PORTS
set_load 0.05 $OUTPUT_PORTS
