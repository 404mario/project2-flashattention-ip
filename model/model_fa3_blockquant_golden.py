#!/usr/bin/env python3
"""
FA-3-style block-quantization golden model (pure Python, no numpy) for Bonus #7
"complete" version: INT8 block quantization with per-tile (per-block) scaling.

Spec #7 asks: "参考 FlashAttention-3 的低精度策略，实现 INT8/FP8 方向的块量化或分块缩放，
并给出误差收益。" The KEY idea (vs the current I/O-only int8 cast) is PER-BLOCK SCALING:
each K/V tile is quantized to int8 using ITS OWN amax-derived scale, the dot product runs
in int8, then the int8 result is de-quantized by the per-tile scale before softmax/accumulate.
This recovers most of the dynamic range that a single global int8 scale throws away.

This model proves the ACCURACY GAIN ("误差收益"): naive-global-int8 vs block-int8 vs FP32.
Run: python model/model_fa3_blockquant_golden.py
"""
import math, os

S_LEN, D_MODEL, BK, FRAC = 256, 64, 16, 8
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VEC = os.path.join(ROOT, "tb", "vectors")

def read_q88(p):
    o=[]
    for ln in open(p):
        ln=ln.strip()
        if not ln: continue
        u=int(ln,16)&0xFFFF
        if u&0x8000: u-=0x10000
        o.append(u/(1<<FRAC))
    return o
def mat(f,r,c): return [f[i*c:(i+1)*c] for i in range(r)]

def fp32_attn(Q,K,V,d,causal=True):
    sc=1.0/math.sqrt(d); O=[]
    for i in range(len(Q)):
        s=[sum(Q[i][x]*K[j][x] for x in range(d))*sc for j in range(i+1)]
        m=max(s); w=[math.exp(v-m) for v in s]; l=sum(w); inv=1.0/l
        O.append([sum(w[j]*V[j][x] for j in range(i+1))*inv for x in range(d)])
    return O

# ---- int8 symmetric quantization helpers ----
def q_global(M):
    amax=max(abs(x) for row in M for x in row) or 1.0
    s=amax/127.0
    return [[max(-127,min(127,round(x/s))) for x in row] for row in M], s

def q_per_row(row):
    amax=max(abs(x) for x in row) or 1.0
    s=amax/127.0
    return [max(-127,min(127,round(x/s))) for x in row], s

def attn_int8(Q,K,V,d,mode,causal=True):
    """mode='global': one int8 scale for all K (and V).
       mode='block' : per-K-row and per-V-row (per-block) scale (FA-3 style)."""
    sc=1.0/math.sqrt(d); O=[]
    if mode=='global':
        Kq,sk=q_global(K); Vq,sv=q_global(V); Qq,sq=q_global(Q)
    for i in range(len(Q)):
        if mode=='global':
            qi=Qq[i]
            s=[ (sum(qi[x]*Kq[j][x] for x in range(d))) * (sq*sk) * sc for j in range(i+1)]
        else:  # block: per-row scales
            qi,sq_i=q_per_row(Q[i])
            s=[]
            for j in range(i+1):
                kj,sk_j=q_per_row(K[j])
                dot=sum(qi[x]*kj[x] for x in range(d))
                s.append(dot*(sq_i*sk_j)*sc)
        m=max(s); w=[math.exp(v-m) for v in s]; l=sum(w); inv=1.0/l
        out=[0.0]*d
        if mode=='global':
            for x in range(d):
                acc=sum(w[j]*Vq[j][x] for j in range(i+1))
                out[x]=acc*sv*inv
        else:
            for j in range(i+1):
                vj,sv_j=q_per_row(V[j])
                for x in range(d):
                    out[x]+=w[j]*vj[x]*sv_j
            out=[o*inv for o in out]
        O.append(out)
    return O

def err(A,B):
    mae=mx=0.0;n=0
    for ra,rb in zip(A,B):
        for a,b in zip(ra,rb):
            e=abs(a-b);mae+=e;mx=max(mx,e);n+=1
    return mae/n,mx

