package bf16_pkg;

    function automatic logic signed [15:0] saturate_q8_8(input longint signed value);
        begin
            if (value > 64'sd32767) begin
                saturate_q8_8 = 16'sh7fff;
            end else if (value < -64'sd32768) begin
                saturate_q8_8 = 16'sh8000;
            end else begin
                saturate_q8_8 = value[15:0];
            end
        end
    endfunction

    function automatic logic signed [15:0] bf16_to_q8_8(input logic [15:0] bf16);
        logic sign;
        logic [7:0] exp;
        logic [6:0] mant;
        int signed exp_unbiased;
        int shift;
        longint signed mag;
        begin
            sign = bf16[15];
            exp  = bf16[14:7];
            mant = bf16[6:0];

            if (exp == 8'd0) begin
                bf16_to_q8_8 = 16'sd0;
            end else if (exp == 8'hff) begin
                bf16_to_q8_8 = sign ? 16'sh8000 : 16'sh7fff;
            end else begin
                exp_unbiased = int'(exp) - 127;
                mag = 64'sd128 + mant;
                if ((exp_unbiased + 1) >= 0) begin
                    shift = exp_unbiased + 1;
                    if (shift >= 16) begin
                        mag = 64'sd32768;
                    end else begin
                        mag = mag <<< shift;
                    end
                end else begin
                    shift = -(exp_unbiased + 1);
                    if (shift >= 63) begin
                        mag = 64'sd0;
                    end else if (shift > 0) begin
                        mag = (mag + (64'sd1 <<< (shift - 1))) >>> shift;
                    end
                end
                bf16_to_q8_8 = saturate_q8_8(sign ? -mag : mag);
            end
        end
    endfunction

    function automatic logic [15:0] q8_8_to_bf16(input logic signed [15:0] q8_8);
        logic sign;
        logic [15:0] abs_q;
        logic [8:0] sig;
        logic [7:0] exp;
        int msb;
        int bit_idx;
        int shift;
        begin
            sign = q8_8[15];
            abs_q = sign ? (~q8_8 + 16'd1) : q8_8;

            if (abs_q == 16'd0) begin
                q8_8_to_bf16 = 16'h0000;
            end else begin
                msb = -1;
                for (bit_idx = 15; bit_idx >= 0; bit_idx = bit_idx - 1) begin
                    if ((msb < 0) && abs_q[bit_idx]) begin
                        msb = bit_idx;
                    end
                end

                exp = (msb - 8) + 127;
                if (msb > 7) begin
                    shift = msb - 7;
                    sig = abs_q >> shift;
                    if ((shift > 0) && abs_q[shift - 1]) begin
                        sig = sig + 1'b1;
                    end
                end else begin
                    sig = abs_q << (7 - msb);
                end

                if (sig >= 9'd256) begin
                    exp = exp + 1'b1;
                    sig = 9'd128;
                end

                q8_8_to_bf16 = {sign, exp, sig[6:0]};
            end
        end
    endfunction

endpackage
