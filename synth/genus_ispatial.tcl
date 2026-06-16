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

# --- TUI-234 fix: dissolve ONLY the dma_controller boundary --------------------
# The iSpatial "advanced structuring" pass inside `syn_generic -physical` runs an
# internal `group` over combinational fan-in cones. dma_controller still contains
# dynamic-index array accesses (beat-indexed q/k/v/o buffers) that Genus realizes
# as CDN_PAS_SKIP_MUX; when those straddle the dma<->core hierarchy boundary the
# advstr `group` fails with TUI-234 (observed in genus.log1: u_flash_core/u_combine
# skip-muxes group fine; only u_dma_controller's cross-boundary one fails).
# Fix = ungroup ONLY u_dma_controller (merge its logic into the top) so there is
# no dma boundary for advstr to straddle. This is exactly what the genuine 8ns
# baseline run used (it synthesized clean in ~7.8h) -- it dissolves ONE small
# block, NOT the whole design, so it does NOT recreate the monolithic-flatten
# slowdown. flash_core and all other modules keep their hierarchy.
puts "INFO: ungrouping u_dma_controller (dissolve its boundary to avoid advstr TUI-234)..."
foreach_in_collection h [get_db hinsts *u_dma_controller*] {
    set_db $h .ungroup_ok true
    set_db $h .module.ungroup_ok true
    catch { ungroup -simple $h }
}

syn_generic
predict_floorplan

# --- TUI-234 fix #2: the REAL crash cause (genus (1).log1, 2026-06-16) ----------
# The dma-only ungroup above is necessary but NOT sufficient. The run still died
# with [TUI-234] [group] -> [SYNTH-3] during the SECOND generic pass
# (`syn_generic -physical`), and NOT on dma at all -- on flash_core's causal-skip
# mux:
#   hinst flash_attn_top/u_flash_core/CDN_PAS_SKIP_MUX_0i  (kept by advstr in
#   pass 1) vs the offending nested cell
#   .../CDN_PAS_SKIP_MUX_0i/CDN_PAS_SKIP_MUX_0i/g100416     (created in pass 2).
#
# Mechanism: the advanced-structuring (CAS) pass runs ONCE per generic call.
#   pass 1 `syn_generic`           -> "Identified hierarchy for CAS:
#                                      .../CDN_PAS_SKIP_MUX_0i" and PRESERVES it
#                                      (advstr_keep_structure=1, advstr_cas=1).
#   pass 2 `syn_generic -physical` -> advstr re-analyzes the SAME cone, creates a
#                                      same-named CDN_PAS_SKIP_MUX_0i NESTED inside
#                                      the preserved one, then `group [all_fanin]`
#                                      straddles that nested boundary -> TUI-234.
# The dma ungroup can't help because USE_CAUSAL_SKIP=1 puts these skip muxes
# INSIDE u_flash_core (which we deliberately keep hierarchical).
#
# Fix: between the two generic passes, dissolve every advstr-created
# CDN_PAS_*_MUX group so the physical advstr pass starts from a FLAT fan-in cone
# (no preserved same-named hierarchy to nest into / straddle). Genus already
# ungroups most of these at ratio=1.0 on its own, so dissolving the survivors is
# behaviorally neutral -- it only removes the tool-made mux wrapper, not any RTL.
puts "INFO: dissolving advstr CDN_PAS_*_MUX groups before physical generic (TUI-234 #2)..."
foreach_in_collection h [get_db hinsts -if {.name=~"*CDN_PAS_SKIP_MUX*" || .name=~"*CDN_PAS_CONNECTED_MUX*"}] {
    catch { set_db $h .ungroup_ok true }
    catch { set_db $h .module.ungroup_ok true }
    catch { set_db $h .module.advstr_keep_structure 0 }
    catch { ungroup -simple $h }
}

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
