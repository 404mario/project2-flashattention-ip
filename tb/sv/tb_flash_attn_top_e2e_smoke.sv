`timescale 1ns/1ps

module tb_flash_attn_top_e2e_smoke;
    parameter int S_LEN          = 8;
    parameter int D_MODEL        = 8;
    parameter int BK             = 4;
    parameter int DATA_W         = 16;
    parameter int ACC_W          = 36;
    parameter int FRAC_W         = 8;
    parameter int AXI_DATA_W     = 64;
    parameter int SCALE_Q8_8     = 91;
    parameter int CHECK_BITEXACT = 1;
    parameter int TIMEOUT_CYCLES = 200000;
    parameter int BQ             = 16;
    parameter int USE_DOT_TREE    = 1;
    parameter int DOT_LANES       = 32;
    parameter int USE_CAUSAL_SKIP = 1;
    parameter int SOFTMAX_FRAC    = 16;
    parameter int FP8_E4M3_MODE   = 0;
    parameter int VALID_LEN       = S_LEN;
    parameter int TASK_COUNT      = 1;
    parameter int TASK_STRIDE_BYTES = S_LEN * D_MODEL * (DATA_W / 8);
    parameter int HEAD_COUNT      = 1;
    parameter int HEAD_STRIDE_BYTES = S_LEN * D_MODEL * (DATA_W / 8);
    parameter int DROPOUT_EN      = 0;
    parameter int DROPOUT_THRESHOLD = 0;
    parameter int DROPOUT_SEED    = 16'hace1;
    parameter int DROPOUT_SCALE_Q8_8 = 256;
    parameter int MAX_CYCLES      = 0;
    parameter int PROGRESS_EVERY  = 0;
    parameter int VERBOSE        = 0;

    localparam int ADDR_W         = 64;
    localparam int AXI_BYTES      = AXI_DATA_W / 8;
    localparam int DATA_BYTES     = DATA_W / 8;
    localparam int AXI_LANES      = AXI_BYTES / DATA_BYTES;
    localparam int STRIDE_BYTES   = D_MODEL * DATA_BYTES;
    localparam int NUM_ELEMS      = S_LEN * D_MODEL;
    localparam int TENSOR_BYTES   = S_LEN * STRIDE_BYTES;
    localparam int TASK_REGION_BYTES =
        ((TASK_COUNT - 1) * TASK_STRIDE_BYTES) +
        ((HEAD_COUNT - 1) * HEAD_STRIDE_BYTES) +
        TENSOR_BYTES;
    localparam int TOTAL_O_ELEMS  = NUM_ELEMS * TASK_COUNT * HEAD_COUNT;
    localparam int REGION_GAP     = 4096;
    localparam int unsigned Q_BASE = 32'h0000_0000;
    localparam int unsigned K_BASE = Q_BASE + TASK_REGION_BYTES + REGION_GAP;
    localparam int unsigned V_BASE = K_BASE + TASK_REGION_BYTES + REGION_GAP;
    localparam int unsigned O_BASE = V_BASE + TASK_REGION_BYTES + REGION_GAP;
    localparam logic [DATA_W-1:0] O_INIT_PATTERN = {DATA_W{1'b1}};
    localparam int WEIGHT_FRAC    = 8;
    localparam int WEIGHT_ONE     = 1 << WEIGHT_FRAC;
    localparam longint signed DATA_MAX = (64'sd1 <<< (DATA_W - 1)) - 1;
    localparam longint signed DATA_MIN = -(64'sd1 <<< (DATA_W - 1));

    localparam logic [31:0] REG_CTRL         = 32'h00;
    localparam logic [31:0] REG_STATUS       = 32'h04;
    localparam logic [31:0] REG_CFG          = 32'h08;
    localparam logic [31:0] REG_Q_BASE_L     = 32'h14;
    localparam logic [31:0] REG_Q_BASE_H     = 32'h18;
    localparam logic [31:0] REG_K_BASE_L     = 32'h1c;
    localparam logic [31:0] REG_K_BASE_H     = 32'h20;
    localparam logic [31:0] REG_V_BASE_L     = 32'h24;
    localparam logic [31:0] REG_V_BASE_H     = 32'h28;
    localparam logic [31:0] REG_O_BASE_L     = 32'h2c;
    localparam logic [31:0] REG_O_BASE_H     = 32'h30;
    localparam logic [31:0] REG_STRIDE_BYTES = 32'h34;
    localparam logic [31:0] REG_NEG_LARGE    = 32'h38;
    localparam logic [31:0] REG_SCALE        = 32'h3c;
    localparam logic [31:0] REG_CYCLES       = 32'h40;
    localparam logic [31:0] REG_RD_BYTES_L   = 32'h44;
    localparam logic [31:0] REG_RD_BYTES_H   = 32'h48;
    localparam logic [31:0] REG_WR_BYTES_L   = 32'h4c;
    localparam logic [31:0] REG_WR_BYTES_H   = 32'h50;
    localparam logic [31:0] REG_VALID_LEN    = 32'h54;
    localparam logic [31:0] REG_TASK_COUNT   = 32'h58;
    localparam logic [31:0] REG_TASK_STRIDE  = 32'h5c;
    localparam logic [31:0] REG_DROPOUT_CFG  = 32'h60;
    localparam logic [31:0] REG_DROPOUT_SEED = 32'h64;
    localparam logic [31:0] REG_DROPOUT_SCALE = 32'h68;
    localparam logic [31:0] REG_HEAD_COUNT    = 32'h6c;
    localparam logic [31:0] REG_HEAD_STRIDE   = 32'h70;

    localparam logic [31:0] CTRL_START       = 32'h0000_0001;
    localparam logic [31:0] STATUS_BUSY      = 32'h0000_0001;
    localparam logic [31:0] STATUS_DONE      = 32'h0000_0002;
    localparam logic [31:0] STATUS_ERROR     = 32'h0000_0004;
    localparam logic [31:0] CFG_CAUSAL_EN    = 32'h0000_0001;
    localparam int QK_PROC_SHIFT = FRAC_W - 4;
    localparam int V_PROC_SHIFT  = FRAC_W - 5;

    logic clk;
    logic rst_n;

    logic [31:0] s_axil_awaddr;
    logic        s_axil_awvalid;
    wire         s_axil_awready;
    logic [31:0] s_axil_wdata;
    logic [3:0]  s_axil_wstrb;
    logic        s_axil_wvalid;
    wire         s_axil_wready;
    wire [1:0]   s_axil_bresp;
    wire         s_axil_bvalid;
    logic        s_axil_bready;
    logic [31:0] s_axil_araddr;
    logic        s_axil_arvalid;
    wire         s_axil_arready;
    wire [31:0]  s_axil_rdata;
    wire [1:0]   s_axil_rresp;
    wire         s_axil_rvalid;
    logic        s_axil_rready;

    wire [ADDR_W-1:0] m_axi_araddr;
    wire [7:0]        m_axi_arlen;
    wire [2:0]        m_axi_arsize;
    wire [1:0]        m_axi_arburst;
    wire              m_axi_arvalid;
    logic             m_axi_arready;
    logic [AXI_DATA_W-1:0] m_axi_rdata;
    logic [1:0]            m_axi_rresp;
    logic                  m_axi_rlast;
    logic                  m_axi_rvalid;
    wire                   m_axi_rready;

    wire [ADDR_W-1:0] m_axi_awaddr;
    wire [7:0]        m_axi_awlen;
    wire [2:0]        m_axi_awsize;
    wire [1:0]        m_axi_awburst;
    wire              m_axi_awvalid;
    logic             m_axi_awready;
    wire [AXI_DATA_W-1:0]   m_axi_wdata;
    wire [AXI_DATA_W/8-1:0] m_axi_wstrb;
    wire                    m_axi_wlast;
    wire                    m_axi_wvalid;
    logic                   m_axi_wready;
    logic [1:0]             m_axi_bresp;
    logic                   m_axi_bvalid;
    wire                    m_axi_bready;
    wire                    irq;

    logic signed [DATA_W-1:0] o_mem [0:TOTAL_O_ELEMS-1];
    logic [31:0] status_value;
    logic [31:0] cycles_value;
    logic [31:0] rd_bytes_l;
    logic [31:0] rd_bytes_h;
    logic [31:0] wr_bytes_l;
    logic [31:0] wr_bytes_h;
    int wait_cycles;
    bit saw_busy;
    int row;
    int col;
    int changed_count;
    int progress_pct;
    int task_iter;
    int head_iter;
    int init_idx;
    int init_run_idx;
    int signed init_q;
    int signed init_k;
    int signed init_v;
    int use_vector_files;
    string out_hex_path;
    string q_hex_path;
    string k_hex_path;
    string v_hex_path;

    logic signed [DATA_W-1:0] q_vec_mem [0:NUM_ELEMS-1];
    logic signed [DATA_W-1:0] k_vec_mem [0:NUM_ELEMS-1];
    logic signed [DATA_W-1:0] v_vec_mem [0:NUM_ELEMS-1];
    logic [DATA_W-1:0] q_src_mem [0:TOTAL_O_ELEMS-1];
    logic [DATA_W-1:0] k_src_mem [0:TOTAL_O_ELEMS-1];
    logic [DATA_W-1:0] v_src_mem [0:TOTAL_O_ELEMS-1];

    typedef enum logic [1:0] {
        RD_IDLE,
        RD_SEND
    } rd_state_t;

    typedef enum logic [1:0] {
        WR_IDLE,
        WR_DATA,
        WR_RESP
    } wr_state_t;

    rd_state_t rd_state_q;
    wr_state_t wr_state_q;
    int unsigned rd_addr_q;
    int rd_len_q;
    int rd_beat_q;
    int unsigned wr_addr_q;
    int wr_len_q;
    int wr_beat_q;

    flash_attn_top #(
        .S_LEN(S_LEN),
        .D_MODEL(D_MODEL),
        .BK(BK),
        .DATA_W(DATA_W),
        .FRAC_W(FRAC_W),
        .ACC_W(ACC_W),
        .ADDR_W(ADDR_W),
        .AXI_DATA_W(AXI_DATA_W),
        .BQ(BQ),
        .USE_DOT_TREE(USE_DOT_TREE),
        .DOT_LANES(DOT_LANES),
        .USE_CAUSAL_SKIP(USE_CAUSAL_SKIP),
        .SOFTMAX_FRAC(SOFTMAX_FRAC),
        .FP8_E4M3_MODE(FP8_E4M3_MODE)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axil_awaddr(s_axil_awaddr),
        .s_axil_awvalid(s_axil_awvalid),
        .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata),
        .s_axil_wstrb(s_axil_wstrb),
        .s_axil_wvalid(s_axil_wvalid),
        .s_axil_wready(s_axil_wready),
        .s_axil_bresp(s_axil_bresp),
        .s_axil_bvalid(s_axil_bvalid),
        .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr),
        .s_axil_arvalid(s_axil_arvalid),
        .s_axil_arready(s_axil_arready),
        .s_axil_rdata(s_axil_rdata),
        .s_axil_rresp(s_axil_rresp),
        .s_axil_rvalid(s_axil_rvalid),
        .s_axil_rready(s_axil_rready),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .irq(irq)
    );

    always #5 clk = ~clk;

    initial begin
        #1000;
        if (VERBOSE != 0) begin
            $display("INFO watchdog time=%0t clk=%0b rst_n=%0b", $time, clk, rst_n);
            $fflush();
        end
    end

    always @(posedge clk) begin
        if (rst_n && (VERBOSE != 0)) begin
            if (dut.o_valid || dut.o_ready || dut.wr_req_valid || dut.wr_data_valid ||
                m_axi_awvalid || m_axi_wvalid || m_axi_bvalid || dut.core_done ||
                dut.overall_done_pulse) begin
                $display("MON t=%0t o_v=%0b o_r=%0b o_row=%0d core_done=%0b wr_req_v=%0b wr_req_r=%0b wr_data_v=%0b wr_data_r=%0b awv=%0b awr=%0b wv=%0b wr=%0b bv=%0b br=%0b overall_done=%0b",
                         $time, dut.o_valid, dut.o_ready, dut.o_row, dut.core_done,
                         dut.wr_req_valid, dut.wr_req_ready,
                         dut.wr_data_valid, dut.wr_data_ready, m_axi_awvalid,
                         m_axi_awready, m_axi_wvalid, m_axi_wready, m_axi_bvalid,
                         m_axi_bready, dut.overall_done_pulse);
                $fflush();
            end
            if (dut.u_flash_core.state_q == 4'd7 && dut.u_flash_core.dot_done) begin
                $display("CORE dot row=%0d key=%0d score_valid=%0b dot=%0d scaled=%0d masked=%0d m=%0d l=%0d old_scale=%0d new_weight=%0d acc0_in=%0d acc0_next=%0d v0=%0d",
                         dut.u_flash_core.current_q_row,
                         dut.u_flash_core.current_key_index,
                         dut.u_flash_core.score_valid,
                         dut.u_flash_core.dot_value,
                         dut.u_flash_core.scaled_score,
                         dut.u_flash_core.masked_score,
                         dut.u_flash_core.m_state_q,
                         dut.u_flash_core.l_state_q,
                         dut.u_flash_core.old_scale,
                         dut.u_flash_core.new_weight,
                         dut.u_flash_core.acc_state_q[0],
                         dut.u_flash_core.acc_next[0],
                         dut.u_flash_core.v_work_data[0]);
                $fflush();
            end
            if (dut.rd_data_valid && dut.rd_data_ready) begin
                $display("DMA rd data=%016h last=%0b", dut.rd_data, dut.rd_last);
                $fflush();
            end
            if (dut.q_data_valid && dut.q_data_ready) begin
                $display("DMA q present q0=%0d q1=%0d", dut.q_data[0], dut.q_data[1]);
                $fflush();
            end
            if (dut.kv_data_valid && dut.kv_data_ready) begin
                $display("DMA kv present k00=%0d k01=%0d v00=%0d v01=%0d",
                         dut.k_tile[0][0],
                         dut.k_tile[0][1],
                         dut.v_tile[0][0],
                         dut.v_tile[0][1]);
                $fflush();
            end
            if (dut.u_flash_core.state_q == 4'd8) begin
                $display("CORE normalize row=%0d idx=%0d denom=%0d acc=%0d norm=%0d valid=%0b",
                         dut.u_flash_core.current_q_row,
                         dut.u_flash_core.norm_index_q,
                         dut.u_flash_core.norm_denom,
                         dut.u_flash_core.norm_acc,
                         dut.u_flash_core.norm_out,
                         dut.u_flash_core.norm_out_valid);
                $fflush();
            end
            if (dut.u_flash_core.state_q == 4'd10) begin
                $display("CORE emit row=%0d o0=%0d o1=%0d flat=%0h",
                         dut.u_flash_core.o_row,
                         dut.u_flash_core.o_data_q[0],
                         dut.u_flash_core.o_data_q[1],
                         dut.o_data_flat);
                $fflush();
            end
        end
    end

    function automatic int signed scale_pattern(input int signed value, input int shift);
        begin
            if (shift >= 0) begin
                scale_pattern = value <<< shift;
            end else begin
                scale_pattern = value >>> (-shift);
            end
        end
    endfunction

    function automatic int signed q_value(input int in_row, input int in_col);
        begin
            q_value = scale_pattern((((in_row * 3 + in_col * 5 + 7) % 17) - 8), QK_PROC_SHIFT);
        end
    endfunction

    function automatic int signed k_value(input int key_row, input int in_col);
        begin
            k_value = scale_pattern((((key_row * 5 + in_col * 7 + 11) % 19) - 9), QK_PROC_SHIFT);
        end
    endfunction

    function automatic int signed v_value(input int key_row, input int in_col);
        begin
            v_value = scale_pattern((((key_row * 7 + in_col * 3 + 5) % 23) - 11), V_PROC_SHIFT);
        end
    endfunction

    function automatic int signed q_data_value(input int in_row, input int in_col, input int in_task, input int in_head);
        begin
            if (use_vector_files != 0) begin
                q_data_value = $signed(q_vec_mem[in_row * D_MODEL + in_col]);
            end else begin
                q_data_value = q_value(in_row, in_col) + ((in_head - in_task) <<< (FRAC_W > 7 ? FRAC_W - 7 : 0));
            end
        end
    endfunction

    function automatic int signed k_data_value(input int key_row, input int in_col, input int in_task, input int in_head);
        begin
            if (use_vector_files != 0) begin
                k_data_value = $signed(k_vec_mem[key_row * D_MODEL + in_col]);
            end else begin
                k_data_value = k_value(key_row, in_col) + ((in_head + in_task) <<< (FRAC_W > 8 ? FRAC_W - 8 : 0));
            end
        end
    endfunction

    function automatic int signed v_data_value(input int key_row, input int in_col, input int in_task, input int in_head);
        begin
            if (use_vector_files != 0) begin
                v_data_value = $signed(v_vec_mem[key_row * D_MODEL + in_col]);
            end else begin
                v_data_value = v_value(key_row, in_col) + ((in_head * 3 + in_task) <<< (FRAC_W > 8 ? FRAC_W - 8 : 0));
            end
        end
    endfunction

    `include "flash_core_ref_exp_lut.svh"

    function automatic logic signed [DATA_W-1:0] saturate_to_data(input longint signed value);
        begin
            if (value > DATA_MAX) begin
                saturate_to_data = DATA_MAX[DATA_W-1:0];
            end else if (value < DATA_MIN) begin
                saturate_to_data = DATA_MIN[DATA_W-1:0];
            end else begin
                saturate_to_data = value[DATA_W-1:0];
            end
        end
    endfunction

    function automatic longint signed scaled_score(input int in_row, input int key, input int in_task, input int in_head);
        longint signed dot;
        begin
            dot = 0;
            for (int c = 0; c < D_MODEL; c = c + 1) begin
                dot += q_data_value(in_row, c, in_task, in_head) *
                       k_data_value(key, c, in_task, in_head);
            end
            scaled_score = ((dot >>> FRAC_W) * SCALE_Q8_8) >>> FRAC_W;
        end
    endfunction

    function automatic logic signed [DATA_W-1:0] expected_o(
        input int in_row,
        input int out_col,
        input int in_task,
        input int in_head
    );
        longint signed m;
        longint signed l;
        longint signed acc;
        longint signed score;
        longint signed old_scale;
        longint signed new_weight;
        longint signed acc_weight;
        begin
            if (in_row >= VALID_LEN) begin
                expected_o = '0;
                return expected_o;
            end

            m = 0;
            l = 0;
            acc = 0;

            for (int key = 0; key < S_LEN; key = key + 1) begin
                if ((key < VALID_LEN) && (key <= in_row)) begin
                    score = scaled_score(in_row, key, in_task, in_head);

                    if (l == 0) begin
                        old_scale = 0;
                        new_weight = WEIGHT_ONE;
                        m = score;
                        l = WEIGHT_ONE;
                    end else if (score > m) begin
                        old_scale = exp_approx_weight(m - score);
                        new_weight = WEIGHT_ONE;
                        l = ((l * old_scale) >>> WEIGHT_FRAC) + new_weight;
                        m = score;
                    end else begin
                        old_scale = WEIGHT_ONE;
                        new_weight = exp_approx_weight(score - m);
                        l = ((l * old_scale) >>> WEIGHT_FRAC) + new_weight;
                    end

                    acc_weight = dropout_acc_weight(in_row, key, new_weight);
                    acc = ((acc * old_scale) >>> WEIGHT_FRAC) +
                          (acc_weight * v_data_value(key, out_col, in_task, in_head));
                end
            end

            expected_o = (l == 0) ? '0 : saturate_to_data(acc / l);
        end
    endfunction

    function automatic logic [15:0] dropout_rand16(input int in_row, input int key);
        logic [31:0] x;
        begin
            x = {DROPOUT_SEED[15:0], DROPOUT_SEED[15:0] ^ 16'hace1};
            x = x ^ (in_row[15:0] << 5);
            x = x ^ (in_row[15:0] << 13);
            x = x ^ (key[15:0] << 3);
            x = x ^ (key[15:0] << 17);
            x = x ^ (x << 7);
            x = x ^ (x >> 9);
            x = x ^ (x << 8);
            dropout_rand16 = x[15:0] ^ x[31:16];
        end
    endfunction

    function automatic longint signed dropout_acc_weight(input int in_row, input int key, input longint signed weight);
        longint signed scaled;
        begin
            if (DROPOUT_EN == 0) begin
                dropout_acc_weight = weight;
            end else if (dropout_rand16(in_row, key) < DROPOUT_THRESHOLD[15:0]) begin
                dropout_acc_weight = 0;
            end else begin
                scaled = ((weight * DROPOUT_SCALE_Q8_8) + 128) >>> 8;
                dropout_acc_weight = scaled;
            end
        end
    endfunction

    function automatic int elem_index(input int in_row, input int in_col);
        begin
            elem_index = in_row * D_MODEL + in_col;
        end
    endfunction

    function automatic int task_region_limit(input int unsigned base);
        begin
            task_region_limit = base + TASK_REGION_BYTES;
        end
    endfunction

    function automatic int task_index_from_addr(input int unsigned addr, input int unsigned base);
        begin
            if (TASK_COUNT <= 1) begin
                task_index_from_addr = 0;
            end else begin
                task_index_from_addr = (addr - base) / TASK_STRIDE_BYTES;
            end
        end
    endfunction

    function automatic int head_index_from_addr(input int unsigned addr, input int unsigned base);
        int task_idx;
        int task_base;
        begin
            task_idx = task_index_from_addr(addr, base);
            task_base = base + task_idx * TASK_STRIDE_BYTES;
            if (HEAD_COUNT <= 1) begin
                head_index_from_addr = 0;
            end else begin
                head_index_from_addr = (addr - task_base) / HEAD_STRIDE_BYTES;
            end
        end
    endfunction

    function automatic int addr_to_elem(input int unsigned addr, input int unsigned base);
        int task_idx;
        int head_idx;
        int tensor_base;
        begin
            task_idx = task_index_from_addr(addr, base);
            head_idx = head_index_from_addr(addr, base);
            tensor_base = base + task_idx * TASK_STRIDE_BYTES + head_idx * HEAD_STRIDE_BYTES;
            addr_to_elem = (addr - tensor_base) / DATA_BYTES;
        end
    endfunction

    function automatic int run_index(input int in_task, input int in_head);
        begin
            run_index = in_task * HEAD_COUNT + in_head;
        end
    endfunction

    function automatic logic [DATA_W-1:0] source_value(input int source, input int idx, input int in_task, input int in_head);
        int run_idx;
        begin
            run_idx = run_index(in_task, in_head);
            case (source)
                0: source_value = q_src_mem[run_idx * NUM_ELEMS + idx];
                1: source_value = k_src_mem[run_idx * NUM_ELEMS + idx];
                2: source_value = v_src_mem[run_idx * NUM_ELEMS + idx];
                default: source_value = '0;
            endcase
        end
    endfunction

    function automatic logic [AXI_DATA_W-1:0] read_axi_word(input int unsigned addr);
        logic [AXI_DATA_W-1:0] word;
        int idx;
        int task_idx;
        int head_idx;
        int run_idx;
        begin
            word = '0;
            for (int lane = 0; lane < AXI_LANES; lane = lane + 1) begin
                if ((addr >= Q_BASE) && (addr < task_region_limit(Q_BASE))) begin
                    task_idx = task_index_from_addr(addr, Q_BASE);
                    head_idx = head_index_from_addr(addr, Q_BASE);
                    idx = addr_to_elem(addr, Q_BASE) + lane;
                    word[lane*DATA_W +: DATA_W] = source_value(0, idx, task_idx, head_idx);
                end else if ((addr >= K_BASE) && (addr < task_region_limit(K_BASE))) begin
                    task_idx = task_index_from_addr(addr, K_BASE);
                    head_idx = head_index_from_addr(addr, K_BASE);
                    idx = addr_to_elem(addr, K_BASE) + lane;
                    word[lane*DATA_W +: DATA_W] = source_value(1, idx, task_idx, head_idx);
                end else if ((addr >= V_BASE) && (addr < task_region_limit(V_BASE))) begin
                    task_idx = task_index_from_addr(addr, V_BASE);
                    head_idx = head_index_from_addr(addr, V_BASE);
                    idx = addr_to_elem(addr, V_BASE) + lane;
                    word[lane*DATA_W +: DATA_W] = source_value(2, idx, task_idx, head_idx);
                end else if ((addr >= O_BASE) && (addr < task_region_limit(O_BASE))) begin
                    task_idx = task_index_from_addr(addr, O_BASE);
                    head_idx = head_index_from_addr(addr, O_BASE);
                    run_idx = run_index(task_idx, head_idx);
                    idx = addr_to_elem(addr, O_BASE) + lane;
                    word[lane*DATA_W +: DATA_W] = o_mem[run_idx * NUM_ELEMS + idx];
                end
            end
            read_axi_word = word;
        end
    endfunction

    task automatic write_axi_word(
        input int unsigned addr,
        input logic [AXI_DATA_W-1:0] data,
        input logic [AXI_DATA_W/8-1:0] strb
    );
        int idx;
        int task_idx;
        int head_idx;
        int run_idx;
        bit lane_write;
        begin
            if ((addr < O_BASE) || (addr >= task_region_limit(O_BASE))) begin
                $display("FAIL write outside O region addr=%0d", addr);
                $fatal(1);
            end

            task_idx = task_index_from_addr(addr, O_BASE);
            head_idx = head_index_from_addr(addr, O_BASE);
            run_idx = run_index(task_idx, head_idx);
            for (int lane = 0; lane < AXI_LANES; lane = lane + 1) begin
                lane_write = 1'b0;
                for (int byte_idx = 0; byte_idx < DATA_BYTES; byte_idx = byte_idx + 1) begin
                    lane_write |= strb[lane * DATA_BYTES + byte_idx];
                end
                if (lane_write) begin
                    idx = addr_to_elem(addr, O_BASE) + lane;
                    o_mem[run_idx * NUM_ELEMS + idx] = data[lane*DATA_W +: DATA_W];
                end
            end
            if (VERBOSE != 0) begin
                $display("INFO AXI write addr=%0d data=%016h strb=%02h idx0=%0d flat=%0h",
                         addr, data, strb, addr_to_elem(addr, O_BASE),
                         dut.o_data_flat);
                $fflush();
            end
        end
    endtask

    always_comb begin
        m_axi_arready = (rd_state_q == RD_IDLE);
        m_axi_rvalid  = (rd_state_q == RD_SEND);
        m_axi_rdata   = read_axi_word(rd_addr_q + rd_beat_q * AXI_BYTES);
        m_axi_rresp   = 2'b00;
        m_axi_rlast   = (rd_state_q == RD_SEND) && (rd_beat_q == rd_len_q - 1);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_state_q    <= RD_IDLE;
            rd_addr_q     <= 0;
            rd_len_q      <= 0;
            rd_beat_q     <= 0;
        end else begin
            case (rd_state_q)
                RD_IDLE: begin
                    if (m_axi_arvalid && m_axi_arready) begin
                        if (m_axi_arsize != 3'd3 || m_axi_arburst != 2'b01) begin
                            $display("FAIL unsupported AXI read size/burst size=%0d burst=%0d",
                                     m_axi_arsize, m_axi_arburst);
                            $fatal(1);
                        end
                        rd_addr_q  <= m_axi_araddr[31:0];
                        rd_len_q   <= m_axi_arlen + 1;
                        rd_beat_q  <= 0;
                        rd_state_q <= RD_SEND;
                    end
                end

                RD_SEND: begin
                    if ((VERBOSE != 0) && m_axi_rvalid && m_axi_rready) begin
                        $display("INFO AXI read addr=%0d data=%016h last=%0b",
                                 rd_addr_q + rd_beat_q * AXI_BYTES,
                                 read_axi_word(rd_addr_q + rd_beat_q * AXI_BYTES),
                                 (rd_beat_q == rd_len_q - 1));
                        $fflush();
                    end

                    if (m_axi_rvalid && m_axi_rready) begin
                        if (rd_beat_q == rd_len_q - 1) begin
                            rd_state_q <= RD_IDLE;
                        end else begin
                            rd_beat_q <= rd_beat_q + 1;
                        end
                    end
                end
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_state_q    <= WR_IDLE;
            wr_addr_q     <= 0;
            wr_len_q      <= 0;
            wr_beat_q     <= 0;
            m_axi_awready <= 1'b0;
            m_axi_wready  <= 1'b0;
            m_axi_bvalid  <= 1'b0;
            m_axi_bresp   <= 2'b00;
        end else begin
            m_axi_awready <= (wr_state_q == WR_IDLE);
            m_axi_wready  <= (wr_state_q == WR_DATA);

            case (wr_state_q)
                WR_IDLE: begin
                    m_axi_bvalid <= 1'b0;
                    if (m_axi_awvalid && m_axi_awready) begin
                        if (m_axi_awsize != 3'd3 || m_axi_awburst != 2'b01) begin
                            $display("FAIL unsupported AXI write size/burst size=%0d burst=%0d",
                                     m_axi_awsize, m_axi_awburst);
                            $fatal(1);
                        end
                        wr_addr_q  <= m_axi_awaddr[31:0];
                        wr_len_q   <= m_axi_awlen + 1;
                        wr_beat_q  <= 0;
                        wr_state_q <= WR_DATA;
                    end
                end

                WR_DATA: begin
                    if (m_axi_wvalid && m_axi_wready) begin
                        write_axi_word(wr_addr_q + wr_beat_q * AXI_BYTES,
                                       m_axi_wdata,
                                       m_axi_wstrb);
                        if (m_axi_wlast !== (wr_beat_q == wr_len_q - 1)) begin
                            $display("FAIL AXI WLAST got=%0d expected=%0d beat=%0d len=%0d",
                                     m_axi_wlast, (wr_beat_q == wr_len_q - 1), wr_beat_q, wr_len_q);
                            $fatal(1);
                        end
                        if (wr_beat_q == wr_len_q - 1) begin
                            wr_state_q <= WR_RESP;
                        end else begin
                            wr_beat_q <= wr_beat_q + 1;
                        end
                    end
                end

                WR_RESP: begin
                    m_axi_bvalid <= 1'b1;
                    m_axi_bresp  <= 2'b00;
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bvalid <= 1'b0;
                        wr_state_q   <= WR_IDLE;
                    end
                end
            endcase
        end
    end

    task automatic axil_write(input logic [31:0] addr, input logic [31:0] data);
        bit aw_done;
        bit w_done;
        int timeout;
        begin
            if (VERBOSE != 0) begin
                $display("INFO axil_write addr=%08h data=%08h", addr, data);
                $fflush();
            end
            aw_done = 0;
            w_done = 0;
            timeout = 0;
            @(negedge clk);
            s_axil_awaddr  = addr;
            s_axil_awvalid = 1'b1;
            s_axil_wdata   = data;
            s_axil_wstrb   = 4'hf;
            s_axil_wvalid  = 1'b1;
            s_axil_bready  = 1'b1;

            while (!aw_done || !w_done) begin
                @(posedge clk);
                timeout++;
                if (timeout > 1000) begin
                    $display("FAIL AXI-Lite write address/data timeout addr=%08h awready=%0b wready=%0b",
                             addr, s_axil_awready, s_axil_wready);
                    $fatal(1);
                end
                if (s_axil_awready) begin
                    aw_done = 1;
                end
                if (s_axil_wready) begin
                    w_done = 1;
                end
            end

            @(negedge clk);
            s_axil_awvalid = 1'b0;
            s_axil_wvalid = 1'b0;

            timeout = 0;
            while (!s_axil_bvalid) begin
                @(posedge clk);
                timeout++;
                if (timeout > 1000) begin
                    $display("FAIL AXI-Lite write response timeout addr=%08h bvalid=%0b", addr, s_axil_bvalid);
                    $fatal(1);
                end
            end
            if (s_axil_bresp != 2'b00) begin
                $display("FAIL AXI-Lite write response addr=%08h resp=%0d", addr, s_axil_bresp);
                $fatal(1);
            end
            @(negedge clk);
            s_axil_bready = 1'b0;
        end
    endtask

    task automatic axil_read(input logic [31:0] addr, output logic [31:0] data);
        bit ar_done;
        int timeout;
        begin
            if (VERBOSE != 0) begin
                $display("INFO axil_read addr=%08h", addr);
                $fflush();
            end
            ar_done = 0;
            timeout = 0;
            @(negedge clk);
            s_axil_araddr  = addr;
            s_axil_arvalid = 1'b1;
            s_axil_rready  = 1'b1;

            while (!ar_done) begin
                @(posedge clk);
                timeout++;
                if (timeout > 1000) begin
                    $display("FAIL AXI-Lite read address timeout addr=%08h arready=%0b", addr, s_axil_arready);
                    $fatal(1);
                end
                if (s_axil_arready) begin
                    ar_done = 1;
                end
            end

            @(negedge clk);
            s_axil_arvalid = 1'b0;

            timeout = 0;
            while (!s_axil_rvalid) begin
                @(posedge clk);
                timeout++;
                if (timeout > 1000) begin
                    $display("FAIL AXI-Lite read response timeout addr=%08h rvalid=%0b", addr, s_axil_rvalid);
                    $fatal(1);
                end
            end
            data = s_axil_rdata;
            if (s_axil_rresp != 2'b00) begin
                $display("FAIL AXI-Lite read response addr=%08h resp=%0d", addr, s_axil_rresp);
                $fatal(1);
            end
            @(negedge clk);
            s_axil_rready = 1'b0;
        end
    endtask

    task automatic axil_write64(input logic [31:0] reg_l, input logic [31:0] reg_h, input logic [63:0] value);
        begin
            axil_write(reg_l, value[31:0]);
            axil_write(reg_h, value[63:32]);
        end
    endtask

    task automatic program_registers;
        begin
            axil_write(REG_CFG, CFG_CAUSAL_EN);
            axil_write64(REG_Q_BASE_L, REG_Q_BASE_H, Q_BASE);
            axil_write64(REG_K_BASE_L, REG_K_BASE_H, K_BASE);
            axil_write64(REG_V_BASE_L, REG_V_BASE_H, V_BASE);
            axil_write64(REG_O_BASE_L, REG_O_BASE_H, O_BASE);
            axil_write(REG_STRIDE_BYTES, STRIDE_BYTES);
            axil_write(REG_NEG_LARGE, 32'hffff_8000);
            axil_write(REG_SCALE, SCALE_Q8_8);
            axil_write(REG_VALID_LEN, VALID_LEN);
            axil_write(REG_TASK_COUNT, TASK_COUNT);
            axil_write(REG_TASK_STRIDE, TASK_STRIDE_BYTES);
            axil_write(REG_DROPOUT_CFG, {DROPOUT_THRESHOLD[15:0], 15'd0, DROPOUT_EN[0]});
            axil_write(REG_DROPOUT_SEED, DROPOUT_SEED[15:0]);
            axil_write(REG_DROPOUT_SCALE, DROPOUT_SCALE_Q8_8[15:0]);
            axil_write(REG_HEAD_COUNT, HEAD_COUNT);
            axil_write(REG_HEAD_STRIDE, HEAD_STRIDE_BYTES);
        end
    endtask

    task automatic check_output_memory;
        logic signed [DATA_W-1:0] got;
        logic signed [DATA_W-1:0] exp;
        int idx;
        int run_idx;
        begin
            changed_count = 0;
            for (int t = 0; t < TASK_COUNT; t = t + 1) begin
                for (int h = 0; h < HEAD_COUNT; h = h + 1) begin
                    run_idx = run_index(t, h);
                    for (int r = 0; r < S_LEN; r = r + 1) begin
                        for (int c = 0; c < D_MODEL; c = c + 1) begin
                            idx = (run_idx * NUM_ELEMS) + elem_index(r, c);
                            got = o_mem[idx];
                            if ((^got) === 1'bx) begin
                                $display("FAIL task%0d head%0d O[%0d][%0d] is X/Z", t, h, r, c);
                                $fatal(1);
                            end
                            changed_count++;
                            if (CHECK_BITEXACT != 0) begin
                                exp = expected_o(r, c, t, h);
                                if (got !== exp) begin
                                    $display("FAIL TOP task%0d head%0d O[%0d][%0d] got=%0d hex=%04h expected=%0d hex=%04h",
                                             t, h, r, c, got, got, exp, exp);
                                    $fatal(1);
                                end
                            end else if (r >= VALID_LEN) begin
                                exp = '0;
                                if (got !== exp) begin
                                    $display("FAIL TOP task%0d head%0d padding row O[%0d][%0d] got=%0d expected zero",
                                             t, h, r, c, got);
                                    $fatal(1);
                                end
                            end else if ((r == 0) && (DROPOUT_EN == 0)) begin
                                if (FP8_E4M3_MODE != 0) begin
                                    exp = fp8_e4m3_pkg::q8_8_to_fp8_e4m3(v_data_value(0, c, t, h));
                                end else begin
                                    exp = v_data_value(0, c, t, h);
                                end
                                if (got !== exp) begin
                                    $display("FAIL TOP task%0d head%0d causal row0 O[0][%0d] got=%0d expected V[0][%0d]=%0d",
                                             t, h, c, got, c, exp);
                                    $fatal(1);
                                end
                            end
                        end
                    end
                end
            end

            if (changed_count != TOTAL_O_ELEMS) begin
                $display("FAIL changed output count=%0d expected=%0d", changed_count, TOTAL_O_ELEMS);
                $fatal(1);
            end
        end
    endtask

    task automatic dump_output_memory;
        int fd;
        int idx;
        logic signed [15:0] dump_value;
        begin
            fd = $fopen(out_hex_path, "w");
            if (fd == 0) begin
                $display("FAIL could not open output dump path %s", out_hex_path);
                $fatal(1);
            end

            for (idx = 0; idx < TOTAL_O_ELEMS; idx = idx + 1) begin
                if (FP8_E4M3_MODE != 0) begin
                    dump_value = fp8_e4m3_pkg::fp8_e4m3_to_q8_8(o_mem[idx][7:0]);
                end else begin
                    dump_value = $signed(o_mem[idx]);
                end
                $fwrite(fd, "%04h\n", dump_value[15:0]);
            end
            $fclose(fd);
        end
    endtask

    task automatic check_dropout_mask_activity;
        int kept_count;
        int dropped_count;
        begin
            kept_count = 0;
            dropped_count = 0;
            if (DROPOUT_EN != 0) begin
                for (int r = 0; r < S_LEN; r = r + 1) begin
                    for (int key = 0; key < S_LEN; key = key + 1) begin
                        if ((r < VALID_LEN) && (key < VALID_LEN) && (key <= r)) begin
                            if (dropout_rand16(r, key) < DROPOUT_THRESHOLD[15:0]) begin
                                dropped_count++;
                            end else begin
                                kept_count++;
                            end
                        end
                    end
                end
                if ((kept_count == 0) || (dropped_count == 0)) begin
                    $display("FAIL dropout mask inactive kept=%0d dropped=%0d threshold=%0d",
                             kept_count, dropped_count, DROPOUT_THRESHOLD);
                    $fatal(1);
                end
                $display("INFO dropout mask seed=%04h threshold=%0d scale_q8_8=%0d kept=%0d dropped=%0d",
                         DROPOUT_SEED[15:0], DROPOUT_THRESHOLD, DROPOUT_SCALE_Q8_8,
                         kept_count, dropped_count);
            end
        end
    endtask

    initial begin
        use_vector_files = 0;
        out_hex_path = "sim_build/tb_flash_attn_top_e2e_output.hex";
        if (!$value$plusargs("OUT_HEX=%s", out_hex_path)) begin
            out_hex_path = "sim_build/tb_flash_attn_top_e2e_output.hex";
        end
        if (!$value$plusargs("USE_VECTOR_FILES=%d", use_vector_files)) begin
            use_vector_files = 0;
        end
        if (use_vector_files != 0) begin
            if (!$value$plusargs("Q_HEX=%s", q_hex_path)) begin
                $display("FAIL +USE_VECTOR_FILES=1 requires +Q_HEX=<path>");
                $fatal(1);
            end
            if (!$value$plusargs("K_HEX=%s", k_hex_path)) begin
                $display("FAIL +USE_VECTOR_FILES=1 requires +K_HEX=<path>");
                $fatal(1);
            end
            if (!$value$plusargs("V_HEX=%s", v_hex_path)) begin
                $display("FAIL +USE_VECTOR_FILES=1 requires +V_HEX=<path>");
                $fatal(1);
            end
            $readmemh(q_hex_path, q_vec_mem);
            $readmemh(k_hex_path, k_vec_mem);
            $readmemh(v_hex_path, v_vec_mem);
        end

        for (task_iter = 0; task_iter < TASK_COUNT; task_iter = task_iter + 1) begin
            for (head_iter = 0; head_iter < HEAD_COUNT; head_iter = head_iter + 1) begin
                init_run_idx = run_index(task_iter, head_iter);
                for (row = 0; row < S_LEN; row = row + 1) begin
                    for (col = 0; col < D_MODEL; col = col + 1) begin
                        init_idx = init_run_idx * NUM_ELEMS + elem_index(row, col);
                        init_q = q_data_value(row, col, task_iter, head_iter);
                        init_k = k_data_value(row, col, task_iter, head_iter);
                        init_v = v_data_value(row, col, task_iter, head_iter);
                        if (FP8_E4M3_MODE != 0) begin
                            q_src_mem[init_idx] = fp8_e4m3_pkg::q8_8_to_fp8_e4m3(init_q);
                            k_src_mem[init_idx] = fp8_e4m3_pkg::q8_8_to_fp8_e4m3(init_k);
                            v_src_mem[init_idx] = fp8_e4m3_pkg::q8_8_to_fp8_e4m3(init_v);
                        end else begin
                            q_src_mem[init_idx] = init_q[DATA_W-1:0];
                            k_src_mem[init_idx] = init_k[DATA_W-1:0];
                            v_src_mem[init_idx] = init_v[DATA_W-1:0];
                        end
                    end
                end
            end
        end

        if (VERBOSE != 0) begin
            $display("INFO top e2e initial entered vector_files=%0d", use_vector_files);
            $fflush();
        end
        clk = 1'b0;
        rst_n = 1'b0;
        s_axil_awaddr = '0;
        s_axil_awvalid = 1'b0;
        s_axil_wdata = '0;
        s_axil_wstrb = '0;
        s_axil_wvalid = 1'b0;
        s_axil_bready = 1'b0;
        s_axil_araddr = '0;
        s_axil_arvalid = 1'b0;
        s_axil_rready = 1'b0;
        saw_busy = 0;

        if (VERBOSE != 0) begin
            $display("INFO tensor sources ready S=%0d D=%0d BK=%0d bitexact=%0d", S_LEN, D_MODEL, BK, CHECK_BITEXACT);
            $fflush();
        end

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        program_registers();
        check_dropout_mask_activity();
        if (VERBOSE != 0) begin
            $display("INFO registers programmed");
            $fflush();
        end
        axil_write(REG_CTRL, CTRL_START);
        if (VERBOSE != 0) begin
            $display("INFO start issued");
            $fflush();
        end

        wait_cycles = 0;
        status_value = 32'd0;
        while ((wait_cycles < TIMEOUT_CYCLES) && ((status_value & STATUS_DONE) == 0)) begin
            repeat (16) @(posedge clk);
            wait_cycles += 16;
            axil_read(REG_STATUS, status_value);
            if ((status_value & STATUS_BUSY) != 0) begin
                saw_busy = 1;
            end
            if ((status_value & STATUS_ERROR) != 0) begin
                $display("FAIL STATUS.ERROR set status=%08h", status_value);
                $fatal(1);
            end
            if ((PROGRESS_EVERY != 0) && ((wait_cycles % PROGRESS_EVERY) == 0)) begin
                axil_read(REG_CYCLES, cycles_value);
                if (MAX_CYCLES != 0) begin
                    progress_pct = (cycles_value * 100) / MAX_CYCLES;
                end else begin
                    progress_pct = (wait_cycles * 100) / TIMEOUT_CYCLES;
                end
                if (progress_pct > 100) begin
                    progress_pct = 100;
                end
                $display("PROGRESS [%0d%%] top e2e S=%0d D=%0d BK=%0d BQ=%0d cycles=%0d/%0d wait_cycles=%0d/%0d status=%08h core_state=%0d q_block=%0d kv_start=%0d emit=%0d",
                         progress_pct, S_LEN, D_MODEL, BK, BQ, cycles_value,
                         MAX_CYCLES, wait_cycles, TIMEOUT_CYCLES, status_value,
                         dut.u_flash_core.state_q, dut.u_flash_core.q_block_start_q,
                         dut.u_flash_core.kv_start_q, dut.u_flash_core.emit_index_q);
                $fflush();
            end
        end

        if ((status_value & STATUS_DONE) == 0) begin
            $display("FAIL timeout waiting for STATUS.DONE status=%08h", status_value);
            $fatal(1);
        end
        if (!saw_busy) begin
            $display("FAIL STATUS.BUSY was never observed");
            $fatal(1);
        end

        axil_read(REG_CYCLES, cycles_value);
        if (cycles_value == 0) begin
            $display("FAIL CYCLES stayed zero");
            $fatal(1);
        end
        if ((MAX_CYCLES != 0) && (cycles_value > MAX_CYCLES)) begin
            $display("FAIL CYCLES=%0d exceeded MAX_CYCLES=%0d", cycles_value, MAX_CYCLES);
            $fatal(1);
        end

        axil_read(REG_RD_BYTES_L, rd_bytes_l);
        axil_read(REG_RD_BYTES_H, rd_bytes_h);
        axil_read(REG_WR_BYTES_L, wr_bytes_l);
        axil_read(REG_WR_BYTES_H, wr_bytes_h);
        if ({rd_bytes_h, rd_bytes_l} == 64'd0) begin
            $display("FAIL RD_BYTES stayed zero");
            $fatal(1);
        end
        if ({wr_bytes_h, wr_bytes_l} == 64'd0) begin
            $display("FAIL WR_BYTES stayed zero");
            $fatal(1);
        end

        check_output_memory();
        dump_output_memory();

        axil_write(REG_STATUS, STATUS_DONE);
        repeat (4) @(posedge clk);
        axil_read(REG_STATUS, status_value);
        if ((status_value & STATUS_DONE) != 0) begin
            $display("FAIL STATUS.DONE did not clear status=%08h", status_value);
            $fatal(1);
        end

        $display("tb_flash_attn_top_e2e_smoke PASS S=%0d D=%0d BK=%0d BQ=%0d bitexact=%0d cycles=%0d wait_cycles=%0d rd_bytes=%0d wr_bytes=%0d",
                 S_LEN, D_MODEL, BK, BQ, CHECK_BITEXACT, cycles_value, wait_cycles,
                 {rd_bytes_h, rd_bytes_l}, {wr_bytes_h, wr_bytes_l});
        $finish;
    end
endmodule
