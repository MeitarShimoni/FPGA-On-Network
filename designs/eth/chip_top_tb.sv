module chip_top_tb;

// ============== PARAMETERS ================
parameter int          DATA_WIDTH  = 8;
parameter logic [47:0] MAC_ADDR    = 48'h02_00_00_00_00_01;
parameter logic [31:0] OUR_IP      = {8'd192, 8'd168, 8'd1, 8'd2};
parameter logic [15:0] LISTEN_PORT = 16'd5000;
parameter int          FIFO_DEPTH  = 2048;

// ================ SIGNALS =================
logic clk50;
logic rst_n;
logic clk;

logic [1:0] rmii_rxd;
logic       rmii_crs_dv;
logic [1:0] rmii_txd;
logic       rmii_tx_en;
logic       eth_refclk50;
logic       eth_rstn;

logic [DATA_WIDTH-1:0] data_in;
logic last_in;
logic valid_in;
logic ready_in;

logic [DATA_WIDTH-1:0] data_out;
logic valid_out;
logic last_out;
logic ready_out;

logic [7:0] f[$], exp[$], app[$];

// "PC" driving the DUT's RX pins (rmii_rxd/rmii_crs_dv)
logic [1:0] pc_txd;
logic       pc_tx_en;

assign rmii_rxd    = pc_txd;
assign rmii_crs_dv = pc_tx_en;

int errors = 0;

// NOTE: Chip_Top_Eth instantiates a clk50_wiz_0 (Vivado MMCM IP), an ODDR
// primitive and a seven_segment display. Those need the Xilinx unisim
// simulation library (and clk50_wiz_0's generated sim sources) on the
// compile, and seven_segment.sv still needs to be added to the repo
// before this will elaborate. Also note Chip_Top_Eth currently wires
// ethernet_core.clk5050 to the raw board `clk50` input (not the clk50_wiz_0
// output), so the data path below is exercised directly on `clk50`/`rst_n`.
Chip_Top_Eth #(
    .MAC_ADDR    (MAC_ADDR),
    .OUR_IP      (OUR_IP),
    .LISTEN_PORT (LISTEN_PORT),
    .FIFO_DEPTH  (FIFO_DEPTH)
) dut (
    .clk         (clk),
    .rst_n       (rst_n),

    .rmii_rxd    (rmii_rxd),
    .rmii_crs_dv (rmii_crs_dv),
    .rmii_txd    (rmii_txd),
    .rmii_tx_en  (rmii_tx_en),
    .eth_refclk  (eth_refclk),
    .eth_rstn    (eth_rstn),

    .data_in     (data_in),
    .last_in     (last_in),
    .valid_in    (valid_in),
    .ready_in    (ready_in),

    .data_out    (data_out),
    .valid_out   (valid_out),
    .last_out    (last_out),
    .ready_out   (ready_out)
);

always #5 clk = ~clk;
always #10 clk50 = ~clk50;

// RX-side spy: collects whatever the DUT hands back on data_out.
// NOTE: Chip_Top_Eth currently ties ethernet_core's ready_out to 1'b1
// internally instead of forwarding the top-level ready_out port, so
// driving ready_out here does not actually gate anything inside the DUT
// yet -- kept for parity with ethernet_tb.sv and to be correct once wired up.
logic [7:0] fq[$];
always @(posedge clk50) begin
    if (valid_out && ready_out) fq.push_back(data_out);
end

