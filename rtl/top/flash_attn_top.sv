`timescale 1ns/1ps

module flash_attn_top #(
    parameter int S_LEN      = 256,
    parameter int D_MODEL    = 64,
    parameter int BK         = 16,
    parameter int DATA_W     = 16,
    parameter int FRAC_W     = 8,
    parameter int ACC_W      = 36,
    parameter int ADDR_W     = 64,
    parameter int AXI_DATA_W = 64,
    parameter int BQ         = 16,
    parameter int USE_DOT_TREE    = 1,
    parameter int DOT_LANES       = 32,
    parameter int USE_CAUSAL_SKIP = 1,
    parameter int SOFTMAX_FRAC    = 16,
    parameter int FP8_E4M3_MODE   = 0,
    parameter int BF16_IO_MODE    = 0,
    parameter int STATIC_SCALE_MODE = 1,
    parameter int STATIC_SCALE_Q8_8 = 32,
    parameter int ENABLE_DROPOUT    = 0
) (
    input  logic clk,
    input  logic rst_n,

    input  logic [31:0] s_axil_awaddr,
    input  logic        s_axil_awvalid,
    output logic        s_axil_awready,

    input  logic [31:0] s_axil_wdata,
    input  logic [3:0]  s_axil_wstrb,
    input  logic        s_axil_wvalid,
    output logic        s_axil_wready,

    output logic [1:0]  s_axil_bresp,
    output logic        s_axil_bvalid,
    input  logic        s_axil_bready,

    input  logic [31:0] s_axil_araddr,
    input  logic        s_axil_arvalid,
    output logic        s_axil_arready,

    output logic [31:0] s_axil_rdata,
    output logic [1:0]  s_axil_rresp,
    output logic        s_axil_rvalid,
    input  logic        s_axil_rready,

    output logic [ADDR_W-1:0] m_axi_araddr,
    output logic [7:0]        m_axi_arlen,
    output logic [2:0]        m_axi_arsize,
    output logic [1:0]        m_axi_arburst,
    output logic              m_axi_arvalid,
    input  logic              m_axi_arready,

    input  logic [AXI_DATA_W-1:0] m_axi_rdata,
    input  logic [1:0]            m_axi_rresp,
    input  logic                  m_axi_rlast,
    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready,

    output logic [ADDR_W-1:0] m_axi_awaddr,
    output logic [7:0]        m_axi_awlen,
    output logic [2:0]        m_axi_awsize,
    output logic [1:0]        m_axi_awburst,
    output logic              m_axi_awvalid,
    input  logic              m_axi_awready,

    output logic [AXI_DATA_W-1:0]   m_axi_wdata,
    output logic [AXI_DATA_W/8-1:0] m_axi_wstrb,
    output logic                    m_axi_wlast,
    output logic                    m_axi_wvalid,
    input  logic                    m_axi_wready,

    input  logic [1:0] m_axi_bresp,
    input  logic       m_axi_bvalid,
    output logic       m_axi_bready,

    output logic irq
);

    localparam int CORE_DATA_W = ((FP8_E4M3_MODE != 0) || (BF16_IO_MODE != 0)) ? 16 : DATA_W;
    localparam int CORE_FRAC_W = ((FP8_E4M3_MODE != 0) || (BF16_IO_MODE != 0)) ? 8 : FRAC_W;

    logic start_pulse;
    logic soft_reset;
    logic irq_en;
    logic causal_en;
    logic [63:0] q_base;
    logic [63:0] k_base;
    logic [63:0] v_base;
    logic [63:0] o_base;
    logic [31:0] stride_bytes;
    logic signed [31:0] neg_large;
    logic signed [31:0] scale;
    logic [31:0] valid_len;
    logic [31:0] task_count;
    logic [31:0] task_stride_bytes;
    logic dropout_en;
    logic [15:0] dropout_threshold;
    logic [15:0] dropout_seed;
    logic [15:0] dropout_scale_q8_8;
    logic [31:0] head_count;
    logic [31:0] head_stride_bytes;
    logic [31:0] cycle_count_q;
    logic [63:0] rd_bytes_count_q;
    logic [63:0] wr_bytes_count_q;
    logic irq_int;

    logic core_busy;
    logic core_done;
    logic core_error;

    logic dma_busy;
    logic dma_done;
    logic dma_error;

    logic q_req_valid;
    logic [$clog2(S_LEN)-1:0] q_req_row;
    logic q_req_ready;
    logic q_data_valid;
    logic signed [CORE_DATA_W-1:0] q_data [0:D_MODEL-1];
    logic [D_MODEL*CORE_DATA_W-1:0] q_data_flat;
    logic q_data_ready;

    logic kv_req_valid;
    logic [$clog2(S_LEN)-1:0] kv_req_start;
    logic [$clog2(BK+1)-1:0]  kv_req_len;
    logic kv_req_ready;
    logic kv_data_valid;
    logic signed [CORE_DATA_W-1:0] k_tile [0:BK-1][0:D_MODEL-1];
    logic signed [CORE_DATA_W-1:0] v_tile [0:BK-1][0:D_MODEL-1];
    logic [BK*D_MODEL*CORE_DATA_W-1:0] k_tile_flat;
    logic [BK*D_MODEL*CORE_DATA_W-1:0] v_tile_flat;
    logic kv_data_ready;

    logic o_valid;
    logic [$clog2(S_LEN)-1:0] o_row;
    logic signed [CORE_DATA_W-1:0] o_data [0:D_MODEL-1];
    logic [D_MODEL*CORE_DATA_W-1:0] o_data_flat;
    logic o_ready;

    logic rd_req_valid;
    logic [ADDR_W-1:0] rd_req_addr;
    logic [31:0]       rd_req_bytes;
    logic rd_req_ready;
    logic rd_data_valid;
    logic [AXI_DATA_W-1:0] rd_data;
    logic rd_last;
    logic rd_data_ready;
    logic rd_busy;
    logic rd_done;
    logic rd_error;

    logic wr_req_valid;
    logic [ADDR_W-1:0] wr_req_addr;
    logic [31:0]       wr_req_bytes;
    logic wr_req_ready;
    logic wr_data_valid;
    logic [AXI_DATA_W-1:0] wr_data;
    logic wr_last;
    logic wr_data_ready;
    logic wr_busy;
    logic wr_done;
    logic wr_error;

    logic work_rst_n;
    logic run_active_q;
    logic core_done_seen_q;
    logic task_continue_pulse_q;
    logic task_start_pulse;
    logic [31:0] task_index_q;
    logic [31:0] head_index_q;
    logic [31:0] task_count_eff;
    logic [31:0] head_count_eff;
    logic [63:0] task_offset_q;
    logic [63:0] head_offset_q;
    logic [63:0] q_base_eff;
    logic [63:0] k_base_eff;
    logic [63:0] v_base_eff;
    logic [63:0] o_base_eff;
    logic current_task_done_pulse;
    logic last_task_done_pulse;
    logic overall_busy;
    logic overall_done_pulse;
    logic overall_error;
    integer comb_row;
    integer comb_col;

    assign work_rst_n = rst_n && !soft_reset;
    assign irq        = irq_int;

    assign overall_busy       = run_active_q || core_busy || dma_busy || rd_busy || wr_busy;
    assign current_task_done_pulse = run_active_q && core_done_seen_q && !dma_busy && !rd_busy && !wr_busy;
    assign last_task_done_pulse = current_task_done_pulse &&
                                  ((head_index_q + 32'd1) >= head_count_eff) &&
                                  ((task_index_q + 32'd1) >= task_count_eff);
    assign overall_done_pulse = last_task_done_pulse;
    assign overall_error      = core_error || dma_error || rd_error || wr_error;
    assign task_count_eff     = (task_count == 32'd0) ? 32'd1 : task_count;
    assign head_count_eff     = (head_count == 32'd0) ? 32'd1 : head_count;
    assign q_base_eff         = q_base + task_offset_q + head_offset_q;
    assign k_base_eff         = k_base + task_offset_q + head_offset_q;
    assign v_base_eff         = v_base + task_offset_q + head_offset_q;
    assign o_base_eff         = o_base + task_offset_q + head_offset_q;
    assign task_start_pulse   = start_pulse || task_continue_pulse_q;

    always_comb begin
        for (comb_col = 0; comb_col < D_MODEL; comb_col = comb_col + 1) begin
            q_data[comb_col] = q_data_flat[comb_col * CORE_DATA_W +: CORE_DATA_W];
            o_data[comb_col] = o_data_flat[comb_col * CORE_DATA_W +: CORE_DATA_W];
        end
        for (comb_row = 0; comb_row < BK; comb_row = comb_row + 1) begin
            for (comb_col = 0; comb_col < D_MODEL; comb_col = comb_col + 1) begin
                k_tile[comb_row][comb_col] =
                    k_tile_flat[((comb_row * D_MODEL + comb_col) * CORE_DATA_W) +: CORE_DATA_W];
                v_tile[comb_row][comb_col] =
                    v_tile_flat[((comb_row * D_MODEL + comb_col) * CORE_DATA_W) +: CORE_DATA_W];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run_active_q     <= 1'b0;
            core_done_seen_q <= 1'b0;
            task_continue_pulse_q <= 1'b0;
            task_index_q     <= 32'd0;
            head_index_q     <= 32'd0;
            task_offset_q    <= 64'd0;
            head_offset_q    <= 64'd0;
            cycle_count_q    <= 32'd0;
            rd_bytes_count_q <= 64'd0;
            wr_bytes_count_q <= 64'd0;
        end else if (soft_reset) begin
            run_active_q     <= 1'b0;
            core_done_seen_q <= 1'b0;
            task_continue_pulse_q <= 1'b0;
            task_index_q     <= 32'd0;
            head_index_q     <= 32'd0;
            task_offset_q    <= 64'd0;
            head_offset_q    <= 64'd0;
            cycle_count_q    <= 32'd0;
            rd_bytes_count_q <= 64'd0;
            wr_bytes_count_q <= 64'd0;
        end else begin
            task_continue_pulse_q <= 1'b0;

            if (start_pulse) begin
                run_active_q     <= 1'b1;
                core_done_seen_q <= 1'b0;
                task_index_q     <= 32'd0;
                head_index_q     <= 32'd0;
                task_offset_q    <= 64'd0;
                head_offset_q    <= 64'd0;
                cycle_count_q    <= 32'd0;
                rd_bytes_count_q <= 64'd0;
                wr_bytes_count_q <= 64'd0;
            end else begin
                if (current_task_done_pulse) begin
                    core_done_seen_q <= 1'b0;
                    if (last_task_done_pulse) begin
                        run_active_q <= 1'b0;
                    end else if ((head_index_q + 32'd1) < head_count_eff) begin
                        head_index_q <= head_index_q + 32'd1;
                        head_offset_q <= head_offset_q + {32'd0, head_stride_bytes};
                        task_continue_pulse_q <= 1'b1;
                    end else begin
                        task_index_q <= task_index_q + 32'd1;
                        task_offset_q <= task_offset_q + {32'd0, task_stride_bytes};
                        head_index_q <= 32'd0;
                        head_offset_q <= 64'd0;
                        task_continue_pulse_q <= 1'b1;
                    end
                end
                if (overall_done_pulse) begin
                    run_active_q <= 1'b0;
                end
                if (run_active_q && !overall_done_pulse) begin
                    cycle_count_q <= cycle_count_q + 1'b1;
                end
            end

            if (rd_req_valid && rd_req_ready) begin
                rd_bytes_count_q <= rd_bytes_count_q + rd_req_bytes;
            end
            if (wr_req_valid && wr_req_ready) begin
                wr_bytes_count_q <= wr_bytes_count_q + wr_req_bytes;
            end

            if (core_done) begin
                core_done_seen_q <= 1'b1;
            end
            if (overall_done_pulse) begin
                core_done_seen_q <= 1'b0;
            end
        end
    end

    axi_lite_regs #(
        .ADDR_W(32),
        .DATA_W(32),
        .S_LEN(S_LEN),
        .D_MODEL(D_MODEL)
    ) u_axi_lite_regs (
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
        .start_pulse(start_pulse),
        .soft_reset(soft_reset),
        .irq_en(irq_en),
        .causal_en(causal_en),
        .q_base(q_base),
        .k_base(k_base),
        .v_base(v_base),
        .o_base(o_base),
        .stride_bytes(stride_bytes),
        .neg_large(neg_large),
        .scale(scale),
        .valid_len(valid_len),
        .task_count(task_count),
        .task_stride_bytes(task_stride_bytes),
        .dropout_en(dropout_en),
        .dropout_threshold(dropout_threshold),
        .dropout_seed(dropout_seed),
        .dropout_scale_q8_8(dropout_scale_q8_8),
        .head_count(head_count),
        .head_stride_bytes(head_stride_bytes),
        .busy(overall_busy),
        .done(overall_done_pulse),
        .error(overall_error),
        .cycles(cycle_count_q),
        .rd_bytes(rd_bytes_count_q),
        .wr_bytes(wr_bytes_count_q),
        .irq(irq_int)
    );

    flash_core #(
        .S_LEN(S_LEN),
        .D_MODEL(D_MODEL),
        .BK(BK),
        .DATA_W(CORE_DATA_W),
        .ACC_W(ACC_W),
        .FRAC_W(CORE_FRAC_W),
        .BQ(BQ),
        .USE_DOT_TREE(USE_DOT_TREE),
        .DOT_LANES(DOT_LANES),
        .USE_CAUSAL_SKIP(USE_CAUSAL_SKIP),
        .SOFTMAX_FRAC(SOFTMAX_FRAC),
        .STATIC_SCALE_MODE(STATIC_SCALE_MODE),
        .STATIC_SCALE_Q8_8(STATIC_SCALE_Q8_8),
        .ENABLE_DROPOUT(ENABLE_DROPOUT)
    ) u_flash_core (
        .clk(clk),
        .rst_n(work_rst_n),
        .start(task_start_pulse),
        .busy(core_busy),
        .done(core_done),
        .error(core_error),
        .causal_en(causal_en),
        .neg_large(neg_large),
        .scale(scale),
        .valid_len(valid_len),
        .dropout_en(dropout_en),
        .dropout_threshold(dropout_threshold),
        .dropout_seed(dropout_seed),
        .dropout_scale_q8_8(dropout_scale_q8_8),
        .q_req_valid(q_req_valid),
        .q_req_row(q_req_row),
        .q_req_ready(q_req_ready),
        .q_data_valid(q_data_valid),
        .q_data(q_data),
        .q_data_ready(q_data_ready),
        .kv_req_valid(kv_req_valid),
        .kv_req_start(kv_req_start),
        .kv_req_len(kv_req_len),
        .kv_req_ready(kv_req_ready),
        .kv_data_valid(kv_data_valid),
        .k_tile(k_tile),
        .v_tile(v_tile),
        .kv_data_ready(kv_data_ready),
        .o_valid(o_valid),
        .o_row(o_row),
        .o_data(),
        .o_data_flat(o_data_flat),
        .o_ready(o_ready)
    );

    generate
        if (BF16_IO_MODE != 0) begin : gen_bf16_dma
            dma_controller_bf16 #(
                .S_LEN(S_LEN),
                .ADDR_W(ADDR_W),
                .CORE_DATA_W(CORE_DATA_W),
                .D_MODEL(D_MODEL),
                .BK(BK),
                .AXI_DATA_W(AXI_DATA_W)
            ) u_dma_controller (
                .clk(clk),
                .rst_n(work_rst_n),
                .start(task_start_pulse),
                .busy(dma_busy),
                .done(dma_done),
                .error(dma_error),
                .q_base(q_base_eff),
                .k_base(k_base_eff),
                .v_base(v_base_eff),
                .o_base(o_base_eff),
                .stride_bytes(stride_bytes),
                .q_req_valid(q_req_valid),
                .q_req_row(q_req_row),
                .q_req_ready(q_req_ready),
                .q_data_valid(q_data_valid),
                .q_data(),
                .q_data_flat(q_data_flat),
                .q_data_ready(q_data_ready),
                .kv_req_valid(kv_req_valid),
                .kv_req_start(kv_req_start),
                .kv_req_len(kv_req_len),
                .kv_req_ready(kv_req_ready),
                .kv_data_valid(kv_data_valid),
                .k_tile(),
                .v_tile(),
                .k_tile_flat(k_tile_flat),
                .v_tile_flat(v_tile_flat),
                .kv_data_ready(kv_data_ready),
                .o_valid(o_valid),
                .o_row(o_row),
                .o_data(o_data),
                .o_data_flat(o_data_flat),
                .o_ready(o_ready),
                .rd_req_valid(rd_req_valid),
                .rd_req_addr(rd_req_addr),
                .rd_req_bytes(rd_req_bytes),
                .rd_req_ready(rd_req_ready),
                .rd_data_valid(rd_data_valid),
                .rd_data(rd_data),
                .rd_last(rd_last),
                .rd_data_ready(rd_data_ready),
                .wr_req_valid(wr_req_valid),
                .wr_req_addr(wr_req_addr),
                .wr_req_bytes(wr_req_bytes),
                .wr_req_ready(wr_req_ready),
                .wr_data_valid(wr_data_valid),
                .wr_data(wr_data),
                .wr_last(wr_last),
                .wr_data_ready(wr_data_ready)
            );
        end else if (FP8_E4M3_MODE != 0) begin : gen_fp8_dma
            dma_controller_fp8 #(
                .S_LEN(S_LEN),
                .ADDR_W(ADDR_W),
                .CORE_DATA_W(CORE_DATA_W),
                .D_MODEL(D_MODEL),
                .BK(BK),
                .AXI_DATA_W(AXI_DATA_W)
            ) u_dma_controller (
                .clk(clk),
                .rst_n(work_rst_n),
                .start(task_start_pulse),
                .busy(dma_busy),
                .done(dma_done),
                .error(dma_error),
                .q_base(q_base_eff),
                .k_base(k_base_eff),
                .v_base(v_base_eff),
                .o_base(o_base_eff),
                .stride_bytes(stride_bytes),
                .q_req_valid(q_req_valid),
                .q_req_row(q_req_row),
                .q_req_ready(q_req_ready),
                .q_data_valid(q_data_valid),
                .q_data(),
                .q_data_flat(q_data_flat),
                .q_data_ready(q_data_ready),
                .kv_req_valid(kv_req_valid),
                .kv_req_start(kv_req_start),
                .kv_req_len(kv_req_len),
                .kv_req_ready(kv_req_ready),
                .kv_data_valid(kv_data_valid),
                .k_tile(),
                .v_tile(),
                .k_tile_flat(k_tile_flat),
                .v_tile_flat(v_tile_flat),
                .kv_data_ready(kv_data_ready),
                .o_valid(o_valid),
                .o_row(o_row),
                .o_data(o_data),
                .o_data_flat(o_data_flat),
                .o_ready(o_ready),
                .rd_req_valid(rd_req_valid),
                .rd_req_addr(rd_req_addr),
                .rd_req_bytes(rd_req_bytes),
                .rd_req_ready(rd_req_ready),
                .rd_data_valid(rd_data_valid),
                .rd_data(rd_data),
                .rd_last(rd_last),
                .rd_data_ready(rd_data_ready),
                .wr_req_valid(wr_req_valid),
                .wr_req_addr(wr_req_addr),
                .wr_req_bytes(wr_req_bytes),
                .wr_req_ready(wr_req_ready),
                .wr_data_valid(wr_data_valid),
                .wr_data(wr_data),
                .wr_last(wr_last),
                .wr_data_ready(wr_data_ready)
            );
        end else begin : gen_fixed_dma
            dma_controller #(
                .S_LEN(S_LEN),
                .ADDR_W(ADDR_W),
                .DATA_W(CORE_DATA_W),
                .D_MODEL(D_MODEL),
                .BK(BK),
                .AXI_DATA_W(AXI_DATA_W)
            ) u_dma_controller (
                .clk(clk),
                .rst_n(work_rst_n),
                .start(task_start_pulse),
                .busy(dma_busy),
                .done(dma_done),
                .error(dma_error),
                .q_base(q_base_eff),
                .k_base(k_base_eff),
                .v_base(v_base_eff),
                .o_base(o_base_eff),
                .stride_bytes(stride_bytes),
                .q_req_valid(q_req_valid),
                .q_req_row(q_req_row),
                .q_req_ready(q_req_ready),
                .q_data_valid(q_data_valid),
                .q_data(),
                .q_data_flat(q_data_flat),
                .q_data_ready(q_data_ready),
                .kv_req_valid(kv_req_valid),
                .kv_req_start(kv_req_start),
                .kv_req_len(kv_req_len),
                .kv_req_ready(kv_req_ready),
                .kv_data_valid(kv_data_valid),
                .k_tile(),
                .v_tile(),
                .k_tile_flat(k_tile_flat),
                .v_tile_flat(v_tile_flat),
                .kv_data_ready(kv_data_ready),
                .o_valid(o_valid),
                .o_row(o_row),
                .o_data(o_data),
                .o_data_flat(o_data_flat),
                .o_ready(o_ready),
                .rd_req_valid(rd_req_valid),
                .rd_req_addr(rd_req_addr),
                .rd_req_bytes(rd_req_bytes),
                .rd_req_ready(rd_req_ready),
                .rd_data_valid(rd_data_valid),
                .rd_data(rd_data),
                .rd_last(rd_last),
                .rd_data_ready(rd_data_ready),
                .wr_req_valid(wr_req_valid),
                .wr_req_addr(wr_req_addr),
                .wr_req_bytes(wr_req_bytes),
                .wr_req_ready(wr_req_ready),
                .wr_data_valid(wr_data_valid),
                .wr_data(wr_data),
                .wr_last(wr_last),
                .wr_data_ready(wr_data_ready)
            );
        end
    endgenerate

    axi_master_read #(
        .ADDR_W(ADDR_W),
        .AXI_DATA_W(AXI_DATA_W)
    ) u_axi_master_read (
        .clk(clk),
        .rst_n(work_rst_n),
        .req_valid(rd_req_valid),
        .req_addr(rd_req_addr),
        .req_bytes(rd_req_bytes),
        .req_ready(rd_req_ready),
        .data_valid(rd_data_valid),
        .data(rd_data),
        .data_last(rd_last),
        .data_ready(rd_data_ready),
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
        .busy(rd_busy),
        .done(rd_done),
        .error(rd_error)
    );

    axi_master_write #(
        .ADDR_W(ADDR_W),
        .AXI_DATA_W(AXI_DATA_W)
    ) u_axi_master_write (
        .clk(clk),
        .rst_n(work_rst_n),
        .req_valid(wr_req_valid),
        .req_addr(wr_req_addr),
        .req_bytes(wr_req_bytes),
        .req_ready(wr_req_ready),
        .data_valid(wr_data_valid),
        .data(wr_data),
        .data_last(wr_last),
        .data_ready(wr_data_ready),
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
        .busy(wr_busy),
        .done(wr_done),
        .error(wr_error)
    );

endmodule
