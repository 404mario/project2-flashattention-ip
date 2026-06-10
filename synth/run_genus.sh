#!/bin/tcsh

# Run from project root: /home/junchi/bonus_5.27
# This server uses csh/tcsh-style module commands.

module load ddi/251/25.12.000

mkdir -p synth/logs
mkdir -p synth/reports
mkdir -p synth/out

echo "Using Genus:"
which genus
genus -version

echo "Start Genus synthesis..."
genus -f synth/genus.tcl |& tee synth/logs/genus.log

echo "Done. Check reports under synth/reports/"
