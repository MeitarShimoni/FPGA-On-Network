module sram_32bit #(
    parameter int ADDR_WIDTH = 15,              // 3k depth by default
    parameter int DATA_WIDTH = 32               // Holds 4 pixels (8-bit each) [cite: 44]
)(
    input  logic                   clk,         // System clock (100MHz) 
    
    // Write Port (from Sequencer/DMA)
    input  logic                   we,          // Write enable
    input  logic [ADDR_WIDTH-1:0]  waddr,       // Write address
    input  logic [DATA_WIDTH-1:0]  din,         // Data in (e.g., R0, R1, R2, R3) [cite: 45]
    
    // Read Port (to TX Sequencer/Display)
    input  logic [ADDR_WIDTH-1:0]  raddr,       // Read address
    output logic [DATA_WIDTH-1:0]  dout         // Data out
);

/*
    NOTE: 
        For Block RAM The Read Channel has to be Registered!
        For Disturbuted
*/

    // Memory array declaration
    // Vivado will infer this as BRAM if accessed synchronously
    (* ram_style = "block" *)
    // (* ram_style = "distributed" *)
    logic [DATA_WIDTH-1:0] mem [(2**ADDR_WIDTH)-1:0];

    // Synchronous Write Process
    always_ff @(posedge clk) begin
        if (we) begin
            mem[waddr] <= din;
        end
        dout <= mem[raddr]; // For BLOCK RAM!
    end

    // assign dout = mem[raddr]; // For Disturbuted RAM

endmodule