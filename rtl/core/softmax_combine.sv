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

    // ---- exp_w SPLIT for the 4-stage pipeline -------------------------------
    // exp_prep is the E1 part (everything before the interpolation multiply):
    // it is realized inline in the E1 always_comb below (sign test, abs,
    // EXP_LUT_MAX_DELTA clamp, LUT index, two LUT reads). exp_finish is the E2
    // part: the interpolation multiply + assembly. By construction
    //     exp_finish( <exp_prep(delta)> ) === exp_w(delta)   for every delta
    // bit-for-bit (it IS the else-branch body of exp_w, verbatim). is_one /
    // is_zero / edge_lut select the three non-interpolating exp_w outcomes.
    function automatic logic [WEIGHT_W-1:0] exp_finish(
        input logic                  is_one,
        input logic                  is_zero,
        input logic                  edge_lut,
        input logic [WEIGHT_W-1:0]   y0,
        input logic [WEIGHT_W-1:0]   y1,
        input logic [ACC_W-1:0]      lut_rem);
        logic signed [WEIGHT_W:0] y_diff;
        logic signed [ACC_W+WEIGHT_W:0] interp_delta, interp_value;
        begin
            if (is_one)        exp_finish = WEIGHT_ONE;
            else if (is_zero)  exp_finish = '0;
            else if (edge_lut) exp_finish = y0;            // lut_index == SIZE-1: no interp
            else begin
                y_diff = $signed({1'b0, y1}) - $signed({1'b0, y0});
                interp_delta = (y_diff * $signed({1'b0, lut_rem}) +
                                $signed(1 << (EXP_LUT_SHIFT - 1))) >>> EXP_LUT_SHIFT;
                interp_value = $signed({1'b0, y0}) + interp_delta;
                exp_finish = interp_value[WEIGHT_W-1:0];
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

    // ========================================================================
    // PIPELINED datapath (5ns timing fix). The original did exp -> 64-wide
    // multiply -> accumulate ALL in one cycle (~9.8ns critical path). The first
    // pipeline (E|X|A) cut that to a 5.58ns path whose whole length was the exp
    // stage itself (subtract -> 64-entry LUT decode -> interpolation multiply),
    // still 0.6ns over a 5ns clock (worst case = the merge corr_old/corr_new,
    // which also has the m_new=max(m_state,m_tile) reduction in front of exp).
    // So we split the exp stage into TWO -> a 4-stage pipeline shared by the MAC
    // inner loop and the two cross-tile merge ops:
    //     E1 : pick delta, m_new=max, abs, LUT index, read y0/y1  ->  p1
    //     E2 : interpolation multiply (y_diff*rem) -> weight        ->  s1
    //     X  : 64-wide multiply (mulA*weight)                       ->  s2
    //     A  : accumulate / add                                     ->  acc regs
    // II=1 is preserved (only the A-stage adder is loop-carried). All arithmetic
    // is BIT-IDENTICAL to the single-cycle version: exp_w() is factored into
    // exp_prep (E1, the part before the interp multiply) + exp_finish (E2, the
    // interp multiply), and exp_finish(exp_prep(d)) === exp_w(d) bit-for-bit. We
    // only register between exp-prep, exp-finish, the multiply and the add, so
    // the per-tile result is unchanged; latency grows by one more drain cycle
    // (negligible vs the <300k cycle budget). The 64-wide multiplier is still
    // shared (time-multiplexed by the in-flight op's mode), so no extra mults.
    // ========================================================================
    localparam logic [1:0] MODE_MAC = 2'd0, MODE_OLD = 2'd1, MODE_NEW = 2'd2;
    localparam int MULW = ACC_W + WEIGHT_W + 2;

    // FSM: MAC issue (len cycles) -> 2 drain -> first-copy OR (issue OLD,NEW ->
    // 2 drain). Issue states drive the E stage; drains let the pipe empty so the
    // acc registers are final before they are read/copied.
    // Drain groups are 3 deep now (issue at E1 -> result at A is 3 cycles):
    //   MAC drain: S_DR1/S_DR2/S_DR3 ; merge drain: S_MDR1/S_MDR2/S_MDR3.
    typedef enum logic [3:0] {
        S_IDLE, S_MAC, S_DR1, S_DR2, S_DR3, S_FIRST, S_OLD, S_NEW, S_MDR1, S_MDR2, S_MDR3
    } state_t;
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

    // combinational tile-max over valid scores (UNCHANGED)
    logic signed [ACC_W-1:0] max_comb;
    int mi;
    always_comb begin
        max_comb = score_in[0];
        for (mi = 1; mi < BK; mi = mi + 1)
            if ((mi < tile_len) && (score_in[mi] > max_comb)) max_comb = score_in[mi];
    end

    // current-key weight delta is (score_cur_in - m_tile_q); the weight itself is
    // now produced across E1 (exp-prep) + E2 (exp-finish), see below. score_cur_in
    // is the registered score_in[j_q] streamed in from flash_core. (UNCHANGED math)

    // ---- next-key request (1 cycle ahead) -- UNCHANGED protocol -------------
    // The MAC issue cadence (one key issued per S_MAC cycle, j_q=0..len-1) is
    // identical to the old loop, so flash_core's prefetch of v_row_in/score_cur_in
    // stays perfectly aligned. Only the downstream multiply/accumulate is delayed.
    assign vreq_valid = (state_q == S_IDLE && start) ||
                        (state_q == S_MAC  && (j_q != len_q - 1'b1));
    assign vreq_idx   = (state_q == S_MAC  && (j_q != len_q - 1'b1)) ? (j_q + 1'b1) : '0;

    // merge running-max, combinational (UNCHANGED expression). m_state_q is stable
    // across the OLD/NEW issue+drain window (only written by the NEW A-stage at the
    // very end), so m_new_comb is stable. The correction factors corr_old/corr_new
    // are now produced via the E1 exp-prep + E2 exp-finish split (deltas
    // m_state_q-m_new_comb and m_tile_q-m_new_comb), bit-identical to exp_w(...).
    logic signed [ACC_W-1:0] m_new_comb;
    assign m_new_comb = (m_state_q > m_tile_q) ? m_state_q : m_tile_q;

    // ===================== E1 stage (operand select + exp prep) ==============
    // Selects the op being issued (MAC key / OLD / NEW), its multiplicand vector,
    // and computes the exp "prep" (delta -> abs -> LUT index -> y0/y1/rem). The
    // interpolation multiply that finishes the weight is deferred to E2, which is
    // what shortens the critical path below 5ns. Operand/mode/lval/mnew choices
    // are IDENTICAL to the old single E stage; only the weight is split E1/E2.
    logic                     e1_vld;
    logic [1:0]               e1_mode;
    logic signed [ACC_W-1:0]  e1_mulA [0:D_MODEL-1];
    logic [L_W-1:0]           e1_lval;
    logic signed [ACC_W-1:0]  e1_mnew;
    logic signed [ACC_W-1:0]  e1_delta;
    // exp-prep outputs (registered into p1, consumed by exp_finish in E2)
    logic                     e1_is_one, e1_is_zero, e1_edge;
    logic [WEIGHT_W-1:0]      e1_y0, e1_y1;
    logic [ACC_W-1:0]         e1_rem, e1_abs, e1_idx;
    int ek;
    always_comb begin
        // ---- operand + mode + delta select (same choices as the old E stage) ----
        e1_vld   = 1'b0;
        e1_mode  = MODE_MAC;
        e1_lval  = '0;
        e1_mnew  = m_new_comb;
        e1_delta = score_cur_in - m_tile_q;       // MAC default
        for (ek = 0; ek < D_MODEL; ek = ek + 1) e1_mulA[ek] = $signed(v_row_in[ek]);
        case (state_q)
            S_MAC: begin                          // issue MAC key j_q: w=exp(score-m_tile), mulA=v
                e1_vld = 1'b1; e1_mode = MODE_MAC;
                e1_delta = score_cur_in - m_tile_q;
            end
            S_OLD: begin                          // issue OLD: scale running state by corr_old
                e1_vld = 1'b1; e1_mode = MODE_OLD; e1_lval = l_state_q;
                e1_delta = m_state_q - m_new_comb;
                for (ek = 0; ek < D_MODEL; ek = ek + 1) e1_mulA[ek] = acc_state_q[ek];
            end
            S_NEW: begin                          // issue NEW: add this tile's partials * corr_new
                e1_vld = 1'b1; e1_mode = MODE_NEW; e1_lval = l_part_q; e1_mnew = m_new_comb;
                e1_delta = m_tile_q - m_new_comb;
                for (ek = 0; ek < D_MODEL; ek = ek + 1) e1_mulA[ek] = acc_inner_q[ek];
            end
            default: e1_vld = 1'b0;
        endcase

        // ---- exp prep: mirrors exp_w() up to (y0,y1,lut_rem), bit-for-bit -----
        e1_is_one = 1'b0; e1_is_zero = 1'b0; e1_edge = 1'b0;
        e1_y0 = '0; e1_y1 = '0; e1_rem = '0; e1_abs = '0; e1_idx = '0;
        if (e1_delta[ACC_W-1] == 1'b0) begin
            e1_is_one = 1'b1;                     // delta >= 0 -> exp = 1.0
        end else begin
            e1_abs = -e1_delta;
            if (e1_abs > EXP_LUT_MAX_DELTA) e1_is_zero = 1'b1;
            else begin
                e1_idx = e1_abs >> EXP_LUT_SHIFT;
                e1_rem = e1_abs - (e1_idx << EXP_LUT_SHIFT);
                if (e1_idx == (EXP_LUT_SIZE - 1)) begin
                    e1_edge = 1'b1;
                    e1_y0 = exp_lut_value(e1_idx[EXP_LUT_ADDR_W-1:0]);
                end else begin
                    e1_y0 = exp_lut_value(e1_idx[EXP_LUT_ADDR_W-1:0]);
                    e1_y1 = exp_lut_value(e1_idx[EXP_LUT_ADDR_W-1:0] + 1'b1);
                end
            end
        end
    end

    // p1 pipeline registers (E1 -> E2): carry the exp-prep + operands one cycle.
    logic                     p1_vld;
    logic [1:0]               p1_mode;
    logic signed [ACC_W-1:0]  p1_mulA [0:D_MODEL-1];
    logic [L_W-1:0]           p1_lval;
    logic signed [ACC_W-1:0]  p1_mnew;
    logic                     p1_is_one, p1_is_zero, p1_edge;
    logic [WEIGHT_W-1:0]      p1_y0, p1_y1;
    logic [ACC_W-1:0]         p1_rem;

    // E2 stage: finish the exp weight from p1's prep (the interpolation multiply).
    logic [WEIGHT_W-1:0]      e2_w;
    assign e2_w = exp_finish(p1_is_one, p1_is_zero, p1_edge, p1_y0, p1_y1, p1_rem);

    // s1 pipeline registers (E2 -> X)
    logic                     s1_vld;
    logic [1:0]               s1_mode;
    logic [WEIGHT_W-1:0]      s1_w;
    logic signed [ACC_W-1:0]  s1_mulA [0:D_MODEL-1];
    logic [L_W-1:0]           s1_lval;
    logic signed [ACC_W-1:0]  s1_mnew;

    // ===================== X stage (the 64-wide multiply) ====================
    // Same product as the old mulP[d] = mulA[d] * $signed({1'b0,mulB}); plus the
    // scalar l product = lval*w (== scale_l's internal val*w).
    logic signed [MULW-1:0]   x_prod [0:D_MODEL-1];
    logic [L_W+WEIGHT_W:0]    x_lprod;
    int xk;
    always_comb begin
        for (xk = 0; xk < D_MODEL; xk = xk + 1)
            x_prod[xk] = s1_mulA[xk] * $signed({1'b0, s1_w});
        x_lprod = s1_lval * s1_w;
    end

    // s2 pipeline registers (X -> A)
    logic                     s2_vld;
    logic [1:0]               s2_mode;
    logic [WEIGHT_W-1:0]      s2_w;
    logic signed [MULW-1:0]   s2_prod [0:D_MODEL-1];
    logic [L_W+WEIGHT_W:0]    s2_lprod;
    logic signed [ACC_W-1:0]  s2_mnew;

    // A-stage l rescale (matches scale_l: (val*w) >> WEIGHT_FRAC, truncated to L_W)
    logic [L_W-1:0] a_lscaled;
    assign a_lscaled = s2_lprod >> WEIGHT_FRAC;

    // outputs (UNCHANGED)
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
            p1_vld <= 1'b0; p1_mode <= MODE_MAC; p1_lval <= '0; p1_mnew <= '0;
            p1_is_one <= 1'b0; p1_is_zero <= 1'b0; p1_edge <= 1'b0;
            p1_y0 <= '0; p1_y1 <= '0; p1_rem <= '0;
            s1_vld <= 1'b0; s1_mode <= MODE_MAC; s1_w <= '0; s1_lval <= '0; s1_mnew <= '0;
            s2_vld <= 1'b0; s2_mode <= MODE_MAC; s2_w <= '0; s2_lprod <= '0; s2_mnew <= '0;
            for (d = 0; d < D_MODEL; d = d + 1) begin
                p1_mulA[d] <= '0; s1_mulA[d] <= '0; s2_prod[d] <= '0;
            end
        end else begin
            done <= 1'b0;

            // ---- pipeline shift: E1 -> p1 (carry exp-prep + operands) ----
            p1_vld     <= e1_vld;
            p1_mode    <= e1_mode;
            p1_lval    <= e1_lval;
            p1_mnew    <= e1_mnew;
            p1_is_one  <= e1_is_one;
            p1_is_zero <= e1_is_zero;
            p1_edge    <= e1_edge;
            p1_y0      <= e1_y0;
            p1_y1      <= e1_y1;
            p1_rem     <= e1_rem;
            for (d = 0; d < D_MODEL; d = d + 1) p1_mulA[d] <= e1_mulA[d];

            // ---- pipeline shift: E2 -> s1 (finish weight via exp_finish) ----
            s1_vld  <= p1_vld;
            s1_mode <= p1_mode;
            s1_w    <= e2_w;
            s1_lval <= p1_lval;
            s1_mnew <= p1_mnew;
            for (d = 0; d < D_MODEL; d = d + 1) s1_mulA[d] <= p1_mulA[d];

            // ---- pipeline shift: X -> s2 ----
            s2_vld   <= s1_vld;
            s2_mode  <= s1_mode;
            s2_w     <= s1_w;
            s2_lprod <= x_lprod;
            s2_mnew  <= s1_mnew;
            for (d = 0; d < D_MODEL; d = d + 1) s2_prod[d] <= x_prod[d];

            // ---- A stage: apply the op now in s2 to the accumulators ----
            // (bit-identical to the old S_MAC / S_MOLD / S_MNEW arithmetic)
            if (s2_vld) begin
                case (s2_mode)
                    MODE_MAC: begin               // acc_inner += v*w ; l_part += w
                        l_part_q <= l_part_q + s2_w;
                        for (d = 0; d < D_MODEL; d = d + 1)
                            acc_inner_q[d] <= acc_inner_q[d] + s2_prod[d][ACC_W-1:0];
                    end
                    MODE_OLD: begin               // acc_state = acc_state_old*corr_old ; l_state scaled
                        l_state_q <= a_lscaled;
                        for (d = 0; d < D_MODEL; d = d + 1)
                            acc_state_q[d] <= s2_prod[d] >>> WEIGHT_FRAC;
                    end
                    MODE_NEW: begin               // acc_state += acc_inner*corr_new ; l_state += ... ; m=m_new
                        m_state_q <= s2_mnew;
                        l_state_q <= l_state_q + a_lscaled;
                        for (d = 0; d < D_MODEL; d = d + 1)
                            acc_state_q[d] <= acc_state_q[d] + (s2_prod[d] >>> WEIGHT_FRAC);
                        done <= 1'b1;
                    end
                    default: ;
                endcase
            end

            // ---- FSM control (textually last: wins on the cycles it writes; the
            //      A-stage and these never write the same reg on the same cycle
            //      because the pipe is empty during S_IDLE/S_FIRST) ----
            case (state_q)
                S_IDLE: if (start) begin
                    len_q <= tile_len; first_q <= row_first; m_tile_q <= max_comb;
                    j_q <= '0; l_part_q <= '0;
                    for (d = 0; d < D_MODEL; d = d + 1) acc_inner_q[d] <= '0;
                    m_state_q <= m_in; l_state_q <= l_in;
                    for (d = 0; d < D_MODEL; d = d + 1) acc_state_q[d] <= acc_in[d];
                    state_q <= S_MAC;
                end

                S_MAC: begin                      // issue one key per cycle (E stage), j_q=0..len-1
                    if (j_q == len_q - 1) state_q <= S_DR1;
                    else                  j_q <= j_q + 1'b1;
                end

                S_DR1: state_q <= S_DR2;          // drain MAC pipe (3 cycles: E1->p1->s1->s2->A)
                S_DR2: state_q <= S_DR3;
                S_DR3: state_q <= (first_q ? S_FIRST : S_OLD);

                S_FIRST: begin                    // first tile of row: state := tile partials
                    m_state_q <= m_tile_q;
                    l_state_q <= l_part_q;
                    for (d = 0; d < D_MODEL; d = d + 1) acc_state_q[d] <= acc_inner_q[d];
                    done <= 1'b1; state_q <= S_IDLE;
                end

                S_OLD:  state_q <= S_NEW;         // issue OLD then NEW back-to-back (E1 stage)
                S_NEW:  state_q <= S_MDR1;
                S_MDR1: state_q <= S_MDR2;        // drain merge pipe (3 cycles);
                S_MDR2: state_q <= S_MDR3;        // OLD lands in A during S_MDR2,
                S_MDR3: state_q <= S_IDLE;        // NEW lands in A during S_MDR3 (done pulses)
                default: state_q <= S_IDLE;
            endcase
        end
    end
endmodule
