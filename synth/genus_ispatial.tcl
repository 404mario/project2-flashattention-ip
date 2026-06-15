# genus_ispatial.tcl
# iSpatial Genus synthesis script for flash_attn_top
# Run from project root with: genus -f synth/genus_ispatial.tcl

set DESIGN flash_attn_top

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set ROOT_DIR   [file normalize [file join $SCRIPT_DIR ".."]]
# Tag report/output dirs by clock period so a period sweep (8/6/5 ns) keeps each
# run's evidence separate instead of overwriting.
if {[info exists ::env(CLK_PERIOD_NS)]} {
    set PTAG [format "%sns" $::env(CLK_PERIOD_NS)]
} else {
    set PTAG "5.000ns"
}
set RPT_DIR    [file join $SCRIPT_DIR "reports_ispatial_${PTAG}"]
set OUT_DIR    [file join $SCRIPT_DIR "out_ispatial_${PTAG}"]

file mkdir $RPT_DIR
file mkdir $OUT_DIR

set FILELIST [file join $SCRIPT_DIR filelist.f]
set SDC_FILE [file join $SCRIPT_DIR constraints.sdc]

set PDK_ROOT /home/share/pdk
set STD_CELL sky130_fd_sc_hs
set LIB_FILE [file join $PDK_ROOT sky130A libs.ref $STD_CELL lib sky130_fd_sc_hs__tt_025C_1v80.lib]

set TECH_LEF [file join $PDK_ROOT sky130A libs.ref $STD_CELL techlef sky130_fd_sc_hs__nom.tlef]
set CELL_LEF [file join $PDK_ROOT sky130A libs.ref $STD_CELL lef sky130_fd_sc_hs.lef]

puts "============================================================"
puts "DESIGN     = $DESIGN (iSpatial Mode)"
puts "ROOT_DIR   = $ROOT_DIR"
puts "FILELIST   = $FILELIST"
puts "SDC_FILE   = $SDC_FILE"
puts "LIB_FILE   = $LIB_FILE"
puts "TECH_LEF   = $TECH_LEF"
puts "CELL_LEF   = $CELL_LEF"
puts "============================================================"

if {![file exists $FILELIST]} {
    puts "ERROR: filelist not found: $FILELIST"
    exit 1
}
if {![file exists $SDC_FILE]} {
    puts "ERROR: SDC not found: $SDC_FILE"
    exit 1
}
if {![file exists $LIB_FILE]} {
    puts "ERROR: Liberty library not found: $LIB_FILE"
    exit 1
}

# Make filelist paths relative to project root valid.
cd $ROOT_DIR

# Logical library setup.
set_db init_lib_search_path [list [file dirname $LIB_FILE]]
set_db init_hdl_search_path [list \
    [file join $ROOT_DIR rtl] \
    [file join $ROOT_DIR rtl include] \
    [file join $ROOT_DIR rtl axi] \
    [file join $ROOT_DIR rtl core] \
    [file join $ROOT_DIR rtl mem] \
    [file join $ROOT_DIR rtl top] \
]
set_db library [list $LIB_FILE]

# Physical library setup (MANDATORY for iSpatial).
set LEF_FILES {}
foreach lef [list $TECH_LEF $CELL_LEF] {
    if {[file exists $lef]} {
        lappend LEF_FILES $lef
    } else {
        puts "WARNING: LEF not found, skip: $lef"
    }
}
if {[llength $LEF_FILES] > 0} {
    puts "INFO: Setting LEF files: $LEF_FILES"
    set_db lef_library $LEF_FILES
} else {
    puts "ERROR: No LEF files found! iSpatial requires physical LEF. Aborting."
    exit 1
}

# QRC Tech File for parasitic extraction (CRITICAL for iSpatial physical synthesis).
# Without this, the physical engine cannot estimate wire resistance/capacitance,
# which causes syn_generic -physical to skip placement entirely (Placement = 0 sec).
set QRC_FILE [file join $PDK_ROOT sky130A libs.tech cadence qrcTechFile]
if {[file exists $QRC_FILE]} {
    puts "INFO: Setting QRC tech file: $QRC_FILE"
    set_db qrc_tech_file $QRC_FILE
} else {
    puts "WARNING: QRC tech file not found: $QRC_FILE"
}

