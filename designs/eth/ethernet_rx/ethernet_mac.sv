module ethernet_mac #(
    parameter logic [47:0] MAC_ADDR    = 48'h02_00_00_00_00_01,
    parameter logic [31:0] OUR_IP      = {8'd192, 8'd168, 8'd1, 8'd2},
    parameter logic [15:0] LISTEN_PORT = 16'd5000,
    parameter int          FIFO_DEPTH  = 2048
)(
    input  logic       clk50,
    input  logic       rst_n,

    // RMII pins
    input  logic [1:0] rmii_rxd,
    input  logic       rmii_crs_dv,
    output logic [1:0] rmii_txd,
    output logic       rmii_tx_en,

    // Add Stream Inputs
    input  logic [7:0] data_in,
    input  logic       last_in, 
    input  logic       valid_in,
    output logic       ready_in,
    // Add Stream Outputs
    output logic [7:0]  data_out,
    output logic        valid_out,
    output logic        last_out,
    input  logic        ready_out


);


    parameter logic [47:0] PC_MAC_ADDR = 48'hE8_9C_25_0E_24_0E;
    logic [47:0] dst_mac;
    logic [15:0] ether_type;

    assign dst_mac = PC_MAC_ADDR;
    assign ether_type = 16'h88B5;  // IEEE 802 local experimental ethertype

    rx_ethernet #(.MAC_ADDR(MAC_ADDR), .FIFO_DEPTH(FIFO_DEPTH)) u_rx (
        .clk50         (clk50),
        .rst_n         (rst_n),
        .rmii_rxd      (rmii_rxd),
        .rmii_crs_dv   (rmii_crs_dv),
        .rd_data       (data_out),
        .rd_last       (last_out),
        .rd_valid      (valid_out),
        .rd_ready      (ready_out),
        .frame_dropped (frame_dropped),
        .mac_reject    (mac_reject)
    );

    tx_ethernet #(.SRC_MAC(MAC_ADDR)) u_tx (
        .clk50      (clk50),
        .rst_n      (rst_n),
        .dst_mac    (dst_mac),
        .ether_type (ether_type),
        .pl_data    (data_in),
        .pl_valid   (valid_in),
        .pl_last    (last_in),
        .pl_ready   (ready_in),
        .rmii_txd   (rmii_txd),
        .rmii_tx_en (rmii_tx_en),
        .busy       ()
    );

    




endmodule