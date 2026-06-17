`timescale 1ns/1ps
//============================================================================
// softmax_combine - v2 combine engine (FlashAttention-2 tile processing)
//----------------------------------------------------------------------------
// Processes ONE (query-row, K/V-tile) given the tile's pre-computed scores and
// V vectors, plus the row's running (m,l,acc) state, and returns updated state.
// flash_core keeps BQ rows' state (for K/V tile reuse) and the dot front-end
// (dot_stream) produces the scores -- this module is the recurrence back-end.
//
// The whole point of v2 lives here: the per-key MAC loop
//     acc_inner[d] += w_j * V_j[d]        (w_j = exp(s_j - m_tile))
// has only an ADDER in the loop-carried path (the multiply is feed-forward),
// so it sustains II=1 and is 5ns-friendly. The single multiply-rescale
//     acc = acc*corr_old + acc_inner*corr_new
// happens once per tile (stage C), off the inner path.
//
// Fixed-point contract (matches the baseline so normalizer is reused as-is):
//   score_in : signed ACC_W, SCORE_FRAC fractional bits
//   weights  : Q(WEIGHT_FRAC)  (== exp LUT, identical to online_softmax_engine)
//   acc      : weight*V terms, frac = WEIGHT_FRAC+FRAC_V (kept in ACC_W)
//   l        : sum of weights, frac = WEIGHT_FRAC (kept in L_W)
//============================================================================
module softmax_combine #(
    parameter int D_MODEL     = 64,
    parameter int BK          = 16,
    parameter int DATA_W      = 16,
    parameter int ACC_W       = 36,
    parameter int WEIGHT_W    = 17,
    parameter int WEIGHT_FRAC = 16,
    parameter int SCORE_FRAC  = 16,
    parameter int L_W         = 36
) (
    input  logic clk,
    input  logic rst_n,

    input  logic start,                                  // pulse: process this (row,tile)
    input  logic row_first,                              // 1 => first tile of the row (init from this tile)
    input  logic [$clog2(BK+1)-1:0] tile_len,            // valid keys in tile (<= BK)
    input  logic signed [ACC_W-1:0]  score_in [0:BK-1],  // FULL score array, used ONLY by max_comb reduction (static, no dynamic index)

    // ---- streamed per-key operands (replaces dynamic v_tile[j_q]/score_in[j_q]) ----
    // We announce the next key index one cycle ahead via vreq_*; flash_core
    // registers v_tile[vreq_idx]/score[vreq_idx] and feeds them back as v_row_in/
    // score_cur_in. This moves the 16:1 dynamic mux OUT of this module and behind a
    // register before it crosses the boundary -- same trick dot_stream uses for k_tile --
    // so Genus advanced-structuring (CDN_PAS_SKIP_MUX) no longer straddles the
    // flash_core/u_combine hierarchy and TUI-234 cannot recur. Behaviour is bit-exact
    // (the registered value arriving at MAC cycle k equals the old v_tile[k]/score_in[k]).
    output logic                     vreq_valid,         // high when vreq_idx is the key we'll MAC next cycle
    output logic [$clog2(BK+1)-1:0]  vreq_idx,           // index of that key (<= tile_len-1 <= BK-1)
    input  logic signed [DATA_W-1:0] v_row_in [0:D_MODEL-1], // registered v_tile[<prev vreq_idx>]
    input  logic signed [ACC_W-1:0]  score_cur_in,       // registered score_in[<prev vreq_idx>]

    input  logic signed [ACC_W-1:0] m_in,
    input  logic [L_W-1:0]          l_in,
    input  logic signed [ACC_W-1:0] acc_in [0:D_MODEL-1],

    output logic busy,
    output logic done,
    output logic signed [ACC_W-1:0] m_out,
    output logic [L_W-1:0]          l_out,
    // Flattened acc output (one ACC_W slice per d). Unpacked-array output ports
    // do not propagate reliably under iverilog, so we expose a packed bus.
    output logic [D_MODEL*ACC_W-1:0] acc_out_flat
);
    localparam int LEN_W = $clog2(BK + 1);
    localparam logic [WEIGHT_W-1:0] WEIGHT_ONE = (1 << WEIGHT_FRAC);

    // ---- exp LUT (identical to online_softmax_engine.sv) -------------------
    localparam int EXP_LUT_ADDR_W    = 6;
    localparam int EXP_LUT_FRAC_BITS = 3;
    localparam int EXP_LUT_SHIFT     = SCORE_FRAC - EXP_LUT_FRAC_BITS;
    localparam int EXP_LUT_SIZE      = 1 << EXP_LUT_ADDR_W;
    localparam logic [ACC_W-1:0] EXP_LUT_MAX_DELTA = (EXP_LUT_SIZE - 1) << EXP_LUT_SHIFT;
    localparam int Q16_TO_WEIGHT_SHIFT = (WEIGHT_FRAC < 16) ? (16 - WEIGHT_FRAC) : 0;
    localparam logic [31:0] Q16_TO_WEIGHT_ROUND =
        (Q16_TO_WEIGHT_SHIFT > 0) ? (1 << (Q16_TO_WEIGHT_SHIFT - 1)) : 0;

    function automatic logic [17:0] exp_lut_q16_value(input logic [EXP_LUT_ADDR_W-1:0] index);
        begin
            case (index)
                6'd0:  exp_lut_q16_value = 18'd65536; 6'd1:  exp_lut_q16_value = 18'd57835;
                6'd2:  exp_lut_q16_value = 18'd51039; 6'd3:  exp_lut_q16_value = 18'd45042;
                6'd4:  exp_lut_q16_value = 18'd39750; 6'd5:  exp_lut_q16_value = 18'd35079;
                6'd6:  exp_lut_q16_value = 18'd30957; 6'd7:  exp_lut_q16_value = 18'd27319;
                6'd8:  exp_lut_q16_value = 18'd24109; 6'd9:  exp_lut_q16_value = 18'd21276;
                6'd10: exp_lut_q16_value = 18'd18776; 6'd11: exp_lut_q16_value = 18'd16570;
                6'd12: exp_lut_q16_value = 18'd14623; 6'd13: exp_lut_q16_value = 18'd12905;
                6'd14: exp_lut_q16_value = 18'd11388; 6'd15: exp_lut_q16_value = 18'd10050;
                6'd16: exp_lut_q16_value = 18'd8869;  6'd17: exp_lut_q16_value = 18'd7827;
                6'd18: exp_lut_q16_value = 18'd6907;  6'd19: exp_lut_q16_value = 18'd6096;
                6'd20: exp_lut_q16_value = 18'd5380;  6'd21: exp_lut_q16_value = 18'd4747;
                6'd22: exp_lut_q16_value = 18'd4190;  6'd23: exp_lut_q16_value = 18'd3697;
                6'd24: exp_lut_q16_value = 18'd3263;  6'd25: exp_lut_q16_value = 18'd2879;
                6'd26: exp_lut_q16_value = 18'd2541;  6'd27: exp_lut_q16_value = 18'd2243;
                6'd28: exp_lut_q16_value = 18'd1979;  6'd29: exp_lut_q16_value = 18'd1746;
                6'd30: exp_lut_q16_value = 18'd1541;  6'd31: exp_lut_q16_value = 18'd1360;
                6'd32: exp_lut_q16_value = 18'd1200;  6'd33: exp_lut_q16_value = 18'd1059;
                6'd34: exp_lut_q16_value = 18'd935;   6'd35: exp_lut_q16_value = 18'd825;
                6'd36: exp_lut_q16_value = 18'd728;   6'd37: exp_lut_q16_value = 18'd642;
                6'd38: exp_lut_q16_value = 18'd567;   6'd39: exp_lut_q16_value = 18'd500;
                6'd40: exp_lut_q16_value = 18'd442;   6'd41: exp_lut_q16_value = 18'd390;
                6'd42: exp_lut_q16_value = 18'd344;   6'd43: exp_lut_q16_value = 18'd303;
                6'd44: exp_lut_q16_value = 18'd268;   6'd45: exp_lut_q16_value = 18'd236;
                6'd46: exp_lut_q16_value = 18'd209;   6'd47: exp_lut_q16_value = 18'd184;
                6'd48: exp_lut_q16_value = 18'd162;   6'd49: exp_lut_q16_value = 18'd143;
                6'd50: exp_lut_q16_value = 18'd127;   6'd51: exp_lut_q16_value = 18'd112;
                6'd52: exp_lut_q16_value = 18'd99;    6'd53: exp_lut_q16_value = 18'd87;
                6'd54: exp_lut_q16_value = 18'd77;    6'd55: exp_lut_q16_value = 18'd68;
                6'd56: exp_lut_q16_value = 18'd60;    6'd57: exp_lut_q16_value = 18'd53;
                6'd58: exp_lut_q16_value = 18'd47;    6'd59: exp_lut_q16_value = 18'd41;
                6'd60: exp_lut_q16_value = 18'd36;    6'd61: exp_lut_q16_value = 18'd32;
                6'd62: exp_lut_q16_value = 18'd28;    6'd63: exp_lut_q16_value = 18'd25;
                default: exp_lut_q16_value = '0;
            endcase
        end
    endfunction

    function automatic logic [WEIGHT_W-1:0] scale_q16_weight(input logic [17:0] q16_value);
        logic [31:0] rounded;
        begin
            if (WEIGHT_FRAC == 16)      scale_q16_weight = q16_value[WEIGHT_W-1:0];
            else if (WEIGHT_FRAC < 16) begin
                rounded = q16_value + Q16_TO_WEIGHT_ROUND;
                scale_q16_weight = rounded >> Q16_TO_WEIGHT_SHIFT;
            end else scale_q16_weight = q16_value << (WEIGHT_FRAC - 16);
        end
    endfunction

    function automatic logic [WEIGHT_W-1:0] exp_lut_value(input logic [EXP_LUT_ADDR_W-1:0] index);
        exp_lut_value = scale_q16_weight(exp_lut_q16_value(index));
    endfunction

    // exp(delta) for delta<=0 (>0 returns 1.0); same interpolation as RTL baseline.
    function automatic logic [WEIGHT_W-1:0] exp_w(input logic signed [ACC_W-1:0] delta);
        logic [ACC_W-1:0] abs_delta, lut_index, lut_rem;
        logic [WEIGHT_W-1:0] y0, y1;
        logic signed [WEIGHT_W:0] y_diff;
        logic signed [ACC_W+WEIGHT_W:0] interp_delta, interp_value;
        begin
            if (delta[ACC_W-1] == 1'b0) exp_w = WEIGHT_ONE;
            else begin
                abs_delta = -delta;
                if (abs_delta > EXP_LUT_MAX_DELTA) exp_w = '0;
                else begin
                    lut_index = abs_delta >> EXP_LUT_SHIFT;
                    lut_rem   = abs_delta - (lut_index << EXP_LUT_SHIFT);
                    if (lut_index == (EXP_LUT_SIZE - 1))
                        exp_w = exp_lut_value(lut_index[EXP_LUT_ADDR_W-1:0]);
                    else begin
                        y0 = exp_lut_value(lut_index[EXP_LUT_ADDR_W-1:0]);
                        y1 = exp_lut_value(lut_index[EXP_LUT_ADDR_W-1:0] + 1'b1);
                        y_diff = $signed({1'b0, y1}) - $signed({1'b0, y0});
                        interp_delta = (y_diff * $signed({1'b0, lut_rem}) +
                                        $signed(1 << (EXP_LUT_SHIFT - 1))) >>> EXP_LUT_SHIFT;
                        interp_value = $signed({1'b0, y0}) + interp_delta;
                        exp_w = interp_value[WEIGHT_W-1:0];
                    end
                end
            end
        end
    endfunction

    // scale a wide accumulator term by a Q(WEIGHT_FRAC) weight: (val*w)>>WEIGHT_FRAC
    function automatic logic signed [ACC_W-1:0] scale_acc(
        input logic signed [ACC_W-1:0] val, input logic [WEIGHT_W-1:0] w);
        logic signed [ACC_W+WEIGHT_W:0] prod;
        begin
            prod = val * $signed({1'b0, w});
            scale_acc = (prod >>> WEIGHT_FRAC);
        end
    endfunction
    function automatic logic [L_W-1:0] scale_l(
        input logic [L_W-1:0] val, input logic [WEIGHT_W-1:0] w);
        logic [L_W+WEIGHT_W:0] prod;
        begin
            prod = val * w;
            scale_l = (prod >> WEIGHT_FRAC);
        end
    endfunction

    // S_MOLD/S_MNEW = the two merge phases that TIME-SHARE the 64-wide multiplier
    // array with S_MAC (resource sharing: 64 mults total instead of 64 MAC + 128 merge).
    typedef enum logic [2:0] { S_IDLE, S_MAC, S_FIRST, S_MOLD, S_MNEW } state_t;
    state_t state_q;

    logic [LEN_W-1:0]        len_q;
    logic                    first_q;
    logic [LEN_W-1:0]        j_q;
    logic signed [ACC_W-1:0] m_tile_q;
    logic [L_W-1:0]          l_part_q;
    logic signed [ACC_W-1:0] acc_inner_q [0:D_MODEL-1];

    logic signed [ACC_W-1:0] m_state_q;
    logic [L_W-1:0]          l_state_q;
    logic signed [ACC_W-1:0] acc_state_q [0:D_MODEL-1];

    // combinational tile-max over valid scores
    logic signed [ACC_W-1:0] max_comb;
    int mi;
    always_comb begin
        max_comb = score_in[0];
        for (mi = 1; mi < BK; mi = mi + 1)
            if ((mi < tile_len) && (score_in[mi] > max_comb)) max_comb = score_in[mi];
    end

    // current-key weight (stage B), combinational.
    // score_cur_in is the registered score_in[j_q] streamed in from flash_core.
    logic [WEIGHT_W-1:0]     w_cur;
    assign w_cur = exp_w(score_cur_in - m_tile_q);

    // ---- next-key request (1 cycle ahead) ----------------------------------
    // At S_IDLE&start we pre-request key 0 (consumed at the first S_MAC cycle).
    // During S_MAC we request j_q+1 while MAC-ing j_q, so the registered value is
    // ready the next cycle. We stop requesting on the last key (j_q==len-1), which
    // also guarantees vreq_idx <= len_q-1 <= BK-1 (never out of v_tile[0:BK-1]).
    assign vreq_valid = (state_q == S_IDLE && start) ||
                        (state_q == S_MAC  && (j_q != len_q - 1'b1));
    assign vreq_idx   = (state_q == S_MAC  && (j_q != len_q - 1'b1)) ? (j_q + 1'b1) : '0;

    // merge correction factors (stage C), combinational
    logic signed [ACC_W-1:0] m_new_comb;
    logic [WEIGHT_W-1:0]     corr_old, corr_new;
    assign m_new_comb = (m_state_q > m_tile_q) ? m_state_q : m_tile_q;
    assign corr_old   = exp_w(m_state_q - m_new_comb);
    assign corr_new   = exp_w(m_tile_q  - m_new_comb);

    // ---- shared 64-wide multiplier array (operands muxed by state) ----
    localparam int MULW = ACC_W + WEIGHT_W + 2;
    logic signed [ACC_W-1:0]  mulA [0:D_MODEL-1];
    logic [WEIGHT_W-1:0]      mulB;
    logic signed [MULW-1:0]   mulP [0:D_MODEL-1];
    int mk;
    always_comb begin
        // default S_MAC: v_j * w_cur  (v_row_in = registered v_tile[j_q] streamed from flash_core)
        mulB = w_cur;
        for (mk = 0; mk < D_MODEL; mk = mk + 1) mulA[mk] = $signed(v_row_in[mk]);
        if (state_q == S_MOLD) begin            // acc_state(old) * corr_old
            mulB = corr_old;
            for (mk = 0; mk < D_MODEL; mk = mk + 1) mulA[mk] = acc_state_q[mk];
        end else if (state_q == S_MNEW) begin   // acc_inner * corr_new
            mulB = corr_new;
            for (mk = 0; mk < D_MODEL; mk = mk + 1) mulA[mk] = acc_inner_q[mk];
        end
        for (mk = 0; mk < D_MODEL; mk = mk + 1)
            mulP[mk] = mulA[mk] * $signed({1'b0, mulB});
    end

    assign busy  = (state_q != S_IDLE);
    assign m_out = m_state_q;
    assign l_out = l_state_q;
    int oc;
    always_comb begin
        for (oc = 0; oc < D_MODEL; oc = oc + 1)
            acc_out_flat[oc*ACC_W +: ACC_W] = acc_state_q[oc];
    end

    integer d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q  <= S_IDLE;
            done     <= 1'b0;
            len_q    <= '0; first_q <= 1'b0; j_q <= '0;
            m_tile_q <= '0; l_part_q <= '0;
            m_state_q <= '0; l_state_q <= '0;
            for (d = 0; d < D_MODEL; d = d + 1) begin
                acc_inner_q[d] <= '0; acc_state_q[d] <= '0;
            end
        end else begin
            done <= 1'b0;
            case (state_q)
                S_IDLE: if (start) begin
                    len_q <= tile_len; first_q <= row_first; m_tile_q <= max_comb;
                    j_q <= '0; l_part_q <= '0;
                    for (d = 0; d < D_MODEL; d = d + 1) acc_inner_q[d] <= '0;
                    m_state_q <= m_in; l_state_q <= l_in;
                    for (d = 0; d < D_MODEL; d = d + 1) acc_state_q[d] <= acc_in[d];
                    state_q <= S_MAC;
                end

                S_MAC: begin
                    // acc_inner += w_j*V_j   (mulP = v*w_cur); loop-carried path = adder
                    l_part_q <= l_part_q + w_cur;
                    for (d = 0; d < D_MODEL; d = d + 1)
                        acc_inner_q[d] <= acc_inner_q[d] + mulP[d][ACC_W-1:0];
                    if (j_q == len_q - 1) state_q <= (first_q ? S_FIRST : S_MOLD);
                    else                  j_q <= j_q + 1'b1;
                end

                S_FIRST: begin                    // first tile of the row: state := tile partials
                    m_state_q <= m_tile_q;
                    l_state_q <= l_part_q;
                    for (d = 0; d < D_MODEL; d = d + 1) acc_state_q[d] <= acc_inner_q[d];
                    done <= 1'b1; state_q <= S_IDLE;
                end

                S_MOLD: begin                     // phase 1: scale OLD running state by corr_old
                    l_state_q <= scale_l(l_state_q, corr_old);
                    for (d = 0; d < D_MODEL; d = d + 1)
                        acc_state_q[d] <= mulP[d] >>> WEIGHT_FRAC;     // acc_state_old * corr_old
                    state_q <= S_MNEW;
                end

                S_MNEW: begin                     // phase 2: add this tile's partials * corr_new
                    m_state_q <= m_new_comb;
                    l_state_q <= l_state_q + scale_l(l_part_q, corr_new);
                    for (d = 0; d < D_MODEL; d = d + 1)
                        acc_state_q[d] <= acc_state_q[d] + (mulP[d] >>> WEIGHT_FRAC); // + acc_inner*corr_new
                    done <= 1'b1; state_q <= S_IDLE;
                end
                default: state_q <= S_IDLE;
            endcase
        end
    end
endmodule
