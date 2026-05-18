# Interface Specification

## Member B Core Interface

`flash_core` is intentionally AXI-agnostic. It consumes rows and tiles from the
DMA/buffer side and returns one output row at a time.

```systemverilog
module flash_core #(
    parameter int S_LEN   = 256,
    parameter int D_MODEL = 64,
    parameter int BK      = 16,
    parameter int DATA_W  = 16,
    parameter int ACC_W   = 48,
    parameter int FRAC_W  = 8
)(...);
```

### Control

| Signal | Direction | Description |
|---|---:|---|
| `start` | input | One-cycle pulse to start a run. |
| `busy` | output | Asserted while the core state machine is active. |
| `done` | output | One-cycle completion indication after the final row is accepted. |
| `error` | output | Reserved for illegal states or downstream failures. |
| `causal_en` | input | Enables causal masking: keys with `key_index > query_index` are ignored. |
| `neg_large` | input | Mask score value, sign-extended into the core score width. |
| `scale` | input | Q8.8 attention scale applied after dot product. |

### Q Row Input

| Signal | Direction | Description |
|---|---:|---|
| `q_req_valid` | output | Core requests a Q row. |
| `q_req_row` | output | Requested row index. |
| `q_req_ready` | input | Producer accepts the request. |
| `q_data_valid` | input | Producer presents the requested row. |
| `q_data_ready` | output | Core can capture `q_data`. |
| `q_data[D_MODEL]` | input | Signed Q8.8 row payload. |

### K/V Tile Input

| Signal | Direction | Description |
|---|---:|---|
| `kv_req_valid` | output | Core requests a K/V tile. |
| `kv_req_start` | output | Starting K/V row index for the tile. |
| `kv_req_len` | output | Number of valid rows in the tile. |
| `kv_req_ready` | input | Producer accepts the request. |
| `kv_data_valid` | input | Producer presents the requested tile. |
| `kv_data_ready` | output | Core can capture `k_tile` and `v_tile`. |
| `k_tile[BK][D_MODEL]` | input | Signed Q8.8 K tile payload. |
| `v_tile[BK][D_MODEL]` | input | Signed Q8.8 V tile payload. |

### O Row Output

| Signal | Direction | Description |
|---|---:|---|
| `o_valid` | output | Core presents one O row. |
| `o_row` | output | Output row index. |
| `o_data[D_MODEL]` | output | Signed Q8.8 output row payload. |
| `o_ready` | input | Consumer accepts the row. |

### Handshake Stability Rules

- `start` is sampled only while `busy=0`; a new `start` pulse during a run is
  ignored.
- Producers may delay `q_req_ready`, `q_data_valid`, `kv_req_ready`, and
  `kv_data_valid` by any number of cycles.
- While `q_data_valid=1`, `q_data` must stay stable until `q_data_ready=1`.
- While `kv_data_valid=1`, `k_tile` and `v_tile` must stay stable until
  `kv_data_ready=1`.
- While `o_valid=1` and `o_ready=0`, `o_row` and all `o_data` lanes remain
  stable.
- `done` is a one-cycle pulse after the last output row is accepted.

See `docs/core_integration_contract.md` for the frozen Member B integration
contract and fixed-point behavior that the software model should mirror.

## Member B Internal Compute Modules

### `dot_product_engine`

Serial signed dot product.

```systemverilog
input  logic start
input  logic signed [DATA_W-1:0] q_vec [0:D_MODEL-1]
input  logic signed [DATA_W-1:0] k_vec [0:D_MODEL-1]
output logic busy
output logic done
output logic signed [ACC_W-1:0] dot
```

### `causal_mask_unit`

Applies causal masking to one score.

```systemverilog
input  logic causal_en
input  logic [ROW_W-1:0] query_index
input  logic [ROW_W-1:0] key_index
input  logic signed [SCORE_W-1:0] score_in
input  logic signed [31:0] neg_large
output logic score_valid
output logic signed [SCORE_W-1:0] score_out
```

### `online_softmax_engine`

Updates one online softmax state. Weights are Q0.8 by default. Negative
score deltas use a 64-entry exp LUT with 1/8-step addressing; deltas beyond the
covered range return zero weight.

```systemverilog
input  logic score_valid
input  logic signed [SCORE_W-1:0] score
input  logic signed [SCORE_W-1:0] m_in
input  logic [L_W-1:0] l_in
output logic signed [SCORE_W-1:0] m_out
output logic [L_W-1:0] l_out
output logic [WEIGHT_W-1:0] old_scale
output logic [WEIGHT_W-1:0] new_weight
```

### `value_accumulator`

Updates the weighted V accumulator vector.

```systemverilog
input  logic signed [ACC_W-1:0] acc_in [0:D_MODEL-1]
input  logic signed [DATA_W-1:0] v_data [0:D_MODEL-1]
input  logic [WEIGHT_W-1:0] old_scale
input  logic [WEIGHT_W-1:0] new_weight
output wire signed [ACC_W-1:0] acc_out [0:D_MODEL-1]
```

### `normalizer` And `quantize_saturate`

`normalizer` divides one accumulator lane by the denominator and then uses
`quantize_saturate` to clamp back to signed Q8.8.

```systemverilog
input  logic signed [ACC_W-1:0] acc
input  logic [L_W-1:0] denom
output logic signed [DATA_W-1:0] out
```

## Member B Memory Blocks

`row_buffer` and `tile_buffer` use a simple synchronous load interface:

```text
clear       clears valid state
load_valid captures payload when asserted
load_ready is always high in the Week 1 MVP
valid      indicates the stored payload is available
```
