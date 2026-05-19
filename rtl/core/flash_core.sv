`timescale 1ns/1ps

module flash_core #(
    parameter int S_LEN   = 256,
    parameter int D_MODEL = 64,
    parameter int BK      = 16,
    parameter int DATA_W  = 16,
    parameter int ACC_W   = 48,
    parameter int FRAC_W  = 8
) (
    input  logic clk,
    input  logic rst_n,

    input  logic start,
    output logic busy,
    output logic done,
    output logic error,

    input  logic causal_en,
    input  logic signed [31:0] neg_large,
    input  logic signed [31:0] scale,

    output logic q_req_valid,
    output logic [$clog2(S_LEN)-1:0] q_req_row,
    input  logic q_req_ready,

    input  logic q_data_valid,
    input  logic signed [DATA_W-1:0] q_data [0:D_MODEL-1],
    output logic q_data_ready,

    output logic kv_req_valid,
    output logic [$clog2(S_LEN)-1:0] kv_req_start,
    output logic [$clog2(BK+1)-1:0]  kv_req_len,
    input  logic kv_req_ready,

    input  logic kv_data_valid,
    input  logic signed [DATA_W-1:0] k_tile [0:BK-1][0:D_MODEL-1],
    input  logic signed [DATA_W-1:0] v_tile [0:BK-1][0:D_MODEL-1],
    output logic kv_data_ready,

    output logic o_valid,
    output logic [$clog2(S_LEN)-1:0] o_row,
    output wire signed [DATA_W-1:0] o_data [0:D_MODEL-1],
    output logic [D_MODEL*DATA_W-1:0] o_data_flat,
    input  logic o_ready
);
    localparam int ROW_W       = (S_LEN <= 1) ? 1 : $clog2(S_LEN);
    localparam int LEN_W       = (BK <= 1) ? 1 : $clog2(BK + 1);
    localparam int WEIGHT_W    = 16;
    localparam int WEIGHT_FRAC = 8;
    localparam int L_W         = ACC_W;
    localparam int SCALE_PROD_W = ACC_W + 32;

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_REQ_Q,
        ST_WAIT_Q,
        ST_REQ_KV,
        ST_WAIT_KV,
        ST_PREP_KEY,
        ST_DOT_START,
        ST_DOT_WAIT,
        ST_NORMALIZE,
        ST_EMIT_O,
        ST_STEP,
        ST_DONE
    } state_t;

    state_t state_q;

    logic sched_start;
    logic sched_step;
    logic sched_valid;
    logic sched_done;
    logic [ROW_W-1:0] sched_row;
    logic [ROW_W-1:0] sched_kv_start;
    logic [LEN_W-1:0] sched_kv_len;
    logic sched_last_tile;
    logic sched_last_row;

    logic signed [DATA_W-1:0] q_row_data [0:D_MODEL-1];
    logic q_row_valid;
    logic row_load_ready;
    logic row_clear;

    logic signed [DATA_W-1:0] k_tile_data [0:BK-1][0:D_MODEL-1];
    logic signed [DATA_W-1:0] v_tile_data [0:BK-1][0:D_MODEL-1];
    logic tile_valid;
    logic tile_load_ready;
    logic tile_clear;

    logic signed [DATA_W-1:0] q_work_data [0:D_MODEL-1];
    logic signed [DATA_W-1:0] k_work_data [0:D_MODEL-1];
    logic signed [DATA_W-1:0] v_work_data [0:D_MODEL-1];
    logic signed [DATA_W-1:0] k_tile_store [0:BK-1][0:D_MODEL-1];
    logic signed [DATA_W-1:0] v_tile_store [0:BK-1][0:D_MODEL-1];

    logic dot_start;
    logic dot_busy;
    logic dot_done;
    logic signed [ACC_W-1:0] dot_value;

    logic [LEN_W-1:0] key_offset_q;
    logic [ROW_W-1:0] key_offset_ext;
    logic [ROW_W-1:0] current_key_index;

    logic signed [SCALE_PROD_W-1:0] scaled_product;
    logic signed [ACC_W-1:0] scaled_score;
    logic signed [ACC_W-1:0] masked_score;
    logic score_valid;

    logic signed [ACC_W-1:0] m_state_q;
    logic [L_W-1:0] l_state_q;
    logic signed [ACC_W-1:0] m_next;
    logic [L_W-1:0] l_next;
    logic [WEIGHT_W-1:0] old_scale;
    logic [WEIGHT_W-1:0] new_weight;
    logic signed [ACC_W-1:0] acc_state_q [0:D_MODEL-1];
    wire signed [ACC_W-1:0] acc_next [0:D_MODEL-1];
    logic signed [DATA_W-1:0] normalized_data [0:D_MODEL-1];

    logic signed [DATA_W-1:0] o_data_q [0:D_MODEL-1];
    int comb_d;
    int seq_d;
    int seq_b;
    genvar o_gen;
    genvar norm_gen;

    generate
        for (o_gen = 0; o_gen < D_MODEL; o_gen = o_gen + 1) begin : gen_o_data_assign
            assign o_data[o_gen] = o_data_q[o_gen];
        end
    endgenerate

    tile_scheduler #(
        .S_LEN(S_LEN),
        .BK(BK)
    ) u_scheduler (
        .clk(clk),
        .rst_n(rst_n),
        .start(sched_start),
        .step(sched_step),
        .valid(sched_valid),
        .done(sched_done),
        .row_index(sched_row),
        .kv_start(sched_kv_start),
        .kv_len(sched_kv_len),
        .first_tile(),
        .last_tile(sched_last_tile),
        .last_row(sched_last_row)
    );

    row_buffer #(
        .D_MODEL(D_MODEL),
        .DATA_W(DATA_W)
    ) u_q_row_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .clear(row_clear),
        .load_valid(q_data_valid && q_data_ready),
        .load_ready(row_load_ready),
        .load_data(q_data),
        .valid(q_row_valid),
        .row_data(q_row_data)
    );

    tile_buffer #(
        .BK(BK),
        .D_MODEL(D_MODEL),
        .DATA_W(DATA_W)
    ) u_kv_tile_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .clear(tile_clear),
        .load_valid(kv_data_valid && kv_data_ready),
        .load_ready(tile_load_ready),
        .k_load(k_tile),
        .v_load(v_tile),
        .valid(tile_valid),
        .k_data(k_tile_data),
        .v_data(v_tile_data)
    );

    dot_product_engine #(
        .D_MODEL(D_MODEL),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W)
    ) u_dot_product (
        .clk(clk),
        .rst_n(rst_n),
        .start(dot_start),
        .q_vec(q_work_data),
        .k_vec(k_work_data),
        .busy(dot_busy),
        .done(dot_done),
        .dot(dot_value)
    );

    causal_mask_unit #(
        .S_LEN(S_LEN),
        .SCORE_W(ACC_W)
    ) u_causal_mask (
        .causal_en(causal_en),
        .query_index(sched_row),
        .key_index(current_key_index),
        .score_in(scaled_score),
        .neg_large(neg_large),
        .score_valid(score_valid),
        .score_out(masked_score)
    );

    online_softmax_engine #(
        .SCORE_W(ACC_W),
        .L_W(L_W),
        .WEIGHT_W(WEIGHT_W),
        .WEIGHT_FRAC(WEIGHT_FRAC)
    ) u_online_softmax (
        .score_valid(score_valid),
        .score(masked_score),
        .m_in(m_state_q),
        .l_in(l_state_q),
        .m_out(m_next),
        .l_out(l_next),
        .old_scale(old_scale),
        .new_weight(new_weight)
    );

    value_accumulator #(
        .D_MODEL(D_MODEL),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W),
        .WEIGHT_W(WEIGHT_W),
        .WEIGHT_FRAC(WEIGHT_FRAC)
    ) u_value_accumulator (
        .acc_in(acc_state_q),
        .v_data(v_work_data),
        .old_scale(old_scale),
        .new_weight(new_weight),
        .acc_out(acc_next)
    );

    generate
        for (norm_gen = 0; norm_gen < D_MODEL; norm_gen = norm_gen + 1) begin : gen_normalizer
            normalizer #(
                .ACC_W(ACC_W),
                .L_W(L_W),
                .DATA_W(DATA_W)
            ) u_normalizer (
                .acc(acc_state_q[norm_gen]),
                .denom(l_state_q),
                .out(normalized_data[norm_gen])
            );
        end
    endgenerate

    assign key_offset_ext = key_offset_q;
    assign current_key_index = sched_kv_start + key_offset_ext;
    assign scaled_product = (dot_value >>> FRAC_W) * scale;
    assign scaled_score = scaled_product >>> FRAC_W;

    always_comb begin
        busy          = (state_q != ST_IDLE) && (state_q != ST_DONE);
        done          = (state_q == ST_DONE);
        error         = 1'b0;

        q_req_valid   = (state_q == ST_REQ_Q) && sched_valid;
        q_req_row     = sched_row;
        q_data_ready  = (state_q == ST_WAIT_Q) && row_load_ready;

        kv_req_valid  = (state_q == ST_REQ_KV) && sched_valid;
        kv_req_start  = sched_kv_start;
        kv_req_len    = sched_kv_len;
        kv_data_ready = (state_q == ST_WAIT_KV) && tile_load_ready;

        o_valid       = (state_q == ST_EMIT_O);
        o_row         = sched_row;
        for (comb_d = 0; comb_d < D_MODEL; comb_d = comb_d + 1) begin
            o_data_flat[comb_d * DATA_W +: DATA_W] = o_data_q[comb_d];
        end

        sched_start   = start && (state_q == ST_IDLE);
        sched_step    = 1'b0;
        dot_start     = (state_q == ST_DOT_START);
        row_clear     = sched_start;
        tile_clear    = sched_start;

        if (state_q == ST_STEP) begin
            sched_step = 1'b1;
            tile_clear = 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q      <= ST_IDLE;
            key_offset_q <= '0;
            m_state_q    <= '0;
            l_state_q    <= '0;

            for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) begin
                q_work_data[seq_d] <= '0;
                k_work_data[seq_d] <= '0;
                v_work_data[seq_d] <= '0;
                o_data_q[seq_d]    <= '0;
                acc_state_q[seq_d] <= '0;
            end

            for (seq_b = 0; seq_b < BK; seq_b = seq_b + 1) begin
                for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) begin
                    k_tile_store[seq_b][seq_d] <= '0;
                    v_tile_store[seq_b][seq_d] <= '0;
                end
            end
        end else begin
            case (state_q)
                ST_IDLE: begin
                    if (start) begin
                        state_q <= ST_REQ_Q;
                    end
                end

                ST_REQ_Q: begin
                    if (sched_valid && q_req_ready) begin
                        state_q <= ST_WAIT_Q;
                    end
                end

                ST_WAIT_Q: begin
                    if (q_data_valid && q_data_ready) begin
                        for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) begin
                            q_work_data[seq_d] <= q_data[seq_d];
                            acc_state_q[seq_d] <= '0;
                            o_data_q[seq_d]    <= '0;
                        end
                        m_state_q    <= '0;
                        l_state_q    <= '0;
                        key_offset_q <= '0;
                        state_q      <= ST_REQ_KV;
                    end
                end

                ST_REQ_KV: begin
                    if (sched_valid && kv_req_ready) begin
                        state_q <= ST_WAIT_KV;
                    end
                end

                ST_WAIT_KV: begin
                    if (kv_data_valid && kv_data_ready) begin
                        for (seq_b = 0; seq_b < BK; seq_b = seq_b + 1) begin
                            for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) begin
                                k_tile_store[seq_b][seq_d] <= k_tile[seq_b][seq_d];
                                v_tile_store[seq_b][seq_d] <= v_tile[seq_b][seq_d];
                            end
                        end
                        key_offset_q <= '0;
                        state_q      <= ST_PREP_KEY;
                    end
                end

                ST_PREP_KEY: begin
                    for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) begin
                        k_work_data[seq_d] <= k_tile_store[key_offset_q][seq_d];
                        v_work_data[seq_d] <= v_tile_store[key_offset_q][seq_d];
                    end
                    state_q <= ST_DOT_START;
                end

                ST_DOT_START: begin
                    state_q <= ST_DOT_WAIT;
                end

                ST_DOT_WAIT: begin
                    if (dot_done) begin
                        m_state_q <= m_next;
                        l_state_q <= l_next;
                        for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) begin
                            acc_state_q[seq_d] <= acc_next[seq_d];
                        end

                        if ((key_offset_q + 1'b1) < sched_kv_len) begin
                            key_offset_q <= key_offset_q + 1'b1;
                            state_q      <= ST_PREP_KEY;
                        end else if (sched_last_tile) begin
                            state_q <= ST_NORMALIZE;
                        end else begin
                            state_q <= ST_STEP;
                        end
                    end
                end

                ST_NORMALIZE: begin
                    for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) begin
                        o_data_q[seq_d] <= normalized_data[seq_d];
                    end
                    state_q <= ST_EMIT_O;
                end

                ST_EMIT_O: begin
                    if (o_ready) begin
                        if (sched_last_row && sched_last_tile) begin
                            state_q <= ST_DONE;
                        end else begin
                            state_q <= ST_STEP;
                        end
                    end
                end

                ST_STEP: begin
                    if (sched_last_tile) begin
                        state_q <= ST_REQ_Q;
                    end else begin
                        state_q <= ST_REQ_KV;
                    end
                end

                ST_DONE: begin
                    state_q <= ST_IDLE;
                end

                default: begin
                    state_q <= ST_IDLE;
                end
            endcase
        end
    end

    logic unused_internal;
    assign unused_internal = dot_busy ^ q_row_valid ^ tile_valid ^ sched_done ^
                             q_row_data[0][0] ^ k_tile_data[0][0][0] ^ v_tile_data[0][0][0];
endmodule
