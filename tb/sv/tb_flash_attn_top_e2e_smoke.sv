`timescale 1ns/1ps

module tb_flash_attn_top_e2e_smoke;
    parameter int S_LEN          = 8;
    parameter int D_MODEL        = 8;
    parameter int BK             = 4;
    parameter int DATA_W         = 16;
    parameter int ACC_W          = 48;
    parameter int FRAC_W         = 8;
    parameter int AXI_DATA_W     = 64;
    parameter int SCALE_Q8_8     = 91;
    parameter int CHECK_BITEXACT = 1;
    parameter int TIMEOUT_CYCLES = 200000;
    parameter int VERBOSE        = 0;

    localparam int ADDR_W         = 64;
    localparam int AXI_BYTES      = AXI_DATA_W / 8;
    localparam int STRIDE_BYTES   = D_MODEL * 2;
    localparam int NUM_ELEMS      = S_LEN * D_MODEL;
    localparam int TENSOR_BYTES   = S_LEN * STRIDE_BYTES;
    localparam int REGION_GAP     = 4096;
    localparam int unsigned Q_BASE = 32'h0000_0000;
    localparam int unsigned K_BASE = Q_BASE + TENSOR_BYTES + REGION_GAP;
    localparam int unsigned V_BASE = K_BASE + TENSOR_BYTES + REGION_GAP;
    localparam int unsigned O_BASE = V_BASE + TENSOR_BYTES + REGION_GAP;
    localparam int O_INIT_PATTERN = 16'h5a5a;
    localparam int WEIGHT_FRAC    = 8;
    localparam int WEIGHT_ONE     = 1 << WEIGHT_FRAC;

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

    localparam logic [31:0] CTRL_START       = 32'h0000_0001;
    localparam logic [31:0] STATUS_BUSY      = 32'h0000_0001;
    localparam logic [31:0] STATUS_DONE      = 32'h0000_0002;
    localparam logic [31:0] STATUS_ERROR     = 32'h0000_0004;
    localparam logic [31:0] CFG_CAUSAL_EN    = 32'h0000_0001;

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

    logic [15:0] o_mem [0:NUM_ELEMS-1];
    logic [31:0] status_value;
    logic [31:0] cycles_value;
    int wait_cycles;
    bit saw_busy;
    int row;
    int col;
    int changed_count;

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
        .AXI_DATA_W(AXI_DATA_W)
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
                $display("MON t=%0t o_v=%0b o_r=%0b o_row=%0d core_done=%0b dma_state=%0d wr_req_v=%0b wr_req_r=%0b wr_data_v=%0b wr_data_r=%0b awv=%0b awr=%0b wv=%0b wr=%0b bv=%0b br=%0b overall_done=%0b",
                         $time, dut.o_valid, dut.o_ready, dut.o_row, dut.core_done,
                         dut.u_dma_controller.state_q, dut.wr_req_valid, dut.wr_req_ready,
                         dut.wr_data_valid, dut.wr_data_ready, m_axi_awvalid,
                         m_axi_awready, m_axi_wvalid, m_axi_wready, m_axi_bvalid,
                         m_axi_bready, dut.overall_done_pulse);
                $fflush();
            end
            if (dut.u_flash_core.state_q == 4'd7 && dut.u_flash_core.dot_done) begin
                $display("CORE dot row=%0d key=%0d score_valid=%0b dot=%0d scaled=%0d masked=%0d m=%0d l=%0d old_scale=%0d new_weight=%0d acc0_in=%0d acc0_next=%0d v0=%0d",
                         dut.u_flash_core.sched_row,
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
                $display("DMA rd state=%0d data=%016h last=%0b",
                         dut.u_dma_controller.state_q,
                         dut.rd_data,
                         dut.rd_last);
                $fflush();
            end
            if (dut.q_data_valid && dut.q_data_ready) begin
                $display("DMA q present q0=%0d q1=%0d buf0=%0d buf1=%0d",
                         dut.q_data[0],
                         dut.q_data[1],
                         dut.u_dma_controller.q_buf[0],
                         dut.u_dma_controller.q_buf[1]);
                $fflush();
            end
            if (dut.kv_data_valid && dut.kv_data_ready) begin
                $display("DMA kv present k00=%0d k01=%0d v00=%0d v01=%0d kbuf00=%0d kbuf01=%0d vbuf00=%0d vbuf01=%0d",
                         dut.k_tile[0][0],
                         dut.k_tile[0][1],
                         dut.v_tile[0][0],
                         dut.v_tile[0][1],
                         dut.u_dma_controller.k_buf[0][0],
                         dut.u_dma_controller.k_buf[0][1],
                         dut.u_dma_controller.v_buf[0][0],
                         dut.u_dma_controller.v_buf[0][1]);
                $fflush();
            end
            if (dut.u_flash_core.state_q == 4'd8) begin
                $display("CORE normalize row=%0d l=%0d acc0=%0d norm0=%0d acc1=%0d norm1=%0d",
                         dut.u_flash_core.sched_row,
                         dut.u_flash_core.l_state_q,
                         dut.u_flash_core.acc_state_q[0],
                         dut.u_flash_core.normalized_data[0],
                         dut.u_flash_core.acc_state_q[1],
                         dut.u_flash_core.normalized_data[1]);
                $fflush();
            end
            if (dut.u_flash_core.state_q == 4'd9) begin
                $display("CORE emit row=%0d o0=%0d o1=%0d flat=%0h",
                         dut.u_flash_core.o_row,
                         dut.u_flash_core.o_data_q[0],
                         dut.u_flash_core.o_data_q[1],
                         dut.o_data_flat);
                $fflush();
            end
        end
    end

    function automatic int signed q_value(input int in_row, input int in_col);
        begin
            q_value = ((((in_row * 3 + in_col * 5 + 7) % 17) - 8) <<< 4);
        end
    endfunction

    function automatic int signed k_value(input int key_row, input int in_col);
        begin
            k_value = ((((key_row * 5 + in_col * 7 + 11) % 19) - 9) <<< 4);
        end
    endfunction

    function automatic int signed v_value(input int key_row, input int in_col);
        begin
            v_value = ((((key_row * 7 + in_col * 3 + 5) % 23) - 11) <<< 3);
        end
    endfunction

    `include "flash_core_ref_exp_lut.svh"

    function automatic logic signed [DATA_W-1:0] saturate_to_data(input longint signed value);
        begin
            if (value > 32767) begin
                saturate_to_data = 16'sh7fff;
            end else if (value < -32768) begin
                saturate_to_data = 16'sh8000;
            end else begin
                saturate_to_data = value[DATA_W-1:0];
            end
        end
    endfunction

    function automatic longint signed scaled_score(input int in_row, input int key);
        longint signed dot;
        begin
            dot = 0;
            for (int c = 0; c < D_MODEL; c = c + 1) begin
                dot += q_value(in_row, c) * k_value(key, c);
            end
            scaled_score = ((dot >>> FRAC_W) * SCALE_Q8_8) >>> FRAC_W;
        end
    endfunction

    function automatic logic signed [DATA_W-1:0] expected_o(input int in_row, input int out_col);
        longint signed m;
        longint signed l;
        longint signed acc;
        longint signed score;
        longint signed old_scale;
        longint signed new_weight;
        begin
            m = 0;
            l = 0;
            acc = 0;

            for (int key = 0; key < S_LEN; key = key + 1) begin
                if (key <= in_row) begin
                    score = scaled_score(in_row, key);

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

                    acc = ((acc * old_scale) >>> WEIGHT_FRAC) +
                          (new_weight * v_value(key, out_col));
                end
            end

            expected_o = (l == 0) ? '0 : saturate_to_data(acc / l);
        end
    endfunction

    function automatic int elem_index(input int in_row, input int in_col);
        begin
            elem_index = in_row * D_MODEL + in_col;
        end
    endfunction

    function automatic int addr_to_elem(input int unsigned addr, input int unsigned base);
        begin
            addr_to_elem = (addr - base) / 2;
        end
    endfunction

    function automatic logic [15:0] source_value(input int source, input int idx);
        int r;
        int c;
        begin
            r = idx / D_MODEL;
            c = idx % D_MODEL;
            case (source)
                0: source_value = q_value(r, c) & 16'hffff;
                1: source_value = k_value(r, c) & 16'hffff;
                2: source_value = v_value(r, c) & 16'hffff;
                default: source_value = 16'h0000;
            endcase
        end
    endfunction

    function automatic logic [AXI_DATA_W-1:0] read_axi_word(input int unsigned addr);
        logic [AXI_DATA_W-1:0] word;
        int idx;
        begin
            word = '0;
            for (int lane = 0; lane < AXI_BYTES / 2; lane = lane + 1) begin
                if ((addr >= Q_BASE) && (addr < Q_BASE + TENSOR_BYTES)) begin
                    idx = addr_to_elem(addr, Q_BASE) + lane;
                    word[lane*16 +: 16] = source_value(0, idx);
                end else if ((addr >= K_BASE) && (addr < K_BASE + TENSOR_BYTES)) begin
                    idx = addr_to_elem(addr, K_BASE) + lane;
                    word[lane*16 +: 16] = source_value(1, idx);
                end else if ((addr >= V_BASE) && (addr < V_BASE + TENSOR_BYTES)) begin
                    idx = addr_to_elem(addr, V_BASE) + lane;
                    word[lane*16 +: 16] = source_value(2, idx);
                end else if ((addr >= O_BASE) && (addr < O_BASE + TENSOR_BYTES)) begin
                    idx = addr_to_elem(addr, O_BASE) + lane;
                    word[lane*16 +: 16] = o_mem[idx];
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
        begin
            if ((addr < O_BASE) || (addr >= O_BASE + TENSOR_BYTES)) begin
                $display("FAIL write outside O region addr=%0d", addr);
                $fatal(1);
            end

            for (int lane = 0; lane < AXI_BYTES / 2; lane = lane + 1) begin
                if (strb[lane * 2] || strb[lane * 2 + 1]) begin
                    idx = addr_to_elem(addr, O_BASE) + lane;
                    o_mem[idx] = data[lane*16 +: 16];
                end
            end
            if (VERBOSE != 0) begin
                $display("INFO AXI write addr=%0d data=%016h strb=%02h idx0=%0d dma_beat=%0d flat=%0h",
                         addr, data, strb, addr_to_elem(addr, O_BASE),
                         dut.u_dma_controller.beat_idx_q, dut.o_data_flat);
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
        end
    endtask

    task automatic check_output_memory;
        logic signed [15:0] got;
        logic signed [15:0] exp;
        int idx;
        begin
            changed_count = 0;
            for (int r = 0; r < S_LEN; r = r + 1) begin
                for (int c = 0; c < D_MODEL; c = c + 1) begin
                    idx = elem_index(r, c);
                    got = o_mem[idx];
                    if ((^got) === 1'bx) begin
                        $display("FAIL O[%0d][%0d] is X/Z", r, c);
                        $fatal(1);
                    end
                    changed_count++;
                    if (CHECK_BITEXACT != 0) begin
                        exp = expected_o(r, c);
                        if (got !== exp) begin
                            $display("FAIL TOP O[%0d][%0d] got=%0d hex=%04h expected=%0d hex=%04h",
                                     r, c, got, got, exp, exp);
                            $fatal(1);
                        end
                    end else if (r == 0) begin
                        exp = v_value(0, c);
                        if (got !== exp) begin
                            $display("FAIL TOP causal row0 O[0][%0d] got=%0d expected V[0][%0d]=%0d",
                                     c, got, c, exp);
                            $fatal(1);
                        end
                    end
                end
            end

            if (changed_count != NUM_ELEMS) begin
                $display("FAIL changed output count=%0d expected=%0d", changed_count, NUM_ELEMS);
                $fatal(1);
            end
        end
    endtask

    initial begin
        if (VERBOSE != 0) begin
            $display("INFO top e2e initial entered");
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

        check_output_memory();

        axil_write(REG_STATUS, STATUS_DONE);
        repeat (4) @(posedge clk);
        axil_read(REG_STATUS, status_value);
        if ((status_value & STATUS_DONE) != 0) begin
            $display("FAIL STATUS.DONE did not clear status=%08h", status_value);
            $fatal(1);
        end

        $display("tb_flash_attn_top_e2e_smoke PASS S=%0d D=%0d BK=%0d bitexact=%0d cycles=%0d wait_cycles=%0d",
                 S_LEN, D_MODEL, BK, CHECK_BITEXACT, cycles_value, wait_cycles);
        $finish;
    end
endmodule