// TX-side spy: decodes the DUT's own rmii_txd/rmii_tx_en pins back into
// bytes (there's no loopback inside rmii_trx, so the tb has to play PHY).
logic [7:0] tx_sh;
logic [1:0] tx_cnt;
logic [7:0] tx_fq[$];
always @(posedge clk50) begin
    if (!rmii_tx_en) begin
        tx_cnt <= 2'd0;
    end else begin
        tx_sh <= {rmii_txd, tx_sh[7:2]};
        if (tx_cnt == 2'd3) begin
            tx_fq.push_back({rmii_txd, tx_sh[7:2]});
            tx_cnt <= 2'd0;
        end else begin
            tx_cnt <= tx_cnt + 2'd1;
        end
    end
end

initial begin
    clk50       = 1'b0;
    clk         = 1'b0;
    rst_n     = 1'b0;
    pc_txd    = '0;
    pc_tx_en  = 1'b0;
    data_in   = '0;
    valid_in  = 1'b0;
    last_in   = 1'b0;
    ready_out = 1'b1;   // always ready to drain the RX FIFO
    repeat(2) @(posedge clk50);
    rst_n = 1'b1;
    repeat(2) @(posedge clk50);

    #2us; // wait for lock

    str_to_bytes(app, "Meitar Shimoni");
    build_frame(f, MAC_ADDR, 48'h02_00_00_00_00_AA, 16'h0800, app);
    exp = f;
    send_frame(f);

    // let the RX pipeline (rmii_rx -> eth_frame_rx -> mac_filter -> fifo) drain
    repeat (50) @(posedge clk50);

    if (fq.size() != exp.size()) begin
        errors++;
        $error("RX got %0d bytes, expected %0d", fq.size(), exp.size());
    end else begin
        foreach (exp[i])
            if (fq[i] !== exp[i]) begin
                errors++;
                $error("byte %0d: got %02h, expected %02h", i, fq[i], exp[i]);
            end
    end

    if (errors == 0) $display("RX test passed: frame round-tripped, %0d bytes", fq.size());
    else              $display("RX test: %0d ERROR(S)", errors);

    // ---- TX test: stream data_in through tx_ethernet, check the wire ----
    begin
        int tx_errors = 0;
        str_to_bytes(app, "TX stream test.......................$");
        stream_data_in(app);
        expected_tx_frame(exp, app);

        if (tx_fq.size() != exp.size()) begin
            tx_errors++;
            $error("TX wire got %0d bytes, expected %0d", tx_fq.size(), exp.size());
        end else begin
            foreach (exp[i])
                if (tx_fq[i] !== exp[i]) begin
                    tx_errors++;
                    $error("TX byte %0d: got %02h, expected %02h", i, tx_fq[i], exp[i]);
                end
        end
        if (tx_errors == 0) $display("TX test passed: %0d bytes on the wire matched", tx_fq.size());
        else                 $display("TX test: %0d ERROR(S)", tx_errors);
        errors += tx_errors;
    end

    if (errors == 0) $display("ALL TESTS PASSED");
    else              $display("%0d ERROR(S)", errors);
    // $finish;
end


// ===================== PC Driver =====================

function automatic logic [31:0] crc32_byte
    (input logic [31:0] crc, input logic [7:0] data);
    logic [31:0] c;
    c = crc ^ {24'h0, data};
    for (int i = 0; i < 8; i++)
        c = c[0] ? (c >> 1) ^ 32'hEDB88320 : (c >> 1);
    return c;
endfunction

task automatic send_byte(input logic [7:0] b);
    for (int i = 0; i < 4; i++) begin
        pc_txd = b[2*i +: 2];
        @(posedge clk50);
    end
endtask

task automatic send_frame(input logic [7:0] frame[$]);
    logic [31:0] crc = 32'hFFFFFFFF;
    logic [31:0] fcs;
    foreach (frame[i]) crc = crc32_byte(crc, frame[i]);
    fcs = ~crc;
    pc_tx_en = 1'b1;
    repeat (2) @(posedge clk50);
    repeat (7) send_byte(8'h55);
    send_byte(8'hD5);
    foreach (frame[i]) send_byte(frame[i]);
    send_byte(fcs[7:0]);  send_byte(fcs[15:8]);
    send_byte(fcs[23:16]); send_byte(fcs[31:24]);
    pc_tx_en = 1'b0;
    pc_txd   = '0;
    repeat (12) @(posedge clk50);
endtask

// Build DA + SA + EtherType + payload (no FCS -- send_frame appends that)
task automatic build_frame(output logic [7:0] q[$],
                            input  logic [47:0] dst_mac,
                            input  logic [47:0] src_mac,
                            input  logic [15:0] eth_type,
                            input  logic [7:0]  payload[$]);
    q.delete();
    for (int i = 0; i < 6; i++) q.push_back(8'(dst_mac >> (8*(5-i))));
    for (int i = 0; i < 6; i++) q.push_back(8'(src_mac >> (8*(5-i))));
    q.push_back(eth_type[15:8]); q.push_back(eth_type[7:0]);
    foreach (payload[i]) q.push_back(payload[i]);
endtask

// ===================== App Driver (data_in -> tx_ethernet) ==============

// Streams a payload into data_in/valid_in/last_in, holding valid until
// ready_in accepts each byte -- same handshake tx_ethernet expects on pl_*.
task automatic stream_data_in(input logic [7:0] p[$]);
    foreach (p[i]) begin
        @(negedge clk50);
        data_in  = p[i];
        last_in  = (i == p.size() - 1);
        valid_in = 1'b1;
        do @(posedge clk50); while (!(valid_in && ready_in));
        @(negedge clk50);
    end
    valid_in = 1'b0;
    last_in  = 1'b0;
    data_in  = '0;
    @(negedge rmii_tx_en);   // wait for PAD/FCS to finish and the frame to end
    repeat (4) @(posedge clk50);
endtask

// What should land on rmii_txd/rmii_tx_en for a given app payload.
// rmii_trx hardwires dst_mac/ether_type to 0 and SRC_MAC to MAC_ADDR;
// eth_frame_tx zero-pads to 60 bytes and appends FCS (LSB byte first).
task automatic expected_tx_frame(output logic [7:0] q[$], input logic [7:0] payload[$]);
    logic [31:0] crc = 32'hFFFFFFFF;
    logic [31:0] fcs;
    q.delete();
    for (int i = 0; i < 6; i++) q.push_back(8'h00);                     // dst_mac = 0
    for (int i = 0; i < 6; i++) q.push_back(8'(MAC_ADDR >> (8*(5-i)))); // src = MAC_ADDR
    q.push_back(8'h00); q.push_back(8'h00);                             // ether_type = 0
    foreach (payload[i]) q.push_back(payload[i]);
    while (q.size() < 60) q.push_back(8'h00);
    foreach (q[i]) crc = crc32_byte(crc, q[i]);
    fcs = ~crc;
    q.push_back(fcs[7:0]);  q.push_back(fcs[15:8]);
    q.push_back(fcs[23:16]); q.push_back(fcs[31:24]);
endtask

// ===================== Helper ========================
function automatic void str_to_bytes(output logic [7:0] q[$],
                                        input string s);
    q.delete();
    for (int i = 0; i < s.len(); i++) q.push_back(s.getc(i));
endfunction

endmodule