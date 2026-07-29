`timescale 1ns/1ps
//=============================================================================
// rmii_rx.sv
//
// RMII receive front-end for the Nexys A7 (LAN8720-style PHY, 100 Mbps).
// Converts the 2-bit @ 50 MHz RMII dibit stream into an aligned byte stream.
//
// Byte alignment strategy:
//   Ethernet preamble = 0x55 repeated -> on the wire (LSB first) this is the
//   dibit '01' repeated. We wait for carrier + first '01' dibit and lock the
//   byte boundary there. The MAC layer (eth_frame_rx) then consumes the
//   preamble bytes (0x55) and hunts for the SFD (0xD5).
//
// Notes:
//   * Everything here runs in the 50 MHz RMII clock domain. Cross to your
//     system clock with an async FIFO *after* this module.
//   * At 100 Mbps, CRS_DV may toggle at 25 MHz near the end of a frame.
//     We therefore treat the carrier as present while either of the last
//     two CRS_DV samples is high.
//=============================================================================
module rmii_rx (
    input  logic       clk50,          // 50 MHz RMII reference clock
    input  logic       rst_n,

    // RMII pins from PHY
    input  logic [1:0] rmii_rxd,
    input  logic       rmii_crs_dv,

    // Aligned byte stream out (clk50 domain)
    output logic [7:0] rx_data,
    output logic       rx_valid,       // 1-cycle pulse per assembled byte
    output logic       rx_frame_end    // 1-cycle pulse when carrier drops
);

    //-------------------------------------------------------------------------
    // Register the PHY inputs (these are synchronous to clk50, so a single
    // register stage is enough -- it also helps timing by using IOB registers)
    //-------------------------------------------------------------------------
    logic [1:0] rxd_q;
    logic       crs_q, crs_qq;

    always_ff @(posedge clk50) begin
        rxd_q  <= rmii_rxd;
        crs_q  <= rmii_crs_dv;
        crs_qq <= crs_q;
    end

    // Filtered carrier: high while either of the last two samples is high
    wire carrier = crs_q | crs_qq;

    //-------------------------------------------------------------------------
    // Dibit -> byte assembly
    // RMII sends the LSBs first: dibit0 = byte[1:0], dibit1 = byte[3:2], ...
    // Shifting in from the top means that after 4 dibits the first dibit
    // has landed in bits [1:0] -- i.e. the byte comes out correctly ordered.
    //-------------------------------------------------------------------------
    typedef enum logic {IDLE, RECV} state_t;
    state_t     state;
    logic [7:0] sh;         // dibit shift register
    logic [1:0] cnt;        // dibit counter within the current byte

    always_ff @(posedge clk50 or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            cnt          <= '0;
            rx_valid     <= 1'b0;
            rx_frame_end <= 1'b0;
        end else begin
            rx_valid     <= 1'b0;
            rx_frame_end <= 1'b0;

            unique case (state)
                //---------------------------------------------------------
                // Wait for carrier and the first '01' preamble dibit.
                // This establishes the byte boundary for the whole frame.
                //---------------------------------------------------------
                IDLE: begin
                    if (carrier && rxd_q == 2'b01) begin
                        sh    <= {rxd_q, sh[7:2]};
                        cnt   <= 2'd1;
                        state <= RECV;
                    end
                end

                //---------------------------------------------------------
                // Shift in dibits; emit a byte every 4th dibit.
                //---------------------------------------------------------
                RECV: begin
                    if (!carrier) begin
                        state        <= IDLE;
                        cnt          <= '0;
                        rx_frame_end <= 1'b1;
                    end else begin
                        sh  <= {rxd_q, sh[7:2]};
                        cnt <= cnt + 2'd1;
                        if (cnt == 2'd3) begin
                            rx_data  <= {rxd_q, sh[7:2]};
                            rx_valid <= 1'b1;
                        end
                    end
                end
            endcase
        end
    end

endmodule
