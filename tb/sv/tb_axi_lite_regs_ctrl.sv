`timescale 1ns/1ps

module tb_axi_lite_regs_ctrl;
    localparam int ADDR_W  = 32;
    localparam int DATA_W  = 32;
    localparam int D_MODEL = 64;

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

    localparam logic [31:0] CTRL_START       = 32'h0000_0001;
    localparam logic [31:0] CTRL_SOFT_RESET  = 32'h0000_0002;
    localparam logic [31:0] CTRL_IRQ_EN      = 32'h0000_0004;
    localparam logic [31:0] STATUS_BUSY      = 32'h0000_0001;
    localparam logic [31:0] STATUS_DONE      = 32'h0000_0002;
    localparam logic [31:0] STATUS_ERROR     = 32'h0000_0004;
    localparam logic [31:0] CFG_CAUSAL_EN    = 32'h0000_0001;

    logic clk;
    logic rst_n;

    logic [ADDR_W-1:0] s_axil_awaddr;
    logic              s_axil_awvalid;
    wire               s_axil_awready;
    logic [DATA_W-1:0] s_axil_wdata;
    logic [DATA_W/8-1:0] s_axil_wstrb;
    logic              s_axil_wvalid;
    wire               s_axil_wready;
    wire [1:0]         s_axil_bresp;
    wire               s_axil_bvalid;
    logic              s_axil_bready;
    logic [ADDR_W-1:0] s_axil_araddr;
    logic              s_axil_arvalid;
    wire               s_axil_arready;
    wire [DATA_W-1:0]  s_axil_rdata;
    wire [1:0]         s_axil_rresp;
    wire               s_axil_rvalid;
    logic              s_axil_rready;

    wire start_pulse;
    wire soft_reset;
    wire irq_en;
    wire causal_en;
    wire [63:0] q_base;
    wire [63:0] k_base;
    wire [63:0] v_base;
    wire [63:0] o_base;
    wire [31:0] stride_bytes;
    wire signed [31:0] neg_large;
    wire signed [31:0] scale;
    logic busy;
    logic done;
    logic error;
    logic [31:0] cycles;
    logic [63:0] rd_bytes;
    logic [63:0] wr_bytes;
    wire irq;

    int start_seen;
    int soft_reset_seen;

    axi_lite_regs #(
        .ADDR_W(ADDR_W),
        .DATA_W(DATA_W),
        .D_MODEL(D_MODEL)
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
        .busy(busy),
        .done(done),
        .error(error),
        .cycles(cycles),
        .rd_bytes(rd_bytes),
        .wr_bytes(wr_bytes),
        .irq(irq)
    );

    always #5 clk = ~clk;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_seen      <= 0;
            soft_reset_seen <= 0;
        end else begin
            if (start_pulse) begin
                start_seen <= start_seen + 1;
            end
            if (soft_reset) begin
                soft_reset_seen <= soft_reset_seen + 1;
            end
        end
    end

    task automatic expect_eq(input string name, input logic [63:0] got, input logic [63:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL %s got=%h expected=%h", name, got, exp);
                $fatal(1);
            end
        end
    endtask

    task automatic axil_write(input logic [31:0] addr, input logic [31:0] data);
        bit aw_done;
        bit w_done;
        int timeout;
        begin
            @(negedge clk);
            s_axil_awaddr  = addr;
            s_axil_awvalid = 1'b1;
            s_axil_wdata   = data;
            s_axil_wstrb   = 4'hf;
            s_axil_wvalid  = 1'b1;
            s_axil_bready  = 1'b0;

            aw_done = 0;
            w_done = 0;
            timeout = 0;
            while ((!aw_done || !w_done) && (timeout < 20)) begin
                @(posedge clk);
                if (s_axil_awvalid && s_axil_awready) begin
                    aw_done = 1;
                end
                if (s_axil_wvalid && s_axil_wready) begin
                    w_done = 1;
                end
                @(negedge clk);
                if (aw_done) begin
                    s_axil_awvalid = 1'b0;
                end
                if (w_done) begin
                    s_axil_wvalid = 1'b0;
                end
                timeout++;
            end
            if (!aw_done || !w_done) begin
                $display("FAIL AXI-Lite write handshake timeout addr=%08h", addr);
                $fatal(1);
            end

            timeout = 0;
            while (!s_axil_bvalid && (timeout < 20)) begin
                @(posedge clk);
                timeout++;
            end
            if (!s_axil_bvalid || (s_axil_bresp != 2'b00)) begin
                $display("FAIL AXI-Lite write response addr=%08h resp=%0d", addr, s_axil_bresp);
                $fatal(1);
            end
            @(negedge clk);
            s_axil_bready = 1'b1;
            @(negedge clk);
            s_axil_bready = 1'b0;
        end
    endtask

    task automatic axil_read(input logic [31:0] addr, output logic [31:0] data);
        int timeout;
        begin
            @(negedge clk);
            s_axil_araddr  = addr;
            s_axil_arvalid = 1'b1;
            s_axil_rready  = 1'b0;

            timeout = 0;
            while (!(s_axil_arvalid && s_axil_arready) && (timeout < 20)) begin
                @(posedge clk);
                timeout++;
            end
            if (!(s_axil_arvalid && s_axil_arready)) begin
                $display("FAIL AXI-Lite read address timeout addr=%08h", addr);
                $fatal(1);
            end
            @(negedge clk);
            s_axil_arvalid = 1'b0;

            timeout = 0;
            while (!s_axil_rvalid && (timeout < 20)) begin
                @(posedge clk);
                timeout++;
            end
            if (!s_axil_rvalid || (s_axil_rresp != 2'b00)) begin
                $display("FAIL AXI-Lite read response addr=%08h resp=%0d", addr, s_axil_rresp);
                $fatal(1);
            end
            data = s_axil_rdata;
            @(negedge clk);
            s_axil_rready = 1'b1;
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

    initial begin
        logic [31:0] data;

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
        busy = 1'b0;
        done = 1'b0;
        error = 1'b0;
        cycles = 32'd12345;
        rd_bytes = 64'h0000_0001_2345_6789;
        wr_bytes = 64'h0000_0000_0000_2000;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        axil_read(REG_CTRL, data);
        expect_eq("CTRL reset", data, 32'd0);
        axil_read(REG_STATUS, data);
        expect_eq("STATUS reset", data, 32'd0);
        axil_read(REG_STRIDE_BYTES, data);
        expect_eq("STRIDE reset", data, D_MODEL * 2);
        axil_read(REG_NEG_LARGE, data);
        expect_eq("NEG_LARGE reset", data, 32'hffff_8000);
        axil_read(REG_SCALE, data);
        expect_eq("SCALE reset", data, 32'd32);

        axil_write(REG_CFG, CFG_CAUSAL_EN);
        axil_read(REG_CFG, data);
        expect_eq("CFG causal", data & CFG_CAUSAL_EN, CFG_CAUSAL_EN);
        expect_eq("causal_en output", causal_en, 1'b1);

        axil_write64(REG_Q_BASE_L, REG_Q_BASE_H, 64'h1111_2222_3333_4444);
        axil_write64(REG_K_BASE_L, REG_K_BASE_H, 64'h5555_6666_7777_8888);
        axil_write64(REG_V_BASE_L, REG_V_BASE_H, 64'h9999_aaaa_bbbb_cccc);
        axil_write64(REG_O_BASE_L, REG_O_BASE_H, 64'hdddd_eeee_ffff_0000);
        axil_write(REG_STRIDE_BYTES, 32'd160);
        axil_write(REG_NEG_LARGE, 32'hffff_9000);
        axil_write(REG_SCALE, 32'd91);

        expect_eq("q_base output", q_base, 64'h1111_2222_3333_4444);
        expect_eq("k_base output", k_base, 64'h5555_6666_7777_8888);
        expect_eq("v_base output", v_base, 64'h9999_aaaa_bbbb_cccc);
        expect_eq("o_base output", o_base, 64'hdddd_eeee_ffff_0000);
        expect_eq("stride output", stride_bytes, 32'd160);
        expect_eq("neg_large output", neg_large, 64'hffff_ffff_ffff_9000);
        expect_eq("scale output", scale, 32'd91);

        axil_read(REG_CYCLES, data);
        expect_eq("CYCLES read", data, cycles);
        axil_read(REG_RD_BYTES_L, data);
        expect_eq("RD_BYTES_L read", data, rd_bytes[31:0]);
        axil_read(REG_RD_BYTES_H, data);
        expect_eq("RD_BYTES_H read", data, rd_bytes[63:32]);
        axil_read(REG_WR_BYTES_L, data);
        expect_eq("WR_BYTES_L read", data, wr_bytes[31:0]);
        axil_read(REG_WR_BYTES_H, data);
        expect_eq("WR_BYTES_H read", data, wr_bytes[63:32]);

        axil_write(REG_CTRL, CTRL_START | CTRL_IRQ_EN);
        repeat (2) @(posedge clk);
        if (start_seen != 1) begin
            $display("FAIL START pulse count=%0d expected=1", start_seen);
            $fatal(1);
        end
        axil_read(REG_CTRL, data);
        expect_eq("CTRL IRQ_EN readback", data & CTRL_IRQ_EN, CTRL_IRQ_EN);
        expect_eq("irq_en output", irq_en, 1'b1);

        busy = 1'b1;
        axil_read(REG_STATUS, data);
        expect_eq("STATUS busy", data & STATUS_BUSY, STATUS_BUSY);
        busy = 1'b0;

        done = 1'b1;
        @(posedge clk);
        @(negedge clk);
        done = 1'b0;
        repeat (1) @(posedge clk);
        axil_read(REG_STATUS, data);
        expect_eq("STATUS done sticky", data & STATUS_DONE, STATUS_DONE);
        expect_eq("IRQ asserted", irq, 1'b1);

        axil_write(REG_STATUS, STATUS_DONE);
        repeat (1) @(posedge clk);
        axil_read(REG_STATUS, data);
        expect_eq("STATUS done clear", data & STATUS_DONE, 32'd0);
        expect_eq("IRQ cleared", irq, 1'b0);

        error = 1'b1;
        @(posedge clk);
        @(negedge clk);
        error = 1'b0;
        repeat (1) @(posedge clk);
        axil_read(REG_STATUS, data);
        expect_eq("STATUS error sticky", data & STATUS_ERROR, STATUS_ERROR);

        axil_write(REG_CTRL, CTRL_SOFT_RESET | CTRL_IRQ_EN);
        repeat (2) @(posedge clk);
        if (soft_reset_seen != 1) begin
            $display("FAIL SOFT_RESET pulse count=%0d expected=1", soft_reset_seen);
            $fatal(1);
        end
        axil_read(REG_STATUS, data);
        expect_eq("STATUS error clear after soft reset", data & STATUS_ERROR, 32'd0);
        axil_read(REG_CTRL, data);
        expect_eq("IRQ_EN retained after soft reset write", data & CTRL_IRQ_EN, CTRL_IRQ_EN);

        $display("tb_axi_lite_regs_ctrl PASS");
        $finish;
    end
endmodule
