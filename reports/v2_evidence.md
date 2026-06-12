# v2 Streaming Architecture — Evidence

Branch: `codex-baseline-v2-streaming-arch`. Sim: iverilog (functional self-check) +
`model/compare_hex.py` vs FP32 `tb/vectors/golden_o.hex`. Synthesis (area/timing) pending Genus.

## Unit tests (iverilog)
| Test | Result |
|---|---|
| `tb/sv/tb_dot_stream.sv` (II=1 dot, 40 vectors, throughput+value) | PASS |
| `tb/sv/tb_softmax_combine.sv` (tile-max+MAC+merge vs FP32 $exp) | PASS (MAE 0.000672, MaxE 0.001272) |
| `model/model_fa2_fixed.py` (FA-2 vs FA-1 vs FP32, 4 cases) | PASS (FA-2 MaxE ≤ 0.0085) |

## Full-size end-to-end (S=256, D=64, BK=16, BQ=16, causal)
| Case | cycles | RD_BYTES | WR_BYTES | MAE | MaxE | Result |
|---|---:|---:|---:|---:|---:|---|
| Random vectors (RUN_VECTORS, supplied Q/K/V) vs golden | 154,784 | 589,824 | 32,768 | 0.000097 | 0.054688 | **PASS** |
| Default generated tensors (RUN_FULL) | 154,784 | 589,824 | 32,768 | (self-check) | | PASS |
| baseline reference (`core-pipeline-fmax`) | 233,312 | 589,824 | 32,768 | 0.000097 | 0.054688 | PASS |

cycles −34% vs baseline; accuracy identical. Cycle count is input-independent (fixed causal schedule).

## Smaller sizes
| Shape | v2 cycles | baseline | Result |
|---|---:|---:|---|
| S=8,D=8,BK=4 | 340 | 335 | PASS |
| S=32,D=16,BK=8,BQ=8 | 3,064 | 3,528 | PASS |

## Reproduce
```bash
# functional + cycles (no numpy needed; uses TB self-check)
./sim/run_top_compile.sh
RUN_VECTORS=1 ./sim/run_top_e2e_smoke.sh          # full FP32 checker needs numpy
# no-numpy golden compare:
python3 model/compare_hex.py sim_build/tb_flash_attn_top_e2e_vectors_o.hex tb/vectors/golden_o.hex
# unit tests
iverilog -g2012 -o /tmp/t.vvp rtl/core/dot_stream.sv tb/sv/tb_dot_stream.sv && vvp /tmp/t.vvp
# synthesis (area/timing — run on Cadence):
cd synth && ./run_genus.sh
```

## Pending (needs Cadence Genus, cannot run locally)
- 8 ns and 5 ns QoR: WNS/TNS/violating paths, Cell Area → NAND2 gate-equiv (≤ 200万?), power.
- Expected: timing ≤ baseline & easier 5 ns (multiply moved off the inner recurrence); area ~baseline.

## Known further cycle levers (not applied — tradeoffs)
- Per-row drain bubble (~15k): feed rows continuously through dot_stream with tag-routed
  capture → ~140k. Area-free but raises control complexity.
- DMA/compute overlap (~55k): double-buffer K/V tiles → ~100k, but +~30万门 (tile FF) → area risk.
- 154k is the cycle/area sweet spot WITHOUT area regression.
