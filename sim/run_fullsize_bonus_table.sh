#!/usr/bin/env bash
# Full-size (S=256,D=64) bonus performance+correctness table on the PREFETCH tree.
# For each config: build with the bonus parameter, run random vectors, capture the
# TB self-check PASS line (cycles / wait / rd_bytes / wr_bytes). Default config also
# compared vs golden_o.hex (MAE/MaxE) since it's full-causal == golden.
# Windowed/padded/dropout outputs legitimately differ from the full-causal golden,
# so their correctness is the TB's bonus-aware self-check (PASS), and the metric of
# interest is performance (cycles/bandwidth).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
B="$ROOT/sim_build"; mkdir -p "$B"
VEC="$ROOT/tb/vectors"
mapfile -t RTL < <(grep -vE '^\s*(\+incdir|#|//|$)' synth/filelist.f | sed "s#^#$ROOT/#")
TB="$ROOT/tb/sv/tb_flash_attn_top_e2e_smoke.sv"
RES="$ROOT/reports/v2_logs/fullsize_bonus_table.txt"
mkdir -p "$ROOT/reports/v2_logs"; : > "$RES"

run() {  # name  extra_params...
  local name="$1"; shift
  local out="$B/fs_${name}.vvp" hex="$B/fs_${name}_o.hex" log="$B/fs_${name}.log"
  iverilog -g2012 -I tb/sv -s tb_flash_attn_top_e2e_smoke -o "$out" \
    -P tb_flash_attn_top_e2e_smoke.S_LEN=256 -P tb_flash_attn_top_e2e_smoke.D_MODEL=64 \
    -P tb_flash_attn_top_e2e_smoke.BK=16 -P tb_flash_attn_top_e2e_smoke.BQ=16 \
    -P tb_flash_attn_top_e2e_smoke.SOFTMAX_FRAC=16 -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8=32 \
    -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT=0 \
    -P tb_flash_attn_top_e2e_smoke.TIMEOUT_CYCLES=4000000 \
    -P tb_flash_attn_top_e2e_smoke.MAX_CYCLES=300000 \
    -P tb_flash_attn_top_e2e_smoke.PROGRESS_EVERY=100000 \
    "$@" "${RTL[@]}" "$TB" 2>/dev/null
  vvp "$out" +USE_VECTOR_FILES=1 +Q_HEX="$VEC/input_q.hex" +K_HEX="$VEC/input_k.hex" \
      +V_HEX="$VEC/input_v.hex" +OUT_HEX="$hex" >"$log" 2>&1
  local pass; pass=$(grep -iE "PASS S=256|FAIL" "$log" | tail -1)
  local cmp=""
  if [[ "$name" == "default" || "$name" == "window_W256" ]]; then
    cmp=$(python model/compare_hex.py "$hex" "$VEC/golden_o.hex" 2>/dev/null | grep -iE "MAE|MaxE|PASS|FAIL" | tr '\n' ' ')
  fi
  echo "[$name] $pass" | tee -a "$RES"
  [[ -n "$cmp" ]] && echo "        vs golden_o: $cmp" | tee -a "$RES"
}

echo "==== FULL-SIZE bonus table (prefetch tree) ====" | tee -a "$RES"
run default                                                                   # == prefetch baseline
run window_W256  -P tb_flash_attn_top_e2e_smoke.WINDOW_LEN=256                 # >=S == full causal
run window_W128  -P tb_flash_attn_top_e2e_smoke.WINDOW_LEN=128
run window_W64   -P tb_flash_attn_top_e2e_smoke.WINDOW_LEN=64
run padding_V128 -P tb_flash_attn_top_e2e_smoke.VALID_LEN=128
run padding_V64  -P tb_flash_attn_top_e2e_smoke.VALID_LEN=64
echo "==== done ====" | tee -a "$RES"
