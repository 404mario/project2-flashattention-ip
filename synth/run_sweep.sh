#!/bin/tcsh
#============================================================================
# run_sweep.sh - synth the SAME netlist at several clock periods to find the
# fastest clean point (fmax). Each period writes its own reports dir:
#   synth/reports_ispatial_<P>ns/ , synth/out_ispatial_<P>ns/
#
# Usage (from package root, where synth/ lives):
#   ./synth/run_sweep.sh                # default sweep: 8 6 5 ns
#   ./synth/run_sweep.sh 8 7 6 5 4.5    # custom list
#
# Auto-locates the package root and loads Genus like run_genus.sh.
#============================================================================
set SCRIPT_PATH = `readlink -f $0`
set SYNTH_DIR   = `dirname $SCRIPT_PATH`
cd $SYNTH_DIR/..
echo "Project root: `pwd`"

module load ddi/251/25.12.000

set PERIODS = ($argv)
if ("$PERIODS" == "") set PERIODS = (8.0 6.0 5.0)

foreach P ($PERIODS)
    echo "============================================================"
    echo "  SWEEP: clock period = $P ns"
    echo "============================================================"
    setenv CLK_PERIOD_NS $P
    genus -f synth/genus_ispatial.tcl |& tee synth/logs/genus_${P}ns.log
end

echo ""
echo "==================== SWEEP SUMMARY ===================="
foreach P ($PERIODS)
    set qor = synth/reports_ispatial_${P}ns/10_qor.rpt
    if ( -e $qor ) then
        echo "--- $P ns ---"
        grep -E "clk|Violating|Cell Area|Slack" $qor | head -6
    else
        echo "--- $P ns : NO QOR (run failed?) ---"
    endif
end
echo "======================================================="
