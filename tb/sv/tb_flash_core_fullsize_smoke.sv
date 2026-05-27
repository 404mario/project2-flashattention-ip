`timescale 1ns/1ps

module tb_flash_core_fullsize_smoke;
    localparam int S_LEN       = 256;
    localparam int D_MODEL     = 64;
    localparam int BK          = 16;
    localparam int DATA_W      = 16;
    localparam int ACC_W       = 48;
    localparam int FRAC_W      = 8;
    localparam int SCALE_Q8_8  = 32;
    localparam int ROW_W       = $clog2(S_LEN);
    localparam int LEN_W       = $clog2(BK + 1);
    localparam int TILES_PER_ROW = S_LEN / BK;
    localparam int TIMEOUT_CYCLES = 5000000;

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
    int start_cycle;
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
        .valid_len(S_LEN),
        .dropout_en(1'b0),
        .dropout_threshold(16'd0),
        .dropout_seed(16'hace1),
        .dropout_scale_q8_8(16'd256),
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
            q_value = ((((row + col * 3) % 9) - 4) <<< 1);
        end
    endfunction

    function automatic longint signed k_value(input int key_row, input int col);
        begin
            k_value = ((((key_row * 2 + col) % 11) - 5) <<< 1);
        end
    endfunction

    function automatic longint signed v_value(input int key_row, input int col);
        begin
            v_value = ((((key_row * 5 + col * 7) % 17) - 8) <<< 2);
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

    task automatic check_no_x_output(input int row);
        begin
            if (o_row !== row[ROW_W-1:0]) begin
                $display("FAIL fullsize O row got=%0d expected=%0d", o_row, row);
                $fatal(1);
            end

            for (d = 0; d < D_MODEL; d = d + 1) begin
                if ((^o_data[d]) === 1'bx) begin
                    $display("FAIL fullsize O[%0d][%0d] is X/Z", row, d);
                    $fatal(1);
                end
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_data_valid  <= 1'b0;
            kv_data_valid <= 1'b0;
            q_requests    <= 0;
            kv_requests   <= 0;
            output_rows   <= 0;
            cycle_count   <= 0;

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
            cycle_count <= cycle_count + 1;
            q_data_valid <= 1'b0;
            kv_data_valid <= 1'b0;

            if (q_req_valid && q_req_ready) begin
                if (q_req_row !== q_requests[ROW_W-1:0]) begin
                    $display("FAIL fullsize Q request got row=%0d expected=%0d", q_req_row, q_requests);
                    $fatal(1);
                end
                drive_q_row(q_requests);
                q_data_valid <= 1'b1;
                q_requests <= q_requests + 1;
            end

            if (kv_req_valid && kv_req_ready) begin
                int expected_tile;
                int expected_start;

                expected_tile = kv_requests % TILES_PER_ROW;
                expected_start = expected_tile * BK;
                if ((kv_req_start !== expected_start[ROW_W-1:0]) ||
                    (kv_req_len !== BK[LEN_W-1:0])) begin
                    $display("FAIL fullsize K/V request index=%0d got start=%0d len=%0d expected start=%0d len=%0d",
                             kv_requests, kv_req_start, kv_req_len, expected_start, BK);
                    $fatal(1);
                end
                drive_kv_tile(expected_start);
                kv_data_valid <= 1'b1;
                kv_requests <= kv_requests + 1;
            end

            if (o_valid && o_ready) begin
                check_no_x_output(output_rows);
                if ((output_rows % 32) == 0) begin
                    $display("PASS fullsize row=%0d o0=%0d", o_row, o_data[0]);
                end
                output_rows <= output_rows + 1;
            end
        end
    end

    initial begin
        clk          = 1'b0;
        rst_n        = 1'b0;
        start        = 1'b0;
        causal_en    = 1'b1;
        neg_large    = -32'sd32768;
        scale        = SCALE_Q8_8;
        q_req_ready  = 1'b1;
        kv_req_ready = 1'b1;
        o_ready      = 1'b1;
        start_cycle  = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        @(negedge clk);
        start_cycle = cycle_count;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        fork
            begin
                wait (done);
            end
            begin
                repeat (TIMEOUT_CYCLES) @(posedge clk);
                $display("FAIL timeout waiting for fullsize core done");
                $fatal(1);
            end
        join_any
        disable fork;

        @(posedge clk);
        if (error) begin
            $display("FAIL fullsize core error asserted");
            $fatal(1);
        end
        if (q_requests != S_LEN) begin
            $display("FAIL fullsize q_requests=%0d expected=%0d", q_requests, S_LEN);
            $fatal(1);
        end
        if (kv_requests != S_LEN * TILES_PER_ROW) begin
            $display("FAIL fullsize kv_requests=%0d expected=%0d", kv_requests, S_LEN * TILES_PER_ROW);
            $fatal(1);
        end
        if (output_rows != S_LEN) begin
            $display("FAIL fullsize output_rows=%0d expected=%0d", output_rows, S_LEN);
            $fatal(1);
        end

        $display("tb_flash_core_fullsize_smoke PASS cycles=%0d q_requests=%0d kv_requests=%0d output_rows=%0d",
                 cycle_count - start_cycle, q_requests, kv_requests, output_rows);
        $finish;
    end
endmodule

