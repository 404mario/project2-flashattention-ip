import argparse
import math
from pathlib import Path

import numpy as np


EXP_LUT_Q08 = np.array(
    [
        256, 226, 199, 176, 155, 137, 121, 107,
        94, 83, 73, 65, 57, 50, 44, 39,
        35, 31, 27, 24, 21, 19, 16, 14,
        13, 11, 10, 9, 8, 7, 6, 5,
        5, 4, 4, 3, 3, 3, 2, 2,
        2, 2, 1, 1, 1, 1, 1, 1,
        1, 1,
    ]
    + [0] * 14,
    dtype=np.int64,
)


def to_hex16(value):
    return f"{int(value) & 0xFFFF:04x}"


def read_hex16_matrix(path, rows, cols):
    values = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            text = line.strip()
            if not text:
                continue
            raw = int(text, 16)
            if raw >= 0x8000:
                raw -= 0x10000
            values.append(raw)

    expected = rows * cols
    if len(values) != expected:
        raise ValueError(f"{path}: got {len(values)} values, expected {expected}")

    return np.asarray(values, dtype=np.int64).reshape(rows, cols)


def q_value(row, col):
    return ((((row * 3 + col * 5 + 7) % 17) - 8) << 4)


def k_value(row, col):
    return ((((row * 5 + col * 7 + 11) % 19) - 9) << 4)


def v_value(row, col):
    return ((((row * 7 + col * 3 + 5) % 23) - 11) << 3)


def exp_approx_q08(delta_q88):
    if delta_q88 >= 0:
        return 256
    lut_index = ((-int(delta_q88)) + 16) >> 5
    if lut_index >= 64:
        return 0
    return int(EXP_LUT_Q08[lut_index])


def trunc_div_signed(numer, denom):
    if denom == 0:
        return 0
    sign = 1 if (numer >= 0) == (denom >= 0) else -1
    return sign * (abs(int(numer)) // abs(int(denom)))


def saturate_i16(value):
    return min(max(int(value), -32768), 32767)


def build_inputs(s_len, d_model):
    q = np.zeros((s_len, d_model), dtype=np.int64)
    k = np.zeros((s_len, d_model), dtype=np.int64)
    v = np.zeros((s_len, d_model), dtype=np.int64)
    for r in range(s_len):
        for c in range(d_model):
            q[r, c] = q_value(r, c)
            k[r, c] = k_value(r, c)
            v[r, c] = v_value(r, c)
    return q, k, v


def load_inputs(args):
    vector_paths = [args.q_hex, args.k_hex, args.v_hex]
    if any(vector_paths) and not all(vector_paths):
        raise ValueError("--q-hex, --k-hex, and --v-hex must be provided together")

    if all(vector_paths):
        q = read_hex16_matrix(Path(args.q_hex), args.s_len, args.d_model)
        k = read_hex16_matrix(Path(args.k_hex), args.s_len, args.d_model)
        v = read_hex16_matrix(Path(args.v_hex), args.s_len, args.d_model)
        return q, k, v

    return build_inputs(args.s_len, args.d_model)


def rtl_expected(q, k, v, bk, scale_q8_8, causal=True):
    s_len, d_model = q.shape
    out = np.zeros((s_len, d_model), dtype=np.int64)

    for row in range(s_len):
        m_state = 0
        l_state = 0
        acc = np.zeros(d_model, dtype=np.int64)

        for kv_start in range(0, s_len, bk):
            kv_len = min(bk, s_len - kv_start)
            for offset in range(kv_len):
                key = kv_start + offset
                if causal and key > row:
                    continue

                dot = int(np.dot(q[row], k[key]))
                score = ((dot >> 8) * int(scale_q8_8)) >> 8

                if l_state == 0:
                    old_scale = 0
                    new_weight = 256
                    m_state = score
                    l_state = 256
                elif score > m_state:
                    old_scale = exp_approx_q08(m_state - score)
                    new_weight = 256
                    l_state = ((l_state * old_scale) >> 8) + new_weight
                    m_state = score
                else:
                    old_scale = 256
                    new_weight = exp_approx_q08(score - m_state)
                    l_state = ((l_state * old_scale) >> 8) + new_weight

                acc = ((acc * old_scale) >> 8) + (new_weight * v[key])

        for d in range(d_model):
            out[row, d] = saturate_i16(trunc_div_signed(int(acc[d]), int(l_state)))

    return out


def fp32_expected(q, k, v, causal=True):
    qf = q.astype(np.float64) / 256.0
    kf = k.astype(np.float64) / 256.0
    vf = v.astype(np.float64) / 256.0
    s_len, d_model = q.shape
    scores = (qf @ kf.T) / math.sqrt(float(d_model))
    if causal:
        mask = np.triu(np.ones((s_len, s_len), dtype=bool), k=1)
        scores = np.where(mask, -1.0e30, scores)
    scores = scores - np.max(scores, axis=1, keepdims=True)
    probs = np.exp(scores)
    probs = probs / np.sum(probs, axis=1, keepdims=True)
    outf = probs @ vf
    out_int = np.rint(outf * 256.0).astype(np.int64)
    return np.clip(out_int, -32768, 32767)


def report(name, got, expected):
    diff = got - expected
    abs_diff = np.abs(diff)
    worst_flat = int(np.argmax(abs_diff))
    worst = np.unravel_index(worst_flat, abs_diff.shape)
    max_int = int(abs_diff[worst])
    mae_int = float(np.mean(abs_diff))
    print(f"{name}:")
    print(f"  mean_abs_int = {mae_int:.6f}")
    print(f"  max_abs_int  = {max_int}")
    print(f"  MAE          = {mae_int / 256.0:.6f}")
    print(f"  MaxE         = {max_int / 256.0:.6f}")
    print(
        "  worst_idx    = "
        f"({int(worst[0])}, {int(worst[1])}) "
        f"got={int(got[worst])} hex={to_hex16(got[worst])} "
        f"expected={int(expected[worst])} hex={to_hex16(expected[worst])}"
    )
    return max_int


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hex", required=True, help="RTL output hex dump from tb_flash_attn_top_e2e_smoke")
    parser.add_argument("--s-len", type=int, required=True)
    parser.add_argument("--d-model", type=int, required=True)
    parser.add_argument("--bk", type=int, required=True)
    parser.add_argument("--scale-q8-8", type=int, required=True)
    parser.add_argument("--noncausal", action="store_true")
    parser.add_argument("--check-fp32", action="store_true")
    parser.add_argument("--q-hex", help="Optional Q input vector hex file")
    parser.add_argument("--k-hex", help="Optional K input vector hex file")
    parser.add_argument("--v-hex", help="Optional V input vector hex file")
    parser.add_argument("--golden-hex", help="Optional supplied output golden hex file")
    args = parser.parse_args()

    hex_path = Path(args.hex)
    got = read_hex16_matrix(hex_path, args.s_len, args.d_model)
    q, k, v = load_inputs(args)
    causal = not args.noncausal

    expected_rtl = rtl_expected(q, k, v, args.bk, args.scale_q8_8, causal=causal)
    max_int = report("RTL output vs RTL-Q0.8 bitexact mirror", got, expected_rtl)
    if max_int != 0:
        raise SystemExit(1)

    if args.golden_hex:
        supplied_golden = read_hex16_matrix(Path(args.golden_hex), args.s_len, args.d_model)
        report("RTL output vs supplied golden_o.hex", got, supplied_golden)

    if args.check_fp32:
        expected_fp32 = fp32_expected(q, k, v, causal=causal)
        report("RTL output vs FP32 softmax golden", got, expected_fp32)


if __name__ == "__main__":
    main()
