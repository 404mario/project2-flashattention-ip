# constraints.sdc
# Target: flash_attn_top, sky130_fd_sc_hs TT 25C 1.80V
#
# Clock period is parameterized. DEFAULT TARGET = 5.000 ns (the goal: 5 ns clean).
# A bare `./run_genus.sh` therefore synthesizes at 5 ns directly.
# Override only if you ever want another point, e.g. CLK_PERIOD_NS=8.0 ...
if {[info exists ::env(CLK_PERIOD_NS)]} {
    set CLK_PERIOD $::env(CLK_PERIOD_NS)
} else {
    set CLK_PERIOD 5.000
}
puts "INFO: SDC clock period = $CLK_PERIOD ns"

create_clock -name clk -period $CLK_PERIOD [get_ports clk]

# Uncertainty/transition scale gently with period (keep ~1-2% margin).
set_clock_uncertainty [expr {$CLK_PERIOD * 0.0125}] [get_clocks clk]
set_clock_transition  0.1 [get_clocks clk]

# Port classification.
set INPUT_PORTS  [remove_from_collection [all_inputs]  [get_ports {clk rst_n}]]
set OUTPUT_PORTS [all_outputs]

# Reset is an ideal network.
set_ideal_network [get_ports rst_n]

# IO delays scale with the period (30% in / 30% out). The original fixed 2.5 ns
# was half of a 5 ns clock and would make any IO path dominate the 5 ns sweep,
# masking the real internal fmax (dot tree / combine). 30%/period keeps IO
# realistic for an SoC-integrated IP while letting internal fmax be the limiter.
set IO_IN  [expr {$CLK_PERIOD * 0.30}]
set IO_OUT [expr {$CLK_PERIOD * 0.30}]
set_input_delay  $IO_IN  -clock [get_clocks clk] $INPUT_PORTS
set_output_delay $IO_OUT -clock [get_clocks clk] $OUTPUT_PORTS

# Basic physical constraints.
set_input_transition 0.2 $INPUT_PORTS
set_load 0.05 $OUTPUT_PORTS
