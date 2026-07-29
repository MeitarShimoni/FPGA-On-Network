//==============================================================================
// eth_udp_payload_filter.sv
//
// Sits between ethernet_mac's decoded RX stream and write_manager. ethernet_mac
// (see MyIPs/Ethernet_MAC/src/rx_ethernet.sv) only does Layer-2: it hands out
// every frame addressed to our MAC address *or broadcast* (needed for ARP),
// FCS-stripped but with Ethernet/IP/UDP headers still in the byte stream --
// it has no EtherType/IP/UDP/port filtering at all (OUR_IP/LISTEN_PORT are
// accepted as ethernet_mac parameters but never actually used inside it).
//
// This module walks each frame's byte offset (0-based from the first byte
// after the preamble/SFD, i.e. offset 0 = first destination-MAC byte) and:
//   - latches EtherType (12:13), IP protocol (23), IP dest addr (30:33),
//     and UDP dest port (36:37) as they go by
//   - only asserts pixel_valid for bytes at offset >= 42 (first payload byte,
//     assuming a 20B IP header with no options -- true for every frame this
//     project generates) of frames that are IPv4/UDP addressed to OUR_IP:
//     LISTEN_PORT
//
// Everything else (ARP broadcasts, other hosts/ports, non-UDP traffic) is
// silently dropped: pixel_valid simply never asserts for that frame's bytes.
//==============================================================================

module eth_udp_payload_filter #(
    parameter logic [31:0] OUR_IP      = {8'd192, 8'd168, 8'd1, 8'd2},
    parameter logic [15:0] LISTEN_PORT = 16'd5000
)(
    input  logic       clk,
    input  logic       rst_n,

    // From ethernet_mac (already FCS-stripped, dest-MAC filtered; still
    // contains the full Ethernet+IP+UDP headers ahead of the payload)
    input  logic [7:0] data_out,
    input  logic       valid_out,
    input  logic       last_out,

    // Pixel byte stream: only UDP payload bytes addressed to us
    output logic [7:0] pixel_data,
    output logic       pixel_valid
);

    localparam int HEADER_LEN = 14 + 20 + 8; // Eth + IPv4(no opts) + UDP = 42

    logic [10:0] byte_idx; // index of the byte currently on data_out this cycle

    logic [15:0] eth_type_l;
    logic [7:0]  ip_proto_l;
    logic [31:0] ip_dst_l;
    logic [15:0] udp_dport_l;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_idx    <= 11'd0;
            eth_type_l  <= 16'd0;
            ip_proto_l  <= 8'd0;
            ip_dst_l    <= 32'd0;
            udp_dport_l <= 16'd0;
        end else begin
            if (valid_out) begin
                case (byte_idx)
                    11'd12:  eth_type_l[15:8]  <= data_out;
                    11'd13:  eth_type_l[7:0]   <= data_out;
                    11'd23:  ip_proto_l        <= data_out;
                    11'd30:  ip_dst_l[31:24]   <= data_out;
                    11'd31:  ip_dst_l[23:16]   <= data_out;
                    11'd32:  ip_dst_l[15:8]    <= data_out;
                    11'd33:  ip_dst_l[7:0]     <= data_out;
                    11'd36:  udp_dport_l[15:8] <= data_out;
                    11'd37:  udp_dport_l[7:0]  <= data_out;
                    default: ;
                endcase
                byte_idx <= byte_idx + 11'd1;
            end

            // Re-arm for the next frame regardless of valid_out this cycle
            // (last_out coincides with valid_out on the frame's final byte).
            if (last_out) begin
                byte_idx    <= 11'd0;
                eth_type_l  <= 16'd0;
                ip_proto_l  <= 8'd0;
                ip_dst_l    <= 32'd0;
                udp_dport_l <= 16'd0;
            end
        end
    end

    wire frame_is_target_udp = (eth_type_l   == 16'h0800) &&  // IPv4
                               (ip_proto_l   == 8'd17)    &&  // UDP
                               (ip_dst_l     == OUR_IP)   &&
                               (udp_dport_l  == LISTEN_PORT);

    assign pixel_valid = valid_out && (byte_idx >= HEADER_LEN) && frame_is_target_udp;
    assign pixel_data  = data_out;

endmodule
