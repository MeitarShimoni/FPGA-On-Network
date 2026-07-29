
// package Asynchronouce_FIFO_Design_Params
//     parameter int DATA_WIDTH = 32;
//     parameter int FIFO_SIZE = 5;
// endpackage

//import Asynchronouce_FIFO_Design_Params::*;

module fifo_async #(
    parameter int DATA_WIDTH = 32,
    parameter int FIFO_SIZE = 4,
    parameter int HALF_FULL_LEVEL = 3 // to get actial half on time use 3
)(
    
    input logic clk_in,
    input logic rst_n,
    input logic wr_en,
    output logic full,
    output logic half_full,

    input logic clk_out,
    input logic rd_en,
    output logic empty,

    input logic [DATA_WIDTH-1:0] din,
    output logic [DATA_WIDTH-1:0] dout 

);

    // using synchronizer,
    // using counter on binary bits,
    // using gray_code for the data, only one changes so you can use normal synchronizers

    localparam int CNT_SIZE = $clog2(FIFO_SIZE);
    
    logic [CNT_SIZE:0] wr_addr_bin, rd_addr_bin;
    logic [CNT_SIZE:0] wr_addr_gray, rd_addr_gray;
    logic [DATA_WIDTH-1:0] mem [0:(FIFO_SIZE-1)];
    
    // Write Logic 
    always_ff @(posedge clk_in or negedge rst_n) begin
        if (!rst_n) 
            wr_addr_bin <= 'd0;
        else begin
        
            if(wr_en && !full) begin
                mem[wr_addr_bin[CNT_SIZE-1:0]] <= din;
                wr_addr_bin <= wr_addr_bin + 1;
            end
        
        end
    end

    // Read Logic 
    always_ff @(posedge clk_out or negedge rst_n) begin
        if (!rst_n) 
            rd_addr_bin <= 'd0;
        else begin
        
            if(rd_en && !empty) begin
                rd_addr_bin <= rd_addr_bin + 1;
                dout <= mem[rd_addr_bin[CNT_SIZE-1:0]];
            end
            // else dout <= 'bX;

        end
    end

    // assign dout = mem[rd_addr_bin[CNT_SIZE-1:0]];

    // Binary To Gray for wr_addr
    assign wr_addr_gray = (wr_addr_bin >> 1) ^ wr_addr_bin;

    // Binary To Gray for rd_addr
    assign rd_addr_gray = (rd_addr_bin >> 1) ^ rd_addr_bin;

    // 2 Stage Sequencer for rd_addr_gray
    logic [CNT_SIZE:0] rd_addr_gray_sync_0, rd_addr_gray_sync_1;

    always_ff @(posedge clk_in or negedge rst_n) begin
        if (!rst_n) begin
            rd_addr_gray_sync_0 <= 'd0;
            rd_addr_gray_sync_1 <= 'd0;
        end else begin
            rd_addr_gray_sync_0 <= rd_addr_gray;
            rd_addr_gray_sync_1 <= rd_addr_gray_sync_0;
        end
    end

    // 2 Stage Sequencer for wr_addr_gray
    logic [CNT_SIZE:0] wr_addr_gray_sync_0, wr_addr_gray_sync_1;

    always_ff @(posedge clk_out or negedge rst_n) begin
        if (!rst_n) begin
            wr_addr_gray_sync_0 <= 'd0;
            wr_addr_gray_sync_1 <= 'd0;
        end else begin
            wr_addr_gray_sync_0 <= wr_addr_gray;
            wr_addr_gray_sync_1 <= wr_addr_gray_sync_0;
        end
    end

    logic [CNT_SIZE:0] rd_addr_bin_sync;
    logic [CNT_SIZE:0] wr_addr_bin_sync;
    // Gray Code to Binary
    always_comb begin
        rd_addr_bin_sync[CNT_SIZE] = rd_addr_gray_sync_1[CNT_SIZE]; // MSB is same
        // Loop creates the XOR chain for the rest
        for (int i = CNT_SIZE-1; i >= 0; i--) begin
            rd_addr_bin_sync[i] = rd_addr_bin_sync[i+1] ^ rd_addr_gray_sync_1[i];
        end
    end

    always_comb begin
        wr_addr_bin_sync[CNT_SIZE] = wr_addr_gray_sync_1[CNT_SIZE];
        for (int i = CNT_SIZE-1; i >= 0; i--) begin
            wr_addr_bin_sync[i] = wr_addr_bin_sync[i+1] ^ wr_addr_gray_sync_1[i];
        end
    end

    assign empty = (wr_addr_bin_sync == rd_addr_bin);

    assign full = (wr_addr_bin[CNT_SIZE] != rd_addr_bin_sync[CNT_SIZE]) && 
    (wr_addr_bin[CNT_SIZE-1:0] == rd_addr_bin_sync[CNT_SIZE-1:0]);

    // ------------------- HALF FULL FLAG LOGIC ------------ 
    logic [CNT_SIZE:0] fill_level;
    assign fill_level = wr_addr_bin - rd_addr_bin_sync;    
    assign half_full = (fill_level >= HALF_FULL_LEVEL) ? 1'b1 : 1'b0;
    // assign empty = (wr_addr_gray_sync_1 == rd_addr_gray) ? 1'b1 : 1'b0;
    // assign full = ((rd_addr_gray_sync_1[CNT_SIZE] == wr_addr_gray[CNT_SIZE]) && (rd_addr_gray_sync_1[CNT_SIZE-1] == wr_addr_gray[CNT_SIZE-1])) ? 1'b1 : 1'b0;


endmodule