//==============================================================================
// eth_tx_msg_streamer.sv
//
// Replaces UART_TX on the transmit side. sram_to_uart_packet_manager is kept
// completely unchanged -- it still thinks it's talking to a UART: it pulses
// start_uart_tx with a 16-byte message_in array latched, waits for
// tx_uart_done, and only asserts a new start once tx_uart_ready is back high.
// This module just translates that same handshake into ethernet_mac's
// AXI-stream-style data_in/valid_in/last_in/ready_in port, one byte per
// accepted transfer, with last_in high on the 16th byte of each message
// (so ethernet_mac knows where each outgoing UDP payload ends).
//==============================================================================

module eth_tx_msg_streamer #(
    parameter int MSG_BYTES = 16
)(
    input  logic       clk,
    input  logic       rst_n,

    // Same interface sram_to_uart_packet_manager used to drive into UART_TX
    input  logic               start_uart_tx,
    input  logic [MSG_BYTES-1:0][7:0] message_in,
    output logic               tx_uart_ready,
    output logic               tx_uart_done,

    // To ethernet_mac (FPGA -> network)
    output logic [7:0] data_in,
    output logic       valid_in,
    output logic       last_in,
    input  logic       ready_in
);

    typedef enum logic [1:0] {IDLE, SEND, DONE} state_t;
    state_t state;

    logic [$clog2(MSG_BYTES)-1:0] idx;
    logic [MSG_BYTES-1:0][7:0]    msg_reg;

    assign tx_uart_ready = (state == IDLE);
    assign data_in       = msg_reg[idx];
    assign valid_in       = (state == SEND);
    assign last_in        = (state == SEND) && (idx == MSG_BYTES-1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            idx          <= '0;
            msg_reg      <= '0;
            tx_uart_done <= 1'b0;
        end else begin
            tx_uart_done <= 1'b0;

            unique case (state)
                IDLE: begin
                    if (start_uart_tx) begin
                        msg_reg <= message_in;
                        idx     <= '0;
                        state   <= SEND;
                    end
                end

                SEND: begin
                    if (ready_in) begin // handshake completed this cycle
                        if (idx == MSG_BYTES-1) begin
                            state <= DONE;
                        end else begin
                            idx <= idx + 1'b1;
                        end
                    end
                end

                DONE: begin
                    tx_uart_done <= 1'b1;   // one-cycle pulse, mirrors old tx_uart_done
                    state        <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
