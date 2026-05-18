# Architecture Notes

## Member B Core And Memory Path

The core implementation is an integration-ready tiled FlashAttention-style
compute path. It is AXI-agnostic: DMA/top provides Q rows and K/V tiles, while
the core returns one normalized O row at a time. The current softmax uses a
deterministic fixed-point exponential lookup table so RTL and testbench can be
checked bit-for-bit.

### Core Control Flow

`flash_core` owns the compute-side sequencing and never accesses AXI directly. It talks to the DMA/top layer through three handshake groups:

- Q row request: `q_req_valid`, `q_req_row`, `q_req_ready`, then `q_data_valid`.
- K/V tile request: `kv_req_valid`, `kv_req_start`, `kv_req_len`, `kv_req_ready`, then `kv_data_valid`.
- O row output: `o_valid`, `o_row`, `o_data`, `o_ready`.

The state machine loads one Q row, walks all K/V tiles with `tile_scheduler`, computes a serial dot product for every key row in every tile, applies the causal mask, updates the online softmax state, accumulates weighted V values, normalizes the accumulator, and emits the complete O row.

### Tile Scheduler

`tile_scheduler` emits `(row_index, kv_start, kv_len)` tuples. With the default `S_LEN=256` and `BK=16`, it walks each query row across sixteen K/V tiles. The final tile length is clamped for non-divisible configurations, which makes the block usable for small tests such as `S_LEN=4`, `BK=2`.

### Dot Product

`dot_product_engine` is a serial signed MAC:

    dot = sum(q_vec[d] * k_vec[d]), d = 0 .. D_MODEL-1

Inputs and outputs are fixed-point containers, but the module treats them as signed integers and leaves scaling interpretation to the caller. The product is sign-extended into a 48-bit accumulator by default.

### Causal Mask

`causal_mask_unit` compares `key_index` against `query_index`. When `causal_en=1` and `key_index > query_index`, the score is replaced with `neg_large` and `score_valid` is cleared. Masked scores do not update the softmax denominator or value accumulator.

### Online Softmax

`online_softmax_engine` updates `(m, l)` for one score at a time:

```text
if first valid score:
    m = score
    l = 1.0
    new_weight = 1.0
elif score > m:
    old_scale = exp_approx(m - score)
    l = l * old_scale + 1.0
    m = score
    new_weight = 1.0
else:
    old_scale = 1.0
    new_weight = exp_approx(score - m)
    l = l + new_weight
```

Weights are Q0.8 values. The current `exp_approx` is a 64-entry lookup table
for negative deltas. The delta input is treated as Q8.8; the lookup rounds to
the nearest 1/8 step and covers approximately `0.0` through `7.875`:

```text
exp_approx(delta) = 1.0                         when delta >= 0
exp_approx(delta) = LUT(round(abs(delta) * 8))   when -7.875 <= delta < 0
exp_approx(delta) = 0.0                         when delta < -7.875
```

This is intentionally isolated in one module so it can later be replaced by a
larger LUT, interpolation, or a model-derived table without changing the core
handshake.

### Value Accumulation And Normalization

`value_accumulator` keeps a vector accumulator:

    acc[d] = acc[d] * old_scale + new_weight * V[key][d]

`normalizer` computes:

    O[d] = saturate(acc[d] / l)

The accumulator stores `weight_int * V_q8.8`; dividing by the Q0.8 denominator returns a Q8.8 output integer.

### Buffers

`row_buffer` and `tile_buffer` are synchronous load/hold buffers. The core also keeps explicit working registers for the currently active Q row, K row, and V row to keep Icarus-compatible array handling stable.

## Member A AXI / DMA / Top Path

The A-side implementation wraps the AXI-agnostic core with one AXI4-Lite register block, one AXI read engine, one AXI write engine, and a DMA sequencer. The main design choice is to keep the DMA **functionally simple and stride-correct**: it fetches Q, K, and V **row by row** and writes O **row by row**. That avoids accidental consumption of padding bytes when `stride_bytes` is larger than the logical row width.

### AXI4-Lite Register Block

`axi_lite_regs.sv` owns the software-visible register map:

- `CTRL` generates one-cycle `start_pulse` and `soft_reset` pulses and stores `irq_en`.
- `STATUS` reflects `busy` and latches sticky `done` / `error` until software clears them.
- `CFG` stores `causal_en`.
- `Q/K/V/O_BASE`, `STRIDE_BYTES`, `NEG_LARGE`, and `SCALE` are persistent configuration registers.
- `CYCLES` is read-only and comes from the top-level cycle counter.

The block also generates the external `irq`, which is asserted when `irq_en=1` and the sticky `done` bit is set.

### AXI Master Read And Write Engines

`axi_master_read.sv` and `axi_master_write.sv` are thin adapters from a simple local request/data handshake into AXI burst transactions.

`axi_master_read` accepts:

    req_valid, req_addr, req_bytes

and produces a beat stream:

    data_valid, data, data_last

`axi_master_write` accepts:

    req_valid, req_addr, req_bytes
    data_valid, data, data_last

and completes only after the AXI `B` response is received. This lets the DMA wait for full write completion before reporting itself idle again.

### DMA Controller

`dma_controller.sv` converts the core-side handshake into memory traffic.

For the Week-1 / baseline implementation it is intentionally serialized:

1. Accept one core request while idle.
2. Read one Q row or one K/V row at a time through the read engine.
3. Buffer the full row / tile locally.
4. Present the buffered payload back to the core.
5. Accept one O row and push it through the write engine.

This is slower than an overlapped design, but it keeps the control logic short, deterministic, and easy to verify.

### Why K/V Tiles Are Read Row By Row

The repository memory layout defines addresses as:

    base + row_index * stride_bytes + element_index * 2

so the logical row payload is `D_MODEL * 2 = 128` bytes, but the configured `stride_bytes` may be larger. If the DMA tried to read the whole tile as one contiguous burst, it would also ingest any padding between rows whenever `stride_bytes > 128`.

Reading each K or V row as an independent 128-byte burst keeps the implementation correct for both the default packed case and future padded layouts.

### Top-Level Integration

`flash_attn_top.sv` connects:

- `axi_lite_regs`
- `flash_core`
- `dma_controller`
- `axi_master_read`
- `axi_master_write`

The top keeps a small run-state controller:

- `run_active_q` is set by `start_pulse`.
- `core_done_seen_q` captures the core completion pulse.
- `overall_done_pulse` is generated only when the core has finished **and** DMA/read/write activity has drained.
- `cycle_count_q` clears on `start_pulse` and increments while a run is active.

This makes the software-visible `DONE` bit correspond to **true end-to-end completion**, not just “the core emitted the last output row.”
