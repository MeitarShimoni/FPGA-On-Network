




module Chip_Top_DSP_ETH #(
    parameter logic [47:0] MAC_ADDR    = 48'h02_00_00_00_00_01,
    parameter logic [31:0] OUR_IP      = {8'd192, 8'd168, 8'd1, 8'd2},
    parameter logic [15:0] LISTEN_PORT = 16'd5000,
    parameter int          FIFO_DEPTH  = 2048,
    parameter int          PHY_RST_W = 20
)(

    input logic clk,
    input logic rst_n,

    // RMII pins
    input  logic [1:0] rmii_rxd,
    input  logic       rmii_crs_dv,
    output logic [1:0] rmii_txd,
    output logic       rmii_tx_en,
    output logic       eth_refclk,
    output logic       eth_rstn,

    output logic [6:0] cathodes_out,
    output logic [7:0] anodes

);


logic [PHY_RST_W-1:0] phy_rst_cnt;
logic sys_rst_n;

// Stream Inputs (driven by loopback below)
logic [7:0] data_in;
logic       last_in;
logic       valid_in;
logic       ready_in;
// Stream Outputs
logic [7:0] data_out;
logic       valid_out;
logic       last_out;
logic       ready_out;

clk_wiz_0 clk50_gen (
    .clk_in1(clk),
    .resetn(rst_n),
    .clk_out1(clk50),
    .locked(locked)
);

// PHY reset sequencer: hold low ~21 ms after PLL lock, then release
always_ff @(posedge clk50 or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        phy_rst_cnt <= '0;
        eth_rstn    <= 1'b0;
    end else if (!(&phy_rst_cnt))
        phy_rst_cnt <= phy_rst_cnt + 1'b1;
    else
        eth_rstn    <= 1'b1;
end

assign sys_rst_n = locked & rst_n;


ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
u_refclk_fwd (
    .Q(eth_refclk), .C(clk50), .CE(1'b1),
    .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0)
);

ethernet_mac #(
    .MAC_ADDR    (MAC_ADDR),
    .OUR_IP      (OUR_IP),
    .LISTEN_PORT (LISTEN_PORT),
    .FIFO_DEPTH  (FIFO_DEPTH)
) ethernet_core (
    .clk50       (clk50),
    .rst_n       (sys_rst_n),

    .rmii_rxd    (rmii_rxd),
    .rmii_crs_dv (rmii_crs_dv),
    .rmii_txd    (rmii_txd),
    .rmii_tx_en  (rmii_tx_en),

    .data_in     (data_in),
    .last_in     (last_in),
    .valid_in    (valid_in),
    .ready_in    (ready_in),

    .data_out    (data_out),
    .valid_out   (valid_out),
    .last_out    (last_out),
    .ready_out   (ready_out)
);



















logic [15:0] in_cnt, out_cnt;

always_ff @(posedge clk50 or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        in_cnt <= 'd0;
    end else if (ready_in && valid_in) begin
        in_cnt <= in_cnt + 1'b1;
    end
end

always_ff @(posedge clk50 or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        out_cnt <= 'd0;
    end else if (valid_out) begin
        out_cnt <= out_cnt + 1'b1;
    end
end

seven_segment segment_display (
    .system_clock (clk50),
    .cpu_rst_n    (sys_rst_n),
    .display_val  ({in_cnt,out_cnt}),
    .cathodes_out (cathodes_out),
    .anodes       (anodes)
);



endmodule