# Read and elaborate RTL.
read_hdl -sv -f $FILELIST
elaborate $DESIGN

# Basic design checks before constraints/synthesis.
check_design > [file join $RPT_DIR 00_check_design_pre_synth.rpt]

# Timing constraints.
read_sdc $SDC_FILE
check_timing > [file join $RPT_DIR 01_check_timing_pre_synth.rpt]

# Multi-threading: let Genus use multiple cores for generic/map/opt + physical.
# Single-thread was a big part of the slow runtime. Adjust to the server's core
# count (8 is safe on the EDA box); harmless if fewer cores are present.
# Wrapped in catch so an attribute-name mismatch across Genus versions warns
# instead of aborting a long run.
if {[catch {set_db max_cpus_per_server 8} m]} { puts "WARN: max_cpus_per_server: $m" }
if {[catch {set_db auto_super_thread   true} m]} { puts "WARN: auto_super_thread: $m" }

# Effort settings. HIGH effort: we are doing one focused 5 ns-clean push (not a
# sweep), so spend the extra optimization time to maximize the chance of closing.
set_db syn_generic_effort high
set_db syn_map_effort     high
set_db syn_opt_effort     high

# Register retiming: allow Genus to rebalance the pipeline registers across the
# dot_stream adder tree / combine datapath to hit a shorter period. Preserves
# cycle-by-cycle I/O behavior (latency & cycle count unchanged), only moves
# flops -> this is the main fmax lever for the 5 ns sweep. Safe to leave on at
# 8 ns too (it just won't move much when timing is already met).
if {[catch {set_db retime true} m]} { puts "WARN: retime: $m" }
if {[catch {set_db retime_effort_level high} m]} { puts "WARN: retime_effort_level: $m" }

# ============================================================
# Synthesis flow (iSpatial)
# ============================================================

# TUI-234 (CDN_PAS_SKIP_MUX) is now fixed at the RTL level: dma_controller no
# longer does dynamic-row-index array writes (k_buf[idx][..]) -- they were
# rewritten as static per-row decoded writes. The forced flatten/ungroup that
# the old flow needed (and which collapsed the whole design into one ~340k-cell
# region -> ~30h runtime) is therefore REMOVED. Hierarchy is preserved so Genus
# optimizes per-module and runs far faster. (See dma_controller.sv "dec_row".)

syn_generic
predict_floorplan
syn_generic -physical
syn_map -physical
syn_opt -spatial
# Reports required for submission.
report_qor    > [file join $RPT_DIR 10_qor.rpt]
report_area   > [file join $RPT_DIR 20_area.rpt]
report_timing > [file join $RPT_DIR 30_timing.rpt]
report_power  > [file join $RPT_DIR 40_power.rpt]
check_design  > [file join $RPT_DIR 50_check_design_post_synth.rpt]
check_timing  > [file join $RPT_DIR 60_check_timing_post_synth.rpt]

# Useful outputs.
write_hdl > [file join $OUT_DIR ${DESIGN}_mapped.v]
write_sdc > [file join $OUT_DIR ${DESIGN}_mapped.sdc]
write_def > [file join $OUT_DIR ${DESIGN}_ispatial.def]

# SDF may fail in some library/flow setups; keep the run alive if that happens.
if {[catch {write_sdf > [file join $OUT_DIR ${DESIGN}.sdf]} SDF_MSG]} {
    puts "WARNING: write_sdf failed. Continue."
    puts "WARNING: $SDF_MSG"
}

puts "============================================================"
puts "Genus iSpatial synthesis finished."
puts "Reports: $RPT_DIR"
puts "Outputs: $OUT_DIR"
puts "============================================================"

puts "Writing Genus Database..."
write_db -all [file join $OUT_DIR ${DESIGN}.db]

exit
