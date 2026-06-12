`timescale 1ns/1ps
//============================================================================
// flash_core (v2 streaming / II=1)  -- codex-baseline-v2-streaming-arch
//----------------------------------------------------------------------------
// Same ports/params as the baseline (drops into flash_attn_top unchanged), but
// the inner score->softmax->acc loop is replaced by the FlashAttention-2
// streaming datapath:
//   * dot_stream      : fully-pipelined dot, 1 score/cycle (front end)
//   * softmax_combine : tile-max + per-key MAC + cross-tile merge (back end;
//                       inner loop-carried path is ADD only, multiply hoisted)
// Schedule (per Q-block): load Q rows; for each K/V tile, for each block row
// with causal-valid keys, stream scores then combine into that row's (m,l,acc).
// row_first == (kv_start==0) since key 0 is causal-valid for every query row.
// Normalizer/emit/DMA handshake reused from the baseline.
//============================================================================
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
    parameter int STATIC_SCALE_Q8_8 = 32
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
    localparam int ROW_W    = (S_LEN <= 1) ? 1 : $clog2(S_LEN);
    localparam int LEN_W    = (BK <= 1) ? 1 : $clog2(BK + 1);
    localparam int D_IDX_W  = (D_MODEL <= 1) ? 1 : $clog2(D_MODEL);
    localparam int BQ_EFF   = (BQ < 1) ? 1 : ((BQ > S_LEN) ? S_LEN : BQ);
    localparam int BQ_IDX_W = (BQ_EFF <= 1) ? 1 : $clog2(BQ_EFF);
    localparam int BQ_LEN_W = (BQ_EFF <= 1) ? 1 : $clog2(BQ_EFF + 1);
    localparam int WEIGHT_W    = (SOFTMAX_FRAC >= DATA_W) ? (SOFTMAX_FRAC + 1) : DATA_W;
    localparam int WEIGHT_FRAC = SOFTMAX_FRAC;
    localparam int L_W         = SOFTMAX_FRAC + ROW_W + 4;
    localparam int SCALE_PROD_W = ACC_W + 32;
    localparam int SCALE_SHIFT  = (SOFTMAX_FRAC == FRAC_W) ? (2 * FRAC_W) : (3 * FRAC_W - SOFTMAX_FRAC);
    localparam logic signed [31:0] STATIC_SCALE_VALUE = STATIC_SCALE_Q8_8;
    localparam int DOT_LAT   = ((D_MODEL <= 1) ? 0 : $clog2(D_MODEL)) + 1;

    typedef enum logic [3:0] {
        ST_IDLE, ST_REQ_Q, ST_WAIT_Q, ST_REQ_KV, ST_WAIT_KV,
        ST_ROW_START, ST_SCORE, ST_COMBINE, ST_COMBINE_WAIT, ST_ROW_NEXT,
        ST_TILE_NEXT, ST_NORMALIZE, ST_NORMALIZE_DRAIN, ST_EMIT_O, ST_DONE
    } state_t;
    state_t state_q;

    logic [ROW_W-1:0]    q_block_start_q;
    logic [BQ_LEN_W-1:0] q_block_len_q;
    logic [BQ_IDX_W-1:0] q_load_index_q;
    logic [BQ_IDX_W-1:0] row_q;          // current block row being processed
    logic [BQ_IDX_W-1:0] emit_index_q;
    logic [ROW_W-1:0]    kv_start_q;
    logic [LEN_W-1:0]    kv_len_q;
    logic [D_IDX_W-1:0]  norm_index_q;
    logic [D_IDX_W-1:0]  norm_write_index_q;

    logic signed [DATA_W-1:0] q_block [0:BQ_EFF-1][0:D_MODEL-1];
    logic signed [ACC_W-1:0]  acc_block [0:BQ_EFF-1][0:D_MODEL-1];
    logic signed [ACC_W-1:0]  m_block [0:BQ_EFF-1];
    logic [L_W-1:0]           l_block [0:BQ_EFF-1];

    logic signed [DATA_W-1:0] o_data_q [0:D_MODEL-1];
    logic signed [31:0] scale_run_q;

    // ---- score streaming bookkeeping ----
    logic [LEN_W-1:0]         valid_cnt_q;     // causal-valid keys for current (row,tile)
    logic [LEN_W-1:0]         feed_idx_q;      // next key index fed to dot_stream
    logic [LEN_W-1:0]         recv_idx_q;      // next score slot to fill
    logic signed [ACC_W-1:0]  score_buf_q [0:BK-1];
    logic                     row_first_q;

    int comb_d, seq_q, seq_d;

    function automatic logic [BQ_LEN_W-1:0] calc_block_len(input logic [ROW_W-1:0] s);
        int rem; begin rem = S_LEN - s; calc_block_len = (rem > BQ_EFF) ? BQ_EFF[BQ_LEN_W-1:0] : rem[BQ_LEN_W-1:0]; end
    endfunction
    function automatic logic [LEN_W-1:0] calc_kv_len(input logic [ROW_W-1:0] s);
        int rem; begin rem = S_LEN - s; calc_kv_len = (rem > BK) ? BK[LEN_W-1:0] : rem[LEN_W-1:0]; end
    endfunction

    // current query row index and causal-valid key count for (row_q, tile)
    logic [ROW_W-1:0] cur_q_row;
    assign cur_q_row = q_block_start_q + row_q;
    logic [ROW_W:0]   causal_last_wide; // last valid local key index +1 within tile
    logic [LEN_W-1:0] row_valid_cnt;
    always_comb begin
        if (!causal_en) begin
            row_valid_cnt = kv_len_q;
        end else if (kv_start_q > cur_q_row) begin
            row_valid_cnt = '0;                       // whole tile is in the future
        end else begin
            // valid keys j: kv_start+j <= cur_q_row  => count = cur_q_row-kv_start+1, capped by kv_len
            causal_last_wide = ({1'b0, cur_q_row} - {1'b0, kv_start_q}) + 1'b1;
            row_valid_cnt = (causal_last_wide > kv_len_q) ? kv_len_q : causal_last_wide[LEN_W-1:0];
        end
    end
    // is this the last tile that can contribute to this block? (causal: up to last row)
    logic [ROW_W:0] block_last_row_wide;
    logic [ROW_W:0] next_kv_start_wide;
    assign block_last_row_wide = {1'b0, q_block_start_q} + q_block_len_q - 1'b1;
    assign next_kv_start_wide  = {1'b0, kv_start_q} + BK;
    logic tile_is_last;
    assign tile_is_last = (next_kv_start_wide >= S_LEN) ||
                          (causal_en && (next_kv_start_wide > block_last_row_wide));

    // ===== dot_stream front end =====
    logic                    dot_in_valid;
    logic signed [DATA_W-1:0] dot_q_vec [0:D_MODEL-1];
    logic signed [DATA_W-1:0] dot_k_vec [0:D_MODEL-1];
    logic                    dot_out_valid;
    logic signed [ACC_W-1:0] dot_value;
    int dv;
    always_comb begin
        for (dv = 0; dv < D_MODEL; dv = dv + 1) begin
            dot_q_vec[dv] = q_block[row_q][dv];
            dot_k_vec[dv] = k_tile[feed_idx_q][dv];
        end
    end
    dot_stream #(.D_MODEL(D_MODEL), .DATA_W(DATA_W), .ACC_W(ACC_W)) u_dot (
        .clk(clk), .rst_n(rst_n), .in_valid(dot_in_valid),
        .q_vec(dot_q_vec), .k_vec(dot_k_vec),
        .out_valid(dot_out_valid), .dot(dot_value)
    );

    // scale dot -> score (frac = SOFTMAX_FRAC), mirrors baseline scaling
    logic signed [31:0] scale_mult;
    logic signed [31:0] scale_start_value;
    logic signed [SCALE_PROD_W-1:0] scaled_product, legacy_scaled_product;
    logic signed [ACC_W-1:0] scaled_score_comb;
    assign scale_mult = (STATIC_SCALE_MODE != 0) ? STATIC_SCALE_VALUE : scale_run_q;
    assign scale_start_value = (STATIC_SCALE_MODE != 0) ? STATIC_SCALE_VALUE : scale;
    generate
        if ((STATIC_SCALE_MODE != 0) && (FRAC_W == 8) && (SOFTMAX_FRAC == 16) && (STATIC_SCALE_Q8_8 == 32)) begin : g32
            assign legacy_scaled_product = '0; assign scaled_product = '0;
            assign scaled_score_comb = dot_value >>> 3;
        end else if ((STATIC_SCALE_MODE != 0) && (FRAC_W == 8) && (SOFTMAX_FRAC == 16) && (STATIC_SCALE_Q8_8 == 64)) begin : g64
            assign legacy_scaled_product = '0; assign scaled_product = '0;
            assign scaled_score_comb = dot_value >>> 2;
        end else if ((STATIC_SCALE_MODE != 0) && (FRAC_W == 8) && (SOFTMAX_FRAC == 16) && (STATIC_SCALE_Q8_8 == 128)) begin : g128
            assign legacy_scaled_product = '0; assign scaled_product = '0;
            assign scaled_score_comb = dot_value >>> 1;
        end else if ((STATIC_SCALE_MODE != 0) && (FRAC_W == 8) && (SOFTMAX_FRAC == 16) && (STATIC_SCALE_Q8_8 == 256)) begin : g256
            assign legacy_scaled_product = '0; assign scaled_product = '0;
            assign scaled_score_comb = dot_value;
        end else begin : grun
            assign legacy_scaled_product = (dot_value >>> FRAC_W) * scale_mult;
            assign scaled_product = dot_value * scale_mult;
            assign scaled_score_comb = (SOFTMAX_FRAC == FRAC_W) ? (legacy_scaled_product >>> FRAC_W)
                                                                : (scaled_product >>> SCALE_SHIFT);
        end
    endgenerate

    // ===== softmax_combine back end =====
    logic                    sc_start;
    logic                    sc_busy, sc_done;
    logic signed [ACC_W-1:0] sc_m_out;
    logic [L_W-1:0]          sc_l_out;
    logic [D_MODEL*ACC_W-1:0] sc_acc_out_flat;
    logic signed [ACC_W-1:0] sc_acc_in [0:D_MODEL-1];
    int ai;
    always_comb for (ai = 0; ai < D_MODEL; ai = ai + 1) sc_acc_in[ai] = acc_block[row_q][ai];

    softmax_combine #(
        .D_MODEL(D_MODEL), .BK(BK), .DATA_W(DATA_W), .ACC_W(ACC_W),
        .WEIGHT_W(WEIGHT_W), .WEIGHT_FRAC(WEIGHT_FRAC), .SCORE_FRAC(SOFTMAX_FRAC), .L_W(L_W)
    ) u_combine (
        .clk(clk), .rst_n(rst_n), .start(sc_start), .row_first(row_first_q),
        .tile_len(valid_cnt_q), .score_in(score_buf_q), .v_tile(v_tile),
        .m_in(m_block[row_q]), .l_in(l_block[row_q]), .acc_in(sc_acc_in),
        .busy(sc_busy), .done(sc_done),
        .m_out(sc_m_out), .l_out(sc_l_out), .acc_out_flat(sc_acc_out_flat)
    );

    // ===== normalizer (reused) =====
    logic signed [ACC_W-1:0] norm_acc;
    logic [L_W-1:0]          norm_denom;
    logic                    norm_in_valid, norm_out_valid;
    logic signed [DATA_W-1:0] norm_out;
    normalizer #(.ACC_W(ACC_W), .L_W(L_W), .DATA_W(DATA_W)) u_norm (
        .clk(clk), .rst_n(rst_n), .in_valid(norm_in_valid),
        .acc(norm_acc), .denom(norm_denom), .out_valid(norm_out_valid), .out(norm_out)
    );

    genvar o_gen;
    generate
        for (o_gen = 0; o_gen < D_MODEL; o_gen = o_gen + 1) begin : gen_o
            assign o_data[o_gen] = o_data_q[o_gen];
        end
    endgenerate

    logic last_block;
    assign last_block = (({1'b0, q_block_start_q} + q_block_len_q) >= S_LEN);

    // -------- debug aliases for the shared VERBOSE-gated testbench --------
    // (only read when VERBOSE!=0, which our runs don't set; pruned in synth)
    logic                     dot_done;
    logic                     score_valid;
    logic [ROW_W-1:0]         current_q_row;
    logic [ROW_W-1:0]         current_key_index;
    logic signed [ACC_W-1:0]  scaled_score;
    logic signed [ACC_W-1:0]  masked_score;
    logic [WEIGHT_W-1:0]      old_scale;
    logic [WEIGHT_W-1:0]      new_weight;
    logic signed [ACC_W-1:0]  m_state_q;
    logic [L_W-1:0]           l_state_q;
    logic signed [ACC_W-1:0]  v_work_data [0:D_MODEL-1];
    logic signed [ACC_W-1:0]  acc_state_q [0:D_MODEL-1];
    logic signed [ACC_W-1:0]  acc_next    [0:D_MODEL-1];
    int dbg;
    assign dot_done          = dot_out_valid;
    assign score_valid       = dot_out_valid;
    assign current_q_row     = cur_q_row;
    assign current_key_index = kv_start_q + feed_idx_q;
    assign scaled_score      = scaled_score_comb;
    assign masked_score      = scaled_score_comb;
    assign old_scale         = '0;
    assign new_weight        = '0;
    assign m_state_q         = m_block[row_q];
    assign l_state_q         = l_block[row_q];
    always_comb for (dbg = 0; dbg < D_MODEL; dbg = dbg + 1) begin
        v_work_data[dbg] = v_tile[0][dbg];
        acc_state_q[dbg] = acc_block[row_q][dbg];
        acc_next[dbg]    = acc_block[row_q][dbg];
    end

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
        // accept the loaded tile when we are about to leave it (in ST_TILE_NEXT)
        kv_data_ready = (state_q == ST_TILE_NEXT);

        o_valid = (state_q == ST_EMIT_O);
        o_row   = q_block_start_q + emit_index_q;

        dot_in_valid = (state_q == ST_SCORE) && (feed_idx_q < valid_cnt_q);

        sc_start = (state_q == ST_COMBINE);

        for (comb_d = 0; comb_d < D_MODEL; comb_d = comb_d + 1)
            o_data_flat[comb_d*DATA_W +: DATA_W] = o_data_q[comb_d];

        norm_acc   = acc_block[emit_index_q][norm_index_q];
        norm_denom = l_block[emit_index_q];
        norm_in_valid = (state_q == ST_NORMALIZE);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= ST_IDLE;
            q_block_start_q <= '0; q_block_len_q <= '0; q_load_index_q <= '0;
            row_q <= '0; emit_index_q <= '0; kv_start_q <= '0; kv_len_q <= '0;
            norm_index_q <= '0; norm_write_index_q <= '0; scale_run_q <= '0;
            valid_cnt_q <= '0; feed_idx_q <= '0; recv_idx_q <= '0; row_first_q <= 1'b0;
            for (seq_q = 0; seq_q < BQ_EFF; seq_q = seq_q + 1) begin
                m_block[seq_q] <= '0; l_block[seq_q] <= '0;
                for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) begin
                    q_block[seq_q][seq_d] <= '0; acc_block[seq_q][seq_d] <= '0;
                end
            end
            for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) o_data_q[seq_d] <= '0;
            for (seq_d = 0; seq_d < BK; seq_d = seq_d + 1) score_buf_q[seq_d] <= '0;
        end else begin
            // normalize writeback (parallel, reused)
            if (norm_out_valid) begin
                o_data_q[norm_write_index_q] <= norm_out;
                if (norm_write_index_q != D_MODEL - 1)
                    norm_write_index_q <= norm_write_index_q + 1'b1;
            end

            // capture streamed scores (runs whenever dot_stream emits during scoring)
            if (dot_out_valid && (state_q == ST_SCORE)) begin
                score_buf_q[recv_idx_q] <= scaled_score_comb;
                recv_idx_q <= recv_idx_q + 1'b1;
            end

            unique case (state_q)
                ST_IDLE: if (start) begin
                    q_block_start_q <= '0; q_block_len_q <= calc_block_len('0);
                    q_load_index_q <= '0; row_q <= '0; emit_index_q <= '0;
                    kv_start_q <= '0; kv_len_q <= calc_kv_len('0);
                    norm_index_q <= '0; norm_write_index_q <= '0;
                    scale_run_q <= scale_start_value;
                    state_q <= ST_REQ_Q;
                end

                ST_REQ_Q: if (q_req_ready) state_q <= ST_WAIT_Q;

                ST_WAIT_Q: if (q_data_valid && q_data_ready) begin
                    for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1) begin
                        q_block[q_load_index_q][seq_d] <= q_data[seq_d];
                        acc_block[q_load_index_q][seq_d] <= '0;
                    end
                    m_block[q_load_index_q] <= '0; l_block[q_load_index_q] <= '0;
                    if ((q_load_index_q + 1'b1) < q_block_len_q) begin
                        q_load_index_q <= q_load_index_q + 1'b1; state_q <= ST_REQ_Q;
                    end else begin
                        kv_start_q <= '0; kv_len_q <= calc_kv_len('0);
                        row_q <= '0; state_q <= ST_REQ_KV;
                    end
                end

                ST_REQ_KV: if (kv_req_ready) state_q <= ST_WAIT_KV;

                ST_WAIT_KV: if (kv_data_valid) begin
                    row_q <= '0; state_q <= ST_ROW_START;
                end

                // decide whether this (row,tile) has work
                ST_ROW_START: begin
                    feed_idx_q <= '0; recv_idx_q <= '0;
                    valid_cnt_q <= row_valid_cnt;
                    row_first_q <= (kv_start_q == '0);
                    if (row_valid_cnt == '0) state_q <= ST_ROW_NEXT;   // skip (future tile for this row)
                    else                     state_q <= ST_SCORE;
                end

                // stream scores through dot_stream (II=1); capture handled above
                ST_SCORE: begin
                    if (feed_idx_q < valid_cnt_q) feed_idx_q <= feed_idx_q + 1'b1;
                    if ((recv_idx_q + (dot_out_valid ? 1 : 0)) >= valid_cnt_q) state_q <= ST_COMBINE;
                end

                ST_COMBINE: state_q <= ST_COMBINE_WAIT;   // sc_start pulse asserted in comb

                ST_COMBINE_WAIT: if (sc_done) begin
                    m_block[row_q] <= sc_m_out;
                    l_block[row_q] <= sc_l_out;
                    for (seq_d = 0; seq_d < D_MODEL; seq_d = seq_d + 1)
                        acc_block[row_q][seq_d] <= sc_acc_out_flat[seq_d*ACC_W +: ACC_W];
                    state_q <= ST_ROW_NEXT;
                end

                ST_ROW_NEXT: begin
                    if ((row_q + 1'b1) < q_block_len_q) begin
                        row_q <= row_q + 1'b1; state_q <= ST_ROW_START;
                    end else begin
                        state_q <= ST_TILE_NEXT;
                    end
                end

                ST_TILE_NEXT: begin
                    if (tile_is_last) begin
                        emit_index_q <= '0; norm_index_q <= '0; norm_write_index_q <= '0;
                        state_q <= ST_NORMALIZE;
                    end else begin
                        kv_start_q <= next_kv_start_wide[ROW_W-1:0];
                        kv_len_q   <= calc_kv_len(next_kv_start_wide[ROW_W-1:0]);
                        row_q <= '0; state_q <= ST_REQ_KV;
                    end
                end

                ST_NORMALIZE: begin
                    if (norm_index_q == D_MODEL - 1) state_q <= ST_NORMALIZE_DRAIN;
                    else norm_index_q <= norm_index_q + 1'b1;
                end

                ST_NORMALIZE_DRAIN: if (norm_out_valid && (norm_write_index_q == D_MODEL - 1))
                    state_q <= ST_EMIT_O;

                ST_EMIT_O: if (o_ready) begin
                    if ((emit_index_q + 1'b1) < q_block_len_q) begin
                        emit_index_q <= emit_index_q + 1'b1;
                        norm_index_q <= '0; norm_write_index_q <= '0; state_q <= ST_NORMALIZE;
                    end else if (last_block) begin
                        state_q <= ST_DONE;
                    end else begin
                        q_block_start_q <= ({1'b0, q_block_start_q} + q_block_len_q);
                        q_block_len_q <= calc_block_len(({1'b0, q_block_start_q} + q_block_len_q));
                        q_load_index_q <= '0; row_q <= '0; emit_index_q <= '0;
                        kv_start_q <= '0; norm_index_q <= '0; state_q <= ST_REQ_Q;
                    end
                end

                ST_DONE: state_q <= ST_IDLE;
                default: state_q <= ST_IDLE;
            endcase
        end
    end
endmodule
