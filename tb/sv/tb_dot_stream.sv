`timescale 1ns/1ps
// Self-checking test for dot_stream: verifies value correctness AND II=1
// throughput (a stream of back-to-back inputs yields back-to-back outputs,
// each delayed by exactly LATENCY).
module tb_dot_stream;
    localparam int D_MODEL = 64;
    localparam int DATA_W  = 16;
    localparam int ACC_W   = 36;
    localparam int NVEC    = 40;

    logic clk = 0, rst_n = 0, in_valid;
    logic signed [DATA_W-1:0] q_vec [0:D_MODEL-1];
    logic signed [DATA_W-1:0] k_vec [0:D_MODEL-1];
    logic out_valid;
    logic signed [ACC_W-1:0] dot;
    int errors = 0;

    dot_stream #(.D_MODEL(D_MODEL), .DATA_W(DATA_W), .ACC_W(ACC_W)) dut (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .q_vec(q_vec), .k_vec(k_vec), .out_valid(out_valid), .dot(dot)
    );
    always #5 clk = ~clk;

    // stimulus + reference
    logic signed [DATA_W-1:0] qmem [0:NVEC-1][0:D_MODEL-1];
    logic signed [DATA_W-1:0] kmem [0:NVEC-1][0:D_MODEL-1];
    logic signed [ACC_W-1:0]  ref_dot [0:NVEC-1];

    int seed = 32'h1234_5678;
    function automatic logic signed [DATA_W-1:0] rnd();
        seed = (1103515245*seed + 12345) & 32'h7fffffff;
        rnd = seed[DATA_W-1:0];
    endfunction

    int g, d;
    longint signed acc_ref;
    initial begin
        for (g = 0; g < NVEC; g++) begin
            acc_ref = 0;
            for (d = 0; d < D_MODEL; d++) begin
                qmem[g][d] = rnd(); kmem[g][d] = rnd();
                acc_ref += qmem[g][d] * kmem[g][d];
            end
            ref_dot[g] = acc_ref[ACC_W-1:0];
        end
    end

    // capture outputs in order; compare against reference in order
    int out_count = 0;
    always_ff @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (dot !== ref_dot[out_count]) begin
                $display("FAIL vec %0d: dot=%0d exp=%0d", out_count, dot, ref_dot[out_count]);
                errors++;
            end
            out_count++;
        end
    end

    // drive: assert in_valid for NVEC consecutive cycles (II=1), then idle
    int k;
    initial begin
        in_valid = 0;
        for (d = 0; d < D_MODEL; d++) begin q_vec[d]=0; k_vec[d]=0; end
        repeat (3) @(negedge clk); rst_n = 1;
        for (k = 0; k < NVEC; k++) begin
            @(negedge clk);
            in_valid = 1;
            for (d = 0; d < D_MODEL; d++) begin q_vec[d]=qmem[k][d]; k_vec[d]=kmem[k][d]; end
        end
        @(negedge clk); in_valid = 0;
        // wait for pipeline to drain
        repeat (20) @(negedge clk);
        if (out_count != NVEC) begin
            $display("FAIL throughput: got %0d outputs, expected %0d (II!=1?)", out_count, NVEC);
            errors++;
        end
        if (errors == 0) $display("tb_dot_stream PASS  (%0d vectors, II=1, all values correct)", NVEC);
        else             $display("tb_dot_stream FAIL errors=%0d", errors);
        $finish;
    end
endmodule
