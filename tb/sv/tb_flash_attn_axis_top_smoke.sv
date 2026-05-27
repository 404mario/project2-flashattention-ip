`timescale 1ns/1ps

module tb_flash_attn_axis_top_smoke;
    localparam int S_LEN = 8;
    localparam int D_MODEL = 8;
    localparam int BK = 4;
    localparam int BQ = 4;
    localparam int DATA_W = 16;
    localparam int ACC_W = 48;
    localparam int FRAC_W = 8;
    localparam int SOFTMAX_FRAC = 16;
    localparam int NUM_ELEMS = S_LEN * D_MODEL;
    localparam int KV_TILES = 3;
    localparam int SCALE_Q8_8 = 91;
    localparam int TIMEOUT_CYCLES = 200000;

    logic clk;
    logic rst_n;
    logic start;
    logic busy;
    logic done;
    logic error;

    logic signed [DATA_W-1:0] s_axis_q_tdata;
    logic s_axis_q_tvalid;
    logic s_axis_q_tready;
    logic s_axis_q_tlast;

    logic signed [DATA_W-1:0] s_axis_kv_tdata;
    logic s_axis_kv_tvalid;
    logic s_axis_kv_tready;
    logic s_axis_kv_tlast;

    logic signed [DATA_W-1:0] m_axis_o_tdata;
    logic m_axis_o_tvalid;
    logic m_axis_o_tready;
    logic m_axis_o_tlast;

    int q_sent;
    int kv_tile_q;
    int kv_phase_q;
    int kv_row_q;
    int kv_col_q;
    int o_count;
    int wait_cycles;
    bit saw_busy;
    string out_hex_path;
    logic [15:0] o_mem [0:NUM_ELEMS-1];

    flash_attn_axis_top #(
        .S_LEN(S_LEN),
        .D_MODEL(D_MODEL),
        .BK(BK),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W),
        .FRAC_W(FRAC_W),
        .BQ(BQ),
        .USE_DOT_TREE(1),
        .USE_CAUSAL_SKIP(1),
        .SOFTMAX_FRAC(SOFTMAX_FRAC)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .causal_en(1'b1),
        .neg_large(-32'sd32768),
        .scale(SCALE_Q8_8),
        .valid_len(S_LEN),
        .busy(busy),
        .done(done),
        .error(error),
        .s_axis_q_tdata(s_axis_q_tdata),
        .s_axis_q_tvalid(s_axis_q_tvalid),
        .s_axis_q_tready(s_axis_q_tready),
        .s_axis_q_tlast(s_axis_q_tlast),
        .s_axis_kv_tdata(s_axis_kv_tdata),
        .s_axis_kv_tvalid(s_axis_kv_tvalid),
        .s_axis_kv_tready(s_axis_kv_tready),
        .s_axis_kv_tlast(s_axis_kv_tlast),
        .m_axis_o_tdata(m_axis_o_tdata),
        .m_axis_o_tvalid(m_axis_o_tvalid),
        .m_axis_o_tready(m_axis_o_tready),
        .m_axis_o_tlast(m_axis_o_tlast)
    );

    always #5 clk = ~clk;

    function automatic int signed q_value(input int in_row, input int in_col);
        begin
            q_value = ((((in_row * 3 + in_col * 5 + 7) % 17) - 8) <<< 4);
        end
    endfunction

    function automatic int signed k_value(input int key_row, input int in_col);
        begin
            k_value = ((((key_row * 5 + in_col * 7 + 11) % 19) - 9) <<< 4);
        end
    endfunction

    function automatic int signed v_value(input int key_row, input int in_col);
        begin
            v_value = ((((key_row * 7 + in_col * 3 + 5) % 23) - 11) <<< 3);
        end
    endfunction

    function automatic int kv_tile_start(input int tile_index);
        begin
            case (tile_index)
                0: kv_tile_start = 0;
                1: kv_tile_start = 0;
                2: kv_tile_start = 4;
                default: kv_tile_start = 0;
            endcase
        end
    endfunction

    task automatic dump_output_memory;
        int fd;
        int idx;
        begin
            fd = $fopen(out_hex_path, "w");
            if (fd == 0) begin
                $display("FAIL could not open output dump path %s", out_hex_path);
                $fatal(1);
            end

            for (idx = 0; idx < NUM_ELEMS; idx = idx + 1) begin
                $fwrite(fd, "%04h\n", o_mem[idx]);
            end
            $fclose(fd);
        end
    endtask

    always_comb begin
        s_axis_q_tvalid = (q_sent < NUM_ELEMS);
        s_axis_q_tdata = q_value(q_sent / D_MODEL, q_sent % D_MODEL);
        s_axis_q_tlast = ((q_sent % D_MODEL) == D_MODEL - 1);

        s_axis_kv_tvalid = (kv_tile_q < KV_TILES);
        if (kv_phase_q == 0) begin
            s_axis_kv_tdata = k_value(kv_tile_start(kv_tile_q) + kv_row_q, kv_col_q);
            s_axis_kv_tlast = 1'b0;
        end else begin
            s_axis_kv_tdata = v_value(kv_tile_start(kv_tile_q) + kv_row_q, kv_col_q);
            s_axis_kv_tlast = (kv_row_q == BK - 1) && (kv_col_q == D_MODEL - 1);
        end

        m_axis_o_tready = 1'b1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_sent <= 0;
            kv_tile_q <= 0;
            kv_phase_q <= 0;
            kv_row_q <= 0;
            kv_col_q <= 0;
            o_count <= 0;
        end else begin
            if (s_axis_q_tvalid && s_axis_q_tready) begin
                q_sent <= q_sent + 1;
            end

            if (s_axis_kv_tvalid && s_axis_kv_tready) begin
                if (kv_col_q == D_MODEL - 1) begin
                    kv_col_q <= 0;
                    if (kv_row_q == BK - 1) begin
                        kv_row_q <= 0;
                        if (kv_phase_q == 0) begin
                            kv_phase_q <= 1;
                        end else begin
                            kv_phase_q <= 0;
                            kv_tile_q <= kv_tile_q + 1;
                        end
                    end else begin
                        kv_row_q <= kv_row_q + 1;
                    end
                end else begin
                    kv_col_q <= kv_col_q + 1;
                end
            end

            if (m_axis_o_tvalid && m_axis_o_tready) begin
                if (o_count >= NUM_ELEMS) begin
                    $display("FAIL too many O stream elements count=%0d", o_count);
                    $fatal(1);
                end
                if (m_axis_o_tlast !== ((o_count % D_MODEL) == D_MODEL - 1)) begin
                    $display("FAIL O TLAST count=%0d got=%0b", o_count, m_axis_o_tlast);
                    $fatal(1);
                end
                o_mem[o_count] <= m_axis_o_tdata;
                o_count <= o_count + 1;
            end
        end
    end

    initial begin
        out_hex_path = "sim_build/tb_flash_attn_axis_top_o.hex";
        if (!$value$plusargs("OUT_HEX=%s", out_hex_path)) begin
            out_hex_path = "sim_build/tb_flash_attn_axis_top_o.hex";
        end

        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        saw_busy = 0;

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        wait_cycles = 0;
        while ((wait_cycles < TIMEOUT_CYCLES) && !done) begin
            @(posedge clk);
            wait_cycles++;
            if (busy) begin
                saw_busy = 1;
            end
            if (error) begin
                $display("FAIL axis top error asserted");
                $fatal(1);
            end
        end

        if (!done) begin
            $display("FAIL timeout waiting for axis top done");
            $fatal(1);
        end
        if (!saw_busy) begin
            $display("FAIL busy was never observed");
            $fatal(1);
        end
        if (q_sent != NUM_ELEMS) begin
            $display("FAIL q stream sent=%0d expected=%0d", q_sent, NUM_ELEMS);
            $fatal(1);
        end
        if (kv_tile_q != KV_TILES) begin
            $display("FAIL kv tiles sent=%0d expected=%0d", kv_tile_q, KV_TILES);
            $fatal(1);
        end
        if (o_count != NUM_ELEMS) begin
            $display("FAIL o stream count=%0d expected=%0d", o_count, NUM_ELEMS);
            $fatal(1);
        end
        if ($signed(o_mem[0]) !== v_value(0, 0)) begin
            $display("FAIL row0 causal check got=%0d expected=%0d", $signed(o_mem[0]), v_value(0, 0));
            $fatal(1);
        end

        dump_output_memory();
        $display("tb_flash_attn_axis_top_smoke PASS S=%0d D=%0d BK=%0d BQ=%0d wait_cycles=%0d",
                 S_LEN, D_MODEL, BK, BQ, wait_cycles);
        $finish;
    end
endmodule
