//==============================================================================
// sram_to_uart_packet_manager.sv
//
// Reads pixels out of the output SRAM and streams them, one raw byte per
// pixel, directly into ethernet_mac's TX AXI-stream-style port (data_in/
// valid_in/last_in/ready_in) -- no UART/ASCII framing, no padding bytes,
// and no intermediate "message" staging buffer (this now drives the MAC
// port directly; eth_tx_msg_streamer is no longer used in this path).
//
// This replaces the old 4-pixels-into-a-16-byte '{p0,p1,p2,p3,,XXXX,,XXXX}'
// message format, which spent 12 of every 16 transmitted bytes on inherited
// UART debug placeholder characters (a 4x bandwidth tax for zero payload)
// and fully serialized "read 4 pixels" then "wait for the whole 16-byte
// message to drain" on every batch.
//
// Framing: last_out pulses (closing out one Ethernet/UDP frame, same
// convention eth_udp_payload_filter documents for last_out on RX) every
// MAX_MSG_BYTES bytes, or at the final pixel of the image if that comes
// first. MAX_MSG_BYTES defaults to 1472 = Ethernet MTU(1500) - 20B IPv4 -
// 8B UDP, matching MAX_UDP_PAYLOAD in tb_chip_top_eth.sv, so a 256x256
// image now takes ceil(65536/1472) = 45 frames instead of 16384, with
// zero filler bytes in any of them.
//
// UNVERIFIED ASSUMPTION (same caveat as elsewhere in this tree -- ethernet_mac
// itself isn't in this repo): last_in is assumed to close one Ethernet frame
// the same way last_out does on RX. If ethernet_mac instead expects the
// caller to supply full Ethernet/IP/UDP headers on data_in, this module
// (like the one it replaces) still only feeds raw payload bytes, so that
// assumption predates this rewrite and isn't new risk introduced here.
//==============================================================================

module sram_to_uart_packet_manager #(
    parameter int IMAGE_SIZE    = 256,
    parameter int ADDR_WIDTH    = 16,
    parameter int DATA_WIDTH    = 8,
    parameter int MAX_MSG_BYTES = 1472
)(
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  start,
    input  logic [31:0]           img_size_i,

    output logic [ADDR_WIDTH-1:0] raddr,
    input  logic [DATA_WIDTH-1:0] rdata,

    output logic [DATA_WIDTH-1:0] data_out,
    output logic                  valid_out,
    output logic                  last_out,
    input  logic                  ready_in,

    output logic                  done
);

    localparam int MSG_CNT_W = $clog2(MAX_MSG_BYTES);
    localparam logic [MSG_CNT_W-1:0] MSG_LAST = MSG_CNT_W'(MAX_MSG_BYTES - 1);

    // Added FETCH_ADDR to handle 1-cycle SRAM read latency
    typedef enum logic [1:0] {IDLE, FETCH_ADDR, READ_DATA, SEND} state_e;
    state_e state;

    logic [31:0]           pix_cnt; // pixels handshaked so far, 0..img_size_i
    logic [MSG_CNT_W-1:0]  msg_cnt; // bytes sent in the current frame chunk
    logic [DATA_WIDTH-1:0] cur_byte;

    wire pixel_is_last = (pix_cnt == img_size_i - 32'd1);
    wire msg_is_full    = (msg_cnt == MSG_LAST);

    assign data_out  = cur_byte;
    assign valid_out = (state == SEND);
    assign last_out  = (state == SEND) && (pixel_is_last || msg_is_full);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= IDLE;
            raddr    <= '0;
            pix_cnt  <= '0;
            msg_cnt  <= '0;
            cur_byte <= '0;
            done     <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                IDLE: begin
                    raddr   <= '0;
                    pix_cnt <= '0;
                    msg_cnt <= '0;
                    if (start && img_size_i != 32'd0) state <= FETCH_ADDR;
                end

                // Do nothing here -- just waiting 1 clock cycle for SRAM
                // to put data on the rdata bus for the address set below.
                FETCH_ADDR: state <= READ_DATA;

                READ_DATA: begin
                    cur_byte <= rdata;
                    raddr    <= raddr + 1'b1; // prefetch address for next byte
                    state    <= SEND;
                end

                SEND: begin
                    if (ready_in) begin
                        pix_cnt <= pix_cnt + 32'd1;
                        if (pixel_is_last) begin
                            done  <= 1'b1;
                            state <= IDLE;
                        end else begin
                            msg_cnt <= msg_is_full ? '0 : (msg_cnt + 1'b1);
                            state   <= FETCH_ADDR;
                        end
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
