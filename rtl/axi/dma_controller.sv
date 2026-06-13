`timescale 1ns/1ps

module dma_controller #(
    parameter int S_LEN      = 256,
    parameter int ADDR_W     = 64,
    parameter int DATA_W     = 16,
    parameter int D_MODEL    = 64,
    parameter int BK         = 16,
    parameter int AXI_DATA_W = 64,
    // ORIGINAL bonus / DMA optimization: speculative next-tile prefetch.
    // 0 (default) = bit-identical to the v2 baseline DMA (no behavior change).
    // 1 = while the core computes the current tile, prefetch tile (kv_start+BK)
    //     into a shadow buffer; serve it instantly on the next request (hit),
    //     hiding DMA latency behind compute. Transparent to flash_core.
    parameter int USE_KV_PREFETCH = 0
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
    output logic signed [DATA_W-1:0] q_data [0:D_MODEL-1],
    output logic [D_MODEL*DATA_W-1:0] q_data_flat,
    input  logic q_data_ready,

    input  logic kv_req_valid,
    input  logic [$clog2(S_LEN)-1:0] kv_req_start,
    input  logic [$clog2(BK+1)-1:0] kv_req_len,
    output logic kv_req_ready,

    output logic kv_data_valid,
    output logic signed [DATA_W-1:0] k_tile [0:BK-1][0:D_MODEL-1],
    output logic signed [DATA_W-1:0] v_tile [0:BK-1][0:D_MODEL-1],
    output logic [BK*D_MODEL*DATA_W-1:0] k_tile_flat,
    output logic [BK*D_MODEL*DATA_W-1:0] v_tile_flat,
    input  logic kv_data_ready,

    input  logic o_valid,
    input  logic [$clog2(S_LEN)-1:0] o_row,
    input  logic signed [DATA_W-1:0] o_data [0:D_MODEL-1],
    input  logic [D_MODEL*DATA_W-1:0] o_data_flat,
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
        S_PF_K_REQ,
        S_PF_K_RECV,
        S_PF_V_REQ,
        S_PF_V_RECV,
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

    // ---- prefetch shadow buffers + bookkeeping (USE_KV_PREFETCH) ----
    logic signed [DATA_W-1:0] k_buf2 [0:BK-1][0:D_MODEL-1];
    logic signed [DATA_W-1:0] v_buf2 [0:BK-1][0:D_MODEL-1];
    logic                  pf_valid_q;          // shadow holds a valid prefetched tile
    logic                  kv_consume_pending_q; // core released current tile during a prefetch
    logic [ROW_W-1:0]      pf_start_q;          // shadow tile's kv_start
    logic [LEN_W-1:0]      pf_len_q;            // shadow tile's length
    logic [ROW_W:0]        pf_next_start;       // candidate next-tile start = kv_start+BK
    assign pf_next_start = {1'b0, kv_start_q} + BK;
    integer pf_row, pf_col;

    integer seq_col;
    integer seq_row;
    integer seq_word;
    integer comb_word;
    integer comb_row;
    integer comb_col;
    integer comb_index;

    always_comb begin
        q_req_ready  = (state_q == S_IDLE);
        kv_req_ready = (state_q == S_IDLE);
        o_ready      = (state_q == S_IDLE);

        q_data_valid  = (state_q == S_Q_PRESENT);
        // current tile stays presented (k_buf/v_buf untouched) while we prefetch
        // the next tile into the shadow buffer.
        kv_data_valid = (state_q == S_KV_PRESENT) ||
                        (state_q == S_PF_K_REQ) || (state_q == S_PF_K_RECV) ||
                        (state_q == S_PF_V_REQ) || (state_q == S_PF_V_RECV);

        for (comb_col = 0; comb_col < D_MODEL; comb_col = comb_col + 1) begin
            q_data[comb_col] = q_buf[comb_col];
            q_data_flat[comb_col * DATA_W +: DATA_W] = q_buf[comb_col];
        end
        for (comb_row = 0; comb_row < BK; comb_row = comb_row + 1) begin
            for (comb_col = 0; comb_col < D_MODEL; comb_col = comb_col + 1) begin
                k_tile[comb_row][comb_col] = k_buf[comb_row][comb_col];
                v_tile[comb_row][comb_col] = v_buf[comb_row][comb_col];
                k_tile_flat[((comb_row * D_MODEL + comb_col) * DATA_W) +: DATA_W] = k_buf[comb_row][comb_col];
                v_tile_flat[((comb_row * D_MODEL + comb_col) * DATA_W) +: DATA_W] = v_buf[comb_row][comb_col];
            end
        end

        rd_req_valid = (state_q == S_Q_RD_REQ) || (state_q == S_K_RD_REQ) || (state_q == S_V_RD_REQ) ||
                       (state_q == S_PF_K_REQ) || (state_q == S_PF_V_REQ);
        rd_req_bytes = ROW_BYTES;
        rd_req_addr  = '0;
        if (state_q == S_Q_RD_REQ) begin
            rd_req_addr = q_base + (q_row_q * stride_bytes);
        end else if (state_q == S_K_RD_REQ) begin
            rd_req_addr = k_base + ((kv_start_q + tile_row_idx_q) * stride_bytes);
        end else if (state_q == S_V_RD_REQ) begin
            rd_req_addr = v_base + ((kv_start_q + tile_row_idx_q) * stride_bytes);
        end else if (state_q == S_PF_K_REQ) begin
            rd_req_addr = k_base + ((pf_start_q + tile_row_idx_q) * stride_bytes);
        end else if (state_q == S_PF_V_REQ) begin
            rd_req_addr = v_base + ((pf_start_q + tile_row_idx_q) * stride_bytes);
        end
        rd_data_ready = (state_q == S_Q_RD_RECV) || (state_q == S_K_RD_RECV) || (state_q == S_V_RD_RECV) ||
                        (state_q == S_PF_K_RECV) || (state_q == S_PF_V_RECV);

        wr_req_valid = (state_q == S_O_WR_REQ);
        wr_req_addr  = o_base + (o_row_q * stride_bytes);
        wr_req_bytes = ROW_BYTES;

        wr_data_valid = (state_q == S_O_WR_SEND);
        wr_last       = (beat_idx_q == ROW_BEATS - 1);
        wr_data       = '0;
        if (state_q == S_O_WR_SEND) begin
            for (comb_word = 0; comb_word < WORDS_PER_BEAT; comb_word = comb_word + 1) begin
                comb_index = beat_idx_q;
                comb_index = (comb_index * WORDS_PER_BEAT) + comb_word;
                if (comb_index < D_MODEL) begin
                    wr_data[(comb_word * DATA_W) +: DATA_W] = o_buf[comb_index];
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
                pf_valid_q     <= 1'b0;
                kv_consume_pending_q <= 1'b0;
                pf_start_q     <= '0;
                pf_len_q       <= '0;
                for (pf_row = 0; pf_row < BK; pf_row = pf_row + 1)
                    for (pf_col = 0; pf_col < D_MODEL; pf_col = pf_col + 1) begin
                        k_buf2[pf_row][pf_col] <= '0;
                        v_buf2[pf_row][pf_col] <= '0;
                    end
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

                            if (kv_req_len == '0) begin
                                error   <= 1'b1;
                                state_q <= S_IDLE;
                            end else if ((USE_KV_PREFETCH != 0) && pf_valid_q &&
                                         (pf_start_q == kv_req_start) && (pf_len_q == kv_req_len)) begin
                                // PREFETCH HIT: shadow already holds this tile -> promote & present
                                // immediately (no AXI load this round). DMA latency hides here.
                                for (seq_row = 0; seq_row < BK; seq_row = seq_row + 1)
                                    for (seq_col = 0; seq_col < D_MODEL; seq_col = seq_col + 1) begin
                                        k_buf[seq_row][seq_col] <= k_buf2[seq_row][seq_col];
                                        v_buf[seq_row][seq_col] <= v_buf2[seq_row][seq_col];
                                    end
                                pf_valid_q <= 1'b0;
                                state_q    <= S_KV_PRESENT;
                            end else begin
                                // miss (or prefetch disabled): normal load
                                pf_valid_q <= 1'b0;
                                for (seq_row = 0; seq_row < BK; seq_row = seq_row + 1)
                                    for (seq_col = 0; seq_col < D_MODEL; seq_col = seq_col + 1) begin
                                        k_buf[seq_row][seq_col] <= '0;
                                        v_buf[seq_row][seq_col] <= '0;
                                    end
                                state_q <= S_K_RD_REQ;
                            end
                        end else if (o_valid) begin
                            o_row_q <= o_row;
                            for (seq_col = 0; seq_col < D_MODEL; seq_col = seq_col + 1) begin
                                o_buf[seq_col] <= o_data_flat[seq_col * DATA_W +: DATA_W];
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
                                seq_col = beat_idx_q;
                                seq_col = (seq_col * WORDS_PER_BEAT) + seq_word;
                                if (seq_col < D_MODEL) begin
                                    q_buf[seq_col] <= rd_data[(seq_word * DATA_W) +: DATA_W];
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
                                seq_col = beat_idx_q;
                                seq_col = (seq_col * WORDS_PER_BEAT) + seq_word;
                                if (seq_col < D_MODEL) begin
                                    k_buf[tile_row_idx_q][seq_col] <= rd_data[(seq_word * DATA_W) +: DATA_W];
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
                                seq_col = beat_idx_q;
                                seq_col = (seq_col * WORDS_PER_BEAT) + seq_word;
                                if (seq_col < D_MODEL) begin
                                    v_buf[tile_row_idx_q][seq_col] <= rd_data[(seq_word * DATA_W) +: DATA_W];
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
                        // Consume by the core takes priority. Otherwise, if prefetch
                        // is enabled and the shadow is empty, speculatively load the
                        // next sequential tile (kv_start+BK) while the core computes.
                        if (kv_data_ready) begin
                            state_q <= S_IDLE;
                        end else if ((USE_KV_PREFETCH != 0) && !pf_valid_q &&
                                     (pf_next_start < S_LEN)) begin
                            pf_start_q <= pf_next_start[ROW_W-1:0];
                            pf_len_q   <= ((S_LEN - pf_next_start) > BK) ? BK[LEN_W-1:0]
                                                                         : (S_LEN - pf_next_start);
                            tile_row_idx_q <= '0;
                            beat_idx_q     <= '0;
                            kv_consume_pending_q <= 1'b0;
                            state_q    <= S_PF_K_REQ;
                        end
                    end

                    // ----- speculative prefetch of the next tile into shadow -----
                    S_PF_K_REQ: begin
                        if (kv_data_ready) kv_consume_pending_q <= 1'b1;  // latch: core released
                        if (rd_req_valid && rd_req_ready) begin
                            beat_idx_q <= '0; state_q <= S_PF_K_RECV;
                        end
                    end
                    S_PF_K_RECV: begin
                        if (kv_data_ready) kv_consume_pending_q <= 1'b1;
                        if (rd_data_valid && rd_data_ready) begin
                            for (seq_word = 0; seq_word < WORDS_PER_BEAT; seq_word = seq_word + 1) begin
                                seq_col = beat_idx_q;
                                seq_col = (seq_col * WORDS_PER_BEAT) + seq_word;
                                if (seq_col < D_MODEL)
                                    k_buf2[tile_row_idx_q][seq_col] <= rd_data[(seq_word * DATA_W) +: DATA_W];
                            end
                            if (rd_last || (beat_idx_q == ROW_BEATS - 1)) begin
                                if ((tile_row_idx_q + 1'b1) < pf_len_q) begin
                                    tile_row_idx_q <= tile_row_idx_q + 1'b1; beat_idx_q <= '0; state_q <= S_PF_K_REQ;
                                end else begin
                                    tile_row_idx_q <= '0; beat_idx_q <= '0; state_q <= S_PF_V_REQ;
                                end
                            end else beat_idx_q <= beat_idx_q + 1'b1;
                        end
                    end
                    S_PF_V_REQ: begin
                        if (kv_data_ready) kv_consume_pending_q <= 1'b1;
                        if (rd_req_valid && rd_req_ready) begin
                            beat_idx_q <= '0; state_q <= S_PF_V_RECV;
                        end
                    end
                    S_PF_V_RECV: begin
                        if (kv_data_ready) kv_consume_pending_q <= 1'b1;
                        if (rd_data_valid && rd_data_ready) begin
                            for (seq_word = 0; seq_word < WORDS_PER_BEAT; seq_word = seq_word + 1) begin
                                seq_col = beat_idx_q;
                                seq_col = (seq_col * WORDS_PER_BEAT) + seq_word;
                                if (seq_col < D_MODEL)
                                    v_buf2[tile_row_idx_q][seq_col] <= rd_data[(seq_word * DATA_W) +: DATA_W];
                            end
                            if (rd_last || (beat_idx_q == ROW_BEATS - 1)) begin
                                if ((tile_row_idx_q + 1'b1) < pf_len_q) begin
                                    tile_row_idx_q <= tile_row_idx_q + 1'b1; beat_idx_q <= '0; state_q <= S_PF_V_REQ;
                                end else begin
                                    // shadow now holds the prefetched tile
                                    tile_row_idx_q <= '0; beat_idx_q <= '0; pf_valid_q <= 1'b1;
                                    // if the core already released the current tile mid-prefetch,
                                    // go idle so its pending next-request hits the shadow.
                                    if (kv_consume_pending_q || kv_data_ready) begin
                                        kv_consume_pending_q <= 1'b0; state_q <= S_IDLE;
                                    end else begin
                                        state_q <= S_KV_PRESENT;
                                    end
                                end
                            end else beat_idx_q <= beat_idx_q + 1'b1;
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
