# Baseline Genus iSpatial Summary

Source package: `baseline_6.5`
Branch: `codex-baseline-core-pipeline-fmax`
Commit: `9d1d4d8`

| Metric | Result |
|---|---:|
| Clock period | 8 ns |
| Critical path slack | +1.7 ps |
| TNS | 0.0 |
| Violating paths | 0 |
| Cell area | 7841248.502 |
| Net area | 5746429.191 |
| Total area | 13587677.693 |
| Total power | 2.06683 W |

Critical path summary from `synth/reports_ispatial/30_timing.rpt`:

| Field | Value |
|---|---|
| Status | MET |
| Slack | +2 ps |
| Startpoint | `u_flash_core/u_dot_product_tree_chunk_q_reg[0]/CLK` |
| Endpoint | `u_flash_core/u_dot_product_dot_reg[35]/SCD` |
| Data path | 7629 ps |

The handout requires 10 ns timing clean for submission; this baseline synthesis run is
clean at 8 ns.
