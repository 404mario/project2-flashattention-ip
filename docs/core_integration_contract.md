# Core Integration Contract

This note freezes the Member B `flash_core` contract for Member A/C
integration. The core is AXI-agnostic: it only requests rows and tiles, then
returns one output row.

## Ownership

Member B owns:

- `rtl/core/*`
- `rtl/mem/*`
- core-level SystemVerilog checks under `tb/sv/tb_flash_core_*`
- this core integration contract

Member A/top or Member C testbench owns the producers and consumer connected to
the request/data/output handshakes.

## Run Control

- `start` is a one-cycle pulse sampled while `busy == 0`.
- A `start` pulse while the core is busy is ignored.
- `busy` stays high while the core is processing a run.
- `done` is a one-cycle pulse after the final `o_valid && o_ready` handshake.
- `error` is reserved and is currently tied low for the legal baseline flow.
- `causal_en`, `neg_large`, and `scale` must be stable for the whole run.

## Q Row Input

The core raises `q_req_valid` with `q_req_row` for the next query row. The
producer accepts the request with `q_req_ready`.

After accepting the request, the producer may wait any number of cycles before
raising `q_data_valid`. While `q_data_valid` is high, `q_data[D_MODEL]` must
remain stable until `q_data_valid && q_data_ready`.

Rows are requested in increasing order from `0` to `S_LEN - 1`.

## K/V Tile Input

The core raises `kv_req_valid` with `kv_req_start` and `kv_req_len`. The
producer accepts the request with `kv_req_ready`.

After accepting the request, the producer may wait any number of cycles before
raising `kv_data_valid`. While `kv_data_valid` is high, `k_tile` and `v_tile`
must remain stable until `kv_data_valid && kv_data_ready`.

For the default `S_LEN=256`, `BK=16`, each row requests 16 tiles. For
non-divisible configurations, the final tile length is clamped through
`kv_req_len`; entries above `kv_req_len` in the final tile are ignored.

## O Row Output

The core raises `o_valid` with `o_row` and `o_data[D_MODEL]`. The downstream
consumer accepts the row with `o_ready`.

If `o_ready` is low, `o_valid`, `o_row`, and all `o_data` lanes must remain
stable until the row is accepted. Rows are emitted in increasing order from `0`
to `S_LEN - 1`.

## Fixed-Point Behavior To Mirror In The Model

- Q/K/V/O are signed Q8.8 containers.
- Dot product is a signed integer MAC over Q8.8 payloads.
- The dot value is shifted by `FRAC_W`, multiplied by Q8.8 `scale`, then shifted
  by `FRAC_W` again before softmax.
- Causal masking ignores keys with `key_index > query_index` when `causal_en`
  is set.
- Online softmax tracks `m`, `l`, `old_scale`, and `new_weight`.
- Exponential weights are Q0.8 and use the 64-entry LUT in
  `online_softmax_engine.sv`.
- The value accumulator stores `weight * V_q8.8`; normalization divides by the
  Q0.8 denominator and saturates back to signed Q8.8.

## Current Verification Hooks

- `sim/run_member_b_week1.ps1` runs short bit-exact and backpressure checks.
- `sim/run_member_b_fullsize.ps1` runs the default `S=256`, `D=64`, `BK=16`
  no-deadlock core smoke and reports total core cycles.
