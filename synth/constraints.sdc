# constraints.sdc
# Target: flash_attn_top, sky130_fd_sc_hs TT 25C 1.80V
# Clock target: 100 MHz = 10 ns

set CLK_PERIOD 10.000
create_clock -name clk -period $CLK_PERIOD [get_ports clk]

set_clock_uncertainty 0.1 [get_clocks clk]
set_clock_transition  0.1 [get_clocks clk]

set INPUT_PORTS  [remove_from_collection [all_inputs] [get_ports {clk rst_n}]]
set OUTPUT_PORTS [all_outputs]

set_ideal_network [get_ports rst_n]

set_input_delay  3.0 -clock [get_clocks clk] $INPUT_PORTS
set_output_delay 3.0 -clock [get_clocks clk] $OUTPUT_PORTS

set_input_transition 0.2 $INPUT_PORTS
set_load 0.05 $OUTPUT_PORTS
