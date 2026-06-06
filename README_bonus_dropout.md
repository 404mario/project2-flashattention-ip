# FlashAttention IP Bonus: Dropout Training Mode

Branch: `codex-bonus-integrated-ppa-skeleton`

This branch adds Bonus #6 to the unified bonus line: deterministic training-mode dropout
after softmax and before the V accumulator update. Dropout is disabled by default, so the
baseline and non-dropout bonus behavior is preserved unless the new registers are programmed.

## Registers

| Address | Name | Access | Meaning |
|---:|---|---|---|
| `0x60` | `DROPOUT_CFG` | R/W | bit 0 enable, bits `[31:16]` threshold. Drop when `rand16 < threshold`. |
| `0x64` | `DROPOUT_SEED` | R/W | bits `[15:0]` deterministic mask seed. |
| `0x68` | `DROPOUT_SCALE` | R/W | bits `[15:0]` Q8.8 inverted dropout scale. |

The smoke configuration uses threshold `16384` for about 25% drop probability and scale
`341`, the Q8.8 approximation of `1 / (1 - 0.25)`.

## Verification

```bash
bash ./sim/run_bonus_dropout_smoke.sh
```

Current quick evidence:

| Case | Shape | Result | Cycles | FP32 dropout MAE | FP32 dropout MaxE |
|---|---:|---|---:|---:|---:|
| Small checker-driven | S=8,D=8 | PASS | 466 | 0.001404 | 0.007812 |
| Medium optimized path | S=32,D=16 | PASS | 4780 | 0.000053 | 0.003906 |

Both cases match the RTL fixed-point mirror with `MaxE = 0`. The full-size
`RUN_FULL=1` dropout run was started but exceeded the local 5-minute tool timeout, so it is
not claimed yet.
