`timescale 1ns/1ps
//=============================================================================
// mac_filter.sv
//
// Destination-MAC filter. Sits between eth_frame_rx and eth_packet_fifo,
// passing the byte stream through untouched while watching bytes 0..5
// (the destination MAC). At end of frame it vetoes the commit for frames
// that are not addressed to us:
//
//     out_frame_ok = in_frame_ok && dst_ok
//     dst_ok       = (DA == MAC_ADDR) or (DA == FF:FF:FF:FF:FF:FF)
//
// Broadcast MUST be accepted -- ARP requests arrive as broadcast; without
// them the PC can never learn our MAC and nothing else works.
//
// The FIFO needs no changes: a filtered frame just looks like a bad-CRC
// frame to it (frame_done with frame_ok low -> rewind).
//
// MAC_ADDR is written in reading order: 48'h02_00_00_00_00_01 means
// 02:00:00:00:00:01. Byte 0 on the wire is compared against the top byte.
// Keep it locally administered (bit 1 of the first byte set, bit 0 clear):
// first byte x2 / x6 / xA / xE.
//=============================================================================
module mac_filter #(
    parameter logic [47:0] MAC_ADDR = 48'h02_00_00_00_00_01
)(
    input  logic       clk,
    input  logic       rst_n,

    // From eth_frame_rx
    input  logic [7:0] in_data,
    input  logic       in_valid,
    input  logic       in_frame_done,
    input  logic       in_frame_ok,

    // To eth_packet_fifo (data path is a pure pass-through)
    output logic [7:0] out_data,
    output logic       out_valid,
    output logic       out_frame_done,
    output logic       out_frame_ok,

    // Debug: pulse when a CRC-good frame was rejected for its address
    output logic       mac_reject
);

    // Byte counter for the first 6 bytes; sticks at 6 for the rest of
    // the frame. Match flags start optimistic and are cleared on the
    // first mismatching byte.
    logic [2:0] cnt;
    logic       match_mac;
    logic       match_bcast;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt         <= '0;
            match_mac   <= 1'b1;
            match_bcast <= 1'b1;
        end else begin
            if (in_valid && cnt < 3'd6) begin
                // MAC_ADDR top byte corresponds to wire byte 0
                if (in_data != MAC_ADDR[8*(3'd5 - cnt) +: 8])
                    match_mac <= 1'b0;
                if (in_data != 8'hFF)
                    match_bcast <= 1'b0;
                cnt <= cnt + 3'd1;
            end

            if (in_frame_done) begin       // re-arm for the next frame
                cnt         <= '0;
                match_mac   <= 1'b1;
                match_bcast <= 1'b1;
            end
        end
    end

    // Valid only once all 6 DA bytes were seen (guards against runts)
    wire dst_ok = (cnt == 3'd6) && (match_mac || match_bcast);

    assign out_data       = in_data;
    assign out_valid      = in_valid;
    assign out_frame_done = in_frame_done;
    assign out_frame_ok   = in_frame_ok && dst_ok;
    assign mac_reject     = in_frame_done && in_frame_ok && !dst_ok;

endmodule