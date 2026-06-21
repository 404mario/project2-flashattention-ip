`timescale 1ns/1ps
//============================================================================
// fp_exp - hardware exp(x) for x <= 0, via range reduction (Bonus #1 complete).
//----------------------------------------------------------------------------
// online-softmax only ever needs exp(delta) with delta = s_j - m <= 0, result in
// (0,1]. Instead of one big whole-range table, this uses the floating-point-style
// decomposition exp(x) = 2^(x*log2e) = 2^(-(n+f)) = 2^(-n) * 2^(-f):
//   y    = (-x) * log2e          (>= 0)
//   n    = floor(y)              integer  -> right shift
//   f    = y - n  in [0,1)       fractional -> 2^(-f) in (0.5,1] via LUT16+interp
//   exp  = (2^(-f)) >> n
// This is "硬件化 exp" (range reduction + small fractional table), distinct from
// the core's existing 64-entry delta table. Combinational functional unit; it is
// instantiated only in BF16_COMPUTE_MODE, so the default path/timing is untouched.
//
// IN  : x  signed Q(IN_FRAC)   (delta; x>0 clamps to 1.0)
// OUT : w  unsigned Q(OUT_FRAC), value in [0, 1.0]
//============================================================================
module fp_exp #(
    parameter int IN_W    = 36,
    parameter int IN_FRAC = 16,
    parameter int OUT_W   = 18,
    parameter int OUT_FRAC= 16
) (
    input  logic signed [IN_W-1:0] x,
    output logic [OUT_W-1:0]       w
);
    localparam logic [OUT_W-1:0] ONE = (1 <<< OUT_FRAC);
    // log2(e) = 1.442695... in Q16
    localparam logic [16:0] LOG2E_Q16 = 17'd94548;   // round(1.442695*65536)

    // 2^(-f) for f = idx/16, idx=0..16, in Q16 (LUT16 + linear interp).
    function automatic logic [OUT_FRAC:0] pow2_negf(input logic [15:0] idx); // idx in Q16-frac units? no: 0..16
        begin
            case (idx)
                5'd0 : pow2_negf = 17'd65536; // 2^0
                5'd1 : pow2_negf = 17'd62757; // 2^(-1/16)
                5'd2 : pow2_negf = 17'd60097;
                5'd3 : pow2_negf = 17'd57549;
                5'd4 : pow2_negf = 17'd55109;
                5'd5 : pow2_negf = 17'd52773;
                5'd6 : pow2_negf = 17'd50535;
                5'd7 : pow2_negf = 17'd48393;
                5'd8 : pow2_negf = 17'd46341; // 2^(-1/2)
                5'd9 : pow2_negf = 17'd44376;
                5'd10: pow2_negf = 17'd42495;
                5'd11: pow2_negf = 17'd40693;
                5'd12: pow2_negf = 17'd38968;
                5'd13: pow2_negf = 17'd37316;
                5'd14: pow2_negf = 17'd35734;
                5'd15: pow2_negf = 17'd34219;
                default: pow2_negf = 17'd32768; // 2^-1
            endcase
        end
    endfunction

    logic [IN_W-1:0]    xabs;
    logic [IN_W+17:0]   y_full;     // (-x)*log2e, Q(IN_FRAC+16)
    logic [IN_W-1:0]    y_q16;      // y in Q16
    logic [IN_W-1:0]    n_int;      // integer part of y
    logic [15:0]        f_q16;      // fractional part of y, Q16
    logic [4:0]         seg;        // top 4 bits of frac -> LUT index 0..15
    logic [15:0]        seg_rem;    // remaining frac for interpolation (12 bits used)
    logic [OUT_FRAC:0]  p0, p1;
    logic signed [OUT_FRAC+2:0] pdiff;
    logic [OUT_FRAC+17:0] interp;
    logic [OUT_FRAC:0]  pfrac;      // 2^(-f) interpolated, Q16
    logic [OUT_W-1:0]   shifted;    // width = output width so w part-select is in range

    always_comb begin
        if (!x[IN_W-1]) begin           // x >= 0  -> exp = 1.0 (online-softmax: only x<=0 used)
            w = ONE;
        end else begin
            xabs   = (~x + 1'b1);
            y_full = xabs * LOG2E_Q16;                 // Q(IN_FRAC+16)
            y_q16  = y_full >> IN_FRAC;                 // Q16
            n_int  = y_q16 >> 16;                       // integer part
            f_q16  = y_q16[15:0];                       // fractional part Q16
            seg    = f_q16[15:12];                      // 0..15
            seg_rem= {4'b0, f_q16[11:0]};               // remaining 12 frac bits
            p0     = pow2_negf({11'd0, seg});
            p1     = (seg == 5'd15) ? 17'd32768 : pow2_negf({11'd0, (seg + 5'd1)});
            // linear interp: pfrac = p0 + (p1-p0)*seg_rem/4096
            pdiff  = $signed({1'b0,p1}) - $signed({1'b0,p0});
            interp = ($signed(pdiff) * $signed({1'b0, seg_rem})) >>> 12;
            pfrac  = p0 + interp[OUT_FRAC:0];
            // multiply by 2^(-n_int) = right shift
            if (n_int >= OUT_FRAC+1) shifted = '0;
            else                     shifted = pfrac >> n_int[5:0];
            w = shifted[OUT_W-1:0];
        end
    end
endmodule
