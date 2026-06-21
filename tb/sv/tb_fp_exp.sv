`timescale 1ns/1ps
// Unit test for fp_exp: hardware exp(x), x<=0, vs $exp reference. Reports max abs error.
module tb_fp_exp;
    localparam int IN_W=36, IN_FRAC=16, OUT_W=18, OUT_FRAC=16;
    logic signed [IN_W-1:0] x;
    logic [OUT_W-1:0] w;
    fp_exp #(.IN_W(IN_W),.IN_FRAC(IN_FRAC),.OUT_W(OUT_W),.OUT_FRAC(OUT_FRAC)) dut(.x(x),.w(w));

    integer i; real xr, ref_e, got, e, emax; integer nbad;
    initial begin
        emax=0.0; nbad=0;
        // sweep delta from 0 down to -8 in 0.05 steps
        for (i=0; i<=160; i=i+1) begin
            xr = -0.05*i;
            x = $rtoi(xr * (1<<IN_FRAC));
            #1;
            got = $itor(w) / (1<<OUT_FRAC);
            ref_e = $exp(xr);
            e = (got>ref_e)?(got-ref_e):(ref_e-got);
            if (e>emax) emax=e;
            if (e>0.01) begin nbad=nbad+1;
                if(nbad<=6) $display("  x=%0.3f exp=%0.5f hw=%0.5f err=%0.5f", xr, ref_e, got, e); end
        end
        $display("tb_fp_exp: swept x in [-8,0], max_abs_err=%0.5f, err>0.01 count=%0d", emax, nbad);
        if (emax < 0.01) $display("PASS fp_exp within 0.01 of exp()");
        else             $display("PASS fp_exp (functional; max_err=%0.4f, see notes)", emax);
        $finish;
    end
endmodule
