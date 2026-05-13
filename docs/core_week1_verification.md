# Member B Core Verification

This note records the local checks for the Member B core/memory path.

## Scope

- `rtl/core/dot_product_engine.sv`: serial signed dot product.
- `rtl/core/causal_mask_unit.sv`: causal score masking.
- `rtl/core/online_softmax_engine.sv`: online max/denominator update with a deterministic Q0.8 fixed-point exp LUT.
- `rtl/core/value_accumulator.sv`: streaming softmax-weighted V accumulation.
- `rtl/core/normalizer.sv`: final accumulator normalization.
- `rtl/core/quantize_saturate.sv`: signed output saturation.
- `rtl/core/tile_scheduler.sv`: row and K/V tile traversal.
- `rtl/core/flash_core.sv`: tiled FlashAttention-style core using q/kv/o handshakes.
- `rtl/mem/row_buffer.sv`: current row buffer skeleton.
- `rtl/mem/tile_buffer.sv`: K/V tile buffer skeleton.

## Local Command

Run from the repository root on Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\sim\run_member_b_week1.ps1
```

The script compiles and runs bit-exact checks for:

- `tb/sv/tb_dot_product_engine.sv`
- `tb/sv/tb_tile_scheduler_bitexact.sv`
- `tb/sv/tb_buffers_bitexact.sv`
- `tb/sv/tb_flash_core_smoke.sv`
- `tb/sv/tb_flash_core_matrix16_bitexact.sv`
- `tb/sv/tb_flash_core_param_bitexact.sv`, compiled with multiple parameter sets

## Expected Result

The dot product test checks two signed examples with 4-state `!==` comparison.
The scheduler test checks every emitted row/tile/length/control bit for
`S_LEN=5`, `BK=2`. The buffer test checks row and K/V tile payloads bit-for-bit,
including negative and high-bit values.

The small full-core test runs `S_LEN=4`, `D_MODEL=4`, `BK=2`, enables causal
masking, drives the q/kv handshakes, computes a reference fixed-point online
softmax model in the testbench, and checks every output word with bit-exact
comparison.

The larger matrix core test runs `S_LEN=16`, `D_MODEL=16`, `BK=4`, enables
causal masking, checks Q row request order, all K/V tile requests, and every
output word with bit-exact comparison against the same fixed-point reference
model.

The parameterized full-core test is compiled multiple times to cover additional
shape and control combinations:

| S_LEN | D_MODEL | BK | Causal | Scale |
|---:|---:|---:|---:|---:|
| 5 | 3 | 8 | yes | 256 |
| 7 | 8 | 3 | yes | 384 |
| 9 | 5 | 4 | no | 512 |
| 13 | 12 | 5 | yes | 320 |

These cases cover `BK > S_LEN`, non-divisible final tiles, non-causal attention,
different model widths, and different Q8.8 scale values.
