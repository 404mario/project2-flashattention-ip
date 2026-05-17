`timescale 1ns/1ps

module dma_controller #(
    parameter int S_LEN      = 256,
    parameter int ADDR_W     = 64,
    parameter int DATA_W     = 16,
    parameter int D_MODEL    = 64,
    parameter int BK         = 16,
    parameter int AXI_DATA_W = 64
) (
    input  logic clk,
    input  logic rst_n,

    input  logic start,
    output logic busy,
    output logic done,
    output logic error,

    input  logic [63:0] q_base,
    input  logic [63:0] k_base,
    input  logic [63:0] v_base,
    input  logic [63:0] o_base,
    input  logic [31:0] stride_bytes,

    input  logic q_req_valid,
    input  logic [$clog2(S_LEN)-1:0] q_req_row,
    output logic q_req_ready,

    output logic q_data_valid,
    output wire signed [DATA_W-1:0] q_data [0:D_MODEL-1],
    input  logic q_data_ready,

    input  logic kv_req_valid,
    input  logic [$clog2(S_LEN)-1:0] kv_req_start,
    input  logic [$clog2(BK+1)-1:0] kv_req_len,
    output logic kv_req_ready,

    output logic kv_data_valid,
    output wire signed [DATA_W-1:0] k_tile [0:BK-1][0:D_MODEL-1],
    output wire signed [DATA_W-1:0] v_tile [0:BK-1][0:D_MODEL-1],
    input  logic kv_data_ready,

    input  logic o_valid,
    input  logic [$clog2(S_LEN)-1:0] o_row,
    input  logic signed [DATA_W-1:0] o_data [0:D_MODEL-1],
    output logic o_ready,

    output logic              rd_req_valid,
    output logic [ADDR_W-1:0] rd_req_addr,
    output logic [31:0]       rd_req_bytes,
    input  logic              rd_req_ready,
    input  logic              rd_data_valid,
    input  logic [63:0]       rd_data,
    input  logic              rd_last,
    output logic              rd_data_ready,

    output logic              wr_req_valid,
    output logic [ADDR_W-1:0] wr_req_addr,
    output logic [31:0]       wr_req_bytes,
    input  logic              wr_req_ready,

    output logic              wr_data_valid,
    output logic [63:0]       wr_data,
    output logic              wr_last,
    input  logic              wr_data_ready
);

    localparam int ROW_W          = (S_LEN <= 1) ? 1 : $clog2(S_LEN);
    localparam int LEN_W          = (BK <= 1) ? 1 : $clog2(BK + 1);
    localparam int TILE_IDX_W     = (BK <= 1) ? 1 : $clog2(BK);
    localparam int AXI_BYTES      = AXI_DATA_W / 8;
    localparam int WORDS_PER_BEAT = AXI_DATA_W / DATA_W;
    localparam int ROW_BYTES      = (D_MODEL * DATA_W) / 8;
    localparam int ROW_BEATS      = (ROW_BYTES + AXI_BYTES - 1) / AXI_BYTES;
    localparam int BEAT_W         = (ROW_BEATS <= 1) ? 1 : $clog2(ROW_BEATS);

    typedef enum logic [3:0] {
        S_IDLE,
        S_Q_RD_REQ,
        S_Q_RD_RECV,
        S_Q_PRESENT,
        S_K_RD_REQ,
        S_K_RD_RECV,
        S_V_RD_REQ,
        S_V_RD_RECV,
        S_KV_PRESENT,
        S_O_WR_REQ,
        S_O_WR_SEND,
        S_O_WR_RESP
    } dma_state_t;

    dma_state_t state_q;

    logic [ROW_W-1:0]      q_row_q;
    logic [ROW_W-1:0]      kv_start_q;
    logic [LEN_W-1:0]      kv_len_q;
    logic [ROW_W-1:0]      o_row_q;
    logic [TILE_IDX_W-1:0] tile_row_idx_q;
    logic [BEAT_W-1:0]     beat_idx_q;

    logic signed [DATA_W-1:0] q_buf [0:D_MODEL-1];
    logic signed [DATA_W-1:0] k_buf [0:BK-1][0:D_MODEL-1];
    logic signed [DATA_W-1:0] v_buf [0:BK-1][0:D_MODEL-1];
    logic signed [DATA_W-1:0] o_buf [0:D_MODEL-1];

    integer seq_col;
    integer seq_row;
    integer seq_word;
    integer comb_word;

    genvar q_gen;
    genvar tile_row_gen;
    genvar tile_col_gen;

    generate
        for (q_gen = 0; q_gen < D_MODEL; q_gen = q_gen + 1) begin : gen_q_out
            assign q_data[q_gen] = q_buf[q_gen];
        end
        for (tile_row_gen = 0; tile_row_gen < BK; tile_row_gen = tile_row_gen + 1) begin : gen_tile_row_out
            for (tile_col_gen = 0; tile_col_gen < D_MODEL; tile_col_gen = tile_col_gen + 1) begin : gen_tile_col_out
                assign k_tile[tile_row_gen][tile_col_gen] = k_buf[tile_row_gen][tile_col_gen];
                assign v_tile[tile_row_gen][tile_col_gen] = v_buf[tile_row_gen][tile_col_gen];
            end
        end
    endgenerate

    always_comb begin
        q_req_ready  = (state_q == S_IDLE);
        kv_req_ready = (state_q == S_IDLE);
        o_ready      = (state_q == S_IDLE);

        q_data_valid  = (state_q == S_Q_PRESENT);
        kv_data_valid = (state_q == S_KV_PRESENT);

        rd_req_valid = (state_q == S_Q_RD_REQ) || (state_q == S_K_RD_REQ) || (state_q == S_V_RD_REQ);
        rd_req_bytes = ROW_BYTES;
        rd_req_addr  = '0;
        if (state_q == S_Q_RD_REQ) begin
            rd_req_addr = q_base + (q_row_q * stride_bytes);
        end else if (state_q == S_K_RD_REQ) begin
            rd_req_addr = k_base + ((kv_start_q + tile_row_idx_q) * stride_bytes);
        end else if (state_q == S_V_RD_REQ) begin
            rd_req_addr = v_base + ((kv_start_q + tile_row_idx_q) * stride_bytes);
        end
        rd_data_ready = (state_q == S_Q_RD_RECV) || (state_q == S_K_RD_RECV) || (state_q == S_V_RD_RECV);

        wr_req_valid = (state_q == S_O_WR_REQ);
        wr_req_addr  = o_base + (o_row_q * stride_bytes);
        wr_req_bytes = ROW_BYTES;

        wr_data_valid = (state_q == S_O_WR_SEND);
        wr_last       = (beat_idx_q == ROW_BEATS - 1);
        wr_data       = '0;
        if (state_q == S_O_WR_SEND) begin
            for (comb_word = 0; comb_word < WORDS_PER_BEAT; comb_word = comb_word + 1) begin
                if (((beat_idx_q * WORDS_PER_BEAT) + comb_word) < D_MODEL) begin
                    wr_data[(comb_word * DATA_W) +: DATA_W] = o_buf[(beat_idx_q * WORDS_PER_BEAT) + comb_word];
                end
            end
        end

        busy = (state_q != S_IDLE);
        done = 1'b0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q       <= S_IDLE;
            q_row_q       <= '0;
            kv_start_q    <= '0;
            kv_len_q      <= '0;
            o_row_q       <= '0;
            tile_row_idx_q <= '0;
            beat_idx_q    <= '0;
            error         <= 1'b0;

            for (seq_col = 0; seq_col < D_MODEL; seq_col = seq_col + 1) begin
                q_buf[seq_col] <= '0;
                o_buf[seq_col] <= '0;
            end
            for (seq_row = 0; seq_row < BK; seq_row = seq_row + 1) begin
                for (seq_col = 0; seq_col < D_MODEL; seq_col = seq_col + 1) begin
                    k_buf[seq_row][seq_col] <= '0;
                    v_buf[seq_row][seq_col] <= '0;
                end
            end
        end else begin
            if (start) begin
                state_q        <= S_IDLE;
                q_row_q        <= '0;
                kv_start_q     <= '0;
                kv_len_q       <= '0;
                o_row_q        <= '0;
                tile_row_idx_q <= '0;
                beat_idx_q     <= '0;
                error          <= 1'b0;
            end else begin
                unique case (state_q)
                    S_IDLE: begin
                        beat_idx_q <= '0;
                        if (q_req_valid) begin
                            q_row_q  <= q_req_row;
                            state_q  <= S_Q_RD_REQ;
                        end else if (kv_req_valid) begin
                            kv_start_q <= kv_req_start;
                            kv_len_q   <= kv_req_len;
                            tile_row_idx_q <= '0;
                            beat_idx_q <= '0;

                            for (seq_row = 0; seq_row < BK; seq_row = seq_row + 1) begin
                                for (seq_col = 0; seq_col < D_MODEL; seq_col = seq_col + 1) begin
                                    k_buf[seq_row][seq_col] <= '0;
                                    v_buf[seq_row][seq_col] <= '0;
                                end
                            end

                            if (kv_req_len == '0) begin
                                error   <= 1'b1;
                                state_q <= S_IDLE;
                            end else begin
                                state_q <= S_K_RD_REQ;
                            end
                        end else if (o_valid) begin
                            o_row_q <= o_row;
                            for (seq_col = 0; seq_col < D_MODEL; seq_col = seq_col + 1) begin
                                o_buf[seq_col] <= o_data[seq_col];
                            end
                            beat_idx_q <= '0;
                            state_q    <= S_O_WR_REQ;
                        end
                    end

                    S_Q_RD_REQ: begin
                        if (rd_req_valid && rd_req_ready) begin
                            beat_idx_q <= '0;
                            state_q    <= S_Q_RD_RECV;
                        end
                    end

                    S_Q_RD_RECV: begin
                        if (rd_data_valid && rd_data_ready) begin
                            for (seq_word = 0; seq_word < WORDS_PER_BEAT; seq_word = seq_word + 1) begin
                                if (((beat_idx_q * WORDS_PER_BEAT) + seq_word) < D_MODEL) begin
                                    q_buf[(beat_idx_q * WORDS_PER_BEAT) + seq_word] <= rd_data[(seq_word * DATA_W) +: DATA_W];
                                end
                            end

                            if (rd_last || (beat_idx_q == ROW_BEATS - 1)) begin
                                state_q <= S_Q_PRESENT;
                            end else begin
                                beat_idx_q <= beat_idx_q + 1'b1;
                            end
                        end
                    end

                    S_Q_PRESENT: begin
                        if (q_data_ready) begin
                            state_q <= S_IDLE;
                        end
                    end

                    S_K_RD_REQ: begin
                        if (rd_req_valid && rd_req_ready) begin
                            beat_idx_q <= '0;
                            state_q    <= S_K_RD_RECV;
                        end
                    end

                    S_K_RD_RECV: begin
                        if (rd_data_valid && rd_data_ready) begin
                            for (seq_word = 0; seq_word < WORDS_PER_BEAT; seq_word = seq_word + 1) begin
                                if (((beat_idx_q * WORDS_PER_BEAT) + seq_word) < D_MODEL) begin
                                    k_buf[tile_row_idx_q][(beat_idx_q * WORDS_PER_BEAT) + seq_word] <= rd_data[(seq_word * DATA_W) +: DATA_W];
                                end
                            end

                            if (rd_last || (beat_idx_q == ROW_BEATS - 1)) begin
                                if ((tile_row_idx_q + 1'b1) < kv_len_q) begin
                                    tile_row_idx_q <= tile_row_idx_q + 1'b1;
                                    beat_idx_q     <= '0;
                                    state_q        <= S_K_RD_REQ;
                                end else begin
                                    tile_row_idx_q <= '0;
                                    beat_idx_q     <= '0;
                                    state_q        <= S_V_RD_REQ;
                                end
                            end else begin
                                beat_idx_q <= beat_idx_q + 1'b1;
                            end
                        end
                    end

                    S_V_RD_REQ: begin
                        if (rd_req_valid && rd_req_ready) begin
                            beat_idx_q <= '0;
                            state_q    <= S_V_RD_RECV;
                        end
                    end

                    S_V_RD_RECV: begin
                        if (rd_data_valid && rd_data_ready) begin
                            for (seq_word = 0; seq_word < WORDS_PER_BEAT; seq_word = seq_word + 1) begin
                                if (((beat_idx_q * WORDS_PER_BEAT) + seq_word) < D_MODEL) begin
                                    v_buf[tile_row_idx_q][(beat_idx_q * WORDS_PER_BEAT) + seq_word] <= rd_data[(seq_word * DATA_W) +: DATA_W];
                                end
                            end

                            if (rd_last || (beat_idx_q == ROW_BEATS - 1)) begin
                                if ((tile_row_idx_q + 1'b1) < kv_len_q) begin
                                    tile_row_idx_q <= tile_row_idx_q + 1'b1;
                                    beat_idx_q     <= '0;
                                    state_q        <= S_V_RD_REQ;
                                end else begin
                                    tile_row_idx_q <= '0;
                                    beat_idx_q     <= '0;
                                    state_q        <= S_KV_PRESENT;
                                end
                            end else begin
                                beat_idx_q <= beat_idx_q + 1'b1;
                            end
                        end
                    end

                    S_KV_PRESENT: begin
                        if (kv_data_ready) begin
                            state_q <= S_IDLE;
                        end
                    end

                    S_O_WR_REQ: begin
                        if (wr_req_valid && wr_req_ready) begin
                            beat_idx_q <= '0;
                            state_q    <= S_O_WR_SEND;
                        end
                    end

                    S_O_WR_SEND: begin
                        if (wr_data_valid && wr_data_ready) begin
                            if (wr_last) begin
                                state_q <= S_O_WR_RESP;
                            end else begin
                                beat_idx_q <= beat_idx_q + 1'b1;
                            end
                        end
                    end

                    S_O_WR_RESP: begin
                        if (wr_req_ready) begin
                            state_q <= S_IDLE;
                        end
                    end

                    default: begin
                        state_q <= S_IDLE;
                    end
                endcase
            end
        end
    end

endmodule
