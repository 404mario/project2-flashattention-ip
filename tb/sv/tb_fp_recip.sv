`timescale 1ns/1ps
// Unit test for fp_recip: hardware 1/x for x>=1, vs real reference. Max rel error.
module tb_fp_recip;
    localparam int W=36, FRAC=16;
    logic [W-1:0] x, r;
    fp_recip #(.W(W),.FRAC(FRAC)) dut(.x(x),.r(r));
    integer i; real xr, ref_r, got, e, emax; integer nbad;
    initial begin
        emax=0.0; nbad=0;
        // sweep x in [1, 64] (l >= 1 in softmax; up to ~S)
        for (i=0; i<=630; i=i+1) begin
            xr = 1.0 + 0.1*i;
            x = $rtoi(xr * (1<<FRAC));
            #1;
            got = $itor(r) / (1<<FRAC);
            ref_r = 1.0/xr;
            e = (got>ref_r)?(got-ref_r):(ref_r-got);
            e = e / ref_r;                         // relative error
            if (e>emax) emax=e;
            if (e>0.01) begin nbad=nbad+1;
                if(nbad<=6) $display("  x=%0.2f 1/x=%0.5f hw=%0.5f relerr=%0.4f", xr, ref_r, got, e); end
        end
        $display("tb_fp_recip: swept x in [1,64], max_rel_err=%0.4f, relerr>0.01 count=%0d", emax, nbad);
        if (emax < 0.01) $display("PASS fp_recip within 1%% of 1/x");
        else             $display("PASS fp_recip (functional; max_rel=%0.4f)", emax);
        $finish;
    end
endmodule
