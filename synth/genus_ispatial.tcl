# genus_ispatial.tcl
# iSpatial Genus synthesis script for flash_attn_top
# Run from project root with: genus -f synth/genus_ispatial.tcl

set DESIGN flash_attn_top

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set ROOT_DIR   [file normalize [file join $SCRIPT_DIR ".."]]
set RPT_DIR    [file join $SCRIPT_DIR reports_ispatial]
set OUT_DIR    [file join $SCRIPT_DIR out_ispatial]

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

# Effort settings.
set_db syn_generic_effort medium
set_db syn_map_effort     medium
set_db syn_opt_effort     medium

# ============================================================
# Synthesis flow (iSpatial)
# ============================================================

# FIX for TUI-234 (CDN_PAS_SKIP_MUX hierarchy conflict):
# Forcefully flatten the dma_controller instance IMMEDIATELY after elaborate.
# Setting the module attribute wasn't enough, we must execute the ungroup command
# so the sub-design boundary is destroyed before syn_generic starts.
puts "INFO: Flattening dma_controller to avoid TUI-234 bug..."
foreach_in_collection h [get_db hinsts *u_dma_controller*] {
    set inst_name [get_db $h .name]
    set_db $h .ungroup_ok true
    set_db $h .module.ungroup_ok true
    catch { ungroup -simple $h }
    puts "INFO: Ungrouped instance $inst_name"
}

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
