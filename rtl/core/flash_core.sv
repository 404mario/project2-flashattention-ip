`timescale 1ns/1ps

module flash_core #(
    parameter int S_LEN           = 256,
    parameter int D_MODEL         = 64,
    parameter int BK              = 16,
    parameter int DATA_W          = 16,
    parameter int ACC_W           = 36,
    parameter int FRAC_W          = 8,
    parameter int BQ              = 1,
    parameter int USE_DOT_TREE    = 0,
    parameter int DOT_LANES       = D_MODEL,
    parameter int USE_CAUSAL_SKIP = 0,
    parameter int SOFTMAX_FRAC    = FRAC_W,
    parameter int STATIC_SCALE_MODE = 0,
    parameter int STATIC_SCALE_Q8_8 = 32,
    parameter int ENABLE_DROPOUT    = 1
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
    input  logic [31:0] valid_len,
    input  logic dropout_en,
    input  logic [15:0] dropout_threshold,
    input  logic [15:0] dropout_seed,
    input  logic [15:0] dropout_scale_q8_8,

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
    localparam int ROW_W        = (S_LEN <= 1) ? 1 : $clog2(S_LEN);
    localparam int LEN_W        = (BK <= 1) ? 1 : $clog2(BK + 1);
    localparam int D_IDX_W      = (D_MODEL <= 1) ? 1 : $clog2(D_MODEL);
    localparam int BQ_EFF       = (BQ < 1) ? 1 : ((BQ > S_LEN) ? S_LEN : BQ);
    localparam int BQ_IDX_W     = (BQ_EFF <= 1) ? 1 : $clog2(BQ_EFF);
    localparam int BQ_LEN_W     = (BQ_EFF <= 1) ? 1 : $clog2(BQ_EFF + 1);
    localparam int WEIGHT_W     = (SOFTMAX_FRAC > 8) ? 18 : 16;
    localparam int WEIGHT_FRAC  = SOFTMAX_FRAC;
    localparam int L_W          = ACC_W;
    localparam int SCALE_PROD_W = ACC_W + 32;
    localparam int SCALE_SHIFT  = (SOFTMAX_FRAC == FRAC_W) ? (2 * FRAC_W) :
                                  (3 * FRAC_W - SOFTMAX_FRAC);
    localparam logic [ROW_W:0] S_LEN_WIDE = S_LEN;

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
        ST_NORMALIZE_DRAIN,
        ST_EMIT_O,
        ST_SCORE_UPDATE,
        ST_DONE,
        ST_ADVANCE_SCORE
    } state_t;

    state_t state_q;

    logic [ROW_W-1:0]    q_block_start_q;
    logic [BQ_LEN_W-1:0] q_block_len_q;
    logic [BQ_IDX_W-1:0] q_load_index_q;
    logic [BQ_IDX_W-1:0] q_proc_index_q;
    logic [BQ_IDX_W-1:0] emit_index_q;
    logic [ROW_W-1:0]    kv_start_q;
    logic [LEN_W-1:0]    kv_len_q;
    logic [LEN_W-1:0]    key_offset_q;
    logic [D_IDX_W-1:0]  norm_index_q;

    logic signed [DATA_W-1:0] q_block [0:BQ_EFF-1][0:D_MODEL-1];
    logic signed [ACC_W-1:0]  acc_block [0:BQ_EFF-1][0:D_MODEL-1];
    logic signed [ACC_W-1:0]  m_block [0:BQ_EFF-1];
    logic [L_W-1:0]           l_block [0:BQ_EFF-1];

    logic signed [DATA_W-1:0] q_work_data [0:D_MODEL-1];
    logic signed [DATA_W-1:0] k_work_data [0:D_MODEL-1];
    logic signed [DATA_W-1:0] v_work_data [0:D_MODEL-1];

    logic dot_start;
    logic dot_busy;
    logic dot_done;
    logic signed [ACC_W-1:0] dot_value;

    logic [ROW_W-1:0] current_q_row;
    logic [ROW_W-1:0] current_key_index;
    logic [ROW_W-1:0] block_end_row;
    logic [ROW_W:0]   block_end_wide;
    logic [ROW_W:0]   next_block_start_wide;
    logic [ROW_W:0]   next_kv_start_wide;
    logic [ROW_W:0]   valid_len_clamped;
    logic             last_block;
    logic             tile_last_for_block;
    logic             score_should_skip;
    logic             advance_has_next_key;
    logic             advance_has_next_query;
    logic             advance_has_next_score;
    logic             advance_score_should_skip;
    logic [LEN_W-1:0]    advance_key_offset;
    logic [BQ_IDX_W-1:0] advance_q_proc_index;
    logic [ROW_W-1:0]    advance_q_row;
    logic [ROW_W-1:0]    advance_key_index;
    logic [ROW_W:0]      causal_first_valid_q_wide;
    logic [ROW_W:0]      causal_next_q_wide;
    logic [ROW_W:0]      causal_jump_q_wide;
    logic                causal_jump_has_score;
    logic [BQ_IDX_W-1:0] causal_jump_q_proc_index;

    wire signed [31:0] scale_eff;
    logic signed [SCALE_PROD_W-1:0] scaled_product;
    logic signed [SCALE_PROD_W-1:0] legacy_scaled_product;
    logic signed [ACC_W-1:0] scaled_score;
    logic signed [ACC_W-1:0] masked_score;
    logic score_valid;
    logic signed [31:0] scale_run_q;

    logic signed [ACC_W-1:0] m_state_q;
    logic [L_W-1:0] l_state_q;
    logic signed [ACC_W-1:0] m_softmax_next;
    logic [L_W-1:0] l_softmax_next;
    logic [WEIGHT_W-1:0] old_scale_softmax;
    logic [WEIGHT_W-1:0] new_weight_softmax;
    logic [WEIGHT_W-1:0] old_scale;
    logic [WEIGHT_W-1:0] new_weight;
    logic [WEIGHT_W-1:0] acc_new_weight;
    logic [15:0] dropout_rand;
    logic dropout_keep;
    logic signed [ACC_W-1:0] m_update_q;
    logic [L_W-1:0] l_update_q;
    logic [WEIGHT_W-1:0] old_scale_update_q;
    logic [WEIGHT_W-1:0] new_weight_update_q;
    logic signed [ACC_W-1:0] acc_state_q [0:D_MODEL-1];
    wire signed [ACC_W-1:0] acc_next [0:D_MODEL-1];

    logic signed [ACC_W-1:0] norm_acc;
    logic [L_W-1:0] norm_denom;
    logic norm_in_valid;
    logic norm_out_valid;
    logic signed [DATA_W-1:0] norm_out;
    logic [D_IDX_W-1:0] norm_write_index_q;
    logic signed [DATA_W-1:0] o_data_q [0:D_MODEL-1];

    int comb_d;
    int seq_d;
    int seq_q;
    genvar o_gen;

    function automatic logic [BQ_LEN_W-1:0] calc_block_len(input logic [ROW_W-1:0] start_index);
        int remaining;
        begin
            remaining = S_LEN - start_index;
            if (remaining > BQ_EFF) begin
                calc_block_len = BQ_EFF[BQ_LEN_W-1:0];
            end else begin
                calc_block_len = remaining[BQ_LEN_W-1:0];
            end
        end
    endfunction

    function automatic logic [LEN_W-1:0] calc_kv_len(input logic [ROW_W-1:0] start_index);
        int remaining;
        begin
            remaining = S_LEN - start_index;
            if (remaining > BK) begin
                calc_kv_len = BK[LEN_W-1:0];
            end else begin
                calc_kv_len = remaining[LEN_W-1:0];
            end
        end
    endfunction

    function automatic logic [15:0] dropout_rand16(
        input logic [ROW_W-1:0] query_index,
        input logic [ROW_W-1:0] key_index,
        input logic [15:0] seed
    );
        logic [31:0] x;
        begin
            x = {seed, seed ^ 16'hace1};
            x = x ^ ({16'd0, query_index} << 5);
            x = x ^ ({16'd0, query_index} << 13);
            x = x ^ ({16'd0, key_index} << 3);
            x = x ^ ({16'd0, key_index} << 17);
            x = x ^ (x << 7);
            x = x ^ (x >> 9);
            x = x ^ (x << 8);
            dropout_rand16 = x[15:0] ^ x[31:16];
        end
    endfunction

    function automatic logic [WEIGHT_W-1:0] dropout_weight(
        input logic [WEIGHT_W-1:0] weight,
        input logic keep,
        input logic [15:0] scale_q8_8
    );
        logic [WEIGHT_W+16:0] scaled;
        begin
            if (!keep) begin
                dropout_weight = '0;
            end else begin
                scaled = (weight * scale_q8_8 + 17'd128) >> 8;
                if (|scaled[WEIGHT_W+16:WEIGHT_W]) begin
                    dropout_weight = {WEIGHT_W{1'b1}};
                end else begin
                    dropout_weight = scaled[WEIGHT_W-1:0];
                end
            end
        end
    endfunction

    generate
        for (o_gen = 0; o_gen < D_MODEL; o_gen = o_gen + 1) begin : gen_o_data_assign
            assign o_data[o_gen] = o_data_q[o_gen];
        end
    endgenerate

    generate
        if (STATIC_SCALE_MODE != 0) begin : gen_static_scale
            assign scale_eff = STATIC_SCALE_Q8_8;
        end else begin : gen_runtime_scale
            assign scale_eff = scale;
        end
    endgenerate

    dot_product_engine #(
        .D_MODEL(D_MODEL),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W),
        .USE_TREE(USE_DOT_TREE),
        .DOT_LANES(DOT_LANES)
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
        .query_index(current_q_row),
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
        .WEIGHT_FRAC(WEIGHT_FRAC),
        .SCORE_FRAC(SOFTMAX_FRAC)
    ) u_online_softmax (
        .score_valid(score_valid),
        .score(masked_score),
        .m_in(m_state_q),
        .l_in(l_state_q),
        .m_out(m_softmax_next),
        .l_out(l_softmax_next),
        .old_scale(old_scale_softmax),
        .new_weight(new_weight_softmax)
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
        .old_scale(old_scale_update_q),
        .new_weight(new_weight_update_q),
        .acc_out(acc_next)
    );

    normalizer #(
        .ACC_W(ACC_W),
        .L_W(L_W),
        .DATA_W(DATA_W)
    ) u_shared_normalizer (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(norm_in_valid),
        .acc(norm_acc),
        .denom(norm_denom),
        .out_valid(norm_out_valid),
        .out(norm_out)
    );

    assign block_end_wide = {1'b0, q_block_start_q} + q_block_len_q - 1'b1;
    assign block_end_row = block_end_wide[ROW_W-1:0];
    assign next_block_start_wide = {1'b0, q_block_start_q} + q_block_len_q;
    assign last_block = (next_block_start_wide >= S_LEN);

    assign current_q_row = q_block_start_q + q_proc_index_q;
    assign current_key_index = kv_start_q + key_offset_q;
    assign next_kv_start_wide = {1'b0, kv_start_q} + BK;
    assign valid_len_clamped = (valid_len > S_LEN) ? S_LEN_WIDE : valid_len[ROW_W:0];
    assign tile_last_for_block =
        (next_kv_start_wide >= S_LEN) ||
        (next_kv_start_wide >= valid_len_clamped) ||
        ((USE_CAUSAL_SKIP != 0) && causal_en && (next_kv_start_wide > block_end_row));
    assign score_should_skip =
        ({1'b0, current_key_index} >= valid_len_clamped) ||
        ({1'b0, current_q_row} >= valid_len_clamped) ||
        ((USE_CAUSAL_SKIP != 0) && causal_en && (current_key_index > current_q_row));
    assign advance_has_next_key = ((key_offset_q + 1'b1) < kv_len_q);
    assign advance_has_next_query = ((q_proc_index_q + 1'b1) < q_block_len_q);
    assign advance_has_next_score = advance_has_next_key || advance_has_next_query;
    assign advance_key_offset =
        advance_has_next_key ? (key_offset_q + 1'b1) : '0;
    assign advance_q_proc_index =
        advance_has_next_key ? q_proc_index_q : (q_proc_index_q + 1'b1);
    assign advance_q_row = q_block_start_q + advance_q_proc_index;
    assign advance_key_index = kv_start_q + advance_key_offset;
    assign advance_score_should_skip =
        ({1'b0, advance_key_index} >= valid_len_clamped) ||
        ({1'b0, advance_q_row} >= valid_len_clamped) ||
        ((USE_CAUSAL_SKIP != 0) && causal_en && (advance_key_index > advance_q_row));
    assign causal_first_valid_q_wide =
        (kv_start_q > q_block_start_q) ? ({1'b0, kv_start_q} - {1'b0, q_block_start_q}) :
                                         {(ROW_W+1){1'b0}};
    assign causal_next_q_wide = {1'b0, q_proc_index_q} + 1'b1;
    assign causal_jump_q_wide =
        (causal_first_valid_q_wide > causal_next_q_wide) ? causal_first_valid_q_wide :
                                                           causal_next_q_wide;
    assign causal_jump_has_score = (causal_jump_q_wide < q_block_len_q);
    assign causal_jump_q_proc_index = causal_jump_q_wide[BQ_IDX_W-1:0];

    assign legacy_scaled_product = (dot_value >>> FRAC_W) * scale_run_q;
    assign scaled_product = dot_value * scale_run_q;
    assign scaled_score = (SOFTMAX_FRAC == FRAC_W) ?
                          (legacy_scaled_product >>> FRAC_W) :
                          (scaled_product >>> SCALE_SHIFT);
    assign old_scale = old_scale_softmax;
    assign new_weight = new_weight_softmax;

    generate
        if (ENABLE_DROPOUT != 0) begin : gen_dropout_path
            assign dropout_rand = dropout_rand16(current_q_row, current_key_index, dropout_seed);
            assign dropout_keep = !dropout_en || (dropout_rand >= dropout_threshold);
            assign acc_new_weight = dropout_en ?
                                    dropout_weight(new_weight, dropout_keep, dropout_scale_q8_8) :
                                    new_weight;
        end else begin : gen_no_dropout_path
            assign dropout_rand = '0;
            assign dropout_keep = 1'b1;
            assign acc_new_weight = new_weight;
        end
    endgenerate

    always_comb begin
        busy  = (state_q != ST_IDLE) && (state_q != ST_DONE);
        done  = (state_q == ST_DONE);
        error = 1'b0;

        q_req_valid  = (state_q == ST_REQ_Q);
        q_req_row    = q_block_start_q + q_load_index_q;
        q_data_ready = (state_q == ST_WAIT_Q);

        kv_req_valid  = (state_q == ST_REQ_KV);
        kv_req_start  = kv_start_q;
        kv_req_len    = kv_len_q;
        kv_data_ready = ((state_q == ST_ADVANCE_SCORE) || (state_q == ST_SCORE_UPDATE)) &&
                        !((key_offset_q + 1'b1) < kv_len_q) &&
                        !((q_proc_index_q + 1'b1) < q_block_len_q);

        o_valid = (state_q == ST_EMIT_O);
        o_row   = q_block_start_q + emit_index_q;

        dot_start = (state_q == ST_DOT_START);

        m_state_q = m_block[q_proc_index_q];
        l_state_q = l_block[q_proc_index_q];
        for (comb_d = 0; comb_d < D_MODEL; comb_d = comb_d + 1) begin
            acc_state_q[comb_d] = acc_block[q_proc_index_q][comb_d];
            o_data_flat[comb_d * DATA_W +: DATA_W] = o_data_q[comb_d];
        end

        norm_acc   = acc_block[emit_index_q][norm_index_q];
        norm_denom = l_block[emit_index_q];
        norm_in_valid = (state_q == ST_NORMALIZE);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q         <= ST_IDLE;
            q_block_start_q <= '0;
            q_block_len_q   <= '0;
            q_load_index_q  <= '0;
            q_proc_index_q  <= '0;
            emit_index_q    <= '0;
            kv_start_q      <= '0;
            kv_len_q        <= '0;
            key_offset_q    <= '0;
            norm_index_q    <= '0;
            norm_write_index_q <= '0;
            scale_run_q     <= '0;
            m_update_q      <= '0;
            l_update_q      <= '0;
            old_scale_update_q <= '0;
            new_weight_update_q <= '0;

            for (seq_q = 0; seq_q < BQ_EFF; seq_q = seq_q + 1) begin
                m_block[seq_q] <= '0;
                l_block[seq_q] <= '0;
                for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) begin
                    q_block[seq_q][seq_d]   <= '0;
                    acc_block[seq_q][seq_d] <= '0;
                end
            end

            for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) begin
                q_work_data[seq_d] <= '0;
                k_work_data[seq_d] <= '0;
                v_work_data[seq_d] <= '0;
                o_data_q[seq_d]    <= '0;
            end

        end else begin
            if (norm_out_valid) begin
                o_data_q[norm_write_index_q] <= norm_out;
                if (norm_write_index_q != D_MODEL - 1) begin
                    norm_write_index_q <= norm_write_index_q + 1'b1;
                end
            end

            unique case (state_q)
                ST_IDLE: begin
                    if (start) begin
                        q_block_start_q <= '0;
                        q_block_len_q   <= calc_block_len('0);
                        q_load_index_q  <= '0;
                        q_proc_index_q  <= '0;
                        emit_index_q    <= '0;
                        kv_start_q      <= '0;
                        kv_len_q        <= calc_kv_len('0);
                        key_offset_q    <= '0;
                        norm_index_q    <= '0;
                        norm_write_index_q <= '0;
                        scale_run_q     <= scale_eff;
                        state_q         <= ST_REQ_Q;
                    end
                end

                ST_REQ_Q: begin
                    if (q_req_ready) begin
                        state_q <= ST_WAIT_Q;
                    end
                end

                ST_WAIT_Q: begin
                    if (q_data_valid && q_data_ready) begin
                        for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) begin
                            q_block[q_load_index_q][seq_d]   <= q_data[seq_d];
                            acc_block[q_load_index_q][seq_d] <= '0;
                        end
                        m_block[q_load_index_q] <= '0;
                        l_block[q_load_index_q] <= '0;

                        if ((q_load_index_q + 1'b1) < q_block_len_q) begin
                            q_load_index_q <= q_load_index_q + 1'b1;
                            state_q        <= ST_REQ_Q;
                        end else begin
                            q_proc_index_q <= '0;
                            key_offset_q   <= '0;
                            kv_start_q     <= '0;
                            kv_len_q       <= calc_kv_len('0);
                            state_q        <= ST_REQ_KV;
                        end
                    end
                end

                ST_REQ_KV: begin
                    if (kv_req_ready) begin
                        state_q <= ST_WAIT_KV;
                    end
                end

                ST_WAIT_KV: begin
                    if (kv_data_valid) begin
                        q_proc_index_q <= '0;
                        key_offset_q   <= '0;
                        if (score_should_skip) begin
                            state_q <= ST_ADVANCE_SCORE;
                        end else begin
                            for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) begin
                                q_work_data[seq_d] <= q_block[0][seq_d];
                                k_work_data[seq_d] <= k_tile[0][seq_d];
                                v_work_data[seq_d] <= v_tile[0][seq_d];
                            end
                            state_q <= ST_DOT_START;
                        end
                    end
                end

                ST_PREP_KEY: begin
                    if (score_should_skip) begin
                        state_q <= ST_ADVANCE_SCORE;
                    end else begin
                        for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) begin
                            q_work_data[seq_d] <= q_block[q_proc_index_q][seq_d];
                            k_work_data[seq_d] <= k_tile[key_offset_q][seq_d];
                            v_work_data[seq_d] <= v_tile[key_offset_q][seq_d];
                        end
                        state_q <= ST_DOT_START;
                    end
                end

                ST_DOT_START: begin
                    state_q <= ST_DOT_WAIT;
                end

                ST_DOT_WAIT: begin
                    if (dot_done) begin
                        m_update_q           <= m_softmax_next;
                        l_update_q           <= l_softmax_next;
                        old_scale_update_q   <= old_scale_softmax;
                        new_weight_update_q  <= acc_new_weight;
                        state_q              <= ST_SCORE_UPDATE;
                    end
                end

                ST_SCORE_UPDATE: begin
                    m_block[q_proc_index_q] <= m_update_q;
                    l_block[q_proc_index_q] <= l_update_q;
                    for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) begin
                        acc_block[q_proc_index_q][seq_d] <= acc_next[seq_d];
                    end

                    if (advance_has_next_score) begin
                        q_proc_index_q <= advance_q_proc_index;
                        key_offset_q   <= advance_key_offset;
                        if (advance_score_should_skip) begin
                            state_q <= ST_ADVANCE_SCORE;
                        end else begin
                            for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) begin
                                q_work_data[seq_d] <= q_block[advance_q_proc_index][seq_d];
                                k_work_data[seq_d] <= k_tile[advance_key_offset][seq_d];
                                v_work_data[seq_d] <= v_tile[advance_key_offset][seq_d];
                            end
                            state_q <= ST_DOT_START;
                        end
                    end else if (tile_last_for_block) begin
                        emit_index_q <= '0;
                        norm_index_q <= '0;
                        norm_write_index_q <= '0;
                        state_q      <= ST_NORMALIZE;
                    end else begin
                        kv_start_q      <= next_kv_start_wide[ROW_W-1:0];
                        kv_len_q        <= calc_kv_len(next_kv_start_wide[ROW_W-1:0]);
                        q_proc_index_q  <= '0;
                        key_offset_q    <= '0;
                        state_q         <= ST_REQ_KV;
                    end
                end

                ST_ADVANCE_SCORE: begin
                    if (score_should_skip && causal_jump_has_score) begin
                        q_proc_index_q <= causal_jump_q_proc_index;
                        key_offset_q   <= '0;
                        for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) begin
                            q_work_data[seq_d] <= q_block[causal_jump_q_proc_index][seq_d];
                            k_work_data[seq_d] <= k_tile[0][seq_d];
                            v_work_data[seq_d] <= v_tile[0][seq_d];
                        end
                        state_q <= ST_DOT_START;
                    end else if (score_should_skip) begin
                        emit_index_q <= '0;
                        norm_index_q <= '0;
                        norm_write_index_q <= '0;
                        state_q      <= ST_NORMALIZE;
                    end else if (advance_has_next_score) begin
                        q_proc_index_q <= advance_q_proc_index;
                        key_offset_q   <= advance_key_offset;
                        if (advance_score_should_skip) begin
                            state_q <= ST_ADVANCE_SCORE;
                        end else begin
                            for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) begin
                                q_work_data[seq_d] <= q_block[advance_q_proc_index][seq_d];
                                k_work_data[seq_d] <= k_tile[advance_key_offset][seq_d];
                                v_work_data[seq_d] <= v_tile[advance_key_offset][seq_d];
                            end
                            state_q <= ST_DOT_START;
                        end
                    end else if (tile_last_for_block) begin
                        emit_index_q <= '0;
                        norm_index_q <= '0;
                        norm_write_index_q <= '0;
                        state_q      <= ST_NORMALIZE;
                    end else begin
                        kv_start_q      <= next_kv_start_wide[ROW_W-1:0];
                        kv_len_q        <= calc_kv_len(next_kv_start_wide[ROW_W-1:0]);
                        q_proc_index_q  <= '0;
                        key_offset_q    <= '0;
                        state_q         <= ST_REQ_KV;
                    end
                end

                ST_NORMALIZE: begin
                    if (norm_index_q == D_MODEL - 1) begin
                        state_q <= ST_NORMALIZE_DRAIN;
                    end else begin
                        norm_index_q <= norm_index_q + 1'b1;
                    end
                end

                ST_NORMALIZE_DRAIN: begin
                    if (norm_out_valid && (norm_write_index_q == D_MODEL - 1)) begin
                        state_q <= ST_EMIT_O;
                    end
                end

                ST_EMIT_O: begin
                    if (o_ready) begin
                        if ((emit_index_q + 1'b1) < q_block_len_q) begin
                            emit_index_q <= emit_index_q + 1'b1;
                            norm_index_q <= '0;
                            norm_write_index_q <= '0;
                            state_q      <= ST_NORMALIZE;
                        end else if (last_block) begin
                            state_q <= ST_DONE;
                        end else begin
                            q_block_start_q <= next_block_start_wide[ROW_W-1:0];
                            q_block_len_q   <= calc_block_len(next_block_start_wide[ROW_W-1:0]);
                            q_load_index_q  <= '0;
                            q_proc_index_q  <= '0;
                            emit_index_q    <= '0;
                            key_offset_q    <= '0;
                            norm_index_q    <= '0;
                            state_q         <= ST_REQ_Q;
                        end
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
endmodule
