`timescale 1ns/1ps
//=============================================================================
// rmii_tx.sv
//
// RMII transmit serializer -- the mirror of rmii_rx. Takes a byte stream
// (valid/ready) and shifts it out as 2-bit dibits at 50 MHz, LSB pair
// first, with rmii_tx_en high for the duration.
//
// Timing contract:
//   * One byte takes 4 clocks. tx_ready is asserted when idle, and during
//     the 4th dibit of the current byte -- accepting the next byte there
//     keeps txd and tx_en gapless across the whole frame.
//   * When no byte follows, tx_en drops -- that IS the end-of-frame marker
//     on RMII (the receiver's carrier-drop). eth_frame_tx's IFG state
//     guarantees the required 12 byte times of silence between frames.
//
// Outputs are registered: the pin signals launch from flip-flops.
//=============================================================================
module rmii_tx (
    input  logic       clk50,
    input  logic       rst_n,

    // Byte stream in
    input  logic [7:0] tx_data,
    input  logic       tx_valid,
    output logic       tx_ready,


    // RMII pins to PHY
    output logic [1:0] rmii_txd,
    output logic       rmii_tx_en
);

    logic       active;
    logic [5:0] sh;          // remaining 3 dibits of the current byte
    logic [1:0] ecnt;        // index of the dibit currently on the pins

    assign tx_ready = !active || (ecnt == 2'd3);

    always_ff @(posedge clk50 or negedge rst_n) begin
        if (!rst_n) begin
            active     <= 1'b0;
            ecnt       <= '0;
            rmii_txd   <= '0;
            rmii_tx_en <= 1'b0;
        end else begin
            if (!active) begin
                if (tx_valid) begin              // first byte of a frame
                    active     <= 1'b1;
                    rmii_tx_en <= 1'b1;
                    rmii_txd   <= tx_data[1:0];  // dibit 0 out next cycle
                    sh         <= tx_data[7:2];
                    ecnt       <= '0;
                end else begin
                    rmii_tx_en <= 1'b0;
                    rmii_txd   <= '0;
                end
            end else begin
                if (ecnt == 2'd3) begin          // last dibit on pins now
                    if (tx_valid) begin          // gapless next byte
                        rmii_txd <= tx_data[1:0];
                        sh       <= tx_data[7:2];
                        ecnt     <= '0;
                    end else begin               // stream ended -> frame ends
                        active     <= 1'b0;
                        rmii_tx_en <= 1'b0;
                        rmii_txd   <= '0;
                    end
                end else begin                   // shift out dibits 1..3
                    rmii_txd <= sh[1:0];
                    sh       <= {2'b00, sh[5:2]};
                    ecnt     <= ecnt + 2'd1;
                end
            end
        end
    end

endmodule
