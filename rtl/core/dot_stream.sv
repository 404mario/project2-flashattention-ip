`timescale 1ns/1ps
//============================================================================
// dot_stream - fully-pipelined dot product, II=1 (one result per cycle)
//----------------------------------------------------------------------------
// v2 streaming front-end. Accepts a (q_vec, k_vec) pair every cycle with
// `in_valid`; emits `dot = sum_d q_vec[d]*k_vec[d]` on `out_valid`, LATENCY
// cycles later. Throughput is 1 dot/cycle regardless of D_MODEL (the adder
// tree is registered per level), which is what lets the inner loop run at II=1
// and keeps each pipeline stage short (5ns-friendly) -- unlike the baseline
// dot_product_engine, which serializes D_MODEL/DOT_LANES chunks per result.
//
// LATENCY = TREE_LEVELS + 1  (1 cycle to register the products, then one cycle
// per adder-tree level). For D_MODEL=64 -> LEAVES=64, LEVELS=6 -> LATENCY=7.
//============================================================================
module dot_stream #(
    parameter int D_MODEL = 64,
    parameter int DATA_W  = 16,
    parameter int ACC_W   = 36
) (
    input  logic clk,
    input  logic rst_n,

    input  logic in_valid,
    input  logic signed [DATA_W-1:0] q_vec [0:D_MODEL-1],
    input  logic signed [DATA_W-1:0] k_vec [0:D_MODEL-1],

    output logic out_valid,
    output logic signed [ACC_W-1:0] dot
);
    localparam int PROD_W = DATA_W * 2;

    function automatic int calc_leaves(input int n);
        int v;
        begin
            v = 1;
            while (v < n) v = v << 1;
            calc_leaves = v;
        end
    endfunction

    localparam int LEAVES  = calc_leaves(D_MODEL);
    localparam int LEVELS  = (LEAVES <= 1) ? 0 : $clog2(LEAVES);
    // LATENCY = LEVELS + 2: +1 (register products) + 1 (NEW operand-register stage).
    // The extra stage splits the long "feed_idx -> k_tile 16:1 mux -> route" (~1.5ns)
    // out of the 16x16 multiply (~2.95ns) so neither sits with the other in one cycle
    // -> the dot critical path drops from ~4.78ns to ~max(mux, multiply) ~3.2ns,
    // clearing 4.5ns (and 4.0ns). Latency-insensitive: flash_core counts dot_out_valid
    // (flash_core.sv:317/394), so +1 latency only adds pipeline-drain cycles; the dot
    // value for each (q_row,key) is bit-identical (same products, same tree, +1 cyc).
    localparam int LATENCY = LEVELS + 2;

    // node_q[l] holds the registered partial sums at tree level l.
    // level 0 = registered products; level LEVELS = final scalar dot.
    logic signed [ACC_W-1:0] node_q [0:LEVELS][0:LEAVES-1];
    logic [LATENCY-1:0]      vpipe_q;

    // NEW operand-register stage: the selected q/k operands are registered BEFORE
    // the multiply (q_vec is stable across a feed, k_vec is the fast 16:1 k_tile mux).
    logic signed [DATA_W-1:0] q_op_q [0:D_MODEL-1];
    logic signed [DATA_W-1:0] k_op_q [0:D_MODEL-1];
    integer op;

    function automatic logic signed [ACC_W-1:0] sext_prod(input logic signed [PROD_W-1:0] p);
        sext_prod = {{(ACC_W-PROD_W){p[PROD_W-1]}}, p};
    endfunction

    genvar l, i;
    integer p;

    // Stage -1 (NEW): register the selected operands before the multiply, so the
    // k_tile mux + routing is no longer in series with the multiply within one cycle.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (op = 0; op < D_MODEL; op = op + 1) begin
                q_op_q[op] <= '0;
                k_op_q[op] <= '0;
            end
        end else begin
            for (op = 0; op < D_MODEL; op = op + 1) begin
                q_op_q[op] <= q_vec[op];
                k_op_q[op] <= k_vec[op];
            end
        end
    end

    // Level 0: register the lane products (0 for padding lanes beyond D_MODEL).
    // Multiplies the REGISTERED operands -> the multiply now stands alone in its stage.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (p = 0; p < LEAVES; p = p + 1) node_q[0][p] <= '0;
        end else begin
            for (p = 0; p < LEAVES; p = p + 1) begin
                if (p < D_MODEL) node_q[0][p] <= sext_prod(q_op_q[p] * k_op_q[p]);
                else             node_q[0][p] <= '0;
            end
        end
    end

    // Levels 1..LEVELS: registered pairwise adders.
    generate
        for (l = 0; l < LEVELS; l = l + 1) begin : gen_level
            for (i = 0; i < (LEAVES >> (l + 1)); i = i + 1) begin : gen_node
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) node_q[l + 1][i] <= '0;
                    else        node_q[l + 1][i] <= node_q[l][i * 2] + node_q[l][i * 2 + 1];
                end
            end
        end
    endgenerate

    // Valid shift register matched to the datapath latency.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) vpipe_q <= '0;
        else        vpipe_q <= {vpipe_q[LATENCY-2:0], in_valid};
    end

    assign dot       = node_q[LEVELS][0];
    assign out_valid = vpipe_q[LATENCY-1];
endmodule
