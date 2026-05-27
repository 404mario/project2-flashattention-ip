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


EXP_LUT_Q16 = np.array(
    [
        65536, 57835, 51039, 45042, 39750, 35079, 30957, 27319,
        24109, 21276, 18776, 16570, 14623, 12905, 11388, 10050,
        8869, 7827, 6907, 6096, 5380, 4747, 4190, 3697,
        3263, 2879, 2541, 2243, 1979, 1746, 1541, 1360,
        1200, 1059, 935, 825, 728, 642, 567, 500,
        442, 390, 344, 303, 268, 236, 209, 184,
        162, 143, 127, 112, 99, 87, 77, 68,
        60, 53, 47, 41, 36, 32, 28, 25,
    ],
    dtype=np.int64,
)

RECIP_LUT_Q20 = np.array(
    [
        16384, 16132, 15888, 15650, 15420, 15197, 14980, 14769,
        14564, 14364, 14170, 13981, 13797, 13618, 13443, 13273,
        13107, 12945, 12788, 12633, 12483, 12336, 12193, 12053,
        11916, 11782, 11651, 11523, 11398, 11275, 11155, 11038,
        10923, 10810, 10700, 10592, 10486, 10382, 10280, 10180,
        10082, 9986, 9892, 9800, 9709, 9620, 9533, 9447,
        9362, 9279, 9198, 9118, 9039, 8962, 8886, 8812,
        8738, 8666, 8595, 8525, 8456, 8389, 8322, 8257, 8192,
    ],
    dtype=np.int64,
)


def to_hex16(value):
    return f"{int(value) & 0xFFFF:04x}"


def read_hex16_matrix(path, rows, cols, offset_values=0):
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
    offset_values = int(offset_values)
    end = offset_values + expected
    if offset_values < 0:
        raise ValueError(f"{path}: offset must be non-negative")
    if len(values) < end:
        raise ValueError(f"{path}: got {len(values)} values, need {end} for offset {offset_values}")

    return np.asarray(values[offset_values:end], dtype=np.int64).reshape(rows, cols)


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


def exp_approx_interp(delta, score_frac, weight_frac):
    one = 1 << weight_frac
    if delta >= 0:
        return one

    shift = score_frac - 3
    if shift <= 0:
        raise ValueError(f"score_frac={score_frac} is too small for 1/8-step exp LUT")

    abs_delta = -int(delta)
    max_delta = (len(EXP_LUT_Q16) - 1) << shift
    if abs_delta > max_delta:
        return 0

    if weight_frac == 16:
        lut = EXP_LUT_Q16
    elif weight_frac < 16:
        round_value = 1 << (16 - weight_frac - 1)
        lut = (EXP_LUT_Q16 + round_value) >> (16 - weight_frac)
    else:
        lut = EXP_LUT_Q16 << (weight_frac - 16)

    idx = abs_delta >> shift
    rem = abs_delta - (idx << shift)
    if idx == len(lut) - 1:
        return int(lut[idx])

    y0 = int(lut[idx])
    y1 = int(lut[idx + 1])
    return y0 + (((y1 - y0) * rem + (1 << (shift - 1))) >> shift)


