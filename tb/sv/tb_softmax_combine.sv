`timescale 1ns/1ps
// Self-checking test for softmax_combine: drives one query row's worth of keys
// as several tiles through the engine (start/wait-done, feeding state back),
// then checks O = acc/l against an FP32 softmax reference within the contest
// tolerance (MAE<=0.03, MaxE<=0.10). Exercises tile-max, the MAC inner loop,
// and the cross-tile merge correction.
module tb_softmax_combine;
    localparam int D_MODEL     = 8;
    localparam int BK          = 4;
    localparam int DATA_W      = 16;
    localparam int ACC_W       = 36;
    localparam int WEIGHT_W    = 17;
    localparam int WEIGHT_FRAC = 16;
    localparam int SCORE_FRAC  = 16;
    localparam int L_W         = 28;
    localparam int NKEY        = 10;   // 3 tiles: 4 + 4 + 2
    localparam int LEN_W       = $clog2(BK+1);

    logic clk = 0, rst_n = 0;
    logic start, row_first;
    logic [LEN_W-1:0] tile_len;
    logic signed [ACC_W-1:0]  score_in [0:BK-1];           // full score array (max_comb), driven as before
    logic signed [DATA_W-1:0] v_tile   [0:BK-1][0:D_MODEL-1]; // per-tile V store (TB-side memory)
    logic signed [ACC_W-1:0]  m_in;
    logic [L_W-1:0]           l_in;
    logic signed [ACC_W-1:0]  acc_in [0:D_MODEL-1];
    logic busy, done;
    logic signed [ACC_W-1:0]  m_out;
    logic [L_W-1:0]           l_out;
    logic [D_MODEL*ACC_W-1:0] acc_out_flat;
    logic signed [ACC_W-1:0]  acc_out [0:D_MODEL-1];
    always_comb for (int u = 0; u < D_MODEL; u++) acc_out[u] = acc_out_flat[u*ACC_W +: ACC_W];

    // ---- streamed v/score feed: mirror flash_core's 1-cycle-ahead prefetch ----
    logic                     vreq_valid;
    logic [LEN_W-1:0]         vreq_idx;
    logic signed [DATA_W-1:0] v_row_in [0:D_MODEL-1];
    logic signed [ACC_W-1:0]  score_cur_in;
    int pf;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (pf = 0; pf < D_MODEL; pf = pf + 1) v_row_in[pf] <= '0;
            score_cur_in <= '0;
        end else if (vreq_valid) begin
            for (pf = 0; pf < D_MODEL; pf = pf + 1) v_row_in[pf] <= v_tile[vreq_idx][pf];
            score_cur_in <= score_in[vreq_idx];
        end
    end

    softmax_combine #(
        .D_MODEL(D_MODEL), .BK(BK), .DATA_W(DATA_W), .ACC_W(ACC_W),
        .WEIGHT_W(WEIGHT_W), .WEIGHT_FRAC(WEIGHT_FRAC),
        .SCORE_FRAC(SCORE_FRAC), .L_W(L_W)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .row_first(row_first),
        .tile_len(tile_len), .score_in(score_in),
        .vreq_valid(vreq_valid), .vreq_idx(vreq_idx),
        .v_row_in(v_row_in), .score_cur_in(score_cur_in),
        .m_in(m_in), .l_in(l_in), .acc_in(acc_in),
        .busy(busy), .done(done), .m_out(m_out), .l_out(l_out), .acc_out_flat(acc_out_flat)
    );
    always #5 clk = ~clk;

    // stimulus: scores (real) and V (Q8.8 int); reference computed in real
    real    score_r [0:NKEY-1];
    logic signed [ACC_W-1:0] score_q [0:NKEY-1];   // 36-bit so the [ACC_W-1:0] slice is fully defined
    integer vq      [0:NKEY-1][0:D_MODEL-1];
    real    ref_O   [0:D_MODEL-1];

    int seed = 32'h0BADF00D;
    function automatic integer rnd();
        seed = (1103515245*seed + 12345) & 32'h7fffffff;
        rnd = seed;
    endfunction

    // running engine state (kept in TB between tile calls)
    logic signed [ACC_W-1:0] m_run;
    logic [L_W-1:0]          l_run;
    logic signed [ACC_W-1:0] acc_run [0:D_MODEL-1];

    int i, d, t, j, base, len;
    bit done_seen;
    real mx, denom, num;
    initial begin
        // build inputs + FP32 reference
        for (i = 0; i < NKEY; i++) begin
            score_r[i] = (((rnd() % 2000) - 1000) / 100.0);          // ~[-10,10]
            score_q[i] = $rtoi(score_r[i] * (1 << SCORE_FRAC));
            for (d = 0; d < D_MODEL; d++) vq[i][d] = (rnd() % 4096) - 2048; // Q8.8 ~[-8,8]
        end
        mx = score_r[0];
        for (i = 1; i < NKEY; i++) if (score_r[i] > mx) mx = score_r[i];
        denom = 0.0;
        for (i = 0; i < NKEY; i++) denom += $exp(score_r[i] - mx);
        for (d = 0; d < D_MODEL; d++) begin
            num = 0.0;
            for (i = 0; i < NKEY; i++) num += $exp(score_r[i] - mx) * (vq[i][d] / 256.0);
            ref_O[d] = num / denom;
        end
    end

    task automatic run_tile(input int base, input int len, input bit first);
        begin
            @(negedge clk);
            tile_len = len[LEN_W-1:0];
            row_first = first;
            for (j = 0; j < BK; j++) begin
                score_in[j] = (j < len) ? score_q[base + j][ACC_W-1:0] : -36'sd999999999;
                for (d = 0; d < D_MODEL; d++)
                    v_tile[j][d] = (j < len) ? vq[base + j][d][DATA_W-1:0] : '0;
            end
            m_in = m_run; l_in = l_run;
            for (d = 0; d < D_MODEL; d++) acc_in[d] = acc_run[d];
            start = 1'b1;
            @(negedge clk); start = 1'b0;
            // sample on the posedge where done is observed high (m/l/acc valid then)
            done_seen = 1'b0;
            while (!done_seen) begin
                @(posedge clk);
                if (done === 1'b1) done_seen = 1'b1;
            end
            #1;
            m_run = m_out; l_run = l_out;
            for (d = 0; d < D_MODEL; d++) acc_run[d] = acc_out[d];
            $display("  [tile base=%0d len=%0d first=%0b] m_out=%0d l_out=%0d acc_out[0]=%0d done=%0b",
                     base, len, first, $signed(m_out), l_out, $signed(acc_out[0]), done);
        end
    endtask

    real o_dut, e, mae, maxe;
    int errors = 0;
    initial begin
        start = 0; row_first = 0; tile_len = 0; m_run = 0; l_run = 0;
        for (d = 0; d < D_MODEL; d++) acc_run[d] = 0;
        repeat (3) @(negedge clk); rst_n = 1;
        @(negedge clk);

        // feed all tiles of the single row
        base = 0; t = 0;
        while (base < NKEY) begin
            len = (NKEY - base > BK) ? BK : (NKEY - base);
            run_tile(base, len, (t == 0));
            base += len; t++;
        end

        // O[d] = (acc/2^24) / (l/2^16) = (acc/l)/256
        mae = 0.0; maxe = 0.0;
        for (d = 0; d < D_MODEL; d++) begin
            o_dut = ($itor(acc_run[d]) / $itor(l_run)) / 256.0;
            e = (o_dut > ref_O[d]) ? (o_dut - ref_O[d]) : (ref_O[d] - o_dut);
            mae += e; if (e > maxe) maxe = e;
            $display("  d=%0d  O_dut=%f  O_ref=%f  err=%f", d, o_dut, ref_O[d], e);
        end
        mae = mae / D_MODEL;
        $display("softmax_combine: MAE=%f MaxE=%f (budget 0.03/0.10)", mae, maxe);
        if (mae <= 0.03 && maxe <= 0.10) $display("tb_softmax_combine PASS");
        else begin $display("tb_softmax_combine FAIL"); errors++; end
        $finish;
    end
endmodule
