`timescale 1ns/1ps

module axi_master_read #(
    parameter int ADDR_W     = 64,
    parameter int AXI_DATA_W = 64
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic                    req_valid,
    input  logic [ADDR_W-1:0]       req_addr,
    input  logic [31:0]             req_bytes,
    output logic                    req_ready,

    output logic                    data_valid,
    output logic [AXI_DATA_W-1:0]   data,
    output logic                    data_last,
    input  logic                    data_ready,

    output logic [ADDR_W-1:0]       m_axi_araddr,
    output logic [7:0]              m_axi_arlen,
    output logic [2:0]              m_axi_arsize,
    output logic [1:0]              m_axi_arburst,
    output logic                    m_axi_arvalid,
    input  logic                    m_axi_arready,

    input  logic [AXI_DATA_W-1:0]   m_axi_rdata,
    input  logic [1:0]              m_axi_rresp,
    input  logic                    m_axi_rlast,
    input  logic                    m_axi_rvalid,
    output logic                    m_axi_rready,

    output logic                    busy,
    output logic                    done,
    output logic                    error
);

    localparam int AXI_BYTES = AXI_DATA_W / 8;
    localparam int AXI_SIZE  = $clog2(AXI_BYTES);

    typedef enum logic [1:0] {
        RD_IDLE,
        RD_AR,
        RD_DATA
    } rd_state_t;

    rd_state_t state_q;
    logic [ADDR_W-1:0] addr_q;
    logic [8:0]        beats_q;
    logic [8:0]        beat_count_q;

    function automatic logic [8:0] calc_beats(input logic [31:0] bytes);
        logic [31:0] rounded;
        begin
            rounded    = bytes + AXI_BYTES - 1;
            calc_beats = rounded / AXI_BYTES;
        end
    endfunction

    assign req_ready    = (state_q == RD_IDLE);
    assign busy         = (state_q != RD_IDLE);
    assign m_axi_araddr = addr_q;
    assign m_axi_arlen  = (beats_q > 0) ? (beats_q - 1'b1) : 8'd0;
    assign m_axi_arsize = AXI_SIZE[2:0];
    assign m_axi_arburst = 2'b01;
    assign m_axi_arvalid = (state_q == RD_AR);

    assign data_valid   = (state_q == RD_DATA) && m_axi_rvalid;
    assign data         = m_axi_rdata;
    assign data_last    = (state_q == RD_DATA) && m_axi_rvalid && m_axi_rlast;
    assign m_axi_rready = (state_q == RD_DATA) && data_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q      <= RD_IDLE;
            addr_q       <= '0;
            beats_q      <= '0;
            beat_count_q <= '0;
            done         <= 1'b0;
            error        <= 1'b0;
        end else begin
            done <= 1'b0;

            unique case (state_q)
                RD_IDLE: begin
                    beat_count_q <= '0;
                    if (req_valid) begin
                        addr_q  <= req_addr;
                        beats_q <= calc_beats(req_bytes);
                        state_q <= RD_AR;
                    end
                end

                RD_AR: begin
                    if (m_axi_arvalid && m_axi_arready) begin
                        beat_count_q <= '0;
                        state_q      <= RD_DATA;
                    end
                end

                RD_DATA: begin
                    if (m_axi_rvalid && data_ready) begin
                        if (m_axi_rresp != 2'b00) begin
                            error <= 1'b1;
                        end

                        if (m_axi_rlast || (beat_count_q + 1'b1 >= beats_q)) begin
                            done    <= 1'b1;
                            state_q <= RD_IDLE;
                        end else begin
                            beat_count_q <= beat_count_q + 1'b1;
                        end
                    end
                end

                default: begin
                    state_q <= RD_IDLE;
                end
            endcase
        end
    end

endmodule
