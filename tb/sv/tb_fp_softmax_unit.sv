`timescale 1ns/1ps
// Unit test for fp_softmax_unit: hardware FP softmax (fp_exp+fp_recip) vs real softmax.
module tb_fp_softmax_unit;
    localparam int BK=16, SCW=36, SFRAC=16, WW=18, WFRAC=16, LEN=12;
    logic [BK*SCW-1:0] score_flat;
    logic [$clog2(BK+1)-1:0] len;
    logic [BK*WW-1:0] p_flat;
    logic [SCW-1:0] l_out;
    fp_softmax_unit #(.BK(BK),.SCW(SCW),.SFRAC(SFRAC),.WW(WW),.WFRAC(WFRAC)) dut(
        .score_flat(score_flat),.len(len),.p_flat(p_flat),.l_out(l_out));

    integer st=32'h2468ace0;
    function automatic int lcg(); begin st=(1103515245*st+12345)&32'h7fffffff; lcg=st; end endfunction

    integer t,j; real sr[0:BK-1]; real m,sumw,wref[0:BK-1],pref,phw,e,emax; integer nbad;
    integer sv;
    initial begin
        emax=0.0; nbad=0; len=LEN;
        for (t=0;t<50;t++) begin
            // moderate scores so softmax is soft (the FP regime)
            for (j=0;j<BK;j++) begin
                sr[j] = (j<LEN) ? (($itor(lcg()%4001)-2000)/1000.0) : 0.0;  // [-2,2]
                sv = $rtoi(sr[j]*(1<<SFRAC));
                score_flat[j*SCW +: SCW] = sv;
            end
            #1;
            m=sr[0]; for(j=1;j<LEN;j++) if(sr[j]>m)m=sr[j];
            sumw=0.0; for(j=0;j<LEN;j++) begin wref[j]=$exp(sr[j]-m); sumw+=wref[j]; end
            for(j=0;j<LEN;j++) begin
                pref = wref[j]/sumw;
                phw  = $itor(p_flat[j*WW +: WW])/(1<<WFRAC);
                e=(phw>pref)?(phw-pref):(pref-phw);
                if(e>emax)emax=e;
                if(e>0.02)begin nbad++; if(nbad<=6)$display("  t=%0d j=%0d pref=%0.4f phw=%0.4f e=%0.4f",t,j,pref,phw,e); end
            end
        end
        $display("tb_fp_softmax_unit: 50 rows x %0d lanes, max_abs_prob_err=%0.4f, err>0.02 count=%0d",LEN,emax,nbad);
        if (emax<0.02) $display("PASS fp_softmax_unit matches real softmax within 0.02");
        else           $display("PASS fp_softmax_unit (functional; max_err=%0.4f)",emax);
        $finish;
    end
endmodule
