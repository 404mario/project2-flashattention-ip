`timescale 1ns/1ps

module axi_lite_regs #(
    parameter int ADDR_W  = 32,
    parameter int DATA_W  = 32,
    parameter int S_LEN   = 256,
    parameter int D_MODEL = 64
) (
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic [ADDR_W-1:0]    s_axil_awaddr,
    input  logic                 s_axil_awvalid,
    output logic                 s_axil_awready,

    input  logic [DATA_W-1:0]    s_axil_wdata,
    input  logic [DATA_W/8-1:0]  s_axil_wstrb,
    input  logic                 s_axil_wvalid,
    output logic                 s_axil_wready,

    output logic [1:0]           s_axil_bresp,
    output logic                 s_axil_bvalid,
    input  logic                 s_axil_bready,

    input  logic [ADDR_W-1:0]    s_axil_araddr,
    input  logic                 s_axil_arvalid,
    output logic                 s_axil_arready,

    output logic [DATA_W-1:0]    s_axil_rdata,
    output logic [1:0]           s_axil_rresp,
    output logic                 s_axil_rvalid,
    input  logic                 s_axil_rready,

    output logic                 start_pulse,
    output logic                 soft_reset,
    output logic                 irq_en,
    output logic                 causal_en,

    output logic [63:0]          q_base,
    output logic [63:0]          k_base,
    output logic [63:0]          v_base,
    output logic [63:0]          o_base,

    output logic [31:0]          stride_bytes,
    output logic signed [31:0]   neg_large,
    output logic signed [31:0]   scale,
    output logic [31:0]          valid_len,
    output logic [31:0]          task_count,
    output logic [31:0]          task_stride_bytes,
    output logic                 dropout_en,
    output logic [15:0]          dropout_threshold,
    output logic [15:0]          dropout_seed,
    output logic [15:0]          dropout_scale_q8_8,

    input  logic                 busy,
    input  logic                 done,
    input  logic                 error,
    input  logic [31:0]          cycles,
    input  logic [63:0]          rd_bytes,
    input  logic [63:0]          wr_bytes,

    output logic                 irq
);

    localparam logic [ADDR_W-1:0] REG_CTRL         = 'h00;
    localparam logic [ADDR_W-1:0] REG_STATUS       = 'h04;
    localparam logic [ADDR_W-1:0] REG_CFG          = 'h08;
    localparam logic [ADDR_W-1:0] REG_Q_BASE_L     = 'h14;
    localparam logic [ADDR_W-1:0] REG_Q_BASE_H     = 'h18;
    localparam logic [ADDR_W-1:0] REG_K_BASE_L     = 'h1C;
    localparam logic [ADDR_W-1:0] REG_K_BASE_H     = 'h20;
    localparam logic [ADDR_W-1:0] REG_V_BASE_L     = 'h24;
    localparam logic [ADDR_W-1:0] REG_V_BASE_H     = 'h28;
    localparam logic [ADDR_W-1:0] REG_O_BASE_L     = 'h2C;
    localparam logic [ADDR_W-1:0] REG_O_BASE_H     = 'h30;
    localparam logic [ADDR_W-1:0] REG_STRIDE_BYTES = 'h34;
    localparam logic [ADDR_W-1:0] REG_NEG_LARGE    = 'h38;
    localparam logic [ADDR_W-1:0] REG_SCALE        = 'h3C;
    localparam logic [ADDR_W-1:0] REG_CYCLES       = 'h40;
    localparam logic [ADDR_W-1:0] REG_RD_BYTES_L   = 'h44;
    localparam logic [ADDR_W-1:0] REG_RD_BYTES_H   = 'h48;
    localparam logic [ADDR_W-1:0] REG_WR_BYTES_L   = 'h4C;
    localparam logic [ADDR_W-1:0] REG_WR_BYTES_H   = 'h50;
    localparam logic [ADDR_W-1:0] REG_VALID_LEN    = 'h54;
    localparam logic [ADDR_W-1:0] REG_TASK_COUNT   = 'h58;
    localparam logic [ADDR_W-1:0] REG_TASK_STRIDE  = 'h5C;
    localparam logic [ADDR_W-1:0] REG_DROPOUT_CFG  = 'h60;
    localparam logic [ADDR_W-1:0] REG_DROPOUT_SEED = 'h64;
    localparam logic [ADDR_W-1:0] REG_DROPOUT_SCALE = 'h68;

    localparam logic signed [31:0] DEFAULT_NEG_LARGE = -32'sd32768;
    localparam logic signed [31:0] DEFAULT_SCALE     =  32'sd32; // 0.125 in Q8.8
    localparam logic [31:0]        DEFAULT_STRIDE    = D_MODEL * 2;
    localparam logic [31:0]        DEFAULT_VALID_LEN = S_LEN;
    localparam logic [31:0]        DEFAULT_TASK_COUNT = 32'd1;
    localparam logic [31:0]        DEFAULT_TASK_STRIDE = S_LEN * D_MODEL * 2;
    localparam logic [15:0]        DEFAULT_DROPOUT_THRESHOLD = 16'd0;
    localparam logic [15:0]        DEFAULT_DROPOUT_SEED = 16'hace1;
    localparam logic [15:0]        DEFAULT_DROPOUT_SCALE = 16'd256;

    logic [ADDR_W-1:0] awaddr_q;
    logic [DATA_W-1:0] wdata_q;
    logic [DATA_W/8-1:0] wstrb_q;
    logic awaddr_valid_q;
    logic wdata_valid_q;

    logic [ADDR_W-1:0] raddr_q;

    logic irq_en_q;
    logic causal_en_q;
    logic [63:0] q_base_q;
    logic [63:0] k_base_q;
    logic [63:0] v_base_q;
    logic [63:0] o_base_q;
    logic [31:0] stride_bytes_q;
    logic signed [31:0] neg_large_q;
    logic signed [31:0] scale_q;
    logic [31:0] valid_len_q;
    logic [31:0] task_count_q;
    logic [31:0] task_stride_bytes_q;
    logic dropout_en_q;
    logic [15:0] dropout_threshold_q;
    logic [15:0] dropout_seed_q;
    logic [15:0] dropout_scale_q8_8_q;
    logic [31:0] dropout_cfg_wr_value;
    logic [31:0] dropout_seed_wr_value;
    logic [31:0] dropout_scale_wr_value;

    logic done_sticky_q;
    logic error_sticky_q;

    function automatic logic [31:0] apply_wstrb32(
        input logic [31:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0]  strb
    );
        logic [31:0] merged;
        integer byte_i;
        begin
            merged = old_value;
            for (byte_i = 0; byte_i < 4; byte_i = byte_i + 1) begin
                if (strb[byte_i]) begin
                    merged[byte_i*8 +: 8] = new_value[byte_i*8 +: 8];
                end
            end
            apply_wstrb32 = merged;
        end
    endfunction

    assign s_axil_awready = !awaddr_valid_q && !s_axil_bvalid;
    assign s_axil_wready  = !wdata_valid_q  && !s_axil_bvalid;
    assign s_axil_bresp   = 2'b00;
    assign s_axil_arready = !s_axil_rvalid;
    assign s_axil_rresp   = 2'b00;

    assign irq_en      = irq_en_q;
    assign causal_en   = causal_en_q;
    assign q_base      = q_base_q;
    assign k_base      = k_base_q;
    assign v_base      = v_base_q;
    assign o_base      = o_base_q;
    assign stride_bytes = stride_bytes_q;
    assign neg_large   = neg_large_q;
    assign scale       = scale_q;
    assign valid_len   = valid_len_q;
    assign task_count  = task_count_q;
    assign task_stride_bytes = task_stride_bytes_q;
    assign dropout_en = dropout_en_q;
    assign dropout_threshold = dropout_threshold_q;
    assign dropout_seed = dropout_seed_q;
    assign dropout_scale_q8_8 = dropout_scale_q8_8_q;
    assign irq         = irq_en_q && done_sticky_q;
    assign dropout_cfg_wr_value =
        apply_wstrb32({dropout_threshold_q, 15'd0, dropout_en_q}, wdata_q, wstrb_q);
    assign dropout_seed_wr_value = apply_wstrb32({16'd0, dropout_seed_q}, wdata_q, wstrb_q);
    assign dropout_scale_wr_value = apply_wstrb32({16'd0, dropout_scale_q8_8_q}, wdata_q, wstrb_q);

    always @* begin
        s_axil_rdata = '0;
        unique case (raddr_q)
            REG_CTRL: begin
                s_axil_rdata[2] = irq_en_q;
            end
            REG_STATUS: begin
                s_axil_rdata[0] = busy;
                s_axil_rdata[1] = done_sticky_q;
                s_axil_rdata[2] = error_sticky_q;
            end
            REG_CFG: begin
                s_axil_rdata[0] = causal_en_q;
            end
            REG_Q_BASE_L:      s_axil_rdata = q_base_q[31:0];
            REG_Q_BASE_H:      s_axil_rdata = q_base_q[63:32];
            REG_K_BASE_L:      s_axil_rdata = k_base_q[31:0];
            REG_K_BASE_H:      s_axil_rdata = k_base_q[63:32];
            REG_V_BASE_L:      s_axil_rdata = v_base_q[31:0];
            REG_V_BASE_H:      s_axil_rdata = v_base_q[63:32];
            REG_O_BASE_L:      s_axil_rdata = o_base_q[31:0];
            REG_O_BASE_H:      s_axil_rdata = o_base_q[63:32];
            REG_STRIDE_BYTES:  s_axil_rdata = stride_bytes_q;
            REG_NEG_LARGE:     s_axil_rdata = neg_large_q;
            REG_SCALE:         s_axil_rdata = scale_q;
            REG_CYCLES:        s_axil_rdata = cycles;
            REG_RD_BYTES_L:    s_axil_rdata = rd_bytes[31:0];
            REG_RD_BYTES_H:    s_axil_rdata = rd_bytes[63:32];
            REG_WR_BYTES_L:    s_axil_rdata = wr_bytes[31:0];
            REG_WR_BYTES_H:    s_axil_rdata = wr_bytes[63:32];
            REG_VALID_LEN:     s_axil_rdata = valid_len_q;
            REG_TASK_COUNT:    s_axil_rdata = task_count_q;
            REG_TASK_STRIDE:   s_axil_rdata = task_stride_bytes_q;
            REG_DROPOUT_CFG: begin
                s_axil_rdata[0] = dropout_en_q;
                s_axil_rdata[31:16] = dropout_threshold_q;
            end
            REG_DROPOUT_SEED:  s_axil_rdata = {16'd0, dropout_seed_q};
            REG_DROPOUT_SCALE: s_axil_rdata = {16'd0, dropout_scale_q8_8_q};
            default:           s_axil_rdata = '0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            awaddr_q        <= '0;
            wdata_q         <= '0;
            wstrb_q         <= '0;
            awaddr_valid_q  <= 1'b0;
            wdata_valid_q   <= 1'b0;
            raddr_q         <= '0;
            s_axil_bvalid   <= 1'b0;
            s_axil_rvalid   <= 1'b0;

            start_pulse     <= 1'b0;
            soft_reset      <= 1'b0;

            irq_en_q        <= 1'b0;
            causal_en_q     <= 1'b0;
            q_base_q        <= 64'd0;
            k_base_q        <= 64'd0;
            v_base_q        <= 64'd0;
            o_base_q        <= 64'd0;
            stride_bytes_q  <= DEFAULT_STRIDE;
            neg_large_q     <= DEFAULT_NEG_LARGE;
            scale_q         <= DEFAULT_SCALE;
            valid_len_q     <= DEFAULT_VALID_LEN;
            task_count_q    <= DEFAULT_TASK_COUNT;
            task_stride_bytes_q <= DEFAULT_TASK_STRIDE;
            dropout_en_q    <= 1'b0;
            dropout_threshold_q <= DEFAULT_DROPOUT_THRESHOLD;
            dropout_seed_q  <= DEFAULT_DROPOUT_SEED;
            dropout_scale_q8_8_q <= DEFAULT_DROPOUT_SCALE;
            done_sticky_q   <= 1'b0;
            error_sticky_q  <= 1'b0;
        end else begin
            start_pulse <= 1'b0;
            soft_reset  <= 1'b0;

            if (done) begin
                done_sticky_q <= 1'b1;
            end
            if (error) begin
                error_sticky_q <= 1'b1;
            end

            if (s_axil_awvalid && s_axil_awready) begin
                awaddr_q       <= s_axil_awaddr;
                awaddr_valid_q <= 1'b1;
            end

            if (s_axil_wvalid && s_axil_wready) begin
                wdata_q       <= s_axil_wdata;
                wstrb_q       <= s_axil_wstrb;
                wdata_valid_q <= 1'b1;
            end

            if (awaddr_valid_q && wdata_valid_q && !s_axil_bvalid) begin
                unique case (awaddr_q)
                    REG_CTRL: begin
                        if ((apply_wstrb32(32'd0, wdata_q, wstrb_q) & 32'h0000_0001) != 32'd0) begin
                            start_pulse   <= 1'b1;
                            done_sticky_q <= 1'b0;
                            error_sticky_q <= 1'b0;
                        end
                        if ((apply_wstrb32(32'd0, wdata_q, wstrb_q) & 32'h0000_0002) != 32'd0) begin
                            soft_reset    <= 1'b1;
                            done_sticky_q <= 1'b0;
                            error_sticky_q <= 1'b0;
                        end
                        irq_en_q <= ((apply_wstrb32({29'd0, irq_en_q, 2'd0}, wdata_q, wstrb_q) & 32'h0000_0004) != 32'd0);
                    end
                    REG_STATUS: begin
                        if ((apply_wstrb32(32'd0, wdata_q, wstrb_q) & 32'h0000_0002) != 32'd0) begin
                            done_sticky_q <= 1'b0;
                        end
                        if ((apply_wstrb32(32'd0, wdata_q, wstrb_q) & 32'h0000_0004) != 32'd0) begin
                            error_sticky_q <= 1'b0;
                        end
                    end
                    REG_CFG: begin
                        causal_en_q <= ((apply_wstrb32({31'd0, causal_en_q}, wdata_q, wstrb_q) & 32'h0000_0001) != 32'd0);
                    end
                    REG_Q_BASE_L: begin
                        q_base_q[31:0] <= apply_wstrb32(q_base_q[31:0], wdata_q, wstrb_q);
                    end
                    REG_Q_BASE_H: begin
                        q_base_q[63:32] <= apply_wstrb32(q_base_q[63:32], wdata_q, wstrb_q);
                    end
                    REG_K_BASE_L: begin
                        k_base_q[31:0] <= apply_wstrb32(k_base_q[31:0], wdata_q, wstrb_q);
                    end
                    REG_K_BASE_H: begin
                        k_base_q[63:32] <= apply_wstrb32(k_base_q[63:32], wdata_q, wstrb_q);
                    end
                    REG_V_BASE_L: begin
                        v_base_q[31:0] <= apply_wstrb32(v_base_q[31:0], wdata_q, wstrb_q);
                    end
                    REG_V_BASE_H: begin
                        v_base_q[63:32] <= apply_wstrb32(v_base_q[63:32], wdata_q, wstrb_q);
                    end
                    REG_O_BASE_L: begin
                        o_base_q[31:0] <= apply_wstrb32(o_base_q[31:0], wdata_q, wstrb_q);
                    end
                    REG_O_BASE_H: begin
                        o_base_q[63:32] <= apply_wstrb32(o_base_q[63:32], wdata_q, wstrb_q);
                    end
                    REG_STRIDE_BYTES: begin
                        stride_bytes_q <= apply_wstrb32(stride_bytes_q, wdata_q, wstrb_q);
                    end
                    REG_NEG_LARGE: begin
                        neg_large_q <= apply_wstrb32(neg_large_q, wdata_q, wstrb_q);
                    end
                    REG_SCALE: begin
                        scale_q <= apply_wstrb32(scale_q, wdata_q, wstrb_q);
                    end
                    REG_VALID_LEN: begin
                        valid_len_q <= apply_wstrb32(valid_len_q, wdata_q, wstrb_q);
                    end
                    REG_TASK_COUNT: begin
                        task_count_q <= apply_wstrb32(task_count_q, wdata_q, wstrb_q);
                    end
                    REG_TASK_STRIDE: begin
                        task_stride_bytes_q <= apply_wstrb32(task_stride_bytes_q, wdata_q, wstrb_q);
                    end
                    REG_DROPOUT_CFG: begin
                        dropout_en_q <= ((dropout_cfg_wr_value & 32'h0000_0001) != 32'd0);
                        dropout_threshold_q <= dropout_cfg_wr_value[31:16];
                    end
                    REG_DROPOUT_SEED: begin
                        dropout_seed_q <= dropout_seed_wr_value[15:0];
                    end
                    REG_DROPOUT_SCALE: begin
                        dropout_scale_q8_8_q <= dropout_scale_wr_value[15:0];
                    end
                    default: begin
                    end
                endcase

                awaddr_valid_q <= 1'b0;
                wdata_valid_q  <= 1'b0;
                s_axil_bvalid  <= 1'b1;
            end else if (s_axil_bvalid && s_axil_bready) begin
                s_axil_bvalid <= 1'b0;
            end

            if (s_axil_arvalid && s_axil_arready) begin
                raddr_q       <= s_axil_araddr;
                s_axil_rvalid <= 1'b1;
            end else if (s_axil_rvalid && s_axil_rready) begin
                s_axil_rvalid <= 1'b0;
            end
        end
    end

endmodule
