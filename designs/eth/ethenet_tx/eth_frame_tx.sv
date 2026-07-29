`timescale 1ns/1ps
//=============================================================================
// eth_frame_tx.sv
//
// Ethernet frame builder -- the mirror of eth_frame_rx. Given a payload
// byte stream and the address/type fields, it emits a complete frame as a
// byte stream toward rmii_tx:
//
//   preamble(7x55) + SFD(D5) + DA + SA + EtherType + payload
//   + zero-pad to 60 bytes + FCS(~CRC32, LSB byte first)  ...then 12-byte IFG
//
// CRC32 is computed on the fly over DA..pad (NOT preamble/SFD) -- the same
// crc32_byte function as the receiver, with the transmit conventions:
// complement at the end, transmit low byte first.
//
// Handshake rules (standard valid/ready):
//   * A frame starts when pl_valid is seen in IDLE. dst_mac/src_mac/
//     ether_type are latched at that moment.
//   * The payload provider MUST keep pl_valid high until pl_last is
//     consumed (one byte per 4 clocks is all rmii_tx can drink, so any
//     provider keeps up). A stall mid-payload would drop tx_valid and
//     corrupt the frame on the wire -- guarded by an assertion in sim.
//   * Output stream (tx_*) is combinational mux from the FSM; rmii_tx
//     registers it.
//
// v1 limitations: no max-length guard (provider must keep payload <= 1500).
//=============================================================================
module eth_frame_tx (
    input  logic        clk,
    input  logic        rst_n,

    // Frame fields (sampled when the frame starts)
    input  logic [47:0] dst_mac,
    input  logic [47:0] src_mac,
    input  logic [15:0] ether_type,

    // Payload byte stream in
    input  logic [7:0]  pl_data,
    input  logic        pl_valid,
    input  logic        pl_last,
    output logic        pl_ready,

    // Byte stream out (to rmii_tx)
    output logic [7:0]  tx_data,
    output logic        tx_valid,
    input  logic        tx_ready,

    output logic        busy
);

    //-------------------------------------------------------------------------
    // CRC32 (same as RX)
    //-------------------------------------------------------------------------
    function automatic logic [31:0] crc32_byte
        (input logic [31:0] crc, input logic [7:0] data);
        logic [31:0] c;
        c = crc ^ {24'h0, data};
        for (int i = 0; i < 8; i++)
            c = c[0] ? (c >> 1) ^ 32'hEDB88320 : (c >> 1);
        return c;
    endfunction

    //-------------------------------------------------------------------------
    // FSM
    //-------------------------------------------------------------------------
    typedef enum logic [2:0] {IDLE, PRE, SFD, HDR, PAY, PAD, FCS, IFG} state_t;
    state_t state;

    logic [47:0] dst_q, src_q;
    logic [15:0] type_q;
    logic [31:0] crc;
    logic [2:0]  pcnt;      // preamble byte counter 0..6
    logic [10:0] bcnt;      // bytes since DA (0 = first DA byte)
    logic [1:0]  fcnt;      // FCS byte counter
    logic [5:0]  icnt;      // inter-frame gap: 12 byte times = 48 clocks

    wire advance = tx_valid && tx_ready;   // one output byte accepted

    // Header byte mux: 0-5 DA, 6-11 SA, 12-13 EtherType (big-endian)
    function automatic logic [7:0] hdr_byte(input logic [10:0] idx);
        if      (idx <= 11'd5)  return 8'((dst_q >> (8 * (5  - idx))));
        else if (idx <= 11'd11) return 8'((src_q >> (8 * (11 - idx))));
        else if (idx == 11'd12) return type_q[15:8];
        else                    return type_q[7:0];
    endfunction

    // FCS = complemented CRC, transmitted LSB byte first
    wire [31:0] fcs = ~crc;
    function automatic logic [7:0] fcs_byte(input logic [1:0] idx);
        return fcs[8*idx +: 8];
    endfunction

    //-------------------------------------------------------------------------
    // Output mux (combinational; rmii_tx registers these)
    //-------------------------------------------------------------------------
    always_comb begin
        tx_valid = 1'b0;
        tx_data  = 8'h00;
        pl_ready = 1'b0;

        unique case (state)
            PRE: begin tx_valid = 1'b1;     tx_data = 8'h55;           end
            SFD: begin tx_valid = 1'b1;     tx_data = 8'hD5;           end
            HDR: begin tx_valid = 1'b1;     tx_data = hdr_byte(bcnt);  end
            PAY: begin tx_valid = pl_valid; tx_data = pl_data;
                       pl_ready = tx_ready;                            end
            PAD: begin tx_valid = 1'b1;     tx_data = 8'h00;           end
            FCS: begin tx_valid = 1'b1;     tx_data = fcs_byte(fcnt);  end
            default: ;                      // IDLE, IFG: no output
        endcase
    end

    assign busy = (state != IDLE);

    //-------------------------------------------------------------------------
    // State / counters / CRC
    //-------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            pcnt  <= '0;
            bcnt  <= '0;
            fcnt  <= '0;
            icnt  <= '0;
            crc   <= '0;
        end else begin
            unique case (state)
                IDLE: if (pl_valid) begin       // a frame is being offered
                    dst_q  <= dst_mac;
                    src_q  <= src_mac;
                    type_q <= ether_type;
                    crc    <= 32'hFFFFFFFF;
                    pcnt   <= '0;
                    bcnt   <= '0;
                    state  <= PRE;
                end

                PRE: if (advance) begin
                    pcnt <= pcnt + 3'd1;
                    if (pcnt == 3'd6) state <= SFD;
                end

                SFD: if (advance) begin
                    bcnt  <= '0;
                    state <= HDR;
                end

                HDR: if (advance) begin
                    crc  <= crc32_byte(crc, tx_data);
                    bcnt <= bcnt + 11'd1;
                    if (bcnt == 11'd13) state <= PAY;
                end

                PAY: if (advance) begin
                    crc  <= crc32_byte(crc, tx_data);
                    bcnt <= bcnt + 11'd1;
                    if (pl_last) begin
                        // bcnt is the index of THIS byte; total so far = bcnt+1
                        state <= (bcnt >= 11'd59) ? FCS : PAD;
                        fcnt  <= '0;
                    end
                end

                PAD: if (advance) begin
                    crc  <= crc32_byte(crc, tx_data);
                    bcnt <= bcnt + 11'd1;
                    if (bcnt == 11'd59) begin   // this advance is byte #60
                        state <= FCS;
                        fcnt  <= '0;
                    end
                end

                FCS: if (advance) begin
                    fcnt <= fcnt + 2'd1;
                    if (fcnt == 2'd3) begin
                        state <= IFG;
                        icnt  <= '0;
                    end
                end

                IFG: begin                      // 96 bit times of silence
                    icnt <= icnt + 6'd1;
                    if (icnt == 6'd47) state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    // The payload provider must not stall mid-frame: pl_valid low in PAY
    // would drop tx_valid, break rmii_tx_en, and corrupt the frame.
    no_underrun: assert property (
        @(posedge clk) disable iff (!rst_n) (state == PAY) |-> pl_valid)
        else $error("payload underrun: pl_valid dropped during PAY");
`endif

endmodule
