`timescale 1ns/1ps

module flash_attn_axis_top #(
    parameter int S_LEN           = 256,
    parameter int D_MODEL         = 64,
    parameter int BK              = 16,
    parameter int DATA_W          = 16,
    parameter int ACC_W           = 48,
    parameter int FRAC_W          = 8,
    parameter int BQ              = 16,
    parameter int USE_DOT_TREE    = 1,
    parameter int USE_CAUSAL_SKIP = 1,
    parameter int SOFTMAX_FRAC    = 16
) (
    input  logic clk,
    input  logic rst_n,

    input  logic start,
    input  logic causal_en,
    input  logic signed [31:0] neg_large,
    input  logic signed [31:0] scale,
    input  logic [31:0] valid_len,

    output logic busy,
    output logic done,
    output logic error,

    input  logic signed [DATA_W-1:0] s_axis_q_tdata,
    input  logic                     s_axis_q_tvalid,
    output logic                     s_axis_q_tready,
    input  logic                     s_axis_q_tlast,

    input  logic signed [DATA_W-1:0] s_axis_kv_tdata,
    input  logic                     s_axis_kv_tvalid,
    output logic                     s_axis_kv_tready,
    input  logic                     s_axis_kv_tlast,

    output logic signed [DATA_W-1:0] m_axis_o_tdata,
    output logic                     m_axis_o_tvalid,
    input  logic                     m_axis_o_tready,
    output logic                     m_axis_o_tlast
);
    localparam int ROW_W       = (S_LEN <= 1) ? 1 : $clog2(S_LEN);
    localparam int LEN_W       = (BK <= 1) ? 1 : $clog2(BK + 1);
    localparam int D_IDX_W     = (D_MODEL <= 1) ? 1 : $clog2(D_MODEL);
    localparam int TILE_IDX_W  = (BK <= 1) ? 1 : $clog2(BK);

    typedef enum logic [1:0] {
        Q_IDLE,
        Q_LOAD,
        Q_PRESENT
    } q_state_t;

    typedef enum logic [1:0] {
        KV_IDLE,
        KV_LOAD_K,
        KV_LOAD_V,
        KV_PRESENT
    } kv_state_t;

    typedef enum logic [1:0] {
        O_IDLE,
        O_SEND
    } o_state_t;

    q_state_t q_state_q;
    kv_state_t kv_state_q;
    o_state_t o_state_q;

    logic q_req_valid;
    logic [ROW_W-1:0] q_req_row;
    logic q_req_ready;
    logic q_data_valid;
    logic q_data_ready;

    logic kv_req_valid;
    logic [ROW_W-1:0] kv_req_start;
    logic [LEN_W-1:0] kv_req_len;
    logic kv_req_ready;
    logic kv_data_valid;
    logic kv_data_ready;

    logic o_valid;
    logic [ROW_W-1:0] o_row;
    logic o_ready;

    logic core_busy;
    logic core_done;
    logic core_error;
    logic core_done_seen_q;

    logic [D_IDX_W-1:0] q_col_q;
    logic [D_IDX_W-1:0] kv_col_q;
    logic [D_IDX_W-1:0] o_col_q;
    logic [TILE_IDX_W-1:0] kv_row_q;
    logic [LEN_W-1:0] kv_len_q;

    logic signed [DATA_W-1:0] q_buf [0:D_MODEL-1];
    logic signed [DATA_W-1:0] k_tile_buf [0:BK-1][0:D_MODEL-1];
    logic signed [DATA_W-1:0] v_tile_buf [0:BK-1][0:D_MODEL-1];
    logic signed [DATA_W-1:0] o_buf [0:D_MODEL-1];
    logic signed [DATA_W-1:0] o_data [0:D_MODEL-1];
    logic [D_MODEL*DATA_W-1:0] o_data_flat;

    logic q_tlast_error_q;
    logic kv_tlast_error_q;

    integer comb_i;
    integer comb_r;
    integer seq_i;
    integer seq_r;

    assign q_req_ready = (q_state_q == Q_IDLE);
    assign q_data_valid = (q_state_q == Q_PRESENT);
    assign s_axis_q_tready = (q_state_q == Q_LOAD);

    assign kv_req_ready = (kv_state_q == KV_IDLE);
    assign kv_data_valid = (kv_state_q == KV_PRESENT);
    assign s_axis_kv_tready = (kv_state_q == KV_LOAD_K) || (kv_state_q == KV_LOAD_V);

    assign o_ready = (o_state_q == O_IDLE);
    assign m_axis_o_tvalid = (o_state_q == O_SEND);
    assign m_axis_o_tdata = o_buf[o_col_q];
    assign m_axis_o_tlast = (o_state_q == O_SEND) && (o_col_q == D_MODEL - 1);

    assign busy = core_busy || (q_state_q != Q_IDLE) || (kv_state_q != KV_IDLE) ||
                  (o_state_q != O_IDLE) || core_done_seen_q;
    assign done = core_done_seen_q && (o_state_q == O_IDLE);
    assign error = core_error || q_tlast_error_q || kv_tlast_error_q;

    always_comb begin
        for (comb_i = 0; comb_i < D_MODEL; comb_i = comb_i + 1) begin
            o_data[comb_i] = o_data_flat[comb_i * DATA_W +: DATA_W];
        end
    end

    flash_core #(
        .S_LEN(S_LEN),
        .D_MODEL(D_MODEL),
        .BK(BK),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W),
        .FRAC_W(FRAC_W),
        .BQ(BQ),
        .USE_DOT_TREE(USE_DOT_TREE),
        .USE_CAUSAL_SKIP(USE_CAUSAL_SKIP),
        .SOFTMAX_FRAC(SOFTMAX_FRAC)
    ) u_flash_core (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .busy(core_busy),
        .done(core_done),
        .error(core_error),
        .causal_en(causal_en),
        .neg_large(neg_large),
        .scale(scale),
        .valid_len(valid_len),
        .dropout_en(1'b0),
        .dropout_threshold(16'd0),
        .dropout_seed(16'hace1),
        .dropout_scale_q8_8(16'd256),
        .q_req_valid(q_req_valid),
        .q_req_row(q_req_row),
        .q_req_ready(q_req_ready),
        .q_data_valid(q_data_valid),
        .q_data(q_buf),
        .q_data_ready(q_data_ready),
        .kv_req_valid(kv_req_valid),
        .kv_req_start(kv_req_start),
        .kv_req_len(kv_req_len),
        .kv_req_ready(kv_req_ready),
        .kv_data_valid(kv_data_valid),
        .k_tile(k_tile_buf),
        .v_tile(v_tile_buf),
        .kv_data_ready(kv_data_ready),
        .o_valid(o_valid),
        .o_row(o_row),
        .o_data(),
        .o_data_flat(o_data_flat),
        .o_ready(o_ready)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_state_q <= Q_IDLE;
            kv_state_q <= KV_IDLE;
            o_state_q <= O_IDLE;
            q_col_q <= '0;
            kv_col_q <= '0;
            o_col_q <= '0;
            kv_row_q <= '0;
            kv_len_q <= '0;
            core_done_seen_q <= 1'b0;
            q_tlast_error_q <= 1'b0;
            kv_tlast_error_q <= 1'b0;

            for (seq_i = 0; seq_i < D_MODEL; seq_i = seq_i + 1) begin
                q_buf[seq_i] <= '0;
                o_buf[seq_i] <= '0;
            end
            for (seq_r = 0; seq_r < BK; seq_r = seq_r + 1) begin
                for (seq_i = 0; seq_i < D_MODEL; seq_i = seq_i + 1) begin
                    k_tile_buf[seq_r][seq_i] <= '0;
                    v_tile_buf[seq_r][seq_i] <= '0;
                end
            end
        end else begin
            if (start) begin
                core_done_seen_q <= 1'b0;
                q_tlast_error_q <= 1'b0;
                kv_tlast_error_q <= 1'b0;
            end

            if (core_done) begin
                core_done_seen_q <= 1'b1;
            end
            if (done && !start) begin
                core_done_seen_q <= 1'b0;
            end

            unique case (q_state_q)
                Q_IDLE: begin
                    if (q_req_valid) begin
                        q_col_q <= '0;
                        q_state_q <= Q_LOAD;
                    end
                end

                Q_LOAD: begin
                    if (s_axis_q_tvalid && s_axis_q_tready) begin
                        q_buf[q_col_q] <= s_axis_q_tdata;
                        if (s_axis_q_tlast != (q_col_q == D_MODEL - 1)) begin
                            q_tlast_error_q <= 1'b1;
                        end
                        if (q_col_q == D_MODEL - 1) begin
                            q_state_q <= Q_PRESENT;
                        end else begin
                            q_col_q <= q_col_q + 1'b1;
                        end
                    end
                end

                Q_PRESENT: begin
                    if (q_data_ready) begin
                        q_state_q <= Q_IDLE;
                    end
                end

                default: q_state_q <= Q_IDLE;
            endcase

            unique case (kv_state_q)
                KV_IDLE: begin
                    if (kv_req_valid) begin
                        kv_len_q <= kv_req_len;
                        kv_row_q <= '0;
                        kv_col_q <= '0;
                        for (seq_r = 0; seq_r < BK; seq_r = seq_r + 1) begin
                            for (seq_i = 0; seq_i < D_MODEL; seq_i = seq_i + 1) begin
                                k_tile_buf[seq_r][seq_i] <= '0;
                                v_tile_buf[seq_r][seq_i] <= '0;
                            end
                        end
                        kv_state_q <= KV_LOAD_K;
                    end
                end

                KV_LOAD_K: begin
                    if (s_axis_kv_tvalid && s_axis_kv_tready) begin
                        k_tile_buf[kv_row_q][kv_col_q] <= s_axis_kv_tdata;
                        if (s_axis_kv_tlast) begin
                            kv_tlast_error_q <= 1'b1;
                        end
                        if (kv_col_q == D_MODEL - 1) begin
                            kv_col_q <= '0;
                            if ((kv_row_q + 1'b1) == kv_len_q) begin
                                kv_row_q <= '0;
                                kv_state_q <= KV_LOAD_V;
                            end else begin
                                kv_row_q <= kv_row_q + 1'b1;
                            end
                        end else begin
                            kv_col_q <= kv_col_q + 1'b1;
                        end
                    end
                end

                KV_LOAD_V: begin
                    if (s_axis_kv_tvalid && s_axis_kv_tready) begin
                        v_tile_buf[kv_row_q][kv_col_q] <= s_axis_kv_tdata;
                        if (s_axis_kv_tlast !=
                            (((kv_row_q + 1'b1) == kv_len_q) && (kv_col_q == D_MODEL - 1))) begin
                            kv_tlast_error_q <= 1'b1;
                        end
                        if (kv_col_q == D_MODEL - 1) begin
                            kv_col_q <= '0;
                            if ((kv_row_q + 1'b1) == kv_len_q) begin
                                kv_row_q <= '0;
                                kv_state_q <= KV_PRESENT;
                            end else begin
                                kv_row_q <= kv_row_q + 1'b1;
                            end
                        end else begin
                            kv_col_q <= kv_col_q + 1'b1;
                        end
                    end
                end

                KV_PRESENT: begin
                    if (kv_data_ready) begin
                        kv_state_q <= KV_IDLE;
                    end
                end

                default: kv_state_q <= KV_IDLE;
            endcase

            unique case (o_state_q)
                O_IDLE: begin
                    if (o_valid) begin
                        for (seq_i = 0; seq_i < D_MODEL; seq_i = seq_i + 1) begin
                            o_buf[seq_i] <= o_data[seq_i];
                        end
                        o_col_q <= '0;
                        o_state_q <= O_SEND;
                    end
                end

                O_SEND: begin
                    if (m_axis_o_tvalid && m_axis_o_tready) begin
                        if (o_col_q == D_MODEL - 1) begin
                            o_col_q <= '0;
                            o_state_q <= O_IDLE;
                        end else begin
                            o_col_q <= o_col_q + 1'b1;
                        end
                    end
                end

                default: o_state_q <= O_IDLE;
            endcase
        end
    end

    logic unused_axis_top;
    assign unused_axis_top = q_req_row[0] ^ kv_req_start[0] ^ o_row[0] ^
                             q_req_valid ^ kv_req_valid;
endmodule
