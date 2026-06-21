#!/usr/bin/env bash
# Bonus #7 (complete): FA-3 per-block INT8 block-quantization datapath.
#  (1) unit test: block_quant_dot bit-exact vs integer block-quant spec (+ approx err).
#  (2) integrated: top E2E with BLOCK_QUANT_MODE=1 (per-block int8 QK^T dot), SV self-check.
# numpy-free.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
B="$ROOT/sim_build"; mkdir -p "$B"
mapfile -t RTL < <(grep -vE '^\s*(\+incdir|#|//|$)' synth/filelist.f | sed "s#^#$ROOT/#")
TB="$ROOT/tb/sv/tb_flash_attn_top_e2e_smoke.sv"
fails=0

echo "=== #7 unit: block_quant_dot vs integer block-quant spec ==="
iverilog -g2012 -s tb_block_quant_dot -o "$B/bq_unit.vvp" \
  rtl/core/block_quant_dot.sv tb/sv/tb_block_quant_dot.sv 2>/dev/null
vvp "$B/bq_unit.vvp" 2>&1 | grep -iE "PASS|FAIL|mean_rel" | tee "$B/bq_unit.log"
grep -q "PASS block_quant_dot" "$B/bq_unit.log" || fails=$((fails+1))

echo "=== #7 integrated: top E2E BLOCK_QUANT_MODE=1 (S=8) ==="
iverilog -g2012 -I tb/sv -s tb_flash_attn_top_e2e_smoke -o "$B/bq_e2e.vvp" \
  -P tb_flash_attn_top_e2e_smoke.S_LEN=8 -P tb_flash_attn_top_e2e_smoke.D_MODEL=8 \
  -P tb_flash_attn_top_e2e_smoke.BK=4 -P tb_flash_attn_top_e2e_smoke.BQ=4 \
  -P tb_flash_attn_top_e2e_smoke.SOFTMAX_FRAC=16 -P tb_flash_attn_top_e2e_smoke.SCALE_Q8_8=91 \
  -P tb_flash_attn_top_e2e_smoke.CHECK_BITEXACT=0 -P tb_flash_attn_top_e2e_smoke.BLOCK_QUANT_MODE=1 \
  "${RTL[@]}" "$TB" 2>/dev/null
vvp "$B/bq_e2e.vvp" +OUT_HEX="$B/bq_e2e_o.hex" 2>&1 | grep -iE "PASS S=|FAIL|cycles=" | tee "$B/bq_e2e.log"
grep -q "PASS S=" "$B/bq_e2e.log" || fails=$((fails+1))

echo ""
echo "block-quant smoke: $([ $fails -eq 0 ] && echo 'PASS (unit bit-exact + integrated E2E)' || echo "FAIL ($fails)")"
echo "Note: 误差收益 (block vs naive-global int8) 见 model/model_fa3_blockquant_golden.py："
echo "  异构块数据 MAE ×2.8 / MaxE ×4.5；赛题均匀大幅度向量上无收益(数据特性)。"
exit $fails
