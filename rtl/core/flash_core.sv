`timescale 1ns/1ps
//============================================================================
// flash_core (v2 streaming, OVERLAPPED pipeline) -- codex-baseline-v2-streaming-arch
//----------------------------------------------------------------------------
// Same ports/params as the baseline. FlashAttention-2 streaming datapath with a
// producer/consumer pipeline so scoring (dot_stream) for one (row,tile) overlaps
// the combine (softmax_combine) of the previous one, via 2 ping-pong score
// buffers. Inner loop-carried path = ADD only (multiply hoisted to per-tile
// merge), II=1 dot front end. DMA/normalizer/emit + BQ K/V reuse reused.
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
    parameter int STATIC_SCALE_Q8_8 = 32,
    parameter int ENABLE_DROPOUT    = 1,
    // Bonus #7 (complete): FA-3-style per-block INT8 block quantization for the
    // QK^T dot. 0 (default) = use the full-precision streaming dot (dot_stream);
    // default path & timing then bit-identical/untouched. 1 = each q/k vector is
    // int8 block-quantized (per-vector scale) before the dot.
    parameter int BLOCK_QUANT_MODE  = 0
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
    // ---- bonus controls ----
    input  logic [31:0] valid_len,            // padding mask: keys with global idx >= valid_len are invalid
    input  logic [31:0] window_len,           // ORIGINAL bonus: sliding-window (local) attention; 0/>=S = full causal
    input  logic        dropout_en,
    input  logic [15:0] dropout_threshold,
    input  logic [15:0] dropout_seed,
    input  logic [15:0] dropout_scale_q8_8,   // kept for register compat; cancels in normalized acc/l
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

    // ---- outer FSM (Q/KV load, tile loop, normalize, emit) ----
    typedef enum logic [3:0] {
        ST_IDLE, ST_REQ_Q, ST_WAIT_Q, ST_REQ_KV, ST_WAIT_KV,
        ST_TILE_RUN, ST_TILE_NEXT, ST_NORMALIZE, ST_NORMALIZE_DRAIN, ST_EMIT_O, ST_DONE
    } state_t;
    state_t state_q;

    logic [ROW_W-1:0]    q_block_start_q;
    logic [BQ_LEN_W-1:0] q_block_len_q;
    logic [BQ_IDX_W-1:0] q_load_index_q;
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
    logic signed [31:0]       scale_run_q;

    int comb_d, seq_q, seq_d;

    function automatic logic [BQ_LEN_W-1:0] calc_block_len(input logic [ROW_W-1:0] s);
        int rem; begin rem = S_LEN - s; calc_block_len = (rem > BQ_EFF) ? BQ_EFF[BQ_LEN_W-1:0] : rem[BQ_LEN_W-1:0]; end
    endfunction
    function automatic logic [LEN_W-1:0] calc_kv_len(input logic [ROW_W-1:0] s);
        int rem; begin rem = S_LEN - s; calc_kv_len = (rem > BK) ? BK[LEN_W-1:0] : rem[LEN_W-1:0]; end
    endfunction

    // valid_len padding mask (Bonus 4): keys with global index >= valid_len are
    // invalid. Clamp to S_LEN so the default (valid_len=S_LEN) is a no-op.
    localparam logic [ROW_W:0] S_LEN_WIDE = S_LEN;
    logic [ROW_W:0] valid_len_clamped;
    assign valid_len_clamped = (valid_len > S_LEN) ? S_LEN_WIDE : valid_len[ROW_W:0];

    // ORIGINAL BONUS: sliding-window / local attention (Longformer/Mistral style).
    // Query qrow attends only to keys in [qrow-window+1, qrow]. window_len 0 or >=S
    // disables it (= full causal, default -> no perf or output change).
    logic [ROW_W:0] window_clamped;
    assign window_clamped = (window_len == 0 || window_len >= S_LEN) ? S_LEN_WIDE : window_len[ROW_W:0];
    function automatic logic [ROW_W:0] window_lo(input logic [ROW_W-1:0] qrow);
        begin
            if (({1'b0, qrow} + 1'b1) > window_clamped) window_lo = ({1'b0, qrow} + 1'b1) - window_clamped;
            else                                        window_lo = '0;
        end
    endfunction

    // valid key count for (block row r, current tile): causal upper bound AND padding.
    // A key with tile-local index j (global = kv_start+j) is valid iff
    //   global < valid_len  AND  (causal ? global <= qrow : true).
    function automatic logic [LEN_W-1:0] valid_cnt_for(input logic [BQ_IDX_W-1:0] r);
        logic [ROW_W-1:0] qrow; logic [ROW_W:0] cnt; logic [ROW_W:0] pad_cnt;
        begin
            qrow = q_block_start_q + r;
            if (qrow >= valid_len_clamped) begin
                valid_cnt_for = '0;                       // invalid (padding) query row -> no output
            end else begin
                if (!causal_en) cnt = {1'b0, kv_len_q};
                else if (kv_start_q > qrow) cnt = '0;
                else cnt = (({1'b0, qrow} - {1'b0, kv_start_q}) + 1'b1);
                if (cnt > {1'b0, kv_len_q}) cnt = {1'b0, kv_len_q};
                // padding cap: keys before valid_len only
                if (kv_start_q >= valid_len_clamped) pad_cnt = '0;
                else pad_cnt = valid_len_clamped - {1'b0, kv_start_q};
                if (cnt > pad_cnt) cnt = pad_cnt;
                // sliding window: skip the whole tile if its last fed key is below
                // the window low bound (out-of-window keys inside a kept tile are
                // masked at score capture). Saves cycles in windowed mode.
                if ((cnt != 0) && (({1'b0, kv_start_q} + cnt - 1'b1) < window_lo(qrow))) cnt = '0;
                valid_cnt_for = cnt[LEN_W-1:0];
            end
        end
    endfunction

    // Dropout (Bonus 6): deterministic per-(query,key) hash; same RNG as the
    // baseline bonus core so drop decisions match. A dropped key's score is set
    // to the most-negative value so its softmax weight is exactly 0 (excluded
    // from l and acc). The keep-scale (dropout_scale_q8_8) cancels in the
    // normalized output acc/l, so it is intentionally not applied here.
    localparam logic signed [ACC_W-1:0] SCORE_NEG = {1'b1, {(ACC_W-1){1'b0}}};
    function automatic logic [15:0] dropout_rand16(
        input logic [ROW_W-1:0] query_index, input logic [ROW_W-1:0] key_index, input logic [15:0] seed);
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

    logic [ROW_W:0] block_last_row_wide, next_kv_start_wide;
    assign block_last_row_wide = {1'b0, q_block_start_q} + q_block_len_q - 1'b1;
    assign next_kv_start_wide  = {1'b0, kv_start_q} + BK;
    logic tile_is_last;
    assign tile_is_last = (next_kv_start_wide >= S_LEN) ||
                          (causal_en && (next_kv_start_wide > block_last_row_wide));
    logic last_block;
    assign last_block = (({1'b0, q_block_start_q} + q_block_len_q) >= S_LEN);

    // =======================================================================
    // Producer / consumer pipeline over the BQ rows of the current tile
    // =======================================================================
    // ping-pong score buffers
    logic signed [ACC_W-1:0] buf_score [0:1][0:BK-1];
    logic [LEN_W-1:0]        buf_vcnt  [0:1];
    logic                    buf_first [0:1];
    logic [BQ_IDX_W-1:0]     buf_row   [0:1];
    logic                    buf_ready [0:1];   // filled by producer, cleared by consumer

    typedef enum logic [1:0] { PS_IDLE, PS_SETUP, PS_FEED, PS_DONE } pstate_t;
    typedef enum logic [2:0] { CS_IDLE, CS_WAIT, CS_KICK, CS_RUN, CS_DONE } cstate_t;
    pstate_t pstate_q;
    logic [BQ_IDX_W-1:0] prod_row_q, cons_row_q;
    logic                prod_buf_q, cons_buf_q;
    logic [LEN_W-1:0]    feed_idx_q, recv_idx_q, prod_vcnt_q;
    logic                tile_run_q;            // 1 while the tile pipeline is active

    // ---- dot_stream front end (producer) ----
    logic                     dot_in_valid;
    logic signed [DATA_W-1:0] dot_q_vec [0:D_MODEL-1];
    logic signed [DATA_W-1:0] dot_k_vec [0:D_MODEL-1];
    logic                     dot_out_valid;
    logic signed [ACC_W-1:0]  dot_value;
    // Guarded key index: feed_idx_q can momentarily equal prod_vcnt_q (when the
    // feed has finished but the FSM hasn't advanced). dot_in_valid is low then, so
    // the value is unused, but clamp the index to keep it in [0,BK-1] and avoid any
    // out-of-bounds read of k_tile.
    logic [LEN_W-1:0] feed_idx_safe;
    assign feed_idx_safe = (feed_idx_q < BK) ? feed_idx_q : (BK[LEN_W-1:0] - 1'b1);
    int dv;
    always_comb for (dv = 0; dv < D_MODEL; dv = dv + 1) begin
        dot_q_vec[dv] = q_block[prod_row_q][dv];
        dot_k_vec[dv] = (dot_in_valid) ? k_tile[feed_idx_safe][dv] : '0;  // feed 0 when not valid
    end
    assign dot_in_valid = (pstate_q == PS_FEED) && (feed_idx_q < prod_vcnt_q);
    logic signed [ACC_W-1:0] dot_value_fp;       // full-precision streaming dot
    dot_stream #(.D_MODEL(D_MODEL), .DATA_W(DATA_W), .ACC_W(ACC_W)) u_dot (
        .clk(clk), .rst_n(rst_n), .in_valid(dot_in_valid),
        .q_vec(dot_q_vec), .k_vec(dot_k_vec), .out_valid(dot_out_valid), .dot(dot_value_fp)
    );

    // ---- Bonus #7 (complete): FA-3 per-block INT8 block-quant dot path ----
    // Combinational block_quant_dot on the same fed vectors, delayed by the SAME
    // latency as dot_stream so it aligns with dot_out_valid. Selected only when
    // BLOCK_QUANT_MODE!=0; otherwise dot_value == dot_value_fp (default untouched).
    function automatic int dot_latency(input int dmodel);
        int leaves, lv;
        begin leaves=1; while(leaves<dmodel) leaves=leaves<<1;
              lv=0; while((1<<lv)<leaves) lv=lv+1; dot_latency=lv+1; end
    endfunction
    localparam int BQ_LAT = dot_latency(D_MODEL);
    logic [D_MODEL*DATA_W-1:0] bq_q_flat, bq_k_flat;
    int bqi;
    always_comb for (bqi=0; bqi<D_MODEL; bqi=bqi+1) begin
        bq_q_flat[bqi*DATA_W +: DATA_W] = dot_q_vec[bqi];
        bq_k_flat[bqi*DATA_W +: DATA_W] = dot_k_vec[bqi];
    end
    logic signed [ACC_W-1:0] bq_dot_comb;
    generate
        if (BLOCK_QUANT_MODE != 0) begin : g_bq
            block_quant_dot #(.D_MODEL(D_MODEL), .DATA_W(DATA_W), .ACC_W(ACC_W)) u_bqdot (
                .q_flat(bq_q_flat), .k_flat(bq_k_flat), .dot(bq_dot_comb));
            logic signed [ACC_W-1:0] bq_pipe [0:BQ_LAT-1];
            integer bp;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) for (bp=0;bp<BQ_LAT;bp=bp+1) bq_pipe[bp] <= '0;
                else begin
                    bq_pipe[0] <= bq_dot_comb;
                    for (bp=1;bp<BQ_LAT;bp=bp+1) bq_pipe[bp] <= bq_pipe[bp-1];
                end
            end
            assign dot_value = bq_pipe[BQ_LAT-1];
        end else begin : g_fp
            assign bq_dot_comb = '0;
            assign dot_value   = dot_value_fp;
        end
    endgenerate

    // scale dot -> score (frac = SOFTMAX_FRAC)
    logic signed [31:0] scale_mult, scale_start_value;
    logic signed [SCALE_PROD_W-1:0] scaled_product, legacy_scaled_product;
    logic signed [ACC_W-1:0] scaled_score_comb;
    assign scale_mult = (STATIC_SCALE_MODE != 0) ? STATIC_SCALE_VALUE : scale_run_q;
    assign scale_start_value = (STATIC_SCALE_MODE != 0) ? STATIC_SCALE_VALUE : scale;
    generate
        if ((STATIC_SCALE_MODE != 0) && (FRAC_W == 8) && (SOFTMAX_FRAC == 16) && (STATIC_SCALE_Q8_8 == 32)) begin : g32
            assign legacy_scaled_product='0; assign scaled_product='0; assign scaled_score_comb = dot_value >>> 3;
        end else if ((STATIC_SCALE_MODE != 0) && (FRAC_W == 8) && (SOFTMAX_FRAC == 16) && (STATIC_SCALE_Q8_8 == 64)) begin : g64
            assign legacy_scaled_product='0; assign scaled_product='0; assign scaled_score_comb = dot_value >>> 2;
        end else if ((STATIC_SCALE_MODE != 0) && (FRAC_W == 8) && (SOFTMAX_FRAC == 16) && (STATIC_SCALE_Q8_8 == 128)) begin : g128
            assign legacy_scaled_product='0; assign scaled_product='0; assign scaled_score_comb = dot_value >>> 1;
        end else if ((STATIC_SCALE_MODE != 0) && (FRAC_W == 8) && (SOFTMAX_FRAC == 16) && (STATIC_SCALE_Q8_8 == 256)) begin : g256
            assign legacy_scaled_product='0; assign scaled_product='0; assign scaled_score_comb = dot_value;
        end else begin : grun
            assign legacy_scaled_product = (dot_value >>> FRAC_W) * scale_mult;
            assign scaled_product = dot_value * scale_mult;
            assign scaled_score_comb = (SOFTMAX_FRAC == FRAC_W) ? (legacy_scaled_product >>> FRAC_W) : (scaled_product >>> SCALE_SHIFT);
        end
    endgenerate

    // ---- softmax_combine back end (consumer) ----
    logic                    sc_start, sc_busy, sc_done;
    logic signed [ACC_W-1:0] sc_m_out;
    logic [L_W-1:0]          sc_l_out;
    logic [D_MODEL*ACC_W-1:0] sc_acc_out_flat;
    logic signed [ACC_W-1:0] sc_score_in [0:BK-1];
    logic signed [ACC_W-1:0] sc_acc_in [0:D_MODEL-1];
    logic [LEN_W-1:0]        sc_tile_len;
    logic                    sc_row_first;
    logic signed [ACC_W-1:0] sc_m_in;
    logic [L_W-1:0]          sc_l_in;
    cstate_t cstate_q;            // (declared here so sc_start can reference it)
    // ---- streamed v/score feed to softmax_combine (kills dynamic v_tile[j_q] mux) ----
    // u_combine asks for the next key via sc_vreq_*; we register v_tile[idx] and the
    // matching score here and feed them back. The 16:1 dynamic mux now lives in
    // flash_core behind a register (like k_tile[feed_idx_q] -> dot_stream), so the
    // physical advanced-structuring pass no longer builds a CDN_PAS_SKIP_MUX that
    // straddles the u_combine boundary (root fix for TUI-234). Bit-exact: the value
    // registered when idx=k was requested arrives the cycle u_combine MACs key k.
    logic                     sc_vreq_valid;
    logic [LEN_W-1:0]         sc_vreq_idx;
    logic signed [DATA_W-1:0] v_row_q [0:D_MODEL-1];
    logic signed [ACC_W-1:0]  score_cur_q;
    int si, ci;
    always_comb begin
        for (si = 0; si < BK; si = si + 1) sc_score_in[si] = buf_score[cons_buf_q][si];
        for (ci = 0; ci < D_MODEL; ci = ci + 1) sc_acc_in[ci] = acc_block[buf_row[cons_buf_q]][ci];
        sc_tile_len  = buf_vcnt[cons_buf_q];
        sc_row_first = buf_first[cons_buf_q];
        sc_m_in      = m_block[buf_row[cons_buf_q]];
        sc_l_in      = l_block[buf_row[cons_buf_q]];
    end
    assign sc_start = (cstate_q == CS_KICK);   // single-cycle pulse

    softmax_combine #(
        .D_MODEL(D_MODEL), .BK(BK), .DATA_W(DATA_W), .ACC_W(ACC_W),
        .WEIGHT_W(WEIGHT_W), .WEIGHT_FRAC(WEIGHT_FRAC), .SCORE_FRAC(SOFTMAX_FRAC), .L_W(L_W)
    ) u_combine (
        .clk(clk), .rst_n(rst_n), .start(sc_start), .row_first(sc_row_first),
        .tile_len(sc_tile_len), .score_in(sc_score_in),
        .vreq_valid(sc_vreq_valid), .vreq_idx(sc_vreq_idx),
        .v_row_in(v_row_q), .score_cur_in(score_cur_q),
        .m_in(sc_m_in), .l_in(sc_l_in), .acc_in(sc_acc_in),
        .busy(sc_busy), .done(sc_done), .m_out(sc_m_out), .l_out(sc_l_out), .acc_out_flat(sc_acc_out_flat)
    );

    // Prefetch the requested V row + score one cycle ahead of u_combine's S_MAC.
    // v_tile is held stable by the DMA/top for the whole tile; cons_buf_q is stable
    // across the kick+run window, so this delayed read is value-identical to the
    // old direct v_tile[j_q]/score_in[j_q] index, just registered.
    int pf;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (pf = 0; pf < D_MODEL; pf = pf + 1) v_row_q[pf] <= '0;
            score_cur_q <= '0;
        end else if (sc_vreq_valid) begin
            for (pf = 0; pf < D_MODEL; pf = pf + 1) v_row_q[pf] <= v_tile[sc_vreq_idx][pf];
            score_cur_q <= buf_score[cons_buf_q][sc_vreq_idx];
        end
    end

    // ---- normalizer (reused) ----
    logic signed [ACC_W-1:0] norm_acc;
    logic [L_W-1:0]          norm_denom;
    logic                    norm_in_valid, norm_out_valid;
    logic signed [DATA_W-1:0] norm_out;
    normalizer #(.ACC_W(ACC_W), .L_W(L_W), .DATA_W(DATA_W)) u_norm (
        .clk(clk), .rst_n(rst_n), .in_valid(norm_in_valid),
        .acc(norm_acc), .denom(norm_denom), .out_valid(norm_out_valid), .out(norm_out)
    );

    genvar o_gen;
    generate for (o_gen = 0; o_gen < D_MODEL; o_gen = o_gen + 1) begin : gen_o
        assign o_data[o_gen] = o_data_q[o_gen];
    end endgenerate

    // -------- debug aliases for the shared VERBOSE-gated testbench --------
    // Simulation-only: wrapped in synthesis translate_off so Genus never sees them
    // (cannot affect PPA / fanout). They only exist for the TB's VERBOSE probes.
    // synthesis translate_off
    logic dot_done, score_valid;
    logic [ROW_W-1:0] current_q_row, current_key_index;
    logic signed [ACC_W-1:0] scaled_score, masked_score;
    logic [WEIGHT_W-1:0] old_scale, new_weight;
    logic signed [ACC_W-1:0] m_state_q; logic [L_W-1:0] l_state_q;
    logic signed [ACC_W-1:0] v_work_data [0:D_MODEL-1];
    logic signed [ACC_W-1:0] acc_state_q [0:D_MODEL-1];
    logic signed [ACC_W-1:0] acc_next    [0:D_MODEL-1];
    int dbg;
    assign dot_done=dot_out_valid; assign score_valid=dot_out_valid;
    assign current_q_row=q_block_start_q+prod_row_q; assign current_key_index=kv_start_q+feed_idx_q;
    assign scaled_score=scaled_score_comb; assign masked_score=scaled_score_comb;
    assign old_scale='0; assign new_weight='0;
    assign m_state_q=m_block[cons_row_q]; assign l_state_q=l_block[cons_row_q];
    always_comb for (dbg=0; dbg<D_MODEL; dbg=dbg+1) begin
        v_work_data[dbg]=v_tile[0][dbg]; acc_state_q[dbg]=acc_block[cons_row_q][dbg]; acc_next[dbg]=acc_block[cons_row_q][dbg];
    end
    // synthesis translate_on

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
        kv_data_ready = (state_q == ST_TILE_NEXT);
        o_valid = (state_q == ST_EMIT_O);
        o_row   = q_block_start_q + emit_index_q;
        for (comb_d = 0; comb_d < D_MODEL; comb_d = comb_d + 1)
            o_data_flat[comb_d*DATA_W +: DATA_W] = o_data_q[comb_d];
        norm_acc   = acc_block[emit_index_q][norm_index_q];
        norm_denom = l_block[emit_index_q];
        norm_in_valid = (state_q == ST_NORMALIZE);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= ST_IDLE;
            q_block_start_q<='0; q_block_len_q<='0; q_load_index_q<='0; emit_index_q<='0;
            kv_start_q<='0; kv_len_q<='0; norm_index_q<='0; norm_write_index_q<='0; scale_run_q<='0;
            pstate_q<=PS_IDLE; cstate_q<=CS_IDLE; prod_row_q<='0; cons_row_q<='0;
            prod_buf_q<=1'b0; cons_buf_q<=1'b0; feed_idx_q<='0; recv_idx_q<='0; prod_vcnt_q<='0;
            tile_run_q<=1'b0;
            buf_ready[0]<=1'b0; buf_ready[1]<=1'b0;
            for (seq_q=0; seq_q<BQ_EFF; seq_q=seq_q+1) begin
                m_block[seq_q]<='0; l_block[seq_q]<='0;
                for (seq_d=0; seq_d<D_MODEL; seq_d=seq_d+1) begin q_block[seq_q][seq_d]<='0; acc_block[seq_q][seq_d]<='0; end
            end
            for (seq_d=0; seq_d<D_MODEL; seq_d=seq_d+1) o_data_q[seq_d]<='0;
        end else begin
            // normalize writeback
            if (norm_out_valid) begin
                o_data_q[norm_write_index_q] <= norm_out;
                if (norm_write_index_q != D_MODEL-1) norm_write_index_q <= norm_write_index_q + 1'b1;
            end

            // ---- producer: capture streamed scores into prod_buf ----
            // Dropout: the score emerging now belongs to key (kv_start+recv_idx)
            // of query (q_block_start+prod_row). If dropped, store the most-negative
            // score so its softmax weight is exactly 0 (excluded from l and acc).
            if (dot_out_valid && (pstate_q == PS_FEED)) begin
                if (// ORIGINAL bonus: mask keys below the sliding window
                    (({1'b0, kv_start_q} + {{(ROW_W+1-LEN_W){1'b0}}, recv_idx_q}) < window_lo(q_block_start_q + prod_row_q)) ||
                    // Bonus 6: dropout (forced most-negative -> softmax weight 0)
                    ((ENABLE_DROPOUT != 0) && dropout_en &&
                     (dropout_rand16(q_block_start_q + prod_row_q,
                                     kv_start_q + {{(ROW_W-LEN_W){1'b0}}, recv_idx_q},
                                     dropout_seed) < dropout_threshold)))
                    buf_score[prod_buf_q][recv_idx_q] <= SCORE_NEG;
                else
                    buf_score[prod_buf_q][recv_idx_q] <= scaled_score_comb;
                recv_idx_q <= recv_idx_q + 1'b1;
            end

            unique case (state_q)
                ST_IDLE: if (start) begin
                    q_block_start_q<='0; q_block_len_q<=calc_block_len('0); q_load_index_q<='0;
                    emit_index_q<='0; kv_start_q<='0; kv_len_q<=calc_kv_len('0);
                    norm_index_q<='0; norm_write_index_q<='0; scale_run_q<=scale_start_value;
                    state_q<=ST_REQ_Q;
                end
                ST_REQ_Q: if (q_req_ready) state_q<=ST_WAIT_Q;
                ST_WAIT_Q: if (q_data_valid && q_data_ready) begin
                    for (seq_d=0; seq_d<D_MODEL; seq_d=seq_d+1) begin
                        q_block[q_load_index_q][seq_d]<=q_data[seq_d]; acc_block[q_load_index_q][seq_d]<='0;
                    end
                    m_block[q_load_index_q]<='0; l_block[q_load_index_q]<='0;
                    if ((q_load_index_q+1'b1) < q_block_len_q) begin q_load_index_q<=q_load_index_q+1'b1; state_q<=ST_REQ_Q; end
                    else begin kv_start_q<='0; kv_len_q<=calc_kv_len('0); state_q<=ST_REQ_KV; end
                end
                ST_REQ_KV: if (kv_req_ready) state_q<=ST_WAIT_KV;
                ST_WAIT_KV: if (kv_data_valid) begin
                    // launch the tile pipeline
                    pstate_q<=PS_SETUP; cstate_q<=CS_WAIT;
                    prod_row_q<='0; cons_row_q<='0; prod_buf_q<=1'b0; cons_buf_q<=1'b0;
                    buf_ready[0]<=1'b0; buf_ready[1]<=1'b0;
                    state_q<=ST_TILE_RUN;
                end

                // tile pipeline active; producer+consumer FSMs below run.
                ST_TILE_RUN: if ((pstate_q==PS_DONE) && (cstate_q==CS_DONE)) state_q<=ST_TILE_NEXT;

                ST_TILE_NEXT: begin
                    if (tile_is_last) begin
                        emit_index_q<='0; norm_index_q<='0; norm_write_index_q<='0; state_q<=ST_NORMALIZE;
                    end else begin
                        kv_start_q<=next_kv_start_wide[ROW_W-1:0]; kv_len_q<=calc_kv_len(next_kv_start_wide[ROW_W-1:0]);
                        state_q<=ST_REQ_KV;
                    end
                end
                ST_NORMALIZE: if (norm_index_q==D_MODEL-1) state_q<=ST_NORMALIZE_DRAIN; else norm_index_q<=norm_index_q+1'b1;
                ST_NORMALIZE_DRAIN: if (norm_out_valid && (norm_write_index_q==D_MODEL-1)) state_q<=ST_EMIT_O;
                ST_EMIT_O: if (o_ready) begin
                    if ((emit_index_q+1'b1) < q_block_len_q) begin
                        emit_index_q<=emit_index_q+1'b1; norm_index_q<='0; norm_write_index_q<='0; state_q<=ST_NORMALIZE;
                    end else if (last_block) state_q<=ST_DONE;
                    else begin
                        q_block_start_q<=({1'b0,q_block_start_q}+q_block_len_q);
                        q_block_len_q<=calc_block_len(({1'b0,q_block_start_q}+q_block_len_q));
                        q_load_index_q<='0; emit_index_q<='0; kv_start_q<='0; norm_index_q<='0; state_q<=ST_REQ_Q;
                    end
                end
                ST_DONE: state_q<=ST_IDLE;
                default: state_q<=ST_IDLE;
            endcase

            // ================= producer FSM (only while tile running) =================
            if (state_q==ST_TILE_RUN) begin
                unique case (pstate_q)
                    PS_SETUP: begin
                        // claim prod_buf if free; set up this row's scoring
                        if (!buf_ready[prod_buf_q]) begin
                            prod_vcnt_q <= valid_cnt_for(prod_row_q);
                            feed_idx_q <= '0; recv_idx_q <= '0;
                            buf_vcnt[prod_buf_q]  <= valid_cnt_for(prod_row_q);
                            buf_first[prod_buf_q] <= (kv_start_q == '0);
                            buf_row[prod_buf_q]   <= prod_row_q;
                            if (valid_cnt_for(prod_row_q) == '0) begin
                                buf_ready[prod_buf_q] <= 1'b1;          // empty row, ready immediately
                                if ((prod_row_q+1'b1) < q_block_len_q) begin prod_row_q<=prod_row_q+1'b1; prod_buf_q<=~prod_buf_q; end
                                else pstate_q<=PS_DONE;
                            end else pstate_q<=PS_FEED;
                        end
                    end
                    PS_FEED: begin
                        if (feed_idx_q < prod_vcnt_q) feed_idx_q <= feed_idx_q + 1'b1;
                        if ((recv_idx_q + (dot_out_valid ? 1 : 0)) >= prod_vcnt_q) begin
                            buf_ready[prod_buf_q] <= 1'b1;
                            if ((prod_row_q+1'b1) < q_block_len_q) begin prod_row_q<=prod_row_q+1'b1; prod_buf_q<=~prod_buf_q; pstate_q<=PS_SETUP; end
                            else pstate_q<=PS_DONE;
                        end
                    end
                    PS_DONE: ; // wait for consumer
                    default: ;
                endcase
            end

            // ================= consumer FSM (only while tile running) =================
            if (state_q==ST_TILE_RUN) begin
                unique case (cstate_q)
                    CS_WAIT: begin
                        if (buf_ready[cons_buf_q]) begin
                            if (buf_vcnt[cons_buf_q] == '0) begin
                                // empty row: nothing to combine, free + advance
                                buf_ready[cons_buf_q] <= 1'b0;
                                if ((cons_row_q+1'b1) < q_block_len_q) begin cons_row_q<=cons_row_q+1'b1; cons_buf_q<=~cons_buf_q; end
                                else cstate_q<=CS_DONE;
                            end else begin
                                cstate_q <= CS_KICK;          // pulse sc_start next cycle
                            end
                        end
                    end
                    CS_KICK: cstate_q <= CS_RUN;              // sc_start high exactly this cycle
                    CS_RUN: begin
                        if (sc_done) begin
                            m_block[buf_row[cons_buf_q]] <= sc_m_out;
                            l_block[buf_row[cons_buf_q]] <= sc_l_out;
                            for (seq_d=0; seq_d<D_MODEL; seq_d=seq_d+1)
                                acc_block[buf_row[cons_buf_q]][seq_d] <= sc_acc_out_flat[seq_d*ACC_W +: ACC_W];
                            buf_ready[cons_buf_q] <= 1'b0;        // free buffer for producer
                            if ((cons_row_q+1'b1) < q_block_len_q) begin cons_row_q<=cons_row_q+1'b1; cons_buf_q<=~cons_buf_q; cstate_q<=CS_WAIT; end
                            else cstate_q<=CS_DONE;
                        end
                    end
                    CS_DONE: ; // wait for outer to advance tile
                    default: ;
                endcase
            end
        end
    end
endmodule
