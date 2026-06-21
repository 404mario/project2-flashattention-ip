#!/usr/bin/env bash
# Bonus #1 (complete): hardware floating-point softmax/exp/reciprocal units.
# Unit-tests the three new HW float blocks vs real-math references (numpy-free).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
B="$ROOT/sim_build"; mkdir -p "$B"; fails=0

run() { # name  topmodule  srcs...
  local name="$1" top="$2"; shift 2
  iverilog -g2012 -s "$top" -o "$B/$name.vvp" "$@" 2>/dev/null
  vvp "$B/$name.vvp" 2>&1 | grep -iE "PASS|FAIL|max_abs|max_rel" | tee "$B/$name.log"
  grep -q "PASS" "$B/$name.log" || fails=$((fails+1))
}

echo "=== #1 unit: hardware exp ==="
run fp_exp   tb_fp_exp          rtl/core/fp_exp.sv tb/sv/tb_fp_exp.sv
echo "=== #1 unit: hardware reciprocal ==="
run fp_recip tb_fp_recip        rtl/core/fp_recip.sv tb/sv/tb_fp_recip.sv
echo "=== #1 unit: hardware FP softmax (exp+recip composed) ==="
run fp_sm    tb_fp_softmax_unit rtl/core/fp_exp.sv rtl/core/fp_recip.sv rtl/core/fp_softmax_unit.sv tb/sv/tb_fp_softmax_unit.sv

echo ""
echo "fp-softmax smoke: $([ $fails -eq 0 ] && echo 'PASS (hardware exp + reciprocal + softmax verified vs real math)' || echo "FAIL ($fails)")"
exit $fails
