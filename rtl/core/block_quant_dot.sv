`timescale 1ns/1ps
//============================================================================
// block_quant_dot - FA-3-style per-block (per-vector) INT8 block-quantized dot
//----------------------------------------------------------------------------
// Bonus #7 "complete" datapath element: instead of casting Q/K to int8 with one
// GLOBAL scale (the I/O-only mode), this quantizes EACH q_vec / k_vec to int8
// using ITS OWN amax-derived step, runs the dot product in INT8, then rescales
// the int8 result by (sq * sk). This is the block-quantization / per-block
// scaling FlashAttention-3 uses to keep dynamic range on heterogeneous blocks.
//
// Fixed-point contract (matches tb_block_quant_dot.sv integer spec exactly):
//   per-vector quant : amax = max|x|; step = ceil(amax/127) (>=1, integer LSBs);
//                      xq = clip(round(x/step away-from-0), -127, 127)
//   int8 dot         : idot = sum_d (qq[d]*qk[d])
//   rescale          : dot  = idot * step_q * step_k  -> same UNITS as raw q*k dot,
//                      so the downstream score-scaling path is unchanged.
//
// Combinational single-cycle functional model; instantiated only when
// BLOCK_QUANT_MODE!=0, so the default datapath (dot_stream) timing is untouched.
//============================================================================
module block_quant_dot #(
    parameter int D_MODEL = 64,
    parameter int DATA_W  = 16,
    parameter int ACC_W   = 40
) (
    // Flattened packed buses (element d = bits [d*DATA_W +: DATA_W]). Packed ports
    // propagate reliably under iverilog, unlike unpacked-array ports.
    input  logic [D_MODEL*DATA_W-1:0] q_flat,
    input  logic [D_MODEL*DATA_W-1:0] k_flat,
    output logic signed [ACC_W-1:0]  dot
);
    logic signed [DATA_W-1:0] q_vec [0:D_MODEL-1];
    logic signed [DATA_W-1:0] k_vec [0:D_MODEL-1];
    genvar gi;
    generate for (gi=0; gi<D_MODEL; gi=gi+1) begin : g_unpack
        assign q_vec[gi] = q_flat[gi*DATA_W +: DATA_W];
        assign k_vec[gi] = k_flat[gi*DATA_W +: DATA_W];
    end endgenerate
    // scalar helpers (iverilog-friendly: no array args)
    function automatic logic [DATA_W:0] step_of(input logic [DATA_W:0] amax);
        begin step_of = (amax == 0) ? 'd1 : ((amax + 'd126) / 'd127); end
    endfunction
    function automatic logic signed [8:0] q8(input logic signed [DATA_W-1:0] x,
                                             input logic [DATA_W:0] step);
        logic signed [DATA_W+2:0] half, num, r;
        begin
            half = $signed({1'b0, step}) >>> 1;
            num  = (x >= 0) ? ($signed(x) + half) : ($signed(x) - half);
            r    = num / $signed({1'b0, step});
            if (r >  127) r =  127;
            if (r < -127) r = -127;
            q8 = r[8:0];
        end
    endfunction

    integer i;
    logic [DATA_W:0] amax_q, amax_k, av, step_q, step_k;
    logic signed [ACC_W-1:0] idot;

    function automatic logic [DATA_W:0] sabs(input logic signed [DATA_W-1:0] x);
        begin sabs = x[DATA_W-1] ? ({1'b0, (~x + 1'b1)}) : {1'b0, x}; end
    endfunction

    always_comb begin
        // per-vector amax
        amax_q = '0; amax_k = '0;
        for (i = 0; i < D_MODEL; i = i + 1) begin
            av = sabs(q_vec[i]); if (av > amax_q) amax_q = av;
            av = sabs(k_vec[i]); if (av > amax_k) amax_k = av;
        end
        step_q = step_of(amax_q);
        step_k = step_of(amax_k);
        // int8 dot
        idot = '0;
        for (i = 0; i < D_MODEL; i = i + 1)
            idot = idot + ($signed(q8(q_vec[i], step_q))
                         * $signed(q8(k_vec[i], step_k)));
    end

    assign dot = idot * $signed({1'b0, step_q}) * $signed({1'b0, step_k});
endmodule
