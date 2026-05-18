`timescale 1ns/1ps

module axi_master_write #(
    parameter int ADDR_W     = 64,
    parameter int AXI_DATA_W = 64
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic                    req_valid,
    input  logic [ADDR_W-1:0]       req_addr,
    input  logic [31:0]             req_bytes,
    output logic                    req_ready,

    input  logic                    data_valid,
    input  logic [AXI_DATA_W-1:0]   data,
    input  logic                    data_last,
    output logic                    data_ready,

    output logic [ADDR_W-1:0]       m_axi_awaddr,
    output logic [7:0]              m_axi_awlen,
    output logic [2:0]              m_axi_awsize,
    output logic [1:0]              m_axi_awburst,
    output logic                    m_axi_awvalid,
    input  logic                    m_axi_awready,

    output logic [AXI_DATA_W-1:0]   m_axi_wdata,
    output logic [AXI_DATA_W/8-1:0] m_axi_wstrb,
    output logic                    m_axi_wlast,
    output logic                    m_axi_wvalid,
    input  logic                    m_axi_wready,

    input  logic [1:0]              m_axi_bresp,
    input  logic                    m_axi_bvalid,
    output logic                    m_axi_bready,

    output logic                    busy,
    output logic                    done,
    output logic                    error
);

    localparam int AXI_BYTES = AXI_DATA_W / 8;
    localparam int AXI_SIZE  = $clog2(AXI_BYTES);

    typedef enum logic [1:0] {
        WR_IDLE,
        WR_AW,
        WR_DATA,
        WR_RESP
    } wr_state_t;

    wr_state_t state_q;
    logic [ADDR_W-1:0] addr_q;
    logic [8:0]        beats_q;

    function automatic logic [8:0] calc_beats(input logic [31:0] bytes);
        logic [31:0] rounded;
        begin
            rounded    = bytes + AXI_BYTES - 1;
            calc_beats = rounded / AXI_BYTES;
        end
    endfunction

    assign req_ready     = (state_q == WR_IDLE);
    assign busy          = (state_q != WR_IDLE);
    assign m_axi_awaddr  = addr_q;
    assign m_axi_awlen   = (beats_q > 0) ? (beats_q - 1'b1) : 8'd0;
    assign m_axi_awsize  = AXI_SIZE[2:0];
    assign m_axi_awburst = 2'b01;
    assign m_axi_awvalid = (state_q == WR_AW);

    assign m_axi_wdata   = data;
    assign m_axi_wstrb   = {AXI_BYTES{1'b1}};
    assign m_axi_wlast   = data_last;
    assign m_axi_wvalid  = (state_q == WR_DATA) && data_valid;
    assign data_ready    = (state_q == WR_DATA) && m_axi_wready;

    assign m_axi_bready  = (state_q == WR_RESP);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= WR_IDLE;
            addr_q  <= '0;
            beats_q <= '0;
            done    <= 1'b0;
            error   <= 1'b0;
        end else begin
            done <= 1'b0;

            unique case (state_q)
                WR_IDLE: begin
                    if (req_valid) begin
                        addr_q  <= req_addr;
                        beats_q <= calc_beats(req_bytes);
                        state_q <= WR_AW;
                    end
                end

                WR_AW: begin
                    if (m_axi_awvalid && m_axi_awready) begin
                        state_q <= WR_DATA;
                    end
                end

                WR_DATA: begin
                    if (data_valid && m_axi_wready && data_last) begin
                        state_q <= WR_RESP;
                    end
                end

                WR_RESP: begin
                    if (m_axi_bvalid) begin
                        if (m_axi_bresp != 2'b00) begin
                            error <= 1'b1;
                        end
                        done    <= 1'b1;
                        state_q <= WR_IDLE;
                    end
                end

                default: begin
                    state_q <= WR_IDLE;
                end
            endcase
        end
    end

endmodule
