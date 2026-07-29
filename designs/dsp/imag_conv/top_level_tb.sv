module top_level_tb;

logic clk;
logic rst_n;
logic start;

logic in_valid_rd;
logic in_ready_rd;
logic [7:0] data_out_rd, data_in;


logic [7:0] rd_data;
logic [7:0] rd_addr, wr_addr;
logic [7:0] data_out_wr;
logic wen;


/// output streaming
logic out_valid;
logic out_ready;
logic [7:0] pixel_out;
logic calc_done;

// Queues:

logic [7:0] pixels_out_q[$];
logic [7:0] pixels_in_q[$];


localparam int IMAGE_SIZE = 5;
localparam int START_ADDR = 0;

read_manager #(.IMAGE_SIZE(IMAGE_SIZE), .START_ADDR(START_ADDR)) read_manager_inst(

    .clk(clk),
    .rst_n(rst_n),
    .start(start),

    .rd_addr(rd_addr),
    .rd_data(rd_data),

    .valid_out(valid_out),
    .ready_out(ready_out),
    .data_out(data_out_rd)


);

ImageConv #(.IMAGE_SIZE(IMAGE_SIZE)) dut(
    .clk(clk),
    .rst_n(rst_n),

    .in_valid(valid_out),
    .in_ready(ready_out),
    .pixel_in(data_out_rd),

    .out_valid(valid_in),
    .out_ready(ready_in),
    .pixel_out(pixel_out),

    .calc_done(calc_done)
);

write_manager write_manager_inst(
    .clk(clk),
    .rst_n(rst_n),

    .data_in(pixel_out),
    .valid_in(valid_in),
    .ready_in(ready_in),
    .calc_done(calc_done),

    .data_out(data_out_wr),
    .wr_addr(wr_addr),
    .wen(wen)
);



// =================== Memory Model =============================
logic [7:0] mem [0:(IMAGE_SIZE*IMAGE_SIZE-1)];
initial foreach(mem[i]) mem[i] = i;


assign rd_data = mem[rd_addr]; 
// ==============================================================

always_ff @(posedge clk or negedge rst_n) begin
    if(wen) begin
        pixels_out_q.push_back(data_out_wr);
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if(valid_out && ready_out) begin
       pixels_in_q.push_back(data_out_rd); 
    end
end

always #5 clk = ~clk;


initial begin
    clk = 0; 
    rst_n = 1;
    start = 0;
    out_ready = 1;
    @(posedge clk) rst_n = 0;
    @(negedge clk) rst_n = 1;


    @(posedge clk) start = 1;
    @(posedge clk) start = 0;


    #1000;
    foreach(pixels_out_q[i]) begin
        $display("IN : i= %d | in pixel  = %d |", i, pixels_in_q[i]);
        $display("OUT: i= %d | out pixel = %d |", i, pixels_out_q[i]);
    end
    $finish;





end


endmodule