`timescale 1ns/1ps
//=============================================================================
// tx_ethernet.sv
//
// Full TX chain, payload stream to RMII pins -- the mirror of rx_ethernet:
//
//   (you) -> eth_frame_tx -> rmii_tx -> PHY pins
//
// Contract for the producer:
//   * Present a payload byte stream on pl_* with dst_mac/src_mac/ether_type
//     valid at the same time; the frame starts on the first pl_valid.
//   * Hold pl_valid until pl_last is consumed (no mid-frame stalls).
//   * Preamble, SFD, zero-padding to 60, FCS, and the inter-frame gap are
//     all handled here -- the producer only supplies real payload bytes.
//   * busy is high from frame start until the IFG completes; a new frame
//     offered while busy simply waits in IDLE's queue-of-one (hold pl_valid).
//
// Everything runs on the 50 MHz RMII clock, same as the RX side.
// v1: no TX packet FIFO -- producers are FSMs that stream on demand
// (one byte per 4 clocks is the drain rate; anything keeps up).
//=============================================================================
module tx_ethernet #(
    parameter logic [47:0] SRC_MAC = 48'h02_00_00_00_00_01
)(
    input  logic        clk50,
    input  logic        rst_n,

    // Frame fields
    input  logic [47:0] dst_mac,
    input  logic [15:0] ether_type,

    // Payload byte stream in
    input  logic [7:0]  pl_data,
    input  logic        pl_valid,
    input  logic        pl_last,
    output logic        pl_ready,

    // RMII pins to PHY
    output logic [1:0]  rmii_txd,
    output logic        rmii_tx_en,

    output logic        busy
);

    logic [7:0] tx_data;
    logic       tx_valid, tx_ready;

    eth_frame_tx u_frame (
        .clk        (clk50),
        .rst_n      (rst_n),
        .dst_mac    (dst_mac),
        .src_mac    (SRC_MAC),
        .ether_type (ether_type),
        .pl_data    (pl_data),
        .pl_valid   (pl_valid),
        .pl_last    (pl_last),
        .pl_ready   (pl_ready),
        .tx_data    (tx_data),
        .tx_valid   (tx_valid),
        .tx_ready   (tx_ready),
        .busy       (busy)
    );

    rmii_tx u_rmii (
        .clk50      (clk50),
        .rst_n      (rst_n),
        .tx_data    (tx_data),
        .tx_valid   (tx_valid),
        .tx_ready   (tx_ready),
        .rmii_txd   (rmii_txd),
        .rmii_tx_en (rmii_tx_en)
    );

endmodule
