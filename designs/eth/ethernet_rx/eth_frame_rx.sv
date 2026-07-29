`timescale 1ns/1ps
//=============================================================================
// eth_frame_rx.sv
//
// MAC-layer frame parser. Consumes the aligned byte stream from rmii_rx and:
//   1. Hunts for preamble (0x55) and SFD (0xD5)
//   2. Streams out the frame contents (DA + SA + EtherType + payload),
//      with the 4-byte FCS stripped off via a 4-byte delay line
//   3. Computes CRC32 over the whole frame incl. FCS and checks the
//      well-known residue value at end of frame
//
// Output convention:
//   m_data/m_valid : frame bytes, FCS already removed
//   frame_done     : 1-cycle pulse after the frame ends
//   frame_ok       : valid together with frame_done; 1 = CRC good
//
// Because the FCS length is only known once the carrier drops, m_valid
// cannot have an in-band "last" -- the classic next step is to write this
// stream into a packet FIFO and commit/drop the frame when frame_done
// arrives, based on frame_ok. Your ARP/ICMP/UDP parsers then read clean,
// CRC-verified frames only.
//=============================================================================
module eth_frame_rx (
    input  logic       clk,           // 50 MHz (same domain as rmii_rx)
    input  logic       rst_n,

    // From rmii_rx
    input  logic [7:0] rx_data,
    input  logic       rx_valid,
    input  logic       rx_frame_end,

    // Frame byte stream out (FCS stripped)
    output logic [7:0] m_data,
    output logic       m_valid,

    // End-of-frame status
    output logic       frame_done,    // 1-cycle pulse
    output logic       frame_ok       // CRC32 result, valid with frame_done
);

    //-------------------------------------------------------------------------
    // Ethernet CRC32 (IEEE 802.3), byte-wise, reflected form.
    // Init = 0xFFFFFFFF. After processing the entire frame INCLUDING the
    // received FCS, the register must equal the residue 0xDEBB20E3.
    // The 8-iteration loop is unrolled by synthesis into pure XOR logic.
    //-------------------------------------------------------------------------
    function automatic logic [31:0] crc32_byte
        (input logic [31:0] crc, input logic [7:0] data);
        logic [31:0] c;
        c = crc ^ {24'h0, data};
        for (int i = 0; i < 8; i++)
            c = c[0] ? (c >> 1) ^ 32'hEDB88320 : (c >> 1);
        return c;
    endfunction

    localparam logic [31:0] CRC_RESIDUE = 32'hDEBB20E3;

    //-------------------------------------------------------------------------
    // FSM
    //-------------------------------------------------------------------------
    typedef enum logic [1:0] {IDLE, PRE, DATA} state_t;
    state_t state;

    logic [31:0] crc;

    // 4-byte delay line: while receiving we always hold the last 4 bytes
    // back. When the frame ends, those 4 bytes are the FCS -> never emitted.
    logic [7:0] d0, d1, d2, d3;
    logic [2:0] fill;                  // 0..4, saturates at 4

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            m_valid    <= 1'b0;
            frame_done <= 1'b0;
            frame_ok   <= 1'b0;
            fill       <= '0;
            m_data    <= '0;
        end else begin
            m_valid    <= 1'b0;
            frame_done <= 1'b0;

            unique case (state)
                //---------------------------------------------------------
                // Wait for the first preamble byte
                //---------------------------------------------------------
                IDLE: begin
                    if (rx_valid && rx_data == 8'h55)
                        state <= PRE;
                end

                //---------------------------------------------------------
                // Consume preamble bytes, hunt for SFD (0xD5)
                //---------------------------------------------------------
                PRE: begin
                    if (rx_valid) begin
                        if (rx_data == 8'hD5) begin
                            state <= DATA;
                            crc   <= 32'hFFFFFFFF;
                            fill  <= '0;
                        end else if (rx_data != 8'h55) begin
                            state <= IDLE;      // garbage -> resync
                        end
                    end
                    if (rx_frame_end)
                        state <= IDLE;
                end

                //---------------------------------------------------------
                // Frame body: update CRC, push bytes through the delay
                // line, emit bytes once 4 are buffered behind them.
                //---------------------------------------------------------
                DATA: begin
                    if (rx_valid) begin
                        crc <= crc32_byte(crc, rx_data);

                        d0 <= rx_data;
                        d1 <= d0;
                        d2 <= d1;
                        d3 <= d2;

                        if (fill == 3'd4) begin
                            m_data  <= d3;      // byte that is now 4 deep
                            m_valid <= 1'b1;
                        end else begin
                            fill <= fill + 3'd1;
                        end
                    end

                    if (rx_frame_end) begin
                        frame_done <= 1'b1;
                        frame_ok   <= (crc == CRC_RESIDUE) ? 1'b1 : 1'b0;
                        state      <= IDLE;
                    end
                end
            endcase
        end
    end

endmodule
