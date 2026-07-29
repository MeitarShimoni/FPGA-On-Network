//==============================================================================
// eth_rx_msg_packer.sv
//
// SUPERSEDED / no longer instantiated by Chip_Top_DSP_ETH_pipeline.sv: this
// module (and rx_phaser_classifier.sv, which consumed its output) assumed an
// ASCII/UART command protocol that doesn't match the raw grayscale pixel
// stream the host actually sends (see eth_udp_payload_filter.sv + the
// updated write_manager.sv, which replaced this pair). Left in the tree
// only because it's still registered as a Vivado source; not part of the
// active RX path.
//
// Replaces RX_UART on the receive side. RX_UART used to deserialize the UART
// line into 16-byte (128-bit) "messages" for rx_phaser_classifier. The
// Ethernet MAC already hands you a clean byte stream (data_out/valid_out/
// last_out), so this module just re-groups every 16 bytes into the same
// 128-bit word format and pulses message_valid the same way
// valid_message_flag used to.
//
// ASSUMPTION THAT NEEDS VERIFYING AGAINST YOUR RX_UART SOURCE:
// The byte order below assumes the first byte received becomes the MOST
// significant byte of the 128-bit word (big-endian packing), i.e. byte 0
// lands in bits [127:120], byte 15 lands in bits [7:0]. This mirrors the
// most common RX_UART style, but if your RX_UART actually packed
// little-endian (first byte -> bits [7:0]), rx_phaser_classifier will
// misread every address/wdata/rgb field. If you share RX_UART.sv I can
// confirm/fix this in one line. Until then: send a known test pattern
// (e.g. address-write command) and check img_size_reg / filter_sel land
// correctly before trusting pixel data.
//==============================================================================

module eth_rx_msg_packer (
    input  logic       clk,
    input  logic       rst_n,

    // From ethernet_mac (network -> FPGA)
    input  logic [7:0] data_out,
    input  logic       valid_out,
    input  logic       last_out,
    output logic       ready_out,   // never back-pressures the MAC -- see note below

    // To rx_phaser_classifier (same shape as old valid_messege_out / valid_message_flag)
    output logic [127:0] message_out,
    output logic         message_valid
);

    // No backpressure here on purpose: the original UART path had no real
    // flow control back to RX_UART either (cts_out was declared but unused
    // at the top level). FIFO_DEPTH inside ethernet_mac is your cushion
    // against bursts; if you start seeing overruns, that's the place to add
    // real backpressure, not here.
    assign ready_out = 1'b1;

    logic [3:0]   byte_cnt;
    logic [127:0] shreg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_cnt      <= 4'd0;
            shreg         <= 128'd0;
            message_out   <= 128'd0;
            message_valid <= 1'b0;
        end else begin
            message_valid <= 1'b0;

            if (valid_out) begin
                shreg <= {shreg[119:0], data_out};   // shift new byte into LSB end

                if (byte_cnt == 4'd15) begin
                    // 16th byte just landed -- shreg above already reflects it
                    message_out   <= {shreg[119:0], data_out};
                    message_valid <= 1'b1;
                    byte_cnt      <= 4'd0;
                end else begin
                    byte_cnt <= byte_cnt + 4'd1;
                end

                // Optional: if you want each UDP payload (marked by last_out)
                // to always start a fresh message regardless of byte_cnt
                // (i.e. never straddle a message across two UDP packets),
                // uncomment the next two lines:
                // if (last_out) byte_cnt <= 4'd0;
            end
        end
    end

endmodule
