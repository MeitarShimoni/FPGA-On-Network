module write_manager_dsp #(parameter int TOTAL_PIXELS = 256)(
    input logic clk,
    input logic rst_n,
    // input logic start,

    input logic [7:0] data_in,
    input logic valid_in,
    output logic ready_in,
    input logic calc_done,
    // output logic valid_out,


    output logic last,
    output logic [7:0] data_out,
    output logic [15:0] wr_addr,
    output logic wen

);

assign ready_in = 1'b1;
// assign data_out = data_in;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        data_out <= 'd0;
    end else begin
        data_out <= data_in;
    end
end
typedef enum logic [1:0] {IDLE, RUN, DONE} state_e;
state_e curr_state, next_state;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        curr_state <= IDLE;
    end else curr_state <= next_state;
end


always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        last <= 1'b0;
        wen <= 1'b0;
    end else begin
        case(curr_state)
        IDLE: 
        begin
            last <= 1'b0;
            wr_addr <= 'd0;
            wen <= 1'b0;
            if (valid_in) begin
                wen <= 1'b1;
                
            end
        end
        RUN: 
        begin 
            wr_addr <= (valid_in && !calc_done) ? wr_addr + 1 : wr_addr;
            wen <= 1'b1;
        end
        DONE: begin
            wen <= 1'b0;
            last <= 1'b1;

        end
        endcase
    end
end


// ============= Next State Registered =================
always_comb begin
    case(curr_state)
    IDLE: next_state = (valid_in) ? RUN : IDLE;
    // RUN: next_state = (calc_done) ? DONE : RUN;
    RUN: next_state = (wr_addr == TOTAL_PIXELS-2) ? DONE : RUN;
    DONE: next_state = IDLE;
    default: next_state = IDLE;
    endcase
end


endmodule