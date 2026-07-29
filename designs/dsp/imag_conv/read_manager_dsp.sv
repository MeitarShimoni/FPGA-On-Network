module read_manager_dsp #(
    parameter int TOTAL_PIXELS = 256,
    parameter logic [7:0] START_ADDR = 8'h0)
    (    
    input logic clk,
    input logic rst_n,
    input logic start,

    // Memory Access Signals
    output logic [15:0] rd_addr,
    input  logic [7:0] rd_data,

    // Output Streaming
    output logic valid_out,
    input  logic ready_out,
    output logic [7:0] data_out

);

logic wen;
// assign data_out = rd_data;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        data_out <= 'd0;
    end else begin
        data_out <= rd_data;
    end
end
typedef enum logic [1:0] {IDLE, READ, DONE} state_e;
state_e curr_state, next_state;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        curr_state <= IDLE;
    end else curr_state <= next_state;
end


always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_addr <= 'd0;
        wen <= 1'b0;
        valid_out <= 1'b0;
    end else begin
        case(curr_state)
        IDLE: 
        begin
            rd_addr <= 'd0;
            wen <= 1'b0;
            valid_out <= 1'b0; 
        end
        READ: 
        begin 
            rd_addr <= (ready_out) ? rd_addr + 1 : rd_addr;
            valid_out <= 1'b1; 
            wen <= 1'b0;
        end
        DONE: wen <= 1'b0;
        endcase
    end
end


// ============= Next State Registered =================
always_comb begin
    case(curr_state)
    IDLE: next_state = (start) ? READ : IDLE;
    READ: next_state = (rd_addr == TOTAL_PIXELS-2) ? DONE : READ;
    DONE: next_state = IDLE;
    default: next_state = IDLE;
    endcase
end


endmodule