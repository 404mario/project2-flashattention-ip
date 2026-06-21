#!/usr/bin/env python3
"""Bonus #5 (其他定点格式 Q6.10/Q4.12) FP32-error evidence driver.

Reuses check_top_e2e_output.py's build_inputs / fp32_expected / report so the inputs
are AMPLITUDE-MATCHED to the chosen frac_w (the reason bonus-v2 couldn't do this: no
numpy in that env). Reports RTL-vs-FP32 MAE/MaxE per fixed-point format WITHOUT the
strict 1-LSB self-mirror gate (which is a tolerance-free self-consistency check, not
the accuracy metric the rubric asks for: "给误差与性能对比").

Usage: fixedfmt_fp32_eval.py --hex o.hex --s-len S --d-model D --frac-w F --scale-q8-8 SC
"""
import argparse, sys
from pathlib import Path
import check_top_e2e_output as C


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hex", required=True)
    ap.add_argument("--s-len", type=int, required=True)
    ap.add_argument("--d-model", type=int, required=True)
    ap.add_argument("--frac-w", type=int, required=True)
    ap.add_argument("--data-w", type=int, default=16)
    ap.add_argument("--scale-q8-8", type=int, required=True)
    ap.add_argument("--softmax-frac", type=int, default=None)
    ap.add_argument("--valid-len", type=int, default=None)
    ap.add_argument("--label", default="")
    ap.add_argument("--bf16-io", action="store_true")
    ap.add_argument("--fp8-e4m3-io", action="store_true")
    a = ap.parse_args()

    q, k, v = C.build_inputs(a.s_len, a.d_model, a.frac_w)
    # lossy I/O modes round-trip the inputs through the reduced format first
    if a.fp8_e4m3_io:
        q, k, v = (C.fp8_e4m3_roundtrip_matrix(x) for x in (q, k, v))
    elif a.bf16_io:
        q, k, v = (C.bf16_roundtrip_matrix(x) for x in (q, k, v))
    got = C.read_hex16_matrix(Path(a.hex), a.s_len, a.d_model)
    exp_fp32 = C.fp32_expected(q, k, v, causal=True, valid_len=a.valid_len,
                               frac_w=a.frac_w, data_w=a.data_w)
    print(f"=== fixed-point format eval: {a.label or ('Q%d.%d' % (a.data_w - a.frac_w, a.frac_w))} "
          f"(DATA_W={a.data_w} FRAC_W={a.frac_w}) S={a.s_len} D={a.d_model} ===")
    mae, maxe = C.report("RTL output vs FP32 softmax golden", got, exp_fp32, frac_w=a.frac_w)
    tag = a.label or ("fp8" if a.fp8_e4m3_io else "bf16" if a.bf16_io else f"Q{a.data_w - a.frac_w}.{a.frac_w}")
    print(f"RESULT fmt={tag} MAE={mae:.6f} MaxE={maxe:.6f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
