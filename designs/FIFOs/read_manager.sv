

module read_manager #(
    parameter int IMAGE_SIZE = 8*8,
    parameter int DATA_WIDTH = 32

)(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        start_read,
    input logic [31:0] img_size_i,

    output logic [15:0] raddr,
    input  logic [DATA_WIDTH-1:0] rdata,

    output logic [DATA_WIDTH-1:0] dout,
    output logic        out_valid,
    input  logic        out_ready,

    output logic        read_done
);


logic [127:0] message_to_uart;


typedef enum logic [2:0] {
    IDLE,
    READ,
    SEND,
    WAIT_READY,
    DONE
} state_e;

state_e current_state, next_state;

logic [15:0] read_count;
logic        fire;

assign fire = out_valid && out_ready;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        current_state <= IDLE;
    end else begin
        current_state <= next_state;
    end
end

logic [1:0] cnt;
always_comb begin 
    case(current_State)
        IDLE: 
        begin
            if (start_read) begin
                next_state = READ;
            end else begin
                next_state = IDLE;
            end
        end
        READ:
        begin
            next_state = (cnt == IMAGE_SIZE - 1) ? SEND : READ;
        end

        SEND:
        begin
            next_state = (out_ready) DONE;
        end
        DONE:
        begin
        
        end

    endcase
    
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        addr <=` 16'd0;   
        cnt <= 2'd0;     
    end else begin
        case(current_state)
        IDLE:
        begin
            
        end
        READ:
        begin
            cnt <= cnt + 1;
            addr <= addr + 1;
        end
        SEND:
        begin
            cnt <= 0;
            addr <= 0;

        end
        DONE:
        begin

        end
        endcase
    end
end



endmodule