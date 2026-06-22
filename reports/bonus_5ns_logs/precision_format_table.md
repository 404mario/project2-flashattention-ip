# Bonus precision/format FP32 error table (new core, numpy golden) — 2026-06-21
## Fixed-point formats (item #5) + low-precision (items #1/#7), S=32 D=16, all RTL PASS:
## (official tolerance: MAE<=0.03, MaxE<=0.10; all four fmts share cycles=2752 -> format is bit-width only, no perf cost)
| fmt | MAE | MaxE | vs tolerance |
|---|---|---|---|
| Q8.8(ref) | 0.000015 | 0.003906 | clean pass (baseline) |
| Q7.9 | 0.001991 | 0.011719 | **clean pass** (higher frac res than baseline) — primary alt-format evidence |
| Q6.10 | 0.002876 | 0.018555 | **clean pass** — primary alt-format evidence |
| Q4.12 | 0.006800 | 0.190430 | MAE passes; MaxE 0.190 EXCEEDS 0.10 — characterized **range-saturation limit**, NOT presented as a pass (±8 int range saturates on this accumulation) |
| BF16 I/O | 0.000015 | 0.003906 | clean pass |
| FP8-E4M3 | 0.000237 | 0.011719 | clean pass |
| INT8 | 0.046387 | 0.187500 | low-precision, expected loss (characterized, not headline) |

Takeaway (per Codex evidence-standard review): alt-format support (#5) is demonstrated by Q7.9 + Q6.10, which both
pass official tolerance at FINER fractional resolution than the Q8.8 baseline. Q4.12 is reported as the characterized
range-vs-resolution limit (MaxE>0.10), not as a passing format — so no tolerance-failing format is offered as proof.
## FP hardware units (item #1), real-math accuracy:
- fp_exp:   max_abs_err 0.00021 over x in [-8,0]  (PASS <0.01)
- fp_recip: max_rel_err 0.37%   over x in [1,64]  (PASS <1%)
- fp_softmax_unit: max_abs_prob_err 0.0005 (50 rows x 12 lanes, PASS <0.02)

## Item #3 (可配序列 S=512) on new core — 2026-06-21
- S=512 D=16 BK=16 BQ=8 causal: RTL PASS, cycles=277496, FP32 MAE=0.000358 MaxE=0.011719 (within budget).
- Confirms longer/configurable sequence works on the 5ns-core graft (compile clean + run-to-completion + FP32-accurate).
