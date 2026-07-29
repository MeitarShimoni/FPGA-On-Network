//==============================================================================
// Chip_Top_DSP_ETH_pipeline.sv
//
// Image pipeline (write_manager -> SRAM -> read_manager_dsp -> ImageConv ->
// write_manager_dsp -> SRAM -> sram_to_uart_packet_manager) running over the
// Ethernet MAC transport from Chip_Top_DSP_ETH.
//
// RX PROTOCOL: raw grayscale byte stream, one byte per pixel, row-major,
// no framing/command protocol -- ethernet_mac's data_out/valid_out/last_out
// is treated as the literal pixel stream (see prepare_image.py mode 'L' and
// tb_chip_top_eth.sv). write_manager below just counts bytes into the input
// SRAM and pulses frame_done once TOTAL_PIXELS have landed.
//
// (This replaces an earlier version that reused rx_phaser_classifier /
// eth_rx_msg_packer, inherited from a UART/ASCII command protocol -- those
// expected specific ASCII markers and a 4-pixels-per-16-bytes RGB layout
// that didn't match this raw binary stream, so real pixel bytes were either
// misclassified as bogus register writes or discarded outright, and
// TOTAL_PIXELS worth of valid writes -- and therefore frame_done -- could
// never be reached.)
//
// FILTER_SEL (identity/Gaussian/sharpen/Sobel) is a compile-time parameter;
// there is no runtime command channel to carry it anymore. IMAGE_SIZE must
// match the actual image the host sends.
//
// IMPORTANT: CLOCK DOMAIN CHANGE
// --------------------------------
// In Chip_Top_DSP, the whole pipeline ran on the board's `clk` (100 MHz).
// Here, ethernet_mac's data_in/data_out are synchronous to clk50 (the PLL-
// generated 50 MHz RMII reference clock) -- there is no valid way to hand
// bytes across to logic running on a different, unrelated clock without a
// CDC crossing. So the entire pipeline below has been moved onto clk50.
// This should be functionally fine (none of write_manager / read_manager_dsp
// / ImageConv / write_manager_dsp / sram_to_uart_packet_manager appeared to
// depend on an absolute clock frequency), but it does mean the whole thing
// now runs at half the throughput in wall-clock terms.
//
// UNVERIFIED ASSUMPTION: ethernet_mac's data_out/valid_out is assumed to
// already be filtered down to just this frame's UDP payload bytes (headers/
// padding/FCS stripped, non-matching MAC/IP/port traffic dropped) -- its
// source isn't in this tree so this couldn't be directly confirmed. Run
// tb_chip_top_eth.sv (which compares captured bytes against the raw image
// payload, not the full frame) to check this before trusting hardware runs.
//==============================================================================

