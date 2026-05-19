`timescale 1ns/1ps

module online_softmax_engine #(
    parameter int SCORE_W     = 48,
    parameter int L_W         = 48,
    parameter int WEIGHT_W    = 16,
    parameter int WEIGHT_FRAC = 8,
    parameter int SCORE_FRAC  = 8
) (
    input  logic score_valid,
    input  logic signed [SCORE_W-1:0] score,
    input  logic signed [SCORE_W-1:0] m_in,
    input  logic [L_W-1:0] l_in,

    output logic signed [SCORE_W-1:0] m_out,
    output logic [L_W-1:0] l_out,
    output logic [WEIGHT_W-1:0] old_scale,
    output logic [WEIGHT_W-1:0] new_weight
);
    localparam logic [WEIGHT_W-1:0] WEIGHT_ONE = (1 << WEIGHT_FRAC);
    localparam int EXP_LUT_ADDR_W    = 6;
    localparam int EXP_LUT_FRAC_BITS = 3;
    localparam int EXP_LUT_SHIFT     = SCORE_FRAC - EXP_LUT_FRAC_BITS;
    localparam int EXP_LUT_SIZE      = 1 << EXP_LUT_ADDR_W;
    localparam logic [SCORE_W-1:0] EXP_LUT_ROUND = (1 << (EXP_LUT_SHIFT - 1));
    localparam logic [SCORE_W-1:0] EXP_LUT_MAX_DELTA =
        (EXP_LUT_SIZE - 1) << EXP_LUT_SHIFT;
    localparam int Q16_TO_WEIGHT_SHIFT = (WEIGHT_FRAC < 16) ? (16 - WEIGHT_FRAC) : 0;
    localparam logic [31:0] Q16_TO_WEIGHT_ROUND =
        (Q16_TO_WEIGHT_SHIFT > 0) ? (1 << (Q16_TO_WEIGHT_SHIFT - 1)) : 0;

    function automatic logic [17:0] exp_lut_q16_value(
        input logic [EXP_LUT_ADDR_W-1:0] index
    );
        begin
            case (index)
                6'd0:  exp_lut_q16_value = 18'd65536;
                6'd1:  exp_lut_q16_value = 18'd57835;
                6'd2:  exp_lut_q16_value = 18'd51039;
                6'd3:  exp_lut_q16_value = 18'd45042;
                6'd4:  exp_lut_q16_value = 18'd39750;
                6'd5:  exp_lut_q16_value = 18'd35079;
                6'd6:  exp_lut_q16_value = 18'd30957;
                6'd7:  exp_lut_q16_value = 18'd27319;
                6'd8:  exp_lut_q16_value = 18'd24109;
                6'd9:  exp_lut_q16_value = 18'd21276;
                6'd10: exp_lut_q16_value = 18'd18776;
                6'd11: exp_lut_q16_value = 18'd16570;
                6'd12: exp_lut_q16_value = 18'd14623;
                6'd13: exp_lut_q16_value = 18'd12905;
                6'd14: exp_lut_q16_value = 18'd11388;
                6'd15: exp_lut_q16_value = 18'd10050;
                6'd16: exp_lut_q16_value = 18'd8869;
                6'd17: exp_lut_q16_value = 18'd7827;
                6'd18: exp_lut_q16_value = 18'd6907;
                6'd19: exp_lut_q16_value = 18'd6096;
                6'd20: exp_lut_q16_value = 18'd5380;
                6'd21: exp_lut_q16_value = 18'd4747;
                6'd22: exp_lut_q16_value = 18'd4190;
                6'd23: exp_lut_q16_value = 18'd3697;
                6'd24: exp_lut_q16_value = 18'd3263;
                6'd25: exp_lut_q16_value = 18'd2879;
                6'd26: exp_lut_q16_value = 18'd2541;
                6'd27: exp_lut_q16_value = 18'd2243;
                6'd28: exp_lut_q16_value = 18'd1979;
                6'd29: exp_lut_q16_value = 18'd1746;
                6'd30: exp_lut_q16_value = 18'd1541;
                6'd31: exp_lut_q16_value = 18'd1360;
                6'd32: exp_lut_q16_value = 18'd1200;
                6'd33: exp_lut_q16_value = 18'd1059;
                6'd34: exp_lut_q16_value = 18'd935;
                6'd35: exp_lut_q16_value = 18'd825;
                6'd36: exp_lut_q16_value = 18'd728;
                6'd37: exp_lut_q16_value = 18'd642;
                6'd38: exp_lut_q16_value = 18'd567;
                6'd39: exp_lut_q16_value = 18'd500;
                6'd40: exp_lut_q16_value = 18'd442;
                6'd41: exp_lut_q16_value = 18'd390;
                6'd42: exp_lut_q16_value = 18'd344;
                6'd43: exp_lut_q16_value = 18'd303;
                6'd44: exp_lut_q16_value = 18'd268;
                6'd45: exp_lut_q16_value = 18'd236;
                6'd46: exp_lut_q16_value = 18'd209;
                6'd47: exp_lut_q16_value = 18'd184;
                6'd48: exp_lut_q16_value = 18'd162;
                6'd49: exp_lut_q16_value = 18'd143;
                6'd50: exp_lut_q16_value = 18'd127;
                6'd51: exp_lut_q16_value = 18'd112;
                6'd52: exp_lut_q16_value = 18'd99;
                6'd53: exp_lut_q16_value = 18'd87;
                6'd54: exp_lut_q16_value = 18'd77;
                6'd55: exp_lut_q16_value = 18'd68;
                6'd56: exp_lut_q16_value = 18'd60;
                6'd57: exp_lut_q16_value = 18'd53;
                6'd58: exp_lut_q16_value = 18'd47;
                6'd59: exp_lut_q16_value = 18'd41;
                6'd60: exp_lut_q16_value = 18'd36;
                6'd61: exp_lut_q16_value = 18'd32;
                6'd62: exp_lut_q16_value = 18'd28;
                6'd63: exp_lut_q16_value = 18'd25;
                default: exp_lut_q16_value = '0;
            endcase
        end
    endfunction

    function automatic logic [WEIGHT_W-1:0] scale_q16_weight(
        input logic [17:0] q16_value
    );
        logic [31:0] rounded;
        begin
            if (WEIGHT_FRAC == 16) begin
                scale_q16_weight = q16_value[WEIGHT_W-1:0];
            end else if (WEIGHT_FRAC < 16) begin
                rounded = q16_value + Q16_TO_WEIGHT_ROUND;
                scale_q16_weight = rounded >> Q16_TO_WEIGHT_SHIFT;
            end else begin
                scale_q16_weight = q16_value << (WEIGHT_FRAC - 16);
            end
        end
    endfunction

    function automatic logic [WEIGHT_W-1:0] exp_lut_value(
        input logic [EXP_LUT_ADDR_W-1:0] index
    );
        begin
            exp_lut_value = scale_q16_weight(exp_lut_q16_value(index));
        end
    endfunction

    function automatic logic [WEIGHT_W-1:0] exp_approx_weight(
        input logic signed [SCORE_W-1:0] delta
    );
        logic [SCORE_W-1:0] abs_delta;
        logic [SCORE_W-1:0] lut_index;
        logic [SCORE_W-1:0] lut_rem;
        logic [WEIGHT_W-1:0] y0;
        logic [WEIGHT_W-1:0] y1;
        logic signed [WEIGHT_W:0] y_diff;
        logic signed [SCORE_W+WEIGHT_W:0] interp_delta;
        logic signed [SCORE_W+WEIGHT_W:0] interp_value;
        begin
            if (delta[SCORE_W-1] == 1'b0) begin
                exp_approx_weight = WEIGHT_ONE;
            end else begin
                abs_delta = -delta;
                if (SCORE_FRAC <= 8) begin
                    lut_index = (abs_delta + EXP_LUT_ROUND) >> EXP_LUT_SHIFT;
                    if (lut_index >= EXP_LUT_SIZE) begin
                        exp_approx_weight = '0;
                    end else begin
                        exp_approx_weight = exp_lut_value(lut_index[EXP_LUT_ADDR_W-1:0]);
                    end
                end else begin
                    if (abs_delta > EXP_LUT_MAX_DELTA) begin
                        exp_approx_weight = '0;
                    end else begin
                        lut_index = abs_delta >> EXP_LUT_SHIFT;
                        lut_rem   = abs_delta - (lut_index << EXP_LUT_SHIFT);
                        if (lut_index == (EXP_LUT_SIZE - 1)) begin
                            exp_approx_weight = exp_lut_value(lut_index[EXP_LUT_ADDR_W-1:0]);
                        end else begin
                            y0 = exp_lut_value(lut_index[EXP_LUT_ADDR_W-1:0]);
                            y1 = exp_lut_value(lut_index[EXP_LUT_ADDR_W-1:0] + 1'b1);
                            y_diff = $signed({1'b0, y1}) - $signed({1'b0, y0});
                            interp_delta = (y_diff * $signed({1'b0, lut_rem}) +
                                            $signed(1 << (EXP_LUT_SHIFT - 1))) >>> EXP_LUT_SHIFT;
                            interp_value = $signed({1'b0, y0}) + interp_delta;
                            exp_approx_weight = interp_value[WEIGHT_W-1:0];
                        end
                    end
                end
            end
        end
    endfunction

    function automatic logic [L_W-1:0] update_l(
        input logic [L_W-1:0] old_l,
        input logic [WEIGHT_W-1:0] scale_old,
        input logic [WEIGHT_W-1:0] weight_new
    );
        logic [L_W+WEIGHT_W:0] scaled_l;
        logic [L_W+WEIGHT_W:0] sum_l;
        begin
            scaled_l = (old_l * scale_old) >> WEIGHT_FRAC;
            sum_l = scaled_l + weight_new;
            update_l = sum_l[L_W-1:0];
        end
    endfunction

    always @* begin
        m_out      = m_in;
        l_out      = l_in;
        old_scale  = WEIGHT_ONE;
        new_weight = '0;

        if (score_valid) begin
            if (l_in == '0) begin
                m_out      = score;
                l_out      = WEIGHT_ONE;
                old_scale  = '0;
                new_weight = WEIGHT_ONE;
            end else if (score > m_in) begin
                m_out      = score;
                old_scale  = exp_approx_weight(m_in - score);
                new_weight = WEIGHT_ONE;
                l_out      = update_l(l_in, old_scale, new_weight);
            end else begin
                m_out      = m_in;
                old_scale  = WEIGHT_ONE;
                new_weight = exp_approx_weight(score - m_in);
                l_out      = update_l(l_in, old_scale, new_weight);
            end
        end
    end
endmodule
