# genus.tcl
# Run from project root with: genus -f synth/genus.tcl
#
# Parameter policy:
#   No manual parameter override is required for normal bonus synthesis.
#   flash_attn_top RTL defaults are the synthesis-friendly production config:
#     STATIC_SCALE_MODE = 1
#     STATIC_SCALE_Q8_8 = 32
#     ENABLE_DROPOUT   = 0
#   The script checks those defaults before elaboration so an old RTL checkout
#   does not accidentally synthesize the slower runtime-scale/dropout path.

set DESIGN flash_attn_top

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set ROOT_DIR   [file normalize [file join $SCRIPT_DIR ".."]]
set RPT_DIR    [file join $SCRIPT_DIR reports]
set OUT_DIR    [file join $SCRIPT_DIR out]
set LOG_DIR    [file join $SCRIPT_DIR logs]

file mkdir $RPT_DIR
file mkdir $OUT_DIR
file mkdir $LOG_DIR

set FILELIST [file join $SCRIPT_DIR filelist.f]
set SDC_FILE [file join $SCRIPT_DIR constraints.sdc]
set TOP_FILE [file join $ROOT_DIR rtl top flash_attn_top.sv]

set PDK_ROOT /home/share/pdk
set STD_CELL sky130_fd_sc_hs
set LIB_FILE [file join $PDK_ROOT sky130A libs.ref $STD_CELL lib sky130_fd_sc_hs__tt_025C_1v80.lib]

set TECH_LEF [file join $PDK_ROOT sky130A libs.ref $STD_CELL techlef sky130_fd_sc_hs__nom.tlef]
set CELL_LEF [file join $PDK_ROOT sky130A libs.ref $STD_CELL lef sky130_fd_sc_hs.lef]

puts "============================================================"
puts "DESIGN     = $DESIGN"
puts "ROOT_DIR   = $ROOT_DIR"
puts "FILELIST   = $FILELIST"
puts "SDC_FILE   = $SDC_FILE"
puts "LIB_FILE   = $LIB_FILE"
puts "TECH_LEF   = $TECH_LEF"
puts "CELL_LEF   = $CELL_LEF"
puts "============================================================"

foreach required [list $FILELIST $SDC_FILE $TOP_FILE $LIB_FILE] {
    if {![file exists $required]} {
        puts "ERROR: Required file not found: $required"
        exit 1
    }
}

set top_fp [open $TOP_FILE r]
set top_text [read $top_fp]
close $top_fp

set param_ok 1
foreach {param pattern} {
    STATIC_SCALE_MODE "parameter int STATIC_SCALE_MODE = 1"
    STATIC_SCALE_Q8_8 "parameter int STATIC_SCALE_Q8_8 = 32"
    ENABLE_DROPOUT "parameter int ENABLE_DROPOUT    = 0"
} {
    if {[string first $pattern $top_text] < 0} {
        puts "ERROR: Expected synthesis default not found for $param."
        puts "ERROR: Pull the latest bonus branch or set the RTL default before synthesis."
        set param_ok 0
    }
}
if {!$param_ok} {
    exit 1
}

puts "INFO: Using RTL-default synthesis-friendly parameters:"
puts "INFO:   STATIC_SCALE_MODE=1"
puts "INFO:   STATIC_SCALE_Q8_8=32"
puts "INFO:   ENABLE_DROPOUT=0"

cd $ROOT_DIR

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

set LEF_FILES {}
foreach lef [list $TECH_LEF $CELL_LEF] {
    if {[file exists $lef]} {
        lappend LEF_FILES $lef
    } else {
        puts "WARNING: LEF not found, skip: $lef"
    }
}
if {[llength $LEF_FILES] > 0} {
    puts "INFO: Trying to read LEF files: $LEF_FILES"
    if {[catch {read_physical -lef $LEF_FILES} PHYS_MSG]} {
        puts "WARNING: read_physical failed or is unsupported. Continue without physical LEF."
        puts "WARNING: $PHYS_MSG"
    }
}

read_hdl -sv -f $FILELIST
elaborate $DESIGN

check_design > [file join $RPT_DIR 00_check_design_pre_synth.rpt]

read_sdc $SDC_FILE
check_timing > [file join $RPT_DIR 01_check_timing_pre_synth.rpt]

set_db syn_generic_effort high
set_db syn_map_effort     high
set_db syn_opt_effort     high

syn_generic
syn_map
syn_opt

report_qor    > [file join $RPT_DIR 10_qor.rpt]
report_area   > [file join $RPT_DIR 20_area.rpt]
report_timing > [file join $RPT_DIR 30_timing.rpt]
report_power  > [file join $RPT_DIR 40_power.rpt]
check_design  > [file join $RPT_DIR 50_check_design_post_synth.rpt]
check_timing  > [file join $RPT_DIR 60_check_timing_post_synth.rpt]

write_hdl > [file join $OUT_DIR ${DESIGN}_mapped.v]
write_sdc > [file join $OUT_DIR ${DESIGN}_mapped.sdc]

if {[catch {write_sdf > [file join $OUT_DIR ${DESIGN}.sdf]} SDF_MSG]} {
    puts "WARNING: write_sdf failed. Continue."
    puts "WARNING: $SDF_MSG"
}

write_db -all [file join $OUT_DIR ${DESIGN}.db]

puts "============================================================"
puts "Genus synthesis finished."
puts "Reports: $RPT_DIR"
puts "Outputs: $OUT_DIR"
puts "============================================================"

exit
