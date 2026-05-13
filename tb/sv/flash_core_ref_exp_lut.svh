function automatic longint unsigned exp_approx_weight(input longint signed delta);
    longint unsigned abs_delta;
    longint unsigned lut_index;
    begin
        if (delta >= 0) begin
            exp_approx_weight = WEIGHT_ONE;
        end else begin
            abs_delta = -delta;
            lut_index = (abs_delta + (1 << (WEIGHT_FRAC - 4))) >> (WEIGHT_FRAC - 3);

            case (lut_index)
                0:  exp_approx_weight = 256;
                1:  exp_approx_weight = 226;
                2:  exp_approx_weight = 199;
                3:  exp_approx_weight = 176;
                4:  exp_approx_weight = 155;
                5:  exp_approx_weight = 137;
                6:  exp_approx_weight = 121;
                7:  exp_approx_weight = 107;
                8:  exp_approx_weight = 94;
                9:  exp_approx_weight = 83;
                10: exp_approx_weight = 73;
                11: exp_approx_weight = 65;
                12: exp_approx_weight = 57;
                13: exp_approx_weight = 50;
                14: exp_approx_weight = 44;
                15: exp_approx_weight = 39;
                16: exp_approx_weight = 35;
                17: exp_approx_weight = 31;
                18: exp_approx_weight = 27;
                19: exp_approx_weight = 24;
                20: exp_approx_weight = 21;
                21: exp_approx_weight = 19;
                22: exp_approx_weight = 16;
                23: exp_approx_weight = 14;
                24: exp_approx_weight = 13;
                25: exp_approx_weight = 11;
                26: exp_approx_weight = 10;
                27: exp_approx_weight = 9;
                28: exp_approx_weight = 8;
                29: exp_approx_weight = 7;
                30: exp_approx_weight = 6;
                31: exp_approx_weight = 5;
                32: exp_approx_weight = 5;
                33: exp_approx_weight = 4;
                34: exp_approx_weight = 4;
                35: exp_approx_weight = 3;
                36: exp_approx_weight = 3;
                37: exp_approx_weight = 3;
                38: exp_approx_weight = 2;
                39: exp_approx_weight = 2;
                40: exp_approx_weight = 2;
                41: exp_approx_weight = 2;
                42: exp_approx_weight = 1;
                43: exp_approx_weight = 1;
                44: exp_approx_weight = 1;
                45: exp_approx_weight = 1;
                46: exp_approx_weight = 1;
                47: exp_approx_weight = 1;
                48: exp_approx_weight = 1;
                49: exp_approx_weight = 1;
                default: exp_approx_weight = 0;
            endcase
        end
    end
endfunction
