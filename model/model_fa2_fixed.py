#!/usr/bin/env python3
"""Stage-0 golden for the v2 streaming architecture (pure Python, no numpy).

Purpose: prove that hoisting the softmax max from per-key (FA-1, current RTL) to
per-tile (FA-2, proposed v2) is numerically equivalent in fixed point and still
meets the contest error budget (MAE<=0.03, MaxE<=0.10) vs FP32.

It uses the SAME exp approximation as the RTL online_softmax_engine.sv:
a 64-entry Q16 LUT, entry k = exp(-k/8), with 1/8-step linear interpolation.
Output is quantized to Q8.8. Accumulation is kept wide (the RTL uses ACC_W=36,
effectively exact for this size), so the only modeled approximations are the
exp LUT + input/output Q8.8 quantization -- exactly the ones that move MAE/MaxE.
"""
import math

# ---- RTL exp LUT (Q16, entry k = round(exp(-k/8)*65536)), from online_softmax_engine.sv
EXP_LUT_Q16 = [
 65536,57835,51039,45042,39750,35079,30957,27319,24109,21276,18776,16570,14623,12905,11388,10050,
 8869,7827,6907,6096,5380,4747,4190,3697,3263,2879,2541,2243,1979,1746,1541,1360,
 1200,1059,935,825,728,642,567,500,442,390,344,303,268,236,209,184,
 162,143,127,112,99,87,77,68,60,53,47,41,36,32,28,25]
EXP_N = 64
ONE_Q16 = 65536

def exp_lut(delta):
    """exp(delta) for delta<=0, returned as float in [0,1]; mirrors RTL addressing.
    delta is a real number (= s - m). index step = 1/8 (EXP_LUT_FRAC_BITS=3)."""
    if delta >= 0.0:
        return 1.0
    a = -delta                      # >=0
    pos = a * 8.0                    # 1/8 steps
    idx = int(pos)
    rem = pos - idx
    if idx >= EXP_N - 1:
        if idx >= EXP_N: return 0.0
        return EXP_LUT_Q16[EXP_N-1] / ONE_Q16
    y0 = EXP_LUT_Q16[idx]; y1 = EXP_LUT_Q16[idx+1]
    return (y0 + (y1 - y0) * rem) / ONE_Q16

# ---- deterministic RNG (LCG) so runs are reproducible without numpy
class LCG:
    def __init__(self, seed=42): self.s = seed & 0xFFFFFFFF
    def next(self):
        self.s = (1103515245 * self.s + 12345) & 0x7FFFFFFF
        return self.s
    def q88(self, lo, hi):
        # random Q8.8 value (int16) mapping to a real in [lo,hi]
        r = self.next() / 0x7FFFFFFF
        real = lo + (hi - lo) * r
        q = max(-32768, min(32767, int(round(real * 256.0))))
        return q

def q88_to_real(q): return q / 256.0
def quant_q88(real):
    q = max(-32768, min(32767, int(round(real * 256.0))))
    return q / 256.0

def gen_inputs(S, D, amp, seed):
    rng = LCG(seed)
    Q = [[q88_to_real(rng.q88(-amp, amp)) for _ in range(D)] for _ in range(S)]
    K = [[q88_to_real(rng.q88(-amp, amp)) for _ in range(D)] for _ in range(S)]
    V = [[q88_to_real(rng.q88(-amp, amp)) for _ in range(D)] for _ in range(S)]
    return Q, K, V

def attn_fp32(Q, K, V, S, D, causal=True):
    scale = 1.0 / math.sqrt(D)
    O = [[0.0]*D for _ in range(S)]
    for i in range(S):
        hi = i if causal else S-1
        sc = [sum(Q[i][d]*K[j][d] for d in range(D))*scale for j in range(hi+1)]
        m = max(sc); ex = [math.exp(s-m) for s in sc]; l = sum(ex)
        for d in range(D):
            O[i][d] = sum(ex[j]*V[j][d] for j in range(hi+1))/l
    return O

