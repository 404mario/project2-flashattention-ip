`timescale 1ns/1ps

module normalizer #(
    parameter int ACC_W      = 40,
    parameter int L_W        = 40,
    parameter int DATA_W     = 16,
    parameter int RECIP_FRAC = 20
) (
    input  logic clk,
    input  logic rst_n,

    input  logic in_valid,
    input  logic signed [ACC_W-1:0] acc,
    input  logic [L_W-1:0] denom,

    output logic out_valid,
    output logic signed [DATA_W-1:0] out
);
    localparam int LUT_BITS = 6;
    localparam int NORM_W   = LUT_BITS + 1;
    localparam int RECIP_W  = RECIP_FRAC + 1;
    localparam int PROD_W   = ACC_W + RECIP_W;
    localparam int SHIFT_W  = (PROD_W <= 1) ? 1 : $clog2(PROD_W + 1);

    logic s1_valid_q;
    logic s1_negative_q;
    logic s1_zero_q;
    logic [ACC_W-1:0] abs_acc_comb;
    logic [ACC_W-1:0] s1_abs_acc_q;
    logic [RECIP_W-1:0] recip_comb;
    logic [LUT_BITS-1:0] lut_index_comb;
    logic [RECIP_W-1:0] s1_recip_q;
    logic [SHIFT_W-1:0] shift_comb;
    logic [SHIFT_W-1:0] s1_shift_q;

    logic s2_valid_q;
    logic s2_negative_q;
    logic s2_zero_q;
    logic [PROD_W-1:0] s2_product_q;
    logic [SHIFT_W-1:0] s2_shift_q;

    logic [PROD_W-1:0] product_comb;
    logic [PROD_W:0] quotient_abs_comb;
    logic signed [PROD_W:0] quotient_signed_comb;
    logic signed [DATA_W-1:0] saturated_comb;

    function automatic logic [RECIP_W-1:0] recip_lut_value(
        input logic [LUT_BITS-1:0] index
    );
        begin
            case (index)
            6'd0: recip_lut_value = 21'd16384;
            6'd1: recip_lut_value = 21'd16132;
            6'd2: recip_lut_value = 21'd15888;
            6'd3: recip_lut_value = 21'd15650;
            6'd4: recip_lut_value = 21'd15420;
            6'd5: recip_lut_value = 21'd15197;
            6'd6: recip_lut_value = 21'd14980;
            6'd7: recip_lut_value = 21'd14769;
            6'd8: recip_lut_value = 21'd14564;
            6'd9: recip_lut_value = 21'd14364;
            6'd10: recip_lut_value = 21'd14170;
            6'd11: recip_lut_value = 21'd13981;
            6'd12: recip_lut_value = 21'd13797;
            6'd13: recip_lut_value = 21'd13618;
            6'd14: recip_lut_value = 21'd13443;
            6'd15: recip_lut_value = 21'd13273;
            6'd16: recip_lut_value = 21'd13107;
            6'd17: recip_lut_value = 21'd12945;
            6'd18: recip_lut_value = 21'd12788;
            6'd19: recip_lut_value = 21'd12633;
            6'd20: recip_lut_value = 21'd12483;
            6'd21: recip_lut_value = 21'd12336;
            6'd22: recip_lut_value = 21'd12193;
            6'd23: recip_lut_value = 21'd12053;
            6'd24: recip_lut_value = 21'd11916;
            6'd25: recip_lut_value = 21'd11782;
            6'd26: recip_lut_value = 21'd11651;
            6'd27: recip_lut_value = 21'd11523;
            6'd28: recip_lut_value = 21'd11398;
            6'd29: recip_lut_value = 21'd11275;
            6'd30: recip_lut_value = 21'd11155;
            6'd31: recip_lut_value = 21'd11038;
            6'd32: recip_lut_value = 21'd10923;
            6'd33: recip_lut_value = 21'd10810;
            6'd34: recip_lut_value = 21'd10700;
            6'd35: recip_lut_value = 21'd10592;
            6'd36: recip_lut_value = 21'd10486;
            6'd37: recip_lut_value = 21'd10382;
            6'd38: recip_lut_value = 21'd10280;
            6'd39: recip_lut_value = 21'd10180;
            6'd40: recip_lut_value = 21'd10082;
            6'd41: recip_lut_value = 21'd9986;
            6'd42: recip_lut_value = 21'd9892;
            6'd43: recip_lut_value = 21'd9800;
            6'd44: recip_lut_value = 21'd9709;
            6'd45: recip_lut_value = 21'd9620;
            6'd46: recip_lut_value = 21'd9533;
            6'd47: recip_lut_value = 21'd9447;
            6'd48: recip_lut_value = 21'd9362;
            6'd49: recip_lut_value = 21'd9279;
            6'd50: recip_lut_value = 21'd9198;
            6'd51: recip_lut_value = 21'd9118;
            6'd52: recip_lut_value = 21'd9039;
            6'd53: recip_lut_value = 21'd8962;
            6'd54: recip_lut_value = 21'd8886;
            6'd55: recip_lut_value = 21'd8812;
            6'd56: recip_lut_value = 21'd8738;
            6'd57: recip_lut_value = 21'd8666;
            6'd58: recip_lut_value = 21'd8595;
            6'd59: recip_lut_value = 21'd8525;
            6'd60: recip_lut_value = 21'd8456;
            6'd61: recip_lut_value = 21'd8389;
            6'd62: recip_lut_value = 21'd8322;
            6'd63: recip_lut_value = 21'd8257;
            default: recip_lut_value = '0;
            endcase
        end
    endfunction

    function automatic logic [SHIFT_W-1:0] leading_pos(input logic [L_W-1:0] value);
        integer i;
        begin
            leading_pos = '0;
            for (i = 0; i < L_W; i = i + 1) begin
                if (value[i]) begin
                    leading_pos = i[SHIFT_W-1:0];
                end
            end
        end
    endfunction

    function automatic logic [NORM_W-1:0] normalize_denom(
        input logic [L_W-1:0] value,
        input logic [SHIFT_W-1:0] lead
    );
        logic [L_W+LUT_BITS:0] shifted;
        begin
            if (lead >= LUT_BITS[SHIFT_W-1:0]) begin
                shifted = value >> (lead - LUT_BITS[SHIFT_W-1:0]);
            end else begin
                shifted = value << (LUT_BITS[SHIFT_W-1:0] - lead);
            end
            normalize_denom = shifted[NORM_W-1:0];
        end
    endfunction

    function automatic logic [PROD_W:0] rounded_shift_abs(
        input logic [PROD_W-1:0] value,
        input logic [SHIFT_W-1:0] shift,
        input logic zero
    );
        logic [PROD_W:0] rounded;
        logic [PROD_W:0] round_inc;
        begin
            if (zero || (shift >= PROD_W[SHIFT_W-1:0])) begin
                rounded_shift_abs = '0;
            end else if (shift == '0) begin
                rounded_shift_abs = {1'b0, value};
            end else begin
                round_inc = {{PROD_W{1'b0}}, 1'b1} << (shift - 1'b1);
                rounded = {1'b0, value} + round_inc;
                rounded_shift_abs = rounded >> shift;
            end
        end
    endfunction

    function automatic logic signed [DATA_W-1:0] saturate_to_data(
        input logic signed [PROD_W:0] value
    );
        localparam logic signed [PROD_W:0] MAX_VALUE =
            {{(PROD_W+1-DATA_W){1'b0}}, 1'b0, {DATA_W-1{1'b1}}};
        localparam logic signed [PROD_W:0] MIN_VALUE =
            -({{(PROD_W+1-DATA_W){1'b0}}, 1'b1, {DATA_W-1{1'b0}}});
        begin
            if (value > MAX_VALUE) begin
                saturate_to_data = {1'b0, {DATA_W-1{1'b1}}};
            end else if (value < MIN_VALUE) begin
                saturate_to_data = {1'b1, {DATA_W-1{1'b0}}};
            end else begin
                saturate_to_data = value[DATA_W-1:0];
            end
        end
    endfunction

    always @* begin
        logic [SHIFT_W-1:0] lead;
        logic [NORM_W-1:0] norm_value;

        if (acc[ACC_W-1]) begin
            abs_acc_comb = -acc;
        end else begin
            abs_acc_comb = acc;
        end

        lead = leading_pos(denom);
        norm_value = normalize_denom(denom, lead);
        lut_index_comb = norm_value;
        recip_comb = recip_lut_value(lut_index_comb);
        if (lead >= LUT_BITS[SHIFT_W-1:0]) begin
            shift_comb = RECIP_FRAC[SHIFT_W-1:0] + lead - LUT_BITS[SHIFT_W-1:0];
        end else begin
            shift_comb = RECIP_FRAC[SHIFT_W-1:0] - (LUT_BITS[SHIFT_W-1:0] - lead);
        end

        product_comb = s1_abs_acc_q * s1_recip_q;
        quotient_abs_comb = rounded_shift_abs(s2_product_q, s2_shift_q, s2_zero_q);
        if (s2_negative_q) begin
            quotient_signed_comb = -$signed(quotient_abs_comb);
        end else begin
            quotient_signed_comb = $signed(quotient_abs_comb);
        end
        saturated_comb = saturate_to_data(quotient_signed_comb);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid_q    <= 1'b0;
            s1_negative_q <= 1'b0;
            s1_zero_q     <= 1'b1;
            s1_abs_acc_q  <= '0;
            s1_recip_q    <= '0;
            s1_shift_q    <= '0;
            s2_valid_q    <= 1'b0;
            s2_negative_q <= 1'b0;
            s2_zero_q     <= 1'b1;
            s2_product_q  <= '0;
            s2_shift_q    <= '0;
            out_valid     <= 1'b0;
            out           <= '0;
        end else begin
            s1_valid_q    <= in_valid;
            s1_negative_q <= acc[ACC_W-1];
            s1_zero_q     <= (denom == '0);
            s1_abs_acc_q  <= abs_acc_comb;
            s1_recip_q    <= recip_comb;
            s1_shift_q    <= shift_comb;

            s2_valid_q    <= s1_valid_q;
            s2_negative_q <= s1_negative_q;
            s2_zero_q     <= s1_zero_q;
            s2_product_q  <= product_comb;
            s2_shift_q    <= s1_shift_q;

            out_valid <= s2_valid_q;
            out       <= saturated_comb;
        end
    end
endmodule
