

// module dsp_manager #(
//     parameter int ADDR_WIDTH = 16,
//     parameter int DATA_WIDTH = 32
// )(
//     input  logic clk,
//     input  logic rst_n,

//     input  logic start,
//     input  logic [ADDR_WIDTH-1:0] img_size_i,

//     output logic done,
//     output logic busy,

//     // Input SRAM read side
//     output logic [ADDR_WIDTH-1:0] sram_in_raddr,
//     input  logic [DATA_WIDTH-1:0] sram_in_rdata,

//     // Output SRAM write side
//     output logic sram_out_we,
//     output logic [ADDR_WIDTH-1:0] sram_out_waddr,
//     output logic [DATA_WIDTH-1:0] sram_out_wdata,

//     // DSP input stream
//     output logic dsp_valid_in,
//     input  logic dsp_ready_in,
//     output logic [DATA_WIDTH-1:0] dsp_data_in,

//     // DSP output stream
//     input  logic dsp_valid_out,
//     output logic dsp_ready_out,
//     input  logic [DATA_WIDTH-1:0] dsp_data_out
// );

// dsp_top 



// typedef enum logic [2:0] {
//     IDLE,
//     RUN,
//     DONE
// } state_e;

// state_e current_state, next_state;

// always_ff @(posedge clk or negedge rst_n) begin
//     if (!rst_n) begin
//         current_state <= IDLE;
//     end else begin
//         current_state <= next_state;
//     end
// end

// always_ff @(posedge clk or negedge rst_n) begin
//     if (!rst_n) begin
        
//     end else begin
//         case(current_state)
//         IDLE:
//         begin
            
//         end
//         RUN:
//         begin
        
//         end
//         DONE:
//         begin
        
//         end
//         endcase
//     end
// end


// always_comb begin
//     case(current_state)
//     IDLE: next_state <= (start) ? RUN : IDLE;
//     RUN: next_state <= (done) ? DONE : RUN; 
//     DONE: next_state <= IDLE;
//     endcase
// end



// endmodule