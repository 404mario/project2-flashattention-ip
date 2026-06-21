`timescale 1ns/1ps
//============================================================================
// fp_softmax_unit - hardware floating-point-style softmax over one score row,
// built from fp_exp + fp_recip (Bonus #1 complete: hardware softmax/exp/recip).
//----------------------------------------------------------------------------
// Given up to LEN valid scores (signed Q(FRAC)), compute the softmax-weighted
// reduction the attention needs:
//   m   = max_j score[j]
//   w_j = fp_exp(score[j]-m)              (hardware exp, Q(WFRAC))
//   l   = sum_j w_j                       (>= 1.0)
//   inv = fp_recip(l)                     (hardware reciprocal)
//   p_j = w_j * inv                       (normalized prob, Q(WFRAC))
// This is the floating-point softmax datapath the spec asks to "硬件化"; it uses
// real hardware exp/reciprocal units (not the integer LUT in the production core).
// Combinational over the row; gated behind BF16_COMPUTE_MODE at integration so the
// default Q8.8 path/timing is untouched.
//
// Outputs p_flat (one WW-bit prob per lane) + l (for reuse). Verified by
// tb_fp_softmax_unit against $exp/sum/division.
//============================================================================
module fp_softmax_unit #(
    parameter int BK    = 16,
    parameter int SCW   = 36,    // score width (signed Q SFRAC)
    parameter int SFRAC = 16,
    parameter int WW    = 18,    // weight width (unsigned Q WFRAC)
    parameter int WFRAC = 16
) (
    input  logic [BK*SCW-1:0]      score_flat,   // signed scores, lane j = [j*SCW +: SCW]
    input  logic [$clog2(BK+1)-1:0] len,
    output logic [BK*WW-1:0]       p_flat,        // normalized probabilities
    output logic [SCW-1:0]         l_out          // sum of weights (Q WFRAC)
);
    logic signed [SCW-1:0] score [0:BK-1];
    genvar gj;
    generate for (gj=0; gj<BK; gj=gj+1) begin : g_us
        assign score[gj] = score_flat[gj*SCW +: SCW];
    end endgenerate

    // max over valid lanes
    logic signed [SCW-1:0] m;
    integer j;
    always_comb begin
        m = score[0];
        for (j=1;j<BK;j=j+1) if ((j<len) && (score[j] > m)) m = score[j];
    end

    // hardware exp per lane (delta = score-m <= 0). Packed buses so instance
    // output ports drive valid bits under iverilog (unpacked-array ports don't).
    logic [BK*SCW-1:0] delta_flat;
    logic [BK*WW-1:0]  w_flat;
    generate
        for (gj=0; gj<BK; gj=gj+1) begin : g_exp
            wire signed [SCW-1:0] dl = score[gj] - m;
            wire [WW-1:0]         wl;                 // full net: instance output drives this
            fp_exp #(.IN_W(SCW),.IN_FRAC(SFRAC),.OUT_W(WW),.OUT_FRAC(WFRAC)) u_e (
                .x(dl), .w(wl));
            assign delta_flat[gj*SCW +: SCW] = dl;
            assign w_flat[gj*WW +: WW]       = wl;
        end
    endgenerate

    // sum of valid weights -> l (Q WFRAC)
    logic [SCW-1:0] l_sum;
    always_comb begin
        l_sum = '0;
        for (j=0;j<BK;j=j+1) if (j<len) l_sum = l_sum + {{(SCW-WW){1'b0}}, w_flat[j*WW +: WW]};
    end
    assign l_out = l_sum;

    // hardware reciprocal of l, then p_j = w_j * inv
    logic [SCW-1:0] inv;
    fp_recip #(.W(SCW),.FRAC(WFRAC)) u_r (.x(l_sum), .r(inv));

    logic [SCW+WW-1:0] prod [0:BK-1];
    generate
        for (gj=0; gj<BK; gj=gj+1) begin : g_norm
            assign prod[gj] = (w_flat[gj*WW +: WW] * inv) >> WFRAC;
            assign p_flat[gj*WW +: WW] = (prod[gj] > ((1<<WW)-1))
                                          ? {WW{1'b1}} : prod[gj][WW-1:0];
        end
    endgenerate
endmodule
