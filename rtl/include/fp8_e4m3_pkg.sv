package fp8_e4m3_pkg;

    function automatic logic signed [15:0] fp8_e4m3_to_q8_8(input logic [7:0] fp8);
        logic sign;
        logic [3:0] exp;
        logic [2:0] mant;
        logic [15:0] mag;
        begin
            sign = fp8[7];
            exp  = fp8[6:3];
            mant = fp8[2:0];

            unique case (exp)
                4'd0: begin
                    unique case (mant)
                        3'd0: mag = 16'd0;
                        3'd1: mag = 16'd1;
                        3'd2: mag = 16'd1;
                        3'd3: mag = 16'd2;
                        3'd4: mag = 16'd2;
                        3'd5: mag = 16'd3;
                        3'd6: mag = 16'd3;
                        default: mag = 16'd4;
                    endcase
                end
                4'd1: mag = (16'd8 + {13'd0, mant} + 16'd1) >> 1;
                4'd2: mag = 16'd8 + {13'd0, mant};
                4'd3: mag = (16'd8 + {13'd0, mant}) << 1;
                4'd4: mag = (16'd8 + {13'd0, mant}) << 2;
                4'd5: mag = (16'd8 + {13'd0, mant}) << 3;
                4'd6: mag = (16'd8 + {13'd0, mant}) << 4;
                4'd7: mag = (16'd8 + {13'd0, mant}) << 5;
                4'd8: mag = (16'd8 + {13'd0, mant}) << 6;
                4'd9: mag = (16'd8 + {13'd0, mant}) << 7;
                4'd10: mag = (16'd8 + {13'd0, mant}) << 8;
                4'd11: mag = (16'd8 + {13'd0, mant}) << 9;
                4'd12: mag = (16'd8 + {13'd0, mant}) << 10;
                4'd13: mag = (16'd8 + {13'd0, mant}) << 11;
                default: mag = 16'd32768;
            endcase

            if (sign) begin
                fp8_e4m3_to_q8_8 = (mag >= 16'd32768) ? 16'sh8000 : -$signed({1'b0, mag[14:0]});
            end else begin
                fp8_e4m3_to_q8_8 = (mag >= 16'd32768) ? 16'sh7fff : $signed({1'b0, mag[14:0]});
            end
        end
    endfunction

    function automatic logic [7:0] pack_e4m3(input logic sign, input logic [3:0] exp, input logic [4:0] sig);
        logic [3:0] exp_adj;
        logic [4:0] sig_adj;
        begin
            exp_adj = exp;
            sig_adj = sig;
            if (sig_adj > 5'd15) begin
                exp_adj = exp_adj + 1'b1;
                sig_adj = 5'd8;
            end
            if (exp_adj >= 4'd15) begin
                pack_e4m3 = {sign, 4'd15, 3'd7};
            end else begin
                pack_e4m3 = {sign, exp_adj, (sig_adj[2:0])};
            end
        end
    endfunction

    function automatic logic [7:0] q8_8_to_fp8_e4m3(input logic signed [15:0] q8_8);
        logic sign;
        logic [15:0] abs_q;
        begin
            sign = q8_8[15];
            abs_q = sign ? (~q8_8 + 16'd1) : q8_8;

            if (abs_q == 16'd0) begin
                q8_8_to_fp8_e4m3 = 8'h00;
            end else if (abs_q <= 16'd3) begin
                q8_8_to_fp8_e4m3 = {sign, 4'd0, (abs_q[2:0] << 1)};
            end else if (abs_q <= 16'd7) begin
                q8_8_to_fp8_e4m3 = pack_e4m3(sign, 4'd1, {1'b0, abs_q[3:0]} << 1);
            end else if (abs_q <= 16'd15) begin
                q8_8_to_fp8_e4m3 = pack_e4m3(sign, 4'd2, {1'b0, abs_q[3:0]});
            end else if (abs_q <= 16'd31) begin
                q8_8_to_fp8_e4m3 = pack_e4m3(sign, 4'd3, (abs_q[5:1] + abs_q[0]));
            end else if (abs_q <= 16'd63) begin
                q8_8_to_fp8_e4m3 = pack_e4m3(sign, 4'd4, (abs_q[6:2] + |abs_q[1:0]));
            end else if (abs_q <= 16'd127) begin
                q8_8_to_fp8_e4m3 = pack_e4m3(sign, 4'd5, (abs_q[7:3] + |abs_q[2:0]));
            end else if (abs_q <= 16'd255) begin
                q8_8_to_fp8_e4m3 = pack_e4m3(sign, 4'd6, (abs_q[8:4] + |abs_q[3:0]));
            end else if (abs_q <= 16'd511) begin
                q8_8_to_fp8_e4m3 = pack_e4m3(sign, 4'd7, (abs_q[9:5] + |abs_q[4:0]));
            end else if (abs_q <= 16'd1023) begin
                q8_8_to_fp8_e4m3 = pack_e4m3(sign, 4'd8, (abs_q[10:6] + |abs_q[5:0]));
            end else if (abs_q <= 16'd2047) begin
                q8_8_to_fp8_e4m3 = pack_e4m3(sign, 4'd9, (abs_q[11:7] + |abs_q[6:0]));
            end else if (abs_q <= 16'd4095) begin
                q8_8_to_fp8_e4m3 = pack_e4m3(sign, 4'd10, (abs_q[12:8] + |abs_q[7:0]));
            end else if (abs_q <= 16'd8191) begin
                q8_8_to_fp8_e4m3 = pack_e4m3(sign, 4'd11, (abs_q[13:9] + |abs_q[8:0]));
            end else if (abs_q <= 16'd16383) begin
                q8_8_to_fp8_e4m3 = pack_e4m3(sign, 4'd12, (abs_q[14:10] + |abs_q[9:0]));
            end else if (abs_q <= 16'd32767) begin
                q8_8_to_fp8_e4m3 = pack_e4m3(sign, 4'd13, (abs_q[15:11] + |abs_q[10:0]));
            end else begin
                q8_8_to_fp8_e4m3 = {sign, 4'd15, 3'd7};
            end
        end
    endfunction

endpackage
