`timescale 1ns/1ps

module tb_flash_core_backpressure_bitexact;
    localparam int S_LEN       = 6;
    localparam int D_MODEL     = 5;
    localparam int BK          = 4;
    localparam int DATA_W      = 16;
    localparam int ACC_W       = 48;
    localparam int FRAC_W      = 8;
    localparam int WEIGHT_FRAC = 8;
    localparam int WEIGHT_ONE  = 1 << WEIGHT_FRAC;
    localparam int SCALE_Q8_8  = 320;
    localparam int ROW_W       = (S_LEN <= 1) ? 1 : $clog2(S_LEN);
    localparam int LEN_W       = (BK <= 1) ? 1 : $clog2(BK + 1);
    localparam int TILES_PER_ROW = (S_LEN + BK - 1) / BK;
    localparam int TIMEOUT_CYCLES = 30000;

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
    int cycle_count;
    int q_requests;
    int kv_requests;
    int output_rows;
    int stall_cycles_seen;

    logic q_pending;
    logic [ROW_W-1:0] q_pending_row;
    int q_delay;

    logic kv_pending;
    logic [ROW_W-1:0] kv_pending_start;
    logic [LEN_W-1:0] kv_pending_len;
    int kv_delay;

    logic o_stall_active;
    logic [ROW_W-1:0] held_o_row;
    logic signed [DATA_W-1:0] held_o_data [0:D_MODEL-1];

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
            q_value = ((((row * 7 + col * 3 + 9) % 21) - 10) <<< 3);
        end
    endfunction

    function automatic longint signed k_value(input int key_row, input int col);
        begin
            k_value = ((((key_row * 5 + col * 11 + 4) % 23) - 11) <<< 3);
        end
    endfunction

    function automatic longint signed v_value(input int key_row, input int col);
        begin
            v_value = ((((key_row * 13 + col * 2 + 6) % 25) - 12) <<< 2);
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
                if (key <= row) begin
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

    task automatic drive_q_row(input int row);
        begin
            for (d = 0; d < D_MODEL; d = d + 1) begin
                q_data[d] <= q_value(row, d);
            end
        end
    endtask

    task automatic drive_kv_tile(input int start_row);
        begin
            for (b = 0; b < BK; b = b + 1) begin
                for (d = 0; d < D_MODEL; d = d + 1) begin
                    k_tile[b][d] <= k_value(start_row + b, d);
                    v_tile[b][d] <= v_value(start_row + b, d);
                end
            end
        end
    endtask

    task automatic check_output_row(input int row);
        begin
            if (o_row !== row[ROW_W-1:0]) begin
                $display("FAIL O row got=%0d expected=%0d", o_row, row);
                $fatal(1);
            end

            for (d = 0; d < D_MODEL; d = d + 1) begin
                if (o_data[d] !== expected_o(row, d)) begin
                    $display("FAIL O[%0d][%0d] got=%0d hex=%04h expected=%0d hex=%04h",
                             o_row, d, o_data[d], o_data[d],
                             expected_o(row, d), expected_o(row, d));
                    $fatal(1);
                end
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_data_valid      <= 1'b0;
            kv_data_valid     <= 1'b0;
            q_req_ready       <= 1'b0;
            kv_req_ready      <= 1'b0;
            o_ready           <= 1'b0;
            q_pending         <= 1'b0;
            kv_pending        <= 1'b0;
            q_delay           <= 0;
            kv_delay          <= 0;
            q_requests        <= 0;
            kv_requests       <= 0;
            output_rows       <= 0;
            cycle_count       <= 0;
            o_stall_active    <= 1'b0;
            stall_cycles_seen <= 0;

            for (d = 0; d < D_MODEL; d = d + 1) begin
                q_data[d]      <= '0;
                held_o_data[d] <= '0;
            end
            for (b = 0; b < BK; b = b + 1) begin
                for (d = 0; d < D_MODEL; d = d + 1) begin
                    k_tile[b][d] <= '0;
                    v_tile[b][d] <= '0;
                end
            end
        end else begin
            int expected_tile;
            int expected_start;
            int expected_len;

            cycle_count <= cycle_count + 1;

            q_req_ready  <= ((cycle_count % 4) != 1);
            kv_req_ready <= ((cycle_count % 5) != 2);
            o_ready      <= ((cycle_count % 8) == 0);

            if (q_data_valid && q_data_ready) begin
                q_data_valid <= 1'b0;
            end else if (!q_data_valid && q_pending) begin
                if (q_delay > 0) begin
                    q_delay <= q_delay - 1;
                end else begin
                    drive_q_row(q_pending_row);
                    q_data_valid <= 1'b1;
                    q_pending <= 1'b0;
                end
            end

            if (kv_data_valid && kv_data_ready) begin
                kv_data_valid <= 1'b0;
            end else if (!kv_data_valid && kv_pending) begin
                if (kv_delay > 0) begin
                    kv_delay <= kv_delay - 1;
                end else begin
                    drive_kv_tile(kv_pending_start);
                    kv_data_valid <= 1'b1;
                    kv_pending <= 1'b0;
                end
            end

            if (q_req_valid && q_req_ready) begin
                if (q_req_row !== q_requests[ROW_W-1:0]) begin
                    $display("FAIL Q request got row=%0d expected=%0d", q_req_row, q_requests);
                    $fatal(1);
                end
                if (q_pending || q_data_valid) begin
                    $display("FAIL overlapping Q request before previous row data completed");
                    $fatal(1);
                end
                q_pending <= 1'b1;
                q_pending_row <= q_req_row;
                q_delay <= (q_requests * 2 + 1) % 4;
                q_requests <= q_requests + 1;
            end

            if (kv_req_valid && kv_req_ready) begin
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
                if (kv_pending || kv_data_valid) begin
                    $display("FAIL overlapping K/V request before previous tile data completed");
                    $fatal(1);
                end
                kv_pending <= 1'b1;
                kv_pending_start <= kv_req_start;
                kv_pending_len <= kv_req_len;
                kv_delay <= (kv_requests * 3 + 2) % 5;
                kv_requests <= kv_requests + 1;
            end

            if (o_valid && !o_ready) begin
                stall_cycles_seen <= stall_cycles_seen + 1;
                if (!o_stall_active) begin
                    o_stall_active <= 1'b1;
                    held_o_row <= o_row;
                    for (d = 0; d < D_MODEL; d = d + 1) begin
                        held_o_data[d] <= o_data[d];
                    end
                end else begin
                    if (o_row !== held_o_row) begin
                        $display("FAIL o_row changed under backpressure got=%0d held=%0d", o_row, held_o_row);
                        $fatal(1);
                    end
                    for (d = 0; d < D_MODEL; d = d + 1) begin
                        if (o_data[d] !== held_o_data[d]) begin
                            $display("FAIL o_data[%0d] changed under backpressure got=%0d held=%0d",
                                     d, o_data[d], held_o_data[d]);
                            $fatal(1);
                        end
                    end
                end
            end else if (o_valid && o_ready) begin
                if (o_stall_active) begin
                    if (o_row !== held_o_row) begin
                        $display("FAIL accepted row changed after output stall");
                        $fatal(1);
                    end
                end
                check_output_row(output_rows);
                $display("PASS backpressure row=%0d o0=%0d stall_cycles_seen=%0d",
                         o_row, o_data[0], stall_cycles_seen);
                output_rows <= output_rows + 1;
                o_stall_active <= 1'b0;
            end else begin
                o_stall_active <= 1'b0;
            end
        end
    end

    initial begin
        $dumpfile("tb_flash_core_backpressure_bitexact.vcd");
        $dumpvars(0, tb_flash_core_backpressure_bitexact);

        clk       = 1'b0;
        rst_n     = 1'b0;
        start     = 1'b0;
        causal_en = 1'b1;
        neg_large = -32'sd32768;
        scale     = SCALE_Q8_8;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        wait (busy);
        repeat (9) @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        fork
            begin
                wait (done);
            end
            begin
                repeat (TIMEOUT_CYCLES) @(posedge clk);
                $display("FAIL timeout waiting for backpressure core done");
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
        if (stall_cycles_seen == 0) begin
            $display("FAIL output backpressure was not exercised");
            $fatal(1);
        end

        $display("tb_flash_core_backpressure_bitexact PASS");
        $finish;
    end
endmodule
