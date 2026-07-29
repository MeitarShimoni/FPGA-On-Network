module dsp_top #(parameter int DATA_SIZE = 32)(
    input logic clk,
    input logic rst_n,

    // input stream
    input logic valid_in,                   // there is valid input
    output logic ready_in,                  // module is ready to accept data
    input logic [DATA_SIZE-1:0] data_in,    

    // output stream
    output logic valid_out,                 // module has valid data
    input logic ready_out,                  // output is ready to accept data
    output logic [DATA_SIZE-1:0] data_out
);


logic in_fire = valid_in && ready_in;       // handshake here the module sample
logic out_fire = valid_out && ready_out;    // output handshake

assign ready_in  = ready_out;
assign valid_out = valid_in;
assign data_out  = data_in; // passthrough DSP

// logic [DATA_SIZE-1:0] data_latched;

// always_ff @(posedge clk or negedge rst_n) begin
//     if (!rst_n) begin
//         data_latched <= 'd0;
//     end else if (in_fire) begin
//         data_latched <= data_in;
//     end
// end

// always_ff @(posedge clk or negedge rst_n) begin
//     if (!rst_n) begin
//         data_out <= 'd0;
//     end else if(out_fire) begin
//         data_out <= data_latched;
//     end
// end




endmodule