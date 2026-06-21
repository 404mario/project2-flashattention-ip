# Bonus precision/format FP32 error table (new core, numpy golden) — 2026-06-21
## Fixed-point formats (item #5) + low-precision (items #1/#7), S=32 D=16, all RTL PASS:
| fmt | MAE | MaxE |
|---|---|---|
| Q8.8(ref) | 0.000015 | 0.003906 |
| Q6.10 | 0.002876 | 0.018555 |
| Q4.12 | 0.006800 | 0.190430 |
| BF16 I/O | 0.000015 | 0.003906 |
| FP8-E4M3 | 0.000237 | 0.011719 |
| INT8 | 0.046387 | 0.187500 |
## FP hardware units (item #1), real-math accuracy:
- fp_exp:   max_abs_err 0.00021 over x in [-8,0]  (PASS <0.01)
- fp_recip: max_rel_err 0.37%   over x in [1,64]  (PASS <1%)
- fp_softmax_unit: max_abs_prob_err 0.0005 (50 rows x 12 lanes, PASS <0.02)

## Item #3 (可配序列 S=512) on new core — 2026-06-21
- S=512 D=16 BK=16 BQ=8 causal: RTL PASS, cycles=277496, FP32 MAE=0.000358 MaxE=0.011719 (within budget).
- Confirms longer/configurable sequence works on the 5ns-core graft (compile clean + run-to-completion + FP32-accurate).
