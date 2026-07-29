`timescale 1ns/1ps
//=============================================================================
// eth_packet_fifo.sv  -- rev B: BRAM-friendly memory coding
//
// Same behavior and ports as rev A (commit/rewind packet FIFO), but the
// memory is restructured so Vivado infers Block RAM instead of ~18k
// flip-flops + a giant read multiplexer:
//
//   1. The RAM lives in its own process with NO reset -- an async reset in
//      the process sensitivity list disqualifies BRAM inference.
//   2. ONE write statement / one write port. The commit-cycle LAST-flag
//      fixup is folded into the same port via a mux; this is legal because
//      wr_valid and frame_done never coincide (asserted below).
//
// 2048 x 9 bits fits exactly one RAMB18.
//=============================================================================
module eth_packet_fifo #(
    parameter int DEPTH = 2048            // must be a power of two
)(
    input  logic       clk,
    input  logic       rst_n,

    //--- Write side: connects 1:1 to eth_frame_rx / mac_filter outputs -----
    input  logic [7:0] wr_data,
    input  logic       wr_valid,
    input  logic       frame_done,
    input  logic       frame_ok,
    output logic       frame_dropped,     // 1-cycle pulse: frame discarded

    //--- Read side: FWFT, valid/ready ---------------------------------------
    output logic [7:0] rd_data,
    output logic       rd_last,
    output logic       rd_valid,
    input  logic       rd_ready
);

    localparam int AW = $clog2(DEPTH);

    (* ram_style = "block" *) logic [8:0] mem [DEPTH];

    logic [AW:0] wr_ptr;     // speculative write pointer
    logic [AW:0] wr_ptr_c;   // committed write pointer (reader's horizon)
    logic [AW:0] rd_ptr;

    wire full  = (wr_ptr[AW] != rd_ptr[AW]) &&
                 (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);
    wire empty = (rd_ptr == wr_ptr_c);

    logic [7:0] last_byte;   // most recent byte, for the LAST-flag fixup
    logic       wrote_any;   // current frame has >= 1 stored byte
    logic       ovf;         // current frame hit a full FIFO -> dropped

    // Frame verdict at end of frame
    wire commit  = frame_done &&  (frame_ok && wrote_any && !ovf);
    wire discard = frame_done && !(frame_ok && wrote_any && !ovf);

    //-------------------------------------------------------------------------
    // Memory: single write port, no reset. Normal cycles write the incoming
    // byte with LAST=0; the commit cycle re-writes the final byte with
    // LAST=1. The two uses share the port via the mux below -- safe because
    // wr_valid and frame_done never coincide.
    //-------------------------------------------------------------------------
    wire            do_write = wr_valid && !ovf && !full;
    wire            wr_en    = do_write || commit;
    wire [AW-1:0]   wr_addr  = commit ? (wr_ptr[AW-1:0] - 1'b1)
                                      :  wr_ptr[AW-1:0];
    wire [8:0]      wr_word  = commit ? {1'b1, last_byte}
                                      : {1'b0, wr_data};

    always_ff @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_word;
    end

    //-------------------------------------------------------------------------
    // Write-side control (pointers, flags) -- ordinary registers, async reset
    //-------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr        <= '0;
            wr_ptr_c      <= '0;
            wrote_any     <= 1'b0;
            ovf           <= 1'b0;
            frame_dropped <= 1'b0;
            last_byte     <= '0;
        end else begin
            frame_dropped <= 1'b0;

            if (wr_valid && !ovf) begin
                if (full) begin
                    ovf <= 1'b1;                       // poison the frame
                end else begin
                    last_byte <= wr_data;
                    wr_ptr    <= wr_ptr + 1'b1;
                    wrote_any <= 1'b1;
                end
            end

            if (frame_done) begin
                if (commit) begin
                    wr_ptr_c <= wr_ptr;                // publish the frame
                end else begin
                    wr_ptr <= wr_ptr_c;                // rewind
                    if (wrote_any || ovf)
                        frame_dropped <= 1'b1;
                end
                wrote_any <= 1'b0;
                ovf       <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    // The commit-cycle fixup shares the single write port, so a data write
    // must never coincide with frame_done. eth_frame_rx guarantees this.
    no_write_on_done: assert property (
        @(posedge clk) disable iff (!rst_n) !(wr_valid && frame_done))
        else $error("wr_valid and frame_done asserted in the same cycle");
`endif

    //-------------------------------------------------------------------------
    // Read side: first-word-fall-through.
    // RAM read in its own reset-free process (BRAM output path);
    // rd_ptr / rd_valid control in a normal resettable process.
    //-------------------------------------------------------------------------
    wire rd_en = !empty && (!rd_valid || rd_ready);

    logic [8:0] rd_word;

    always_ff @(posedge clk) begin
        if(!rst_n) begin
            rd_word <= 'd0;
        end else if (rd_en) begin
            rd_word <= mem[rd_ptr[AW-1:0]];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr   <= '0;
            rd_valid <= 1'b0;
        end else begin
            if (rd_en) begin
                rd_ptr   <= rd_ptr + 1'b1;
                rd_valid <= 1'b1;
            end else if (rd_valid && rd_ready) begin
                rd_valid <= 1'b0;
            end
        end
    end

    assign {rd_last, rd_data} = rd_word;

endmodule
