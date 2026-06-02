`timescale 1ns/1ps

module dot_product_engine #(
    parameter int D_MODEL = 64,
    parameter int DATA_W  = 16,
    parameter int ACC_W   = 48,
    parameter int USE_TREE = 0,
    parameter int DOT_LANES = D_MODEL
) (
    input  logic clk,
    input  logic rst_n,

    input  logic start,
    input  logic signed [DATA_W-1:0] q_vec [0:D_MODEL-1],
    input  logic signed [DATA_W-1:0] k_vec [0:D_MODEL-1],

    output logic busy,
    output logic done,
    output logic signed [ACC_W-1:0] dot
);
    localparam int IDX_W = (D_MODEL <= 1) ? 1 : $clog2(D_MODEL);
    localparam int PROD_W = DATA_W * 2;

    function automatic int calc_tree_leaves(input int n);
        int value;
        begin
            value = 1;
            while (value < n) begin
                value = value << 1;
            end
            calc_tree_leaves = value;
        end
    endfunction

    localparam int DOT_LANES_EFF =
        (DOT_LANES < 1) ? D_MODEL : ((DOT_LANES > D_MODEL) ? D_MODEL : DOT_LANES);
    localparam int TREE_CHUNKS = (D_MODEL + DOT_LANES_EFF - 1) / DOT_LANES_EFF;
    localparam int CHUNK_IDX_W = (TREE_CHUNKS <= 1) ? 1 : $clog2(TREE_CHUNKS);
    localparam int TREE_LEAVES = calc_tree_leaves(DOT_LANES_EFF);
    localparam int TREE_LEVELS = (TREE_LEAVES <= 1) ? 0 : $clog2(TREE_LEAVES);

    logic [IDX_W-1:0] index_q;
    logic [CHUNK_IDX_W-1:0] tree_chunk_q;
    logic [IDX_W:0] tree_base;
    logic signed [ACC_W-1:0] acc_q;
    logic signed [PROD_W-1:0] product;
    logic busy_q;
    logic done_q;
    logic tree_busy_q;
    logic tree_done_q;
    logic signed [ACC_W-1:0] dot_comb;
    logic signed [ACC_W-1:0] dot_tree [0:TREE_LEVELS][0:TREE_LEAVES-1];
    int lane_i;
    int lane_index;
    genvar tree_i;
    genvar tree_l;

    assign product = q_vec[index_q] * k_vec[index_q];
    assign busy = (USE_TREE != 0) ? tree_busy_q : busy_q;
    assign done = (USE_TREE != 0) ? tree_done_q : done_q;
    assign tree_base = tree_chunk_q * DOT_LANES_EFF;

    function automatic logic signed [ACC_W-1:0] extend_product(
        input logic signed [PROD_W-1:0] value
    );
        begin
            extend_product = {{(ACC_W-PROD_W){value[PROD_W-1]}}, value};
        end
    endfunction

    always_comb begin
        for (lane_i = 0; lane_i < TREE_LEAVES; lane_i = lane_i + 1) begin
            lane_index = tree_base + lane_i;
            if ((lane_i < DOT_LANES_EFF) && (lane_index < D_MODEL)) begin
                dot_tree[0][lane_i] = extend_product(q_vec[lane_index] * k_vec[lane_index]);
            end else begin
                dot_tree[0][lane_i] = '0;
            end
        end
    end

    generate
        for (tree_l = 0; tree_l < TREE_LEVELS; tree_l = tree_l + 1) begin : gen_dot_tree_level
            for (tree_i = 0; tree_i < (TREE_LEAVES >> (tree_l + 1)); tree_i = tree_i + 1) begin : gen_dot_tree_sum
                always_comb begin
                    dot_tree[tree_l + 1][tree_i] =
                        dot_tree[tree_l][tree_i * 2] + dot_tree[tree_l][tree_i * 2 + 1];
                end
            end
        end
    endgenerate

    assign dot_comb = dot_tree[TREE_LEVELS][0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_q  <= 1'b0;
            done_q  <= 1'b0;
            dot     <= '0;
            acc_q   <= '0;
            index_q <= '0;
            tree_busy_q <= 1'b0;
            tree_done_q <= 1'b0;
            tree_chunk_q <= '0;
        end else begin
            done_q <= 1'b0;
            tree_done_q <= 1'b0;

            if (USE_TREE != 0) begin
                if (start && !tree_busy_q) begin
                    if (TREE_CHUNKS == 1) begin
                        dot         <= dot_comb;
                        tree_done_q <= 1'b1;
                    end else begin
                        acc_q        <= dot_comb;
                        tree_chunk_q <= 1;
                        tree_busy_q  <= 1'b1;
                    end
                end else if (tree_busy_q) begin
                    if (tree_chunk_q == (TREE_CHUNKS - 1)) begin
                        dot          <= acc_q + dot_comb;
                        acc_q        <= '0;
                        tree_chunk_q <= '0;
                        tree_busy_q  <= 1'b0;
                        tree_done_q  <= 1'b1;
                    end else begin
                        acc_q        <= acc_q + dot_comb;
                        tree_chunk_q <= tree_chunk_q + 1'b1;
                    end
                end
            end else begin
                if (start && !busy_q) begin
                    busy_q  <= 1'b1;
                    acc_q   <= '0;
                    index_q <= '0;
                    dot     <= '0;
                end else if (busy_q) begin
                    if (index_q == D_MODEL - 1) begin
                        dot     <= acc_q + extend_product(product);
                        busy_q  <= 1'b0;
                        done_q  <= 1'b1;
                        acc_q   <= '0;
                        index_q <= '0;
                    end else begin
                        acc_q   <= acc_q + extend_product(product);
                        index_q <= index_q + 1'b1;
                    end
                end
            end
        end
    end
endmodule
