#!/usr/bin/env bash
# Bonus #5 — 其他定点格式 (Q6.10 / Q4.12) 误差与性能对比 smoke.
# Builds the e2e top at each fixed-point format (DATA_W=16, varying FRAC_W), runs RTL,
# checks RTL PASS + (NEW, numpy) reports RTL-vs-FP32 MAE/MaxE on AMPLITUDE-MATCHED inputs.
# Reference Q8.8 (FRAC_W=8) included so the format error comparison is apples-to-apples.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/sim_build"
mkdir -p "$BUILD"
PYTHON_BIN="${PYTHON_BIN:-python3}"

SOURCES=$(grep -vE '^\s*#|^\s*$|incdir' "$ROOT/synth/filelist.f" | sed "s#^#$ROOT/#" | grep -v 'tb_flash_attn_top_e2e_smoke' | tr '\n' ' ')
TB="$ROOT/tb/sv/tb_flash_attn_top_e2e_smoke.sv"

# fmt_case: label data_w frac_w softmax_frac scale s_len d_model bk bq timeout maxcyc
fmt_case() {
  local label=$1 dw=$2 fw=$3 sf=$4 sc=$5 s=$6 d=$7 bk=$8 bq=$9 to=${10} mx=${11}
  local out="$BUILD/fmt_${label}.vvp" hex="$BUILD/fmt_${label}_o.hex"
  iverilog -g2012 -I "$ROOT/tb/sv" -I "$ROOT/rtl/include" -s tb_flash_attn_top_e2e_smoke \
    -P tb_flash_attn_top_e2e_smoke.S_LEN=$s -P tb_flash_attn_top_e2e_smoke.D_MODEL=$d \
    -P tb_flash_attn_top_e2e_smoke.BK=$bk -P tb_flash_attn_top_e2e_smoke.BQ=$bq \
    -P tb_flash_attn_top_e2e_smoke.DATA_W=$dw -P tb_flash_attn_top_e2e_smoke.FRAC_W=$fw \
    -P tb_flash_attn_top_e2e_smoke.SOFTMAX_FRAC=$sf -P tb_flash_attn_top_e2e_smoke.VALID_LEN=$s \
    -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8=$sc -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT=0 \
    -P tb_flash_attn_top_e2e_smoke.TIMEOUT_CYCLES=$to -P tb_flash_attn_top_e2e_smoke.MAX_CYCLES=$mx \
    -o "$out" $SOURCES "$TB" 2>"$BUILD/fmt_${label}_build.err"
  if [ ! -f "$out" ]; then echo "[$label] COMPILE FAIL"; grep -iE 'error' "$BUILD/fmt_${label}_build.err"|grep -vE 'always_ff|constant'|head; return 1; fi
  vvp "$out" "+OUT_HEX=$hex" > "$BUILD/fmt_${label}.log" 2>&1
  local pass; pass=$(grep -oE 'tb_flash_attn_top_e2e_smoke (PASS|FAIL)[^"]*' "$BUILD/fmt_${label}.log"|head -1)
  local cyc; cyc=$(grep -oE 'cycles=[0-9]+' "$BUILD/fmt_${label}.log"|head -1)
  echo "[$label] RTL: $pass"
  "$PYTHON_BIN" "$ROOT/model/fixedfmt_fp32_eval.py" --hex "$hex" --s-len $s --d-model $d \
    --frac-w $fw --data-w $dw --scale-q8-8 $sc --softmax-frac $sf --valid-len $s --label "$label" 2>&1 | grep -E 'RESULT'
}

echo "######## Bonus #5: fixed-point format error/perf comparison (numpy FP32 golden) ########"
# Q8.8 reference, Q6.10, Q4.12 — at S=32/D=16 (amplitude auto-matched per frac_w by build_inputs)
fmt_case "Q8.8_s32"  16 8  16 64 32 16 8 8 800000 120000
fmt_case "Q6.10_s32" 16 10 20 64 32 16 8 8 800000 120000
fmt_case "Q4.12_s32" 16 12 24 64 32 16 8 8 800000 120000
echo "######## done ########"
