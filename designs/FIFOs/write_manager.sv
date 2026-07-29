

module write_manager #(
    parameter int TOTAL_PIXELS = 65536
)(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        in_valid,
    output logic         in_ready,

    input  logic [7:0]  pixel_in,

    output logic [7:0]  data_out,
    output logic [15:0] addr_out,
    output logic        sram_we,
    output logic        frame_done
);

// One grayscale byte in == one pixel == one SRAM write, no framing/decoding
// needed: ethernet_mac already hands us exactly the image's pixel bytes in
// row-major order. SRAM write is single-cycle, so every valid byte is
// accepted immediately -- no elastic buffering required.
assign in_ready = 1'b1;
assign sram_we  = in_valid;
assign data_out = pixel_in;

logic [15:0] pixel_addr;
assign addr_out = pixel_addr;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pixel_addr <= 16'd0;
        frame_done <= 1'b0;
    end else begin
        frame_done <= 1'b0;

        if (in_valid) begin
            if (pixel_addr == TOTAL_PIXELS - 1) begin
                frame_done <= 1'b1;
                pixel_addr <= 16'd0;
            end else begin
                pixel_addr <= pixel_addr + 1'b1;
            end
        end
    end
end

endmodule
