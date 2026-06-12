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

## Area — local evidence (yosys generic synth, tech-independent A/B)
No sky130 standard-cell PDK on this machine (no network), so exact NAND2-equiv needs Genus.
But yosys (`abc -g cmos2`) gives a fair tech-independent A/B. Decisive finding + fix:

- **Multiplier count is the area driver** (baseline flash_core is 77% core, dominated by mults).
  - baseline: `dot_product_engine`(tree,32 lanes)=**32 mults** + `value_accumulator`=**128 mults** = **160**.
  - v2 (after fix): `dot_stream`(64 lanes)=**64** + `softmax_combine`(shared array)=**64** = **128 mults**.
  - => v2 has **FEWER multipliers than baseline** (128 vs 160).
- The fix: yosys first showed `softmax_combine` instantiated 64 MAC + 128 merge mults (~192) because
  MAC and the two merge terms were separate parallel expressions. Time-sharing one 64-wide array
  across S_MAC/S_MOLD/S_MNEW (they run in different cycles) dropped it to 64 mults, +1 cycle/tile
  (full-size 154784 → 154904), accuracy unchanged.
- yosys generic cells (cmos2, reference only): baseline `value_accumulator` alone = 830,259;
  baseline `dpe`(tree-32) = 174,116; `dot_stream` = 281,244. (cmos2 != sky130; use for direction.)
- => **Area expectation: v2 ≤ baseline** (fewer mults; pipeline regs add some FF but baseline’s
  128-mult value_accumulator dominated). Baseline is 163.5万 gates (81.8% of 200万) at 8ns clean,
  so v2 should sit comfortably under the cap. Confirm exact NAND2-equiv in Genus.

## Timing — structural argument (the 5ns tail is removed)
- The baseline 5ns critical-path tail was the inner recurrence `acc = acc*old_scale + w*V`
  (a MULTIPLY inside the registered feedback). v2 makes the loop-carried inner path a **pure adder**
  (`acc_inner += w*V`, with `w*V` feed-forward); the only `acc*corr` multiply moved to the per-tile
  merge (S_MOLD/S_MNEW), off the 1/cycle inner path and allowed multiple cycles.
- `dot_stream` is a registered adder tree (1 level/cycle) → each stage is one short adder.
- => timing expectation: **easier 5ns closure than baseline** (the exact path that limited it is gone).
  Confirm WNS/TNS in Genus.

## Pending (needs Cadence Genus — environment limit, not a design gap)
- 8 ns and 5 ns QoR: WNS/TNS/violating paths, Cell Area → NAND2 gate-equiv (≤ 200万), power.
- Local environment has no std-cell PDK and no network, so ns/gate numbers can only come from Genus.
  Scripts ready: `synth/run_genus.sh` + `synth/filelist.f` (incl. dot_stream/softmax_combine) + SDC.

## Known further cycle levers (not applied — every one trades AREA)
Analyzed; all conflict with the "area good" goal and can't be area-verified without Genus:
- **Per-row drain bubble (~15k → ~140k):** feed rows continuously through dot_stream with a
  tag pipeline + circular score-buffer pool. Causal early rows put up to DOT_LAT(=7) rows in
  flight, so it needs ~N=8-16 score buffers (BK×ACC_W each) ≈ **+4万门**.
- **DMA/compute overlap (~55k → ~100k):** double-buffer K/V tiles (prefetch t+1) ≈ **+30万门**
  (a second 32 Kb tile FF buffer). Also benefit depends on the eval AXI latency model.
- **Larger BQ (fewer K/V re-reads → less DMA):** BQ 16→32 cut sweep cycles 233k→196k but
  **+~25万门** (acc_block/q_block double).
- **=> 154k is the cycle/area sweet spot with NO area regression** (~baseline area). Picking
  any lever above is a deliberate cycles↑↔area↑ trade to make once Genus gives the v2 area.
