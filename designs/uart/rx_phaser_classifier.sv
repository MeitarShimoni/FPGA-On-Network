/*==============================================================================

File    : rx_phaser_classifier.sv
Author  : Meitar Shimoni
Date    : 2026-04-28
----------------------------------------------------------------------------
Desc    : Checks Data, and Classify for stream, write or read commands. 
          Connected to 

*/




// module rx_phaser_classifier(
//     input  logic        clk,          // 240MHz (PLL)
//     input  logic        rst_n,
    
//     input logic         valid_in,
//     input logic [127:0] data_in,

//     output logic [24:0] address, 
//     output logic [31:0] wdata,

//     output logic        write_command_valid,
//     output logic        read_command_valid,

//     output logic [95:0] rgb_out,
//     // input  logic        rgb_out_ready,
//     output logic rgb_message_valid

// );



// localparam MSG_CLOSE = 8'h7D; // ASCII "}"
// localparam MSG_R_ASCCI = 8'h52; // ASCII "R"
// localparam MSG_G_ASCCI = 8'h47; // ASCII "G"
// localparam MSG_B_ASCCI = 8'h42; // ASCII "B"
// localparam MSG_L_ASCCI = 8'h4C; // ASCII "L"
// localparam MSG_W_ASCCI = 8'h57; // ASCII "W"
// localparam MSG_V_ASCCI = 8'h56; // ASCII "V"

// localparam MSG_I_ASCII = 8'h49; // ASCII "I"
// localparam MSG_H_ASCII = 8'h48; // ASCII "H"
// localparam MSG_COMA_ASCCI  = 8'h2C; // ASCII ","

// logic valid_in_d;
// logic valid_in_rise;
// always_ff @(posedge clk or negedge rst_n) begin
//     if(!rst_n) valid_in_d <= 1'b0;
//     else valid_in_d <= valid_in;
// end

// assign valid_in_rise = valid_in && !valid_in_d;

// logic [15:0][7:0] msg_out;


// // ================================================
// logic [23:0] rgb0, rgb1, rgb2, rgb3;

// assign rgb0 = {msg_out[14],msg_out[13],msg_out[12]};
// assign rgb1 = {msg_out[11],msg_out[9],msg_out[8]};
// assign rgb2 = {msg_out[7],msg_out[6],msg_out[4]};
// assign rgb3 = {msg_out[3],msg_out[2],msg_out[1]};
 
// assign rgb_out = {rgb0, rgb1, rgb2, rgb3};
// // ================================================



// assign msg_out = data_in[127:0];

// always_ff @(posedge clk or negedge rst_n) begin
//     if(!rst_n) begin
//         write_command_valid <= 1'b0;
//         read_command_valid  <= 1'b0;
//         rgb_message_valid <= 1'b0;
//         address <= 'd0;
//         wdata <= 'd0;
//     end else if(valid_in_rise) begin
//         write_command_valid <= 1'b0;
//         read_command_valid  <= 1'b0;
//         rgb_message_valid <= 1'b0;
//         address <= 'd0;
//         wdata <= 'd0;

//         // ----------------- WRITE COMMAND ----------------------
//         if(msg_out[14] == MSG_W_ASCCI && msg_out[9] == MSG_V_ASCCI && msg_out[4] == MSG_V_ASCCI) begin
//             // write_command_msg   <= {msg_out[13],msg_out[12],msg_out[11],msg_out[7],msg_out[6],msg_out[2],msg_out[1]};
//             write_command_valid <= 1'b1;
//             address <= {msg_out[13],msg_out[12],msg_out[11]};
//             wdata <= {8'd0,msg_out[6],msg_out[2],msg_out[1]};
//         end
//         // --------------- READ PC TO FPGA -----------------------
//         else if (msg_out[4] == MSG_R_ASCCI && (msg_out[9] != MSG_G_ASCCI) && (msg_out[5] != MSG_COMA_ASCCI)) begin
//             // read_command_msg   <= {msg_out[13], msg_out[12], msg_out[11]};
//             read_command_valid <= 1'b1;
//             address <= {msg_out[3],msg_out[2],msg_out[1]};
//         end
//         else begin
//             rgb_message_valid <= 1'b1;
//         end
//     end else begin
//         write_command_valid <= 1'b0;
//         read_command_valid  <= 1'b0;
//         rgb_message_valid <= 1'b0;
//     end
// end

