`timescale 1ns/1ps

module tb_flash_core_param_bitexact;
    parameter int S_LEN       = 7;
    parameter int D_MODEL     = 8;
    parameter int BK          = 3;
    parameter int DATA_W      = 16;
    parameter int ACC_W       = 48;
    parameter int FRAC_W      = 8;
    parameter int WEIGHT_FRAC = 8;
    parameter int SCALE_Q8_8  = 384;
    parameter int CAUSAL_EN   = 1;

    localparam int WEIGHT_ONE   = 1 << WEIGHT_FRAC;
    localparam int ROW_W        = (S_LEN <= 1) ? 1 : $clog2(S_LEN);
    localparam int LEN_W        = (BK <= 1) ? 1 : $clog2(BK + 1);
    localparam int TILES_PER_ROW = (S_LEN + BK - 1) / BK;
    localparam int TIMEOUT_CYCLES = 200000;

    logic clk;
    logic rst_n;
    logic start;
    logic busy;
    logic done;
    logic error;
    logic causal_en;
    logic signed [31:0] neg_large;
    logic signed [31:0] scale;

    logic q_req_valid;
    logic [ROW_W-1:0] q_req_row;
    logic q_req_ready;
    logic q_data_valid;
    logic signed [DATA_W-1:0] q_data [0:D_MODEL-1];
    logic q_data_ready;

    logic kv_req_valid;
    logic [ROW_W-1:0] kv_req_start;
    logic [LEN_W-1:0] kv_req_len;
    logic kv_req_ready;
    logic kv_data_valid;
    logic signed [DATA_W-1:0] k_tile [0:BK-1][0:D_MODEL-1];
    logic signed [DATA_W-1:0] v_tile [0:BK-1][0:D_MODEL-1];
    logic kv_data_ready;

    logic o_valid;
    logic [ROW_W-1:0] o_row;
    wire signed [DATA_W-1:0] o_data [0:D_MODEL-1];
    logic o_ready;

    int d;
    int b;
    int q_requests;
    int kv_requests;
    int output_rows;

    flash_core #(
        .S_LEN(S_LEN),
        .D_MODEL(D_MODEL),
        .BK(BK),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W),
        .FRAC_W(FRAC_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .busy(busy),
        .done(done),
        .error(error),
        .causal_en(causal_en),
        .neg_large(neg_large),
        .scale(scale),
        .q_req_valid(q_req_valid),
        .q_req_row(q_req_row),
        .q_req_ready(q_req_ready),
        .q_data_valid(q_data_valid),
        .q_data(q_data),
        .q_data_ready(q_data_ready),
        .kv_req_valid(kv_req_valid),
        .kv_req_start(kv_req_start),
        .kv_req_len(kv_req_len),
        .kv_req_ready(kv_req_ready),
        .kv_data_valid(kv_data_valid),
        .k_tile(k_tile),
        .v_tile(v_tile),
        .kv_data_ready(kv_data_ready),
        .o_valid(o_valid),
        .o_row(o_row),
        .o_data(o_data),
        .o_ready(o_ready)
    );

    always #5 clk = ~clk;

    function automatic longint signed q_value(input int row, input int col);
        begin
            q_value = ((((row * 3 + col * 5 + 7) % 17) - 8) <<< 4);
        end
    endfunction

    function automatic longint signed k_value(input int key_row, input int col);
        begin
            k_value = ((((key_row * 5 + col * 7 + 11) % 19) - 9) <<< 4);
        end
    endfunction

    function automatic longint signed v_value(input int key_row, input int col);
        begin
            v_value = ((((key_row * 7 + col * 3 + 5) % 23) - 11) <<< 3);
        end
    endfunction

    `include "flash_core_ref_exp_lut.svh"

    function automatic logic signed [DATA_W-1:0] saturate_to_data(input longint signed value);
        begin
            if (value > 32767) begin
                saturate_to_data = 16'sh7fff;
            end else if (value < -32768) begin
                saturate_to_data = 16'sh8000;
            end else begin
                saturate_to_data = value[DATA_W-1:0];
            end
        end
    endfunction

    function automatic longint signed scaled_score(input int row, input int key);
        longint signed dot;
        begin
            dot = 0;
            for (int col = 0; col < D_MODEL; col = col + 1) begin
                dot += q_value(row, col) * k_value(key, col);
            end
            scaled_score = ((dot >>> FRAC_W) * SCALE_Q8_8) >>> FRAC_W;
        end
    endfunction

    function automatic logic signed [DATA_W-1:0] expected_o(input int row, input int out_col);
        longint signed m;
        longint signed l;
        longint signed acc;
        longint signed score;
        longint signed old_scale;
        longint signed new_weight;
        begin
            m = 0;
            l = 0;
            acc = 0;

            for (int key = 0; key < S_LEN; key = key + 1) begin
                if ((CAUSAL_EN == 0) || (key <= row)) begin
                    score = scaled_score(row, key);

                    if (l == 0) begin
                        old_scale = 0;
                        new_weight = WEIGHT_ONE;
                        m = score;
                        l = WEIGHT_ONE;
                    end else if (score > m) begin
                        old_scale = exp_approx_weight(m - score);
                        new_weight = WEIGHT_ONE;
                        l = ((l * old_scale) >>> WEIGHT_FRAC) + new_weight;
                        m = score;
                    end else begin
                        old_scale = WEIGHT_ONE;
                        new_weight = exp_approx_weight(score - m);
                        l = ((l * old_scale) >>> WEIGHT_FRAC) + new_weight;
                    end

                    acc = ((acc * old_scale) >>> WEIGHT_FRAC) + (new_weight * v_value(key, out_col));
                end
            end

            expected_o = (l == 0) ? '0 : saturate_to_data(acc / l);
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_data_valid  <= 1'b0;
            kv_data_valid <= 1'b0;
            q_requests    <= 0;
            kv_requests   <= 0;
            output_rows   <= 0;

            for (d = 0; d < D_MODEL; d = d + 1) begin
                q_data[d] <= '0;
            end
            for (b = 0; b < BK; b = b + 1) begin
                for (d = 0; d < D_MODEL; d = d + 1) begin
                    k_tile[b][d] <= '0;
                    v_tile[b][d] <= '0;
                end
            end
        end else begin
            q_data_valid  <= 1'b0;
            kv_data_valid <= 1'b0;

            if (q_req_valid && q_req_ready) begin
                if (q_req_row !== q_requests[ROW_W-1:0]) begin
                    $display("FAIL Q request got row=%0d expected=%0d", q_req_row, q_requests);
                    $fatal(1);
                end

                for (d = 0; d < D_MODEL; d = d + 1) begin
                    q_data[d] <= q_value(q_requests, d);
                end
                q_data_valid <= 1'b1;
                q_requests <= q_requests + 1;
            end

            if (kv_req_valid && kv_req_ready) begin
                int expected_tile;
                int expected_start;
                int expected_len;

                expected_tile = kv_requests % TILES_PER_ROW;
                expected_start = expected_tile * BK;
                expected_len = S_LEN - expected_start;
                if (expected_len > BK) begin
                    expected_len = BK;
                end

                if ((kv_req_start !== expected_start[ROW_W-1:0]) ||
                    (kv_req_len !== expected_len[LEN_W-1:0])) begin
                    $display("FAIL K/V request index=%0d got start=%0d len=%0d expected start=%0d len=%0d",
                             kv_requests, kv_req_start, kv_req_len, expected_start, expected_len);
                    $fatal(1);
                end

                for (b = 0; b < BK; b = b + 1) begin
                    for (d = 0; d < D_MODEL; d = d + 1) begin
                        k_tile[b][d] <= k_value(expected_start + b, d);
                        v_tile[b][d] <= v_value(expected_start + b, d);
                    end
                end
                kv_data_valid <= 1'b1;
                kv_requests <= kv_requests + 1;
            end

            if (o_valid && o_ready) begin
                if (o_row !== output_rows[ROW_W-1:0]) begin
                    $display("FAIL O row got=%0d expected=%0d", o_row, output_rows);
                    $fatal(1);
                end

                for (d = 0; d < D_MODEL; d = d + 1) begin
                    if (o_data[d] !== expected_o(output_rows, d)) begin
                        $display("FAIL O[%0d][%0d] got=%0d hex=%04h expected=%0d hex=%04h",
                                 o_row, d, o_data[d], o_data[d],
                                 expected_o(output_rows, d), expected_o(output_rows, d));
                        $fatal(1);
                    end
                end

                $display("PASS param core S=%0d D=%0d BK=%0d causal=%0d row=%0d o0=%0d hex=%04h",
                         S_LEN, D_MODEL, BK, CAUSAL_EN, o_row, o_data[0], o_data[0]);
                output_rows <= output_rows + 1;
            end
        end
    end

    initial begin
        $dumpfile("tb_flash_core_param_bitexact.vcd");
        $dumpvars(0, tb_flash_core_param_bitexact);

        clk          = 1'b0;
        rst_n        = 1'b0;
        start        = 1'b0;
        causal_en    = (CAUSAL_EN != 0);
        neg_large    = -32'sd32768;
        scale        = SCALE_Q8_8;
        q_req_ready  = 1'b1;
        kv_req_ready = 1'b1;
        o_ready      = 1'b1;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        fork
            begin
                wait (done);
            end
            begin
                repeat (TIMEOUT_CYCLES) @(posedge clk);
                $display("FAIL timeout waiting for param core done S=%0d D=%0d BK=%0d causal=%0d",
                         S_LEN, D_MODEL, BK, CAUSAL_EN);
                $fatal(1);
            end
        join_any
        disable fork;

        @(posedge clk);
        if (error) begin
            $display("FAIL core error asserted");
            $fatal(1);
        end
        if (q_requests != S_LEN) begin
            $display("FAIL q_requests=%0d expected=%0d", q_requests, S_LEN);
            $fatal(1);
        end
        if (kv_requests != S_LEN * TILES_PER_ROW) begin
            $display("FAIL kv_requests=%0d expected=%0d", kv_requests, S_LEN * TILES_PER_ROW);
            $fatal(1);
        end
        if (output_rows != S_LEN) begin
            $display("FAIL output_rows=%0d expected=%0d", output_rows, S_LEN);
            $fatal(1);
        end

        $display("tb_flash_core_param_bitexact PASS S=%0d D=%0d BK=%0d causal=%0d scale=%0d",
                 S_LEN, D_MODEL, BK, CAUSAL_EN, SCALE_Q8_8);
        $finish;
    end
endmodule
