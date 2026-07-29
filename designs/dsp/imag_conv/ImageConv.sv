///////////////////////////////////////////////////////////////////////////////
// Company: Reichman Tech School / Google Project
// Engineer: Meitar Shimoni
// 
// Create Date: 03/03/2026
// Design Name: ImageConv
// Target Devices: FPGA / ASIC
// Tool Versions: Vivado / Questasim
///////////////////////////////////////////////////////////////////////////////

module ImageConv#(parameter int IMAGE_SIZE = 256)(
    input  logic clk,
    input  logic rst_n,

    // Filter Selection (0: Identity, 1: Gaussian, 2: Sharpen, 3: Sobel)
    input  logic [1:0] filter_sel,

    // Stream Input
    input  logic in_valid,
    output logic in_ready, // For backpressure
    input  logic [7:0] pixel_in,
    
    // Stream Output
    output logic out_valid,
    input  logic out_ready, // For backpressure
    output logic [7:0] pixel_out,
    
    output logic calc_done
);

logic in_fire;
logic out_fire;
assign in_fire = in_valid && in_ready;
assign out_fire = out_valid && out_ready;


localparam int DATA_WIDTH = 8;
localparam int LINE_SIZE = IMAGE_SIZE;
localparam int COUNTERS_WIDTH = $clog2(IMAGE_SIZE*IMAGE_SIZE);

// Filter Selection Constants
localparam logic [1:0] FILTER_IDENTITY = 2'd0;
localparam logic [1:0] FILTER_GAUSSIAN = 2'd1;
localparam logic [1:0] FILTER_SHARPEN  = 2'd2;
localparam logic [1:0] FILTER_SOBEL    = 2'd3;

// Coefficients & Shift (Now dynamic and SIGNED)
logic signed [7:0] c1,c2,c3;
logic signed [7:0] c4,c5,c6;
logic signed [7:0] c7,c8,c9;
logic [3:0] normalize_shift;

// Signals
logic [COUNTERS_WIDTH-1:0] pixels_counter; 
logic [COUNTERS_WIDTH-1:0] pixels_processed;

logic enable;
// line buffer:
logic [0:LINE_SIZE-1][DATA_WIDTH-1:0] line_buffer_1;
logic [0:LINE_SIZE-1][DATA_WIDTH-1:0] line_buffer_2;
logic [0:LINE_SIZE-1][DATA_WIDTH-1:0] line_buffer_3;

// Calc Registers:
logic [DATA_WIDTH-1:0] x1,x2,x3;
logic [DATA_WIDTH-1:0] x4,x5,x6;
logic [DATA_WIDTH-1:0] x7,x8,x9;

// Math Accumulators
logic signed [15:0] acc;
logic signed [15:0] shifted_acc;

logic [1:0] filter_sel_l;
always_ff @(posedge clk or negedge rst_n) begin
//always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        filter_sel_l <= 0;
    end else begin
        filter_sel_l <= filter_sel;
    end
