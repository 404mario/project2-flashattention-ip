#!/usr/bin/env bash
# ORIGINAL bonus: sliding-window / local attention (WINDOW_LEN).
# Verifies RTL matches the windowed reference at several window sizes, and that
# WINDOW_LEN>=S is identical to full causal (no regression). Uses the SV self-check.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; BUILD="$ROOT/sim_build"; mkdir -p "$BUILD"
SRC=$(sed -n '/^SOURCES=(/,/^)/p' "$ROOT/sim/run_bonus_sequence_smoke.sh" | grep -oE '\$ROOT/[^"]+\.sv' | sed "s#\$ROOT#$ROOT#" | awk '!seen[$0]++')
pass=0; fail=0
for W in 16 8 4 1; do
  out="$BUILD/win_${W}.vvp"
  iverilog -g2012 -I "$ROOT/tb/sv" -s tb_flash_attn_top_e2e_smoke \
    -P tb_flash_attn_top_e2e_smoke.S_LEN=16 -P tb_flash_attn_top_e2e_smoke.D_MODEL=8 \
    -P tb_flash_attn_top_e2e_smoke.BK=4 -P tb_flash_attn_top_e2e_smoke.BQ=4 \
    -P tb_flash_attn_top_e2e_smoke.SOFTMAX_FRAC=16 -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8=91 \
    -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT=0 -P tb_flash_attn_top_e2e_smoke.WINDOW_LEN=$W \
    -P tb_flash_attn_top_e2e_smoke.TIMEOUT_CYCLES=200000 -o "$out" $SRC 2>/dev/null
  line=$(vvp "$out" +OUT_HEX="$BUILD/win_${W}_o.hex" 2>/dev/null | grep -oE "tb_flash_attn_top_e2e_smoke (PASS|FAIL)[^\"]*" | head -1)
  echo "WINDOW_LEN=$W : $line"
  echo "$line" | grep -q PASS && pass=$((pass+1)) || fail=$((fail+1))
done
echo "window smoke: $pass PASS / $fail FAIL"
[ "$fail" -eq 0 ] || exit 1
