#!/usr/bin/env python3
"""Pure-Python (no numpy) MAE/MaxE between two Q8.8 hex dumps (one int16/line)."""
import sys

def read_q88(path):
    out = []
    with open(path) as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            v = int(s, 16)
            if v >= 0x8000:
                v -= 0x10000          # sign-extend int16
            out.append(v / 256.0)     # Q8.8 -> real
    return out

def main():
    rtl_path, gold_path = sys.argv[1], sys.argv[2]
    rtl = read_q88(rtl_path)
    gold = read_q88(gold_path)
    n = min(len(rtl), len(gold))
    if len(rtl) != len(gold):
        print(f"WARN length mismatch rtl={len(rtl)} gold={len(gold)} (comparing first {n})")
    mae = 0.0; mx = 0.0; arg = -1
    for i in range(n):
        e = abs(rtl[i] - gold[i])
        mae += e
        if e > mx:
            mx = e; arg = i
    mae /= n
    print(f"compared {n} elements")
    print(f"  MAE  = {mae:.6f}")
    print(f"  MaxE = {mx:.6f}  (at index {arg}: rtl={rtl[arg]:.4f} gold={gold[arg]:.4f})")
    ok = (mae <= 0.03 and mx <= 0.10)
    print(f"  budget MAE<=0.03 MaxE<=0.10 : {'PASS' if ok else 'FAIL'}")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