end
// ==============================================================
//                  COEFFICIENT MULTIPLEXER
// ==============================================================
always_comb begin
    case (filter_sel_l)
        FILTER_IDENTITY: begin
            {c1,c2,c3} = {8'sd0, 8'sd0, 8'sd0};
            {c4,c5,c6} = {8'sd0, 8'sd1, 8'sd0};
            {c7,c8,c9} = {8'sd0, 8'sd0, 8'sd0};
            normalize_shift = 4'd0;
        end
        FILTER_GAUSSIAN: begin
            {c1,c2,c3} = {8'sd1, 8'sd2, 8'sd1};
            {c4,c5,c6} = {8'sd2, 8'sd4, 8'sd2};
            {c7,c8,c9} = {8'sd1, 8'sd2, 8'sd1};
            normalize_shift = 4'd4; // Divides accumulator by 16
        end
        FILTER_SHARPEN: begin
            {c1,c2,c3} = { 8'sd0, -8'sd1,  8'sd0};
            {c4,c5,c6} = {-8'sd1,  8'sd5, -8'sd1};
            {c7,c8,c9} = { 8'sd0, -8'sd1,  8'sd0};
            normalize_shift = 4'd0;
        end
        FILTER_SOBEL: begin
            {c1,c2,c3} = {-8'sd1,  8'sd0,  8'sd1};
            {c4,c5,c6} = {-8'sd2,  8'sd0,  8'sd2};
            {c7,c8,c9} = {-8'sd1,  8'sd0,  8'sd1};
            normalize_shift = 4'd0;
        end
        default: begin // Default to Identity
            {c1,c2,c3} = {8'sd0, 8'sd0, 8'sd0};
            {c4,c5,c6} = {8'sd0, 8'sd1, 8'sd0};
            {c7,c8,c9} = {8'sd0, 8'sd0, 8'sd0};
            normalize_shift = 4'd0;
        end
    endcase
end

// ==============================================================
//                              FSM 
// ===============================================================
typedef enum logic [1:0] {IDLE, LOAD, CALC, DONE} state_e;
state_e curr_state, next_state;

assign in_ready = (curr_state == LOAD || curr_state == CALC);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        curr_state <= IDLE;
    end else curr_state <= next_state;
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        enable <= 1'b0;
        pixels_counter <= 'd0;
        pixels_processed <= 'd0;
    end else begin
        case(curr_state)
        IDLE: 
        begin
            enable <= 1'b0;
            pixels_processed <= 'd0;
            pixels_counter <= 'd0;
        end
        LOAD: 
        begin 
            enable <= 1'b1; 
            pixels_counter <= pixels_counter + 1'b1;
        end
        CALC: 
        begin
            enable <= 1'b1;
            pixels_counter <= pixels_counter + 1'b1;
            pixels_processed <= pixels_processed + 1'b1;
        end
        DONE: 
        begin
            enable <= 1'b0;
        end
        endcase
    end
end

// ============= Next State Registered =================
always_comb begin
    case(curr_state)
    IDLE: next_state = (in_valid) ? LOAD : IDLE;
    LOAD: next_state = (pixels_counter == (IMAGE_SIZE * 2) + 3) ? CALC : LOAD;
    CALC: next_state = (pixels_processed == (IMAGE_SIZE*IMAGE_SIZE-1)) ? DONE : CALC;
    DONE: next_state = IDLE;
    default: next_state = IDLE;
    endcase
end

// ==============================================================
//                          CALCULATION 
// ==============================================================

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        line_buffer_1 <= 'd0;
        line_buffer_2 <= 'd0;
        line_buffer_3 <= 'd0;
    end else if(curr_state == LOAD || curr_state == CALC) begin
        line_buffer_1 <= {pixel_in, line_buffer_1[0:LINE_SIZE-2]}; 
        line_buffer_2 <= {line_buffer_1[LINE_SIZE-1], line_buffer_2[0:LINE_SIZE-2]};
        line_buffer_3 <= {line_buffer_2[LINE_SIZE-1], line_buffer_3[0:LINE_SIZE-2]};
    end
end

// =============================================================
//                            WINDOW 
// =============================================================
always_ff @(posedge clk or negedge rst_n) begin 
    if (!rst_n) begin
        {x1, x2, x3} <= '0;
        {x4, x5, x6} <= '0;
        {x7, x8, x9} <= '0;
    end else begin
        {x3, x2, x1} <= {x2, x1, line_buffer_3[LINE_SIZE-1]};
        {x6, x5, x4} <= {x5, x4, line_buffer_2[LINE_SIZE-1]};
        {x9, x8, x7} <= {x8, x7, line_buffer_1[LINE_SIZE-1]};
    end
end

// =============================================================
//                      COMBINATIONAL LOGIC
// =============================================================

assign out_valid = ((curr_state == CALC) && (curr_state != DONE)); //  ? 1'b1 : 1'b0;
assign calc_done = (curr_state == DONE);

always_comb begin
    // 1. Zero-extend unsigned pixels, then cast to signed for safe multiplication
    acc =
        c1 * $signed({1'b0, x1}) + c2 * $signed({1'b0, x2}) + c3 * $signed({1'b0, x3}) +
        c4 * $signed({1'b0, x4}) + c5 * $signed({1'b0, x5}) + c6 * $signed({1'b0, x6}) +
        c7 * $signed({1'b0, x7}) + c8 * $signed({1'b0, x8}) + c9 * $signed({1'b0, x9});

    // 2. Arithmetic shift
    shifted_acc = acc >>> normalize_shift;

    // 3. Hardware Saturation (Clamping)
    if (shifted_acc < 0) begin
        pixel_out = 8'd0;
    end else if (shifted_acc > 255) begin
        pixel_out = 8'd255;
    end else begin
        pixel_out = shifted_acc[7:0];
    end
end

function void print_window();
    $display("--- Window at Pixel Count: %0d ---", pixels_counter);
    $display("[%3d] [%3d] [%3d]", x1, x2, x3);
    $display("[%3d] [%3d] [%3d]", x4, x5, x6);
    $display("[%3d] [%3d] [%3d]\n", x7, x8, x9);
endfunction

endmodule