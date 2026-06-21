`timescale 1ns/1ps
// Unit test for block_quant_dot (Bonus #7 FA-3 block quantization datapath element).
//  (1) bit-exact: recompute the integer block-quant spec inline, assert == DUT.
//  (2) quality  : report mean/max relative error of block-quant dot vs the TRUE dot.
// Self-contained (no python/numpy). LCG random vectors.
module tb_block_quant_dot;
    localparam int D_MODEL = 64;
    localparam int DATA_W  = 16;
    localparam int ACC_W   = 40;
    localparam int N       = 200;

    logic signed [DATA_W-1:0] q_vec [0:D_MODEL-1];
    logic signed [DATA_W-1:0] k_vec [0:D_MODEL-1];
    logic [D_MODEL*DATA_W-1:0] q_flat, k_flat;
    logic signed [ACC_W-1:0]  dut_dot;
    genvar gi;
    generate for (gi=0; gi<D_MODEL; gi=gi+1) begin : g_pack
        assign q_flat[gi*DATA_W +: DATA_W] = q_vec[gi];
        assign k_flat[gi*DATA_W +: DATA_W] = k_vec[gi];
    end endgenerate

    block_quant_dot #(.D_MODEL(D_MODEL), .DATA_W(DATA_W), .ACC_W(ACC_W)) dut (
        .q_flat(q_flat), .k_flat(k_flat), .dot(dut_dot));

    function automatic int unsigned qstep(input int unsigned amax);
        begin qstep=(amax==0)?1:((amax+126)/127); end
    endfunction
    function automatic int q8(input int x, input int unsigned step);
        int half, num, r;
        begin half=step/2; num=(x>=0)?(x+half):(x-half); r=num/$signed(step);
              if(r>127)r=127; if(r<-127)r=-127; q8=r; end
    endfunction

    integer st = 32'h1234_5678;
    function automatic int lcg();
        begin st=(1103515245*st+12345)&32'h7fffffff; lcg=st; end
    endfunction

    integer t, d, fails;
    int unsigned amq, amk, sq, sk, a;
    longint idot, refv, rawv;
    real rel_sum, rel_max, rel;
    integer amp;
    initial begin
        fails=0; rel_sum=0.0; rel_max=0.0;
        for (t=0;t<N;t++) begin
            amp = (1 + (lcg()%16));
            for (d=0; d<D_MODEL; d++) begin
                q_vec[d] = $signed((lcg()%512)-256);
                k_vec[d] = $signed((((lcg()%512)-256)*amp)/4);
            end
            #1;
            // inline integer reference (must equal DUT)
            amq=0; amk=0;
            for (d=0;d<D_MODEL;d++) begin
                a=(q_vec[d]<0)?-q_vec[d]:q_vec[d]; if(a>amq)amq=a;
                a=(k_vec[d]<0)?-k_vec[d]:k_vec[d]; if(a>amk)amk=a;
            end
            sq=qstep(amq); sk=qstep(amk); idot=0;
            for (d=0;d<D_MODEL;d++) idot+=q8(q_vec[d],sq)*q8(k_vec[d],sk);
            refv=idot*$signed(sq)*$signed(sk);
            rawv=0; for(d=0;d<D_MODEL;d++) rawv+=q_vec[d]*k_vec[d];

            if (dut_dot !== refv[ACC_W-1:0]) begin
                fails++; if(fails<=5) $display("  MISMATCH t=%0d dut=%0d ref=%0d",t,dut_dot,refv);
            end
            if (rawv != 0) begin
                rel=(($itor(dut_dot)-$itor(rawv))/$itor(rawv)); if(rel<0.0)rel=-rel;
                rel_sum+=rel; if(rel>rel_max)rel_max=rel;
            end
        end
        $display("tb_block_quant_dot: %0d vectors, bit-exact-vs-spec FAILS=%0d", N, fails);
        $display("  block-quant dot vs TRUE dot: mean_rel_err=%.4f max_rel_err=%.4f", rel_sum/N, rel_max);
        if (fails==0) $display("PASS block_quant_dot matches integer block-quant spec (bit-exact)");
        else          $display("FAIL block_quant_dot spec mismatch");
        $finish;
    end
endmodule
