`timescale 1ns/1ps

module online_softmax_engine #(
    parameter int SCORE_W     = 48,
    parameter int L_W         = 48,
    parameter int WEIGHT_W    = 16,
    parameter int WEIGHT_FRAC = 8
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
    localparam int EXP_LUT_SHIFT     = WEIGHT_FRAC - EXP_LUT_FRAC_BITS;
    localparam int EXP_LUT_SIZE      = 1 << EXP_LUT_ADDR_W;
    localparam logic [SCORE_W-1:0] EXP_LUT_ROUND = (1 << (EXP_LUT_SHIFT - 1));

    function automatic logic [WEIGHT_W-1:0] exp_lut_value(
        input logic [EXP_LUT_ADDR_W-1:0] index
    );
        begin
            case (index)
                6'd0:  exp_lut_value = 16'd256;
                6'd1:  exp_lut_value = 16'd226;
                6'd2:  exp_lut_value = 16'd199;
                6'd3:  exp_lut_value = 16'd176;
                6'd4:  exp_lut_value = 16'd155;
                6'd5:  exp_lut_value = 16'd137;
                6'd6:  exp_lut_value = 16'd121;
                6'd7:  exp_lut_value = 16'd107;
                6'd8:  exp_lut_value = 16'd94;
                6'd9:  exp_lut_value = 16'd83;
                6'd10: exp_lut_value = 16'd73;
                6'd11: exp_lut_value = 16'd65;
                6'd12: exp_lut_value = 16'd57;
                6'd13: exp_lut_value = 16'd50;
                6'd14: exp_lut_value = 16'd44;
                6'd15: exp_lut_value = 16'd39;
                6'd16: exp_lut_value = 16'd35;
                6'd17: exp_lut_value = 16'd31;
                6'd18: exp_lut_value = 16'd27;
                6'd19: exp_lut_value = 16'd24;
                6'd20: exp_lut_value = 16'd21;
                6'd21: exp_lut_value = 16'd19;
                6'd22: exp_lut_value = 16'd16;
                6'd23: exp_lut_value = 16'd14;
                6'd24: exp_lut_value = 16'd13;
                6'd25: exp_lut_value = 16'd11;
                6'd26: exp_lut_value = 16'd10;
                6'd27: exp_lut_value = 16'd9;
                6'd28: exp_lut_value = 16'd8;
                6'd29: exp_lut_value = 16'd7;
                6'd30: exp_lut_value = 16'd6;
                6'd31: exp_lut_value = 16'd5;
                6'd32: exp_lut_value = 16'd5;
                6'd33: exp_lut_value = 16'd4;
                6'd34: exp_lut_value = 16'd4;
                6'd35: exp_lut_value = 16'd3;
                6'd36: exp_lut_value = 16'd3;
                6'd37: exp_lut_value = 16'd3;
                6'd38: exp_lut_value = 16'd2;
                6'd39: exp_lut_value = 16'd2;
                6'd40: exp_lut_value = 16'd2;
                6'd41: exp_lut_value = 16'd2;
                6'd42: exp_lut_value = 16'd1;
                6'd43: exp_lut_value = 16'd1;
                6'd44: exp_lut_value = 16'd1;
                6'd45: exp_lut_value = 16'd1;
                6'd46: exp_lut_value = 16'd1;
                6'd47: exp_lut_value = 16'd1;
                6'd48: exp_lut_value = 16'd1;
                6'd49: exp_lut_value = 16'd1;
                default: exp_lut_value = '0;
            endcase
        end
    endfunction

    function automatic logic [WEIGHT_W-1:0] exp_approx_weight(
        input logic signed [SCORE_W-1:0] delta
    );
        logic [SCORE_W-1:0] abs_delta;
        logic [SCORE_W-1:0] lut_index;
        begin
            if (delta[SCORE_W-1] == 1'b0) begin
                exp_approx_weight = WEIGHT_ONE;
            end else begin
                abs_delta = -delta;
                lut_index = (abs_delta + EXP_LUT_ROUND) >> EXP_LUT_SHIFT;

                if (lut_index >= EXP_LUT_SIZE) begin
                    exp_approx_weight = '0;
                end else begin
                    exp_approx_weight = exp_lut_value(lut_index[EXP_LUT_ADDR_W-1:0]);
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
