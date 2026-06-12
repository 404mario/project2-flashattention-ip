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
    localparam int LATENCY = LEVELS + 1;

    // node_q[l] holds the registered partial sums at tree level l.
    // level 0 = registered products; level LEVELS = final scalar dot.
    logic signed [ACC_W-1:0] node_q [0:LEVELS][0:LEAVES-1];
    logic [LATENCY-1:0]      vpipe_q;

    function automatic logic signed [ACC_W-1:0] sext_prod(input logic signed [PROD_W-1:0] p);
        sext_prod = {{(ACC_W-PROD_W){p[PROD_W-1]}}, p};
    endfunction

    genvar l, i;
    integer p;

    // Level 0: register the lane products (0 for padding lanes beyond D_MODEL).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (p = 0; p < LEAVES; p = p + 1) node_q[0][p] <= '0;
        end else begin
            for (p = 0; p < LEAVES; p = p + 1) begin
                if (p < D_MODEL) node_q[0][p] <= sext_prod(q_vec[p] * k_vec[p]);
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
