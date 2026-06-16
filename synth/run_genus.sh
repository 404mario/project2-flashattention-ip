#!/bin/tcsh
#============================================================================
# run_genus.sh - one-command Genus iSpatial synthesis (correct physical flow).
# Equivalent to the manual steps:  module load ddi/251/25.12.000
#                                   genus -f synth/genus_ispatial.tcl
# Auto-locates the package root, so it works from anywhere.
#============================================================================
set SCRIPT_PATH = `readlink -f $0`
set SYNTH_DIR   = `dirname $SCRIPT_PATH`
cd $SYNTH_DIR/..
echo "Project root: `pwd`"

module load ddi/251/25.12.000

mkdir -p synth/logs

echo "Using Genus:"
which genus
genus -version

# IMPORTANT: use the iSpatial (physical) flow -> real PPA + the TUI-234 ungroup
# fix live in genus_ispatial.tcl. genus.tcl is the older logical-only flow and
# is NOT what we submit/measure with.
echo "Start Genus iSpatial synthesis (5ns default; CLK_PERIOD_NS to override)..."
genus -f synth/genus_ispatial.tcl |& tee synth/logs/genus.log

echo "Done. Reports: synth/reports_ispatial_<period>ns/  (see 10_qor.rpt)"