def attn_fa1_fixed(Q, K, V, S, D, BK, causal=True):
    """Per-key running-max (current RTL structure), fixed exp LUT, wide acc."""
    scale = 1.0/math.sqrt(D)
    O = [[0.0]*D for _ in range(S)]
    for i in range(S):
        hi = i if causal else S-1
        m = -1e30; l = 0.0; acc = [0.0]*D
        for j in range(hi+1):
            s = sum(Q[i][d]*K[j][d] for d in range(D))*scale
            if l == 0.0:
                m = s; l = 1.0; acc = [V[j][d] for d in range(D)]
            elif s > m:
                osc = exp_lut(m - s); m = s
                l = l*osc + 1.0
                for d in range(D): acc[d] = acc[d]*osc + V[j][d]
            else:
                w = exp_lut(s - m)
                l = l + w
                for d in range(D): acc[d] = acc[d] + w*V[j][d]
        for d in range(D): O[i][d] = quant_q88(acc[d]/l if l != 0 else 0.0)
    return O

def attn_fa2_fixed(Q, K, V, S, D, BK, causal=True):
    """Per-tile max then merge (proposed v2 structure), SAME exp LUT, wide acc."""
    scale = 1.0/math.sqrt(D)
    O = [[0.0]*D for _ in range(S)]
    for i in range(S):
        hi = i if causal else S-1
        m = -1e30; l = 0.0; acc = [0.0]*D
        first = True
        for j0 in range(0, hi+1, BK):
            j1 = min(j0+BK, hi+1)
            # --- stage A: scores + tile max (pipelined dot, 1/cyc in HW) ---
            sc = [sum(Q[i][d]*K[j][d] for d in range(D))*scale for j in range(j0, j1)]
            m_tile = max(sc)
            # --- stage B: combine with fixed tile max (inner recurrence = ADD only) ---
            l_part = 0.0; acc_inner = [0.0]*D
            for jj, j in enumerate(range(j0, j1)):
                w = exp_lut(sc[jj] - m_tile)     # feed-forward; m_tile fixed in tile
                l_part += w
                for d in range(D): acc_inner[d] += w*V[j][d]
            # --- stage C: tile merge (once per tile; the only multiply-rescale) ---
            if first:
                m = m_tile; l = l_part; acc = acc_inner[:]; first = False
            else:
                m_new = max(m, m_tile)
                corr_old = exp_lut(m - m_new)     # rescale old running state
                corr_new = exp_lut(m_tile - m_new)# rescale this tile's partials
                l = l*corr_old + l_part*corr_new
                for d in range(D): acc[d] = acc[d]*corr_old + acc_inner[d]*corr_new
                m = m_new
        for d in range(D): O[i][d] = quant_q88(acc[d]/l if l != 0 else 0.0)
    return O

def err(A, B, S, D):
    mae = 0.0; mx = 0.0; n = S*D
    for i in range(S):
        for d in range(D):
            e = abs(A[i][d]-B[i][d]); mae += e; mx = max(mx, e)
    return mae/n, mx

def run(S=64, D=16, BK=16, amp=4.0, seed=42):
    Q,K,V = gen_inputs(S, D, amp, seed)
    ref = attn_fp32(Q,K,V,S,D)
    fa1 = attn_fa1_fixed(Q,K,V,S,D,BK)
    fa2 = attn_fa2_fixed(Q,K,V,S,D,BK)
    print(f"--- S={S} D={D} BK={BK} amp={amp} seed={seed} (causal) ---")
    m1,x1 = err(fa1, ref, S, D); print(f"FA1(current) vs FP32 : MAE={m1:.6f} MaxE={x1:.6f}")
    m2,x2 = err(fa2, ref, S, D); print(f"FA2(v2)      vs FP32 : MAE={m2:.6f} MaxE={x2:.6f}")
    md,xd = err(fa2, fa1, S, D); print(f"FA2 vs FA1 (restructure delta): MAE={md:.6f} MaxE={xd:.6f}")
    ok = (m2 <= 0.03 and x2 <= 0.10)
    print(f"FA2 budget (MAE<=0.03,MaxE<=0.10): {'PASS' if ok else 'FAIL'}")
    return ok

if __name__ == "__main__":
    allok = True
    for (S,D,BK,amp,seed) in [(64,16,16,4.0,42),(64,16,16,8.0,7),(128,16,16,4.0,123),(256,64,16,4.0,42)]:
        allok &= run(S,D,BK,amp,seed); print()
    print("STAGE0_RESULT:", "PASS" if allok else "FAIL")