def trunc_div_signed(numer, denom):
    if denom == 0:
        return 0
    sign = 1 if (numer >= 0) == (denom >= 0) else -1
    return sign * (abs(int(numer)) // abs(int(denom)))


def saturate_i16(value):
    return min(max(int(value), -32768), 32767)


def normalize_approx(acc, denom):
    if denom == 0:
        return 0

    lut_bits = 6
    interp_bits = 8
    recip_frac = 20
    neg = acc < 0
    abs_acc = abs(int(acc))
    lead = int(denom).bit_length() - 1
    norm_shift = lut_bits + interp_bits
    if lead >= norm_shift:
        norm_value = int(denom) >> (lead - norm_shift)
    else:
        norm_value = int(denom) << (norm_shift - lead)

    lut_index = (norm_value >> interp_bits) & ((1 << lut_bits) - 1)
    lut_frac = norm_value & ((1 << interp_bits) - 1)
    recip_base = int(RECIP_LUT_Q20[lut_index])
    recip_next = int(RECIP_LUT_Q20[lut_index + 1])
    recip_delta = (((recip_base - recip_next) * lut_frac) + (1 << (interp_bits - 1))) >> interp_bits
    recip = recip_base - recip_delta
    shift = recip_frac + lead - lut_bits
    product = abs_acc * recip
    if shift <= 0:
        quotient_abs = product
    else:
        quotient_abs = (product + (1 << (shift - 1))) >> shift

    quotient = -quotient_abs if neg else quotient_abs
    return saturate_i16(quotient)


def build_inputs(s_len, d_model, frac_w=8, task_index=0, head_index=0):
    q = np.zeros((s_len, d_model), dtype=np.int64)
    k = np.zeros((s_len, d_model), dtype=np.int64)
    v = np.zeros((s_len, d_model), dtype=np.int64)
    qk_shift = frac_w - 4
    v_shift = frac_w - 5
    q_head_shift = frac_w - 7 if frac_w > 7 else 0
    kv_head_shift = frac_w - 8 if frac_w > 8 else 0
    for r in range(s_len):
        for c in range(d_model):
            q_base = (((r * 3 + c * 5 + 7) % 17) - 8) << qk_shift
            k_base = (((r * 5 + c * 7 + 11) % 19) - 9) << qk_shift
            v_base = (((r * 7 + c * 3 + 5) % 23) - 11) << v_shift
            q[r, c] = q_base + ((int(head_index) - int(task_index)) << q_head_shift)
            k[r, c] = k_base + ((int(head_index) + int(task_index)) << kv_head_shift)
            v[r, c] = v_base + ((int(head_index) * 3 + int(task_index)) << kv_head_shift)
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

    return build_inputs(args.s_len, args.d_model, args.frac_w, args.task_index, args.head_index)


def dropout_rand16(row, key, seed):
    x = ((int(seed) & 0xFFFF) << 16) | ((int(seed) ^ 0xACE1) & 0xFFFF)
    x ^= (int(row) & 0xFFFF) << 5
    x ^= (int(row) & 0xFFFF) << 13
    x ^= (int(key) & 0xFFFF) << 3
    x ^= (int(key) & 0xFFFF) << 17
    x &= 0xFFFFFFFF
    x ^= (x << 7) & 0xFFFFFFFF
    x ^= (x >> 9)
    x &= 0xFFFFFFFF
    x ^= (x << 8) & 0xFFFFFFFF
    x &= 0xFFFFFFFF
    return ((x & 0xFFFF) ^ (x >> 16)) & 0xFFFF


def dropout_keep(row, key, enabled=False, threshold=0, seed=0xACE1):
    return (not enabled) or (dropout_rand16(row, key, seed) >= int(threshold))


def dropout_weight(weight, row, key, enabled=False, threshold=0, seed=0xACE1, scale_q8_8=256, weight_w=16):
    if not enabled:
        return int(weight)
    if not dropout_keep(row, key, enabled=True, threshold=threshold, seed=seed):
        return 0
    scaled = ((int(weight) * int(scale_q8_8)) + 128) >> 8
    max_weight = (1 << weight_w) - 1
    return min(max(scaled, 0), max_weight)


def rtl_expected(
    q,
    k,
    v,
    bk,
    scale_q8_8,
    causal=True,
    softmax_frac=8,
    valid_len=None,
    frac_w=8,
    dropout_enabled=False,
    dropout_threshold=0,
    dropout_seed=0xACE1,
    dropout_scale_q8_8=256,
):
    s_len, d_model = q.shape
    out = np.zeros((s_len, d_model), dtype=np.int64)
    weight_frac = softmax_frac
    weight_one = 1 << weight_frac
    weight_w = 18 if softmax_frac > 8 else 16
    scale_shift = (3 * frac_w) - softmax_frac
    valid_len = s_len if valid_len is None else max(0, min(int(valid_len), s_len))

    for row in range(s_len):
        if row >= valid_len:
            continue

        m_state = 0
        l_state = 0
        acc = np.zeros(d_model, dtype=np.int64)

        for kv_start in range(0, s_len, bk):
            kv_len = min(bk, s_len - kv_start)
            for offset in range(kv_len):
                key = kv_start + offset
                if key >= valid_len:
                    continue
                if causal and key > row:
                    continue

                dot = int(np.dot(q[row], k[key]))
                if softmax_frac == frac_w:
                    score = ((dot >> frac_w) * int(scale_q8_8)) >> frac_w
                else:
                    score = (dot * int(scale_q8_8)) >> scale_shift

                if l_state == 0:
                    old_scale = 0
                    new_weight = weight_one
                    m_state = score
                    l_state = weight_one
                elif score > m_state:
                    if softmax_frac == 8:
                        old_scale = exp_approx_q08(m_state - score)
                    else:
                        old_scale = exp_approx_interp(m_state - score, softmax_frac, weight_frac)
                    new_weight = weight_one
                    l_state = ((l_state * old_scale) >> weight_frac) + new_weight
                    m_state = score
                else:
                    old_scale = weight_one
                    if softmax_frac == 8:
                        new_weight = exp_approx_q08(score - m_state)
                    else:
                        new_weight = exp_approx_interp(score - m_state, softmax_frac, weight_frac)
                    l_state = ((l_state * old_scale) >> weight_frac) + new_weight

                acc_weight = dropout_weight(
                    new_weight,
                    row,
                    key,
                    enabled=dropout_enabled,
                    threshold=dropout_threshold,
                    seed=dropout_seed,
                    scale_q8_8=dropout_scale_q8_8,
                    weight_w=weight_w,
                )
                acc = ((acc * old_scale) >> weight_frac) + (acc_weight * v[key])

        for d in range(d_model):
            out[row, d] = normalize_approx(int(acc[d]), int(l_state))

    return out


def fp32_expected(
    q,
    k,
    v,
    causal=True,
    valid_len=None,
    frac_w=8,
    dropout_enabled=False,
    dropout_threshold=0,
    dropout_seed=0xACE1,
    dropout_scale_q8_8=256,
):
    scale = float(1 << frac_w)
    qf = q.astype(np.float64) / scale
    kf = k.astype(np.float64) / scale
    vf = v.astype(np.float64) / scale
    s_len, d_model = q.shape
    valid_len = s_len if valid_len is None else max(0, min(int(valid_len), s_len))
    scores = (qf @ kf.T) / math.sqrt(float(d_model))
    if causal:
        mask = np.triu(np.ones((s_len, s_len), dtype=bool), k=1)
        scores = np.where(mask, -1.0e30, scores)
    if valid_len < s_len:
        scores[:, valid_len:] = -1.0e30
        scores[valid_len:, :] = -1.0e30
    scores = scores - np.max(scores, axis=1, keepdims=True)
    probs = np.exp(scores)
    probs = probs / np.sum(probs, axis=1, keepdims=True)
    if dropout_enabled:
        keep = np.zeros_like(probs)
        for row in range(s_len):
            for key in range(s_len):
                if row < valid_len and key < valid_len and (not causal or key <= row):
                    keep[row, key] = 1.0 if dropout_keep(
                        row,
                        key,
                        enabled=True,
                        threshold=dropout_threshold,
                        seed=dropout_seed,
                    ) else 0.0
        probs = probs * keep * (float(dropout_scale_q8_8) / 256.0)
    if valid_len < s_len:
        probs[valid_len:, :] = 0.0
    outf = probs @ vf
    out_int = np.rint(outf * scale).astype(np.int64)
    return np.clip(out_int, -32768, 32767)


def report(name, got, expected, frac_w=8):
    diff = got - expected
    abs_diff = np.abs(diff)
    worst_flat = int(np.argmax(abs_diff))
    worst = np.unravel_index(worst_flat, abs_diff.shape)
    max_int = int(abs_diff[worst])
    mae_int = float(np.mean(abs_diff))
    print(f"{name}:")
    print(f"  mean_abs_int = {mae_int:.6f}")
    print(f"  max_abs_int  = {max_int}")
    scale = float(1 << frac_w)
    print(f"  MAE          = {mae_int / scale:.6f}")
    print(f"  MaxE         = {max_int / scale:.6f}")
    print(
        "  worst_idx    = "
        f"({int(worst[0])}, {int(worst[1])}) "
        f"got={int(got[worst])} hex={to_hex16(got[worst])} "
        f"expected={int(expected[worst])} hex={to_hex16(expected[worst])}"
    )
    return mae_int / scale, max_int / scale


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hex", required=True, help="RTL output hex dump from tb_flash_attn_top_e2e_smoke")
    parser.add_argument("--s-len", type=int, required=True)
    parser.add_argument("--d-model", type=int, required=True)
    parser.add_argument("--bk", type=int, required=True)
    parser.add_argument("--scale-q8-8", type=int, required=True)
    parser.add_argument("--frac-w", type=int, default=8)
    parser.add_argument("--softmax-frac", type=int, default=8)
    parser.add_argument("--valid-len", type=int)
    parser.add_argument("--hex-offset", type=int, default=0, help="Number of hex values to skip before reading output")
    parser.add_argument("--task-index", type=int, default=0, help="Synthetic input task index for queued/multi-head checks")
    parser.add_argument("--head-index", type=int, default=0, help="Synthetic input head index for multi-head checks")
    parser.add_argument("--noncausal", action="store_true")
    parser.add_argument("--check-fp32", action="store_true")
    parser.add_argument("--q-hex", help="Optional Q input vector hex file")
    parser.add_argument("--k-hex", help="Optional K input vector hex file")
    parser.add_argument("--v-hex", help="Optional V input vector hex file")
    parser.add_argument("--golden-hex", help="Optional supplied output golden hex file")
    parser.add_argument("--max-mae", type=float, help="Fail if FP32 MAE exceeds this threshold")
    parser.add_argument("--max-maxe", type=float, help="Fail if FP32 MaxE exceeds this threshold")
    parser.add_argument("--dropout-en", action="store_true", help="Enable deterministic dropout in the RTL/FP32 mirrors")
    parser.add_argument("--dropout-threshold", type=int, default=0)
    parser.add_argument("--dropout-seed", type=lambda x: int(x, 0), default=0xACE1)
    parser.add_argument("--dropout-scale-q8-8", type=int, default=256)
    args = parser.parse_args()

    hex_path = Path(args.hex)
    got = read_hex16_matrix(hex_path, args.s_len, args.d_model, args.hex_offset)
    q, k, v = load_inputs(args)
    causal = not args.noncausal

    expected_rtl = rtl_expected(
        q,
        k,
        v,
        args.bk,
        args.scale_q8_8,
        causal=causal,
        softmax_frac=args.softmax_frac,
        valid_len=args.valid_len,
        frac_w=args.frac_w,
        dropout_enabled=args.dropout_en,
        dropout_threshold=args.dropout_threshold,
        dropout_seed=args.dropout_seed,
        dropout_scale_q8_8=args.dropout_scale_q8_8,
    )
    _, max_err = report("RTL output vs RTL fixed-point mirror", got, expected_rtl, frac_w=args.frac_w)
    if max_err != 0:
        raise SystemExit(1)

    if args.golden_hex:
        supplied_golden = read_hex16_matrix(Path(args.golden_hex), args.s_len, args.d_model)
        report("RTL output vs supplied golden_o.hex", got, supplied_golden, frac_w=args.frac_w)

    if args.check_fp32:
        expected_fp32 = fp32_expected(
            q,
            k,
            v,
            causal=causal,
            valid_len=args.valid_len,
            frac_w=args.frac_w,
            dropout_enabled=args.dropout_en,
            dropout_threshold=args.dropout_threshold,
            dropout_seed=args.dropout_seed,
            dropout_scale_q8_8=args.dropout_scale_q8_8,
        )
        fp32_name = "RTL output vs FP32 dropout softmax golden" if args.dropout_en else "RTL output vs FP32 softmax golden"
        mae, maxe = report(fp32_name, got, expected_fp32, frac_w=args.frac_w)
        if args.max_mae is not None and mae > args.max_mae:
            print(f"FAIL FP32 MAE {mae:.6f} exceeded threshold {args.max_mae:.6f}")
            raise SystemExit(1)
        if args.max_maxe is not None and maxe > args.max_maxe:
            print(f"FAIL FP32 MaxE {maxe:.6f} exceeded threshold {args.max_maxe:.6f}")
            raise SystemExit(1)


if __name__ == "__main__":
    main()
