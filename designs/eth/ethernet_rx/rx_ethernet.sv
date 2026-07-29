`timescale 1ns/1ps
//=============================================================================
// rx_ethernet.sv
//
// Full RX chain, RMII pins to clean-frame stream:
//
//   rmii_rx -> eth_frame_rx -> mac_filter -> eth_packet_fifo -> (you)
//
// Everything runs in the 50 MHz RMII clock domain. The read side is a
// first-word-fall-through valid/ready stream; frame boundaries are marked
// by rd_last on the final byte.
//
// Contract for the consumer:
//   * Every frame that appears on rd_* is complete, CRC-verified, and
//     addressed to MAC_ADDR or broadcast. FCS already stripped.
//   * !empty implies a whole frame is buffered -- a parser can stream a
//     frame start-to-end without stalling mid-frame.
//   * Byte 0..5 = destination MAC, 6..11 = source MAC, 12..13 = EtherType,
//     14.. = payload.
//=============================================================================
module rx_ethernet #(
    parameter logic [47:0] MAC_ADDR   = 48'h02_00_00_00_00_01,
    parameter int          FIFO_DEPTH = 2048
)(
    input  logic       clk50,
    input  logic       rst_n,

    // RMII pins from PHY
    input  logic [1:0] rmii_rxd,
    input  logic       rmii_crs_dv,

    // Clean frame stream out (FIFO read side, FWFT)
    output logic [7:0] rd_data,
    output logic       rd_last,
    output logic       rd_valid,
    input  logic       rd_ready,

    // Status pulses (LEDs / counters / debug)
    output logic       frame_dropped,   // any discarded frame (CRC/MAC/overflow)
    output logic       mac_reject       // subset: CRC was fine, address wasn't
);


    // assign rd_data = f_data;
    // assign rd_last = f_frame_done;
    // assign rd_valid = f_valid; 
    // assign rd_ready = 

    // Stage 1 -> 2
    logic [7:0] rx_data;
    logic       rx_valid, rx_frame_end;

    // Stage 2 -> 3
    logic [7:0] m_data;
    logic       m_valid, frame_done, frame_ok;

    // Stage 3 -> 4
    logic [7:0] f_data;
    logic       f_valid, f_frame_done, f_frame_ok;

    rmii_rx u_rmii (
        .clk50        (clk50),
        .rst_n        (rst_n),
        .rmii_rxd     (rmii_rxd),
        .rmii_crs_dv  (rmii_crs_dv),
        .rx_data      (rx_data),
        .rx_valid     (rx_valid),
        .rx_frame_end (rx_frame_end)
    );

    eth_frame_rx u_mac (
        .clk          (clk50),
        .rst_n        (rst_n),
        .rx_data      (rx_data),
        .rx_valid     (rx_valid),
        .rx_frame_end (rx_frame_end),
        .m_data       (m_data),
        .m_valid      (m_valid),
        .frame_done   (frame_done),
        .frame_ok     (frame_ok)
    );

    mac_filter #(.MAC_ADDR(MAC_ADDR)) u_filter (
        .clk            (clk50),
        .rst_n          (rst_n),
        .in_data        (m_data),
        .in_valid       (m_valid),
        .in_frame_done  (frame_done),
        .in_frame_ok    (frame_ok),
        .out_data       (f_data),
        .out_valid      (f_valid),
        .out_frame_done (f_frame_done),
        .out_frame_ok   (f_frame_ok),
        .mac_reject     (mac_reject)
    );

    eth_packet_fifo #(.DEPTH(FIFO_DEPTH)) u_fifo (
        .clk           (clk50),
        .rst_n         (rst_n),
        .wr_data       (f_data),
        .wr_valid      (f_valid),
        .frame_done    (f_frame_done),
        .frame_ok      (f_frame_ok),
        .frame_dropped (frame_dropped),
        .rd_data       (rd_data),
        .rd_last       (rd_last),
        .rd_valid      (rd_valid),
        .rd_ready      (rd_ready)
    );

endmodule