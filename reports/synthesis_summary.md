# Bonus Genus iSpatial Summary

Source package: `bonus_6.6`
Branch: `codex-bonus-integrated-static-scale-fmax`
Synthesis commit: `f6ded9a`
Current branch head: `c529f47`

The commits after `f6ded9a` add simulation/report evidence and script portability only;
the RTL used by synthesis is unchanged.

| Metric | Result |
|---|---:|
| Clock period | 8 ns |
| Critical path slack | +1.3 ps |
| TNS | 0.0 |
| Violating paths | 0 |
| Cell area | 7918810.862 |
| Net area | 6315329.605 |
| Total area | 14234140.467 |
| Total power | 2.10594 W |
| **Gate equivalent (NAND2)** | **≈ 1,651,404 (≈ 165.1 万)** |

Gate-equivalent (handout area metric):

```text
gate_equivalent = cell_area / area(NAND2_X1) = 7918810.862 / 4.7952 ≈ 1,651,404  (≈ 165.1 万)
limit 2,000,000 → 82.6% used  (PASS)
```

`NAND2_X1` cell area = 4.7952 um^2. Cell area (standard cells, excluding net/routing) is
used per the 2-input-NAND equivalent convention. This is ~16k gates above the baseline
(1,635,229), i.e. the added logic of all nine bonus features. Replace the divisor if the
evaluation library reports a different NAND2 area.

Critical path summary from `synth/reports_ispatial/30_timing.rpt`:

| Field | Value |
|---|---|
| Status | MET |
| Slack | +1 ps |
| Startpoint | `u_flash_core/q_proc_index_q_reg[2]/CLK` |
| Endpoint | `u_flash_core/l_update_q_reg[21]/D` |
| Data path | 7778 ps |

The handout requires 10 ns timing clean for submission; this integrated bonus synthesis
run is clean at 8 ns.
