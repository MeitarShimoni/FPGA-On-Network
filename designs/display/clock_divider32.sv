// FILE : CLOCK DIVIDER
// Author : MEITAR SHIMONI
// DESCRIPTION : Creates Clock enable for FPGA Methodology at Baud Rate of 57600bps.
module clock_divider32#(parameter int div_by = 31250)(
    input logic sys_clk,
    input logic reset_n,
    output logic clk_32
);

logic [15:0] count; // update to $clog

always_ff @(posedge sys_clk or negedge reset_n) begin
    if(!reset_n) begin
        count <= 0;
        clk_32 <= 0;
    end else begin
        if(count == (div_by/1)-1) begin
            clk_32 <= 1;
            count <= 0;
        end else begin
            count++;
            clk_32 <= 0;
        end
    end

end

endmodule