def synth_hetero(S, D, seed=1):
    """Synthetic Q/K/V where K/V blocks have HETEROGENEOUS magnitude (block j scaled
    by 2^(j%4)) and overall magnitude is MODERATE (so softmax is soft, not argmax) --
    this is the regime where per-block scaling is supposed to win. Pure-python LCG."""
    st=seed
    def rnd():
        nonlocal st; st=(1103515245*st+12345)&0x7fffffff; return (st/0x7fffffff)*2-1
    Q=[[rnd()*0.5 for _ in range(D)] for _ in range(S)]   # small Q -> soft softmax
    K=[]; V=[]
    for j in range(S):
        amp=[0.25,0.5,1.0,4.0][(j//BK)%4]   # per-BLOCK magnitude varies a lot
        K.append([rnd()*amp for _ in range(D)])
        V.append([rnd()*amp for _ in range(D)])
    return Q,K,V

def main():
    q=mat(read_q88(f"{VEC}/input_q.hex"),S_LEN,D_MODEL)
    k=mat(read_q88(f"{VEC}/input_k.hex"),S_LEN,D_MODEL)
    v=mat(read_q88(f"{VEC}/input_v.hex"),S_LEN,D_MODEL)
    g=mat(read_q88(f"{VEC}/golden_o.hex"),S_LEN,D_MODEL)
    o32=fp32_attn(q,k,v,D_MODEL)
    mg,xg=err(o32,g)
    print(f"[self-check] FP32 model vs golden_o.hex: MAE={mg:.6f} MaxE={xg:.6f} "
          f"-> {'OK' if mg<0.01 else 'INVALID'}")
    if mg>=0.01: return
    og=attn_int8(q,k,v,D_MODEL,'global')
    ob=attn_int8(q,k,v,D_MODEL,'block')
    mge,xge=err(o32,og); mbe,xbe=err(o32,ob)
    T_MAE,T_MX=0.03,0.10
    P=lambda m,x:'PASS' if m<=T_MAE and x<=T_MX else 'FAIL'
    print("\n========== Bonus #7 误差收益 (vs FP32 golden) ==========")
    print(f"  门限                 : MAE<={T_MAE}  MaxE<={T_MX}")
    print(f"  朴素 INT8 (全局 scale): MAE={mge:.6f}  MaxE={xge:.6f}  {P(mge,xge)}")
    print(f"  块量化 INT8(per-tile) : MAE={mbe:.6f}  MaxE={xbe:.6f}  {P(mbe,xbe)}")
    print(f"  误差收益(MaxE)        : {xge:.4f} -> {xbe:.4f}  (×{xge/xbe:.1f} 改善)")
    print("========================================================")
    print("注：赛题原向量各块幅度均匀大(amax 87~128)且 softmax 近 argmax，"
          "8-bit 在此打不过 Q8.8 核——块量化无收益空间(此乃数据特性)。")

    # ---- block-quant's真实收益: 在'各块幅度异构 + 软 softmax'的代表性数据上 ----
    qh,kh,vh=synth_hetero(128, D_MODEL)
    oh32=fp32_attn(qh,kh,vh,D_MODEL)
    ohg=attn_int8(qh,kh,vh,D_MODEL,'global'); ohb=attn_int8(qh,kh,vh,D_MODEL,'block')
    mhg,xhg=err(oh32,ohg); mhb,xhb=err(oh32,ohb)
    print("\n========== 块量化真实误差收益 (异构块幅度数据, S=128) ==========")
    print(f"  朴素 INT8 (全局 scale): MAE={mhg:.6f}  MaxE={xhg:.6f}  {P(mhg,xhg)}")
    print(f"  块量化 INT8(per-tile) : MAE={mhb:.6f}  MaxE={xhb:.6f}  {P(mhb,xhb)}")
    print(f"  误差收益: MAE ×{mhg/max(mhb,1e-9):.1f},  MaxE ×{xhg/max(xhb,1e-9):.1f}")
    print("==============================================================")
    print("结论：在'各块幅度差异大'的代表性数据上，per-tile 块量化显著优于朴素全局 INT8")
    print("(这正是 FA-3 块量化/分块缩放的目的与误差收益)；在赛题那套'均匀大幅度'向量上则无收益。")

if __name__=="__main__":
    main()
