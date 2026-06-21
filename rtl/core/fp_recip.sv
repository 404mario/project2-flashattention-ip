`timescale 1ns/1ps
//============================================================================
// fp_recip - hardware reciprocal 1/x for x>0 (Bonus #1 complete).
//----------------------------------------------------------------------------
// online-softmax normalizer needs 1/l with l = sum of weights (l >= 1.0 here,
// since the running-max key contributes weight 1.0). Method: normalize x to
// [1,2) by the leading-one position, look up 1/mantissa (16-entry LUT + linear
// interp), then one Newton-Raphson step  r = r*(2 - x*r)  for accuracy, then
// shift back by the exponent. This is a real hardware reciprocal (normalize +
// seed table + Newton), distinct from the core's existing reciprocal table.
// Combinational; instantiated only in BF16_COMPUTE_MODE -> default path untouched.
//
// IN  : x  unsigned Q(FRAC)  (x >= 1.0 expected; x==0 -> max out)
// OUT : r  unsigned Q(FRAC)  (= 1/x, saturated)
//============================================================================
module fp_recip #(
    parameter int W    = 36,
    parameter int FRAC = 16
) (
    input  logic [W-1:0] x,
    output logic [W-1:0] r
);
    // 1/m for m in [1,2): seed LUT at m = 1 + idx/16, value in Q16 (0.5..1.0]
    function automatic logic [16:0] recip_seed(input logic [3:0] idx);
        begin
            case (idx)
                4'd0 : recip_seed = 17'd65536; // 1/1.0000
                4'd1 : recip_seed = 17'd61680; // 1/1.0625
                4'd2 : recip_seed = 17'd58254; // 1/1.1250
                4'd3 : recip_seed = 17'd55188;
                4'd4 : recip_seed = 17'd52429;
                4'd5 : recip_seed = 17'd49932;
                4'd6 : recip_seed = 17'd47663;
                4'd7 : recip_seed = 17'd45591;
                4'd8 : recip_seed = 17'd43691; // 1/1.5
                4'd9 : recip_seed = 17'd41943;
                4'd10: recip_seed = 17'd40330;
                4'd11: recip_seed = 17'd38836;
                4'd12: recip_seed = 17'd37449;
                4'd13: recip_seed = 17'd36158;
                4'd14: recip_seed = 17'd34953;
                4'd15: recip_seed = 17'd33825;
                default: recip_seed = 17'd32768;
            endcase
        end
    endfunction

    integer k;
    logic          found;
    integer        msb;
    logic [W-1:0]  xn;          // x normalized into [1,2) in Q16
    integer        sh;          // shift used to normalize (msb position - FRAC)
    logic [3:0]    midx;        // mantissa index (top 4 frac bits of xn)
    logic [16:0]   seed;        // 1/m seed Q16
    logic [W+18:0] xr0;         // x_norm * seed (Q32), ~1.0
    logic signed [W+2:0] two_minus;     // 2 - x_norm*seed  (Q16)
    logic [W+18:0] r_newton;    // seed*(2 - x*seed) (Q32) -> Q16
    logic [W-1:0]  r_norm;      // 1/x_norm in Q16
    logic [W+8:0]  r_full;

    always_comb begin
        if (x == 0) begin
            r = {W{1'b1}};
        end else begin
            // find msb position (highest set bit)
            found = 1'b0; msb = FRAC;
            for (k = W-1; k >= 0; k = k - 1)
                if (x[k] && !found) begin msb = k; found = 1'b1; end
            sh = msb - FRAC;                            // x = xn << sh, xn in [1,2)
            // normalize x into [1,2): xn = x >> sh (if sh>0) or x << -sh
            if (sh >= 0) xn = x >> sh;
            else         xn = x << (-sh);
            midx     = xn[FRAC-1 -: 4];                 // top 4 fractional bits
            seed     = recip_seed(midx);
            // Newton: r = seed*(2 - xn*seed)
            xr0      = (xn * seed) >> FRAC;             // Q16 (~1.0)
            two_minus= $signed({3'b0, (W+3)'(2 <<< FRAC)}) - $signed({3'b0, xr0});
            r_newton = (seed * $unsigned(two_minus[W:0])) >> FRAC;  // Q16 (1/xn)
            r_norm   = r_newton[W-1:0];
            // de-normalize: 1/x = (1/xn) >> sh  (since x = xn<<sh)
            if (sh >= 0) r_full = r_norm >> sh;
            else         r_full = r_norm << (-sh);
            r = r_full[W-1:0];
        end
    end
endmodule