module Chip_Top_DSP_ETH_pipeline #(
    parameter logic [47:0] MAC_ADDR    = 48'h02_00_00_00_00_01,
    parameter logic [31:0] OUR_IP      = {8'd192, 8'd168, 8'd1, 8'd2},
    parameter logic [15:0] LISTEN_PORT = 16'd5000,
    parameter int          FIFO_DEPTH  = 2048,
    parameter int          PHY_RST_W   = 20,
    // Must match the actual image the host sends (see prepare_image.py
    // --width/--height, which must be IMAGE_SIZE x IMAGE_SIZE, mode L).
    parameter int          IMAGE_SIZE  = 256,
    parameter logic [1:0]  FILTER_SEL  = 2'd1, // 0=identity 1=gaussian 2=sharpen 3=sobel
    parameter int          ADDR_WIDTH  = 16
)(
    input  logic clk,
    input  logic rst_n,

    // RMII pins
    input  logic [1:0] rmii_rxd,
    input  logic       rmii_crs_dv,
    output logic [1:0] rmii_txd,
    output logic       rmii_tx_en,
    output logic       eth_refclk,
    output logic       eth_rstn,

    // Status LEDs (carried over from Chip_Top_DSP)
    output logic       led1_green,
    output logic       led2_blue,
    output logic [15:0] led_arr,

    // bottuns:
    input logic btn_up,
    input logic btn_c,
    input logic btn_l,
    input logic btn_r,


    output logic [6:0] cathodes_out,
    output logic [7:0] anodes
);

    localparam int TOTAL_PIXELS         = IMAGE_SIZE * IMAGE_SIZE;
    localparam int IMAGE_TRANSFER_SIZE  = TOTAL_PIXELS; // 1 real pixel byte per TX handshake now

    // Filters
    localparam logic [1:0] IDENTICAL = 2'd0;
    localparam logic [1:0] GAUSSIAN = 2'd1;
    localparam logic [1:0] SHARPEN = 2'd2;
    localparam logic [1:0] SOBEL = 2'd3;
    logic [1:0] filter_l;

    // -------------------------------------------------------------------
    // Clocking / PHY reset (unchanged from Chip_Top_DSP_ETH)
    // -------------------------------------------------------------------
    logic clk50, locked;
    logic [PHY_RST_W-1:0] phy_rst_cnt;
    logic sys_rst_n;

    clk_wiz_0 clk50_gen (
        .clk_in1  (clk),
        .resetn   (rst_n),
        .clk_out1 (clk50),
        .locked   (locked)
    );

    assign sys_rst_n = locked & rst_n;

    always_ff @(posedge clk50 or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            phy_rst_cnt <= '0;
            eth_rstn    <= 1'b0;
        end else if (!(&phy_rst_cnt))
            phy_rst_cnt <= phy_rst_cnt + 1'b1;
        else
            eth_rstn <= 1'b1;
    end

    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
    u_refclk_fwd (
        .Q(eth_refclk), .C(clk50), .CE(1'b1),
        .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0)
    );

    // -------------------------------------------------------------------
    // Ethernet MAC (transport layer -- replaces RX_UART + UART_TX as a pair)
    // -------------------------------------------------------------------
    logic [7:0] mac_data_in,  mac_data_out;
    logic       mac_last_in,  mac_valid_in,  mac_ready_in;
    logic       mac_last_out, mac_valid_out;

    // Never back-pressures the MAC: write_manager below accepts one pixel
    // byte per valid cycle unconditionally, same as eth_rx_msg_packer used
    // to. Named `ready_out` (not `mac_ready_out`) because tb_chip_top_eth.sv
    // forces this exact signal via a hierarchical reference (`dut.ready_out`).
    logic ready_out;
    assign ready_out = 1'b1;

    ethernet_mac #(
        .MAC_ADDR    (MAC_ADDR),
        .OUR_IP      (OUR_IP),
        .LISTEN_PORT (LISTEN_PORT),
        .FIFO_DEPTH  (FIFO_DEPTH)
    ) ethernet_core (
        .clk50       (clk50),
        .rst_n       (sys_rst_n),

        .rmii_rxd    (rmii_rxd),
        .rmii_crs_dv (rmii_crs_dv),
        .rmii_txd    (rmii_txd),
        .rmii_tx_en  (rmii_tx_en),

        .data_in     (mac_data_in),
        .last_in     (mac_last_in),
        .valid_in    (mac_valid_in),
        .ready_in    (mac_ready_in),

        .data_out    (mac_data_out),
        .valid_out   (mac_valid_out),
        .last_out    (mac_last_out),
        .ready_out   (ready_out)
    );

    // -------------------------------------------------------------------
    // RX path: ethernet_mac only strips the Ethernet preamble/SFD/FCS and
    // filters by destination MAC (see eth_udp_payload_filter.sv header for
    // why) -- it does NOT strip Ethernet/IP/UDP headers or check EtherType/
    // dest IP/dest port, despite OUR_IP/LISTEN_PORT being accepted as its
    // parameters. eth_udp_payload_filter does that: it walks each frame and
    // only passes through bytes that are UDP payload addressed to us.
    //
    // The host sends one grayscale byte per pixel as that UDP payload, in
    // row-major order, with no further framing/command protocol -- see
    // prepare_image.py (mode 'L') and tb_chip_top_eth.sv. So the filtered
    // byte stream *is* the pixel stream directly.
    //
    // filter_sel is the FILTER_SEL compile-time parameter -- there's no
    // in-band command channel left to carry it at runtime.
    // -------------------------------------------------------------------
    logic [7:0] pixel_data;
    logic       pixel_valid;

    eth_udp_payload_filter #(
        .OUR_IP      (OUR_IP),
        .LISTEN_PORT (LISTEN_PORT)
    ) udp_filter (
        .clk         (clk50),
        .rst_n       (sys_rst_n),

        .data_out    (mac_data_out),
        .valid_out   (mac_valid_out),
        .last_out    (mac_last_out),

        .pixel_data  (pixel_data),
        .pixel_valid (pixel_valid)
    );

    // -------------------------------------------------------------------
    // Write manager + input SRAM
    // -------------------------------------------------------------------
    logic [7:0]            wm_data_out;
    logic [ADDR_WIDTH-1:0] wm_addr_out;
    logic                  sram_we;
    logic                  frame_done;

    write_manager #(
        .TOTAL_PIXELS (TOTAL_PIXELS)
    ) wr_manager (
        .clk   (clk50),
        .rst_n (sys_rst_n),

        .in_valid (pixel_valid),
        .in_ready (),               // MAC is never back-pressured: one SRAM
                                     // write per valid byte always keeps up.
        .pixel_in (pixel_data),

        .data_out   (wm_data_out),
        .addr_out   (wm_addr_out),
        .sram_we    (sram_we),
        .frame_done (frame_done)
    );

    logic [ADDR_WIDTH-1:0] rd_addr;
    logic [7:0]            rd_data;

    sram_32bit #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(8)) sram_in_inst (
        .clk   (clk50),
        .we    (sram_we),
        .waddr (wm_addr_out),
        .din   (wm_data_out),
        .raddr (rd_addr),
        .dout  (rd_data)
    );

    // -------------------------------------------------------------------
    // Read manager + DSP conv + write manager + output SRAM (UNCHANGED)
    // -------------------------------------------------------------------
    logic       valid_out_rm, ready_out_rm;
    logic [7:0] data_out_rd;

    read_manager_dsp #(.TOTAL_PIXELS(TOTAL_PIXELS), .START_ADDR(0)) read_manager_dsp_inst (
        .clk   (clk50),
        .rst_n (sys_rst_n),
        .start (frame_done),

        .rd_addr (rd_addr),
        .rd_data (rd_data),

        .valid_out (valid_out_rm),
        .ready_out (ready_out_rm),
        .data_out  (data_out_rd)
    );

    logic       valid_in_conv, ready_in_conv, calc_done;
    logic [7:0] pixel_out;

    ImageConv #(.IMAGE_SIZE(IMAGE_SIZE)) Conv_Inst (
        .clk   (clk50),
        .rst_n (sys_rst_n),
        // .filter_sel (FILTER_SEL),
        .filter_sel (filter_l),

        .in_valid (valid_out_rm),
        .in_ready (ready_out_rm),
        .pixel_in (data_out_rd),

        .out_valid (valid_in_conv),
        .out_ready (ready_in_conv),
        .pixel_out (pixel_out),

        .calc_done (calc_done)
    );

    logic        last_wm;
    logic [7:0]  data_out_wr;
    logic [15:0] wr_addr;
    logic        wen;

    write_manager_dsp #(.TOTAL_PIXELS(TOTAL_PIXELS)) write_manager_inst (
        .clk   (clk50),
        .rst_n (sys_rst_n),

        .data_in  (pixel_out),
        .valid_in (valid_in_conv),
        .ready_in (ready_in_conv),
        .calc_done (calc_done),

        .last     (last_wm),
        .data_out (data_out_wr),
        .wr_addr  (wr_addr),
        .wen      (wen)
    );

    logic [ADDR_WIDTH-1:0] raddr;
    logic [7:0]            rdata;

    sram_32bit #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(8)) sram_out_inst (
        .clk   (clk50),
        .we    (wen),
        .waddr (wr_addr),
        .din   (data_out_wr),
        .raddr (raddr),
        .dout  (rdata)
    );

    // -------------------------------------------------------------------
    // TX path: SRAM -> raw pixel bytes -> ethernet_mac (replaces UART_TX).
    // Streams straight into the MAC's data_in/valid_in/last_in/ready_in
    // port -- no intermediate message-buffering stage (eth_tx_msg_streamer
    // is no longer used here: see sram_to_uart_packet_manager.sv header).
    // -------------------------------------------------------------------
    logic read_done;

    sram_to_uart_packet_manager #(
        .IMAGE_SIZE (IMAGE_SIZE),
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (8)
    ) packet_reader (
        .clk   (clk50),
        .rst_n (sys_rst_n),

        .start (calc_done),

        .img_size_i (32'(TOTAL_PIXELS)),
        .raddr      (raddr),
        .rdata      (rdata),

        .data_out  (mac_data_in),
        .valid_out (mac_valid_in),
        .last_out  (mac_last_in),
        .ready_in  (mac_ready_in),

        .done (read_done)
    );

    // -------------------------------------------------------------------
    // Status counters + seven-seg (mirrors Chip_Top_DSP's semantics --
    // actual pixel counts, not raw MAC byte counts)
    // -------------------------------------------------------------------
    logic [15:0] pixel_in_counter, pixel_out_counter;//frame_out_cnt;
    logic [31:0] frame_out_cnt;

    always_ff @(posedge clk50 or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            pixel_in_counter <= 0;
        // end else if (frame_done) begin
        //     pixel_in_counter <= 0;
        end else if (mac_valid_out) begin
            pixel_in_counter <= pixel_in_counter + 1;
        end
    end

    always_ff @(posedge clk50 or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            pixel_out_counter <= 0;
        end else if (mac_valid_in && mac_ready_in) begin
            pixel_out_counter <= pixel_out_counter + 1;
        end
    end

    always_ff @(posedge clk50 or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            frame_out_cnt <= 0;
        end else if (read_done) begin
            frame_out_cnt <= frame_out_cnt + 1;
        end
    end

logic [15:0] led_arr;
logic sd;
logic [15:0] cnt2;

    always_ff @(posedge clk50 or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            cnt2 <= '0;
        end else if (mac_valid_in) begin
            cnt2 <= (cnt2 == 16'hFFFF) ? 'd0 : cnt2 + 1'b1;
        end
    end

always_ff @(posedge clk50 or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        led_arr <= 16'b0000_0000_0000_0011;
        sd      <= 1'b0;
    end else if (cnt2 == 16'hFFFF) begin
        if (sd) begin
            if (led_arr[15]) begin
                led_arr <= 16'b1100_0000_0000_0000;
                sd      <= 1'b0;
            end else begin
                led_arr <= {led_arr[14:0], 1'b0};
            end
        end else begin
            if (led_arr[0]) begin
                led_arr <= 16'b0000_0000_0000_0011;
                sd      <= 1'b1;
            end else begin
                led_arr <= {1'b0, led_arr[15:1]};
            end
        end
    end
end

    always_ff @(posedge clk50 or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            led1_green <= 1'b0;
            led2_blue  <= 1'b0;
        end else begin
            if (read_done) begin
                led1_green <= 1'b0;
            end else if (calc_done) begin
                led2_blue <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk50 or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            filter_l <= IDENTICAL;
        end else begin
            if (btn_c) begin
                filter_l <= IDENTICAL;
            end else if (btn_l) begin
                filter_l <= SHARPEN;
            end else if (btn_r) begin
                filter_l <= GAUSSIAN;
            end else if (btn_up) begin
                filter_l <= SOBEL;
            end
        end
    end

    seven_segment segment_display (
        .system_clock (clk50),
        .cpu_rst_n    (sys_rst_n),
        // .display_val  ({pixel_in_counter, frame_out_cnt[15:0]}),
        .display_val  (frame_out_cnt),
        .cathodes_out (cathodes_out),
        .anodes       (anodes)
    );

endmodule
