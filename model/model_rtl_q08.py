import numpy as np

import compare_models as cmp


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


def _exp_approx_q08(delta_q88):
    """Mirror online_softmax_engine.sv: Q8.8 delta, Q0.8 output."""
    if delta_q88 >= 0:
        return 256

    lut_index = ((-int(delta_q88)) + 16) >> 5
    if lut_index >= 64:
        return 0
    return int(EXP_LUT_Q08[lut_index])


def _trunc_div_signed(numer, denom):
    """SystemVerilog signed division truncates toward zero."""
    if denom == 0:
        return 0
    sign = 1 if (numer >= 0) == (denom >= 0) else -1
    return sign * (abs(int(numer)) // abs(int(denom)))


def flash_attn_rtl_q08_sim(Q_fixed, K_fixed, V_fixed, causal_en=True, scale_q8_8=None):
    """
    Mirror the current RTL core arithmetic closely:

    - Q/K/V/O containers are signed Q8.8 int16 values.
    - dot score is shifted by FRAC_W, multiplied by Q8.8 scale, then shifted again.
    - online softmax weights and denominator are Q0.8.
    - normalization divides accumulator by the Q0.8 denominator.

    This is intentionally separate from model_fixed.py, which is a higher
    precision Q16.16 candidate model rather than a current RTL mirror.
    """
    S = int(cmp.cfg.S_LEN)
    D = int(cmp.cfg.D_MODEL)
    BK = int(cmp.cfg.BK)
    frac_w = int(cmp.cfg.FRAC_BITS)

    if scale_q8_8 is None:
        scale_q8_8 = int(round((1.0 / np.sqrt(D)) * int(cmp.cfg.SCALE_FACTOR)))

    Q = np.asarray(Q_fixed, dtype=np.int64)
    K = np.asarray(K_fixed, dtype=np.int64)
    V = np.asarray(V_fixed, dtype=np.int64)
    O = np.zeros((S, D), dtype=np.int64)

    for i in range(S):
        m_state = 0
        l_state = 0
        acc = np.zeros(D, dtype=np.int64)

        for j_start in range(0, S, BK):
            for offset in range(min(BK, S - j_start)):
                j = j_start + offset

                dot = int(np.dot(Q[i], K[j]))
                score = ((dot >> frac_w) * scale_q8_8) >> frac_w

                if causal_en and j > i:
                    continue

                if l_state == 0:
                    m_state = score
                    l_state = 256
                    old_scale = 0
                    new_weight = 256
                elif score > m_state:
                    old_scale = _exp_approx_q08(m_state - score)
                    new_weight = 256
                    l_state = ((l_state * old_scale) >> 8) + new_weight
                    m_state = score
                else:
                    old_scale = 256
                    new_weight = _exp_approx_q08(score - m_state)
                    l_state = ((l_state * old_scale) >> 8) + new_weight

                acc = ((acc * old_scale) >> 8) + new_weight * V[j]

        for d in range(D):
            out = _trunc_div_signed(int(acc[d]), int(l_state))
            O[i, d] = min(max(out, -32768), 32767)

    return O


def compare_current_rtl_mirror_against_golden():
    Q_float, K_float, V_float, O_golden_float = cmp.load_qkv_and_golden()

    Q_int = cmp.float_to_q88_int(Q_float)
    K_int = cmp.float_to_q88_int(K_float)
    V_int = cmp.float_to_q88_int(V_float)

    O_int = flash_attn_rtl_q08_sim(Q_int, K_int, V_int)
    O_float = cmp.int_to_q88_float(O_int)

    return cmp.check_error(O_golden_float, O_float)


if __name__ == "__main__":
    result = compare_current_rtl_mirror_against_golden()
    print("current RTL Q0.8 mirror vs FP32 golden")
    print(f"mean_abs_error = {result['mean_abs_error']:.6f}")
    print(f"max_abs_error  = {result['max_abs_error']:.6f}")
    print(f"passed         = {result['passed']}")

    worst_flat = int(np.argmax(result["abs_diff"]))
    worst_idx = np.unravel_index(worst_flat, result["abs_diff"].shape)
    print(
        "worst_idx      = "
        f"({int(worst_idx[0])}, {int(worst_idx[1])}), "
        f"diff={result['abs_diff'][worst_idx]:.6f}"
    )