// endmodule


module rx_phaser_classifier(
    input  logic         clk,
    input  logic         rst_n,
    
    input  logic         valid_in,
    input  logic [127:0] data_in,

    output logic [24:0]  address, 
    output logic [31:0]  wdata,

    output logic         write_command_valid,
    output logic         read_command_valid,

    output logic [95:0]  rgb_out,
    output logic         rgb_message_valid,
    input  logic         rgb_out_ready
);

localparam MSG_CLOSE      = 8'h7D; // ASCII "}"
localparam MSG_R_ASCCI    = 8'h52; // ASCII "R"
localparam MSG_G_ASCCI    = 8'h47; // ASCII "G"
localparam MSG_B_ASCCI    = 8'h42; // ASCII "B"
localparam MSG_L_ASCCI    = 8'h4C; // ASCII "L"
localparam MSG_W_ASCCI    = 8'h57; // ASCII "W"
localparam MSG_V_ASCCI    = 8'h56; // ASCII "V"
localparam MSG_I_ASCII    = 8'h49; // ASCII "I"
localparam MSG_H_ASCII    = 8'h48; // ASCII "H"
localparam MSG_COMA_ASCCI = 8'h2C; // ASCII ","

logic valid_in_d;
logic valid_in_rise;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        valid_in_d <= 1'b0;
    else
        valid_in_d <= valid_in;
end

assign valid_in_rise = valid_in && !valid_in_d;

logic [15:0][7:0] msg_out;

assign msg_out = data_in[127:0];

logic [23:0] rgb0, rgb1, rgb2, rgb3;
logic [95:0] rgb_next;

assign rgb0 = {msg_out[14], msg_out[13], msg_out[12]};
assign rgb1 = {msg_out[11], msg_out[9],  msg_out[8]};
assign rgb2 = {msg_out[7],  msg_out[6],  msg_out[4]};
assign rgb3 = {msg_out[3],  msg_out[2],  msg_out[1]};

assign rgb_next = {rgb0, rgb1, rgb2, rgb3};

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        write_command_valid <= 1'b0;
        read_command_valid  <= 1'b0;
        rgb_message_valid   <= 1'b0;
        rgb_out             <= 96'd0;
        address             <= 25'd0;
        wdata               <= 32'd0;
    end else begin

        write_command_valid <= 1'b0;
        read_command_valid  <= 1'b0;

        if (rgb_message_valid && rgb_out_ready) begin
            rgb_message_valid <= 1'b0;
        end

        if (valid_in_rise && !rgb_message_valid) begin
            address <= 25'd0;
            wdata   <= 32'd0;

            if (msg_out[14] == MSG_W_ASCCI &&
                msg_out[9]  == MSG_V_ASCCI &&
                msg_out[4]  == MSG_V_ASCCI) begin

                write_command_valid <= 1'b1;
                address <= {msg_out[13], msg_out[12], msg_out[11]};
                wdata   <= {8'd0, msg_out[6], msg_out[2], msg_out[1]};
            end

            else if (msg_out[4] == MSG_R_ASCCI &&
                    (msg_out[9] != MSG_G_ASCCI) &&
                    (msg_out[5] != MSG_COMA_ASCCI)) begin

                read_command_valid <= 1'b1;
                address <= {msg_out[3], msg_out[2], msg_out[1]};
            end

            else begin
                rgb_out           <= rgb_next;
                rgb_message_valid <= 1'b1;
            end
        end
    end
end

endmodule