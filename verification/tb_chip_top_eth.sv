`timescale 1ns/1ps
//==============================================================================
// tb_chip_top_eth.sv
//
// Sends an image (as a flat byte buffer prepared by prepare_image.py) into
// Chip_Top_DSP_ETH over a *simulated* RMII link, then checks what the MAC
// decoded back out.
//
// HOW THE "WHICH BYTES ARE DATA" QUESTION IS ANSWERED
// ----------------------------------------------------
// RMII itself carries a flat bitstream -- there's no separate "data" wire.
// What tells a receiver (real PHY/MAC, or this testbench) where data starts
// and stops is the FRAME STRUCTURE, all built here explicitly:
//
//   [ 7B preamble 0x55 ][1B SFD 0xD5][ 6B dst MAC ][6B src MAC ][2B EtherType]
//   [ 20B IPv4 header ][ 8B UDP header ][ N bytes payload ][ pad to 60B ][4B FCS]
//   <--------------------- rmii_crs_dv held high for all of this -------------->
//   <---------------- min. 96-bit (48 clk50 cycle) idle gap ------------------->
//
// crs_dv marks "there is a frame on the wire right now"; within that frame,
// the header fields are what let the MAC (and here, the testbench itself)
// figure out where the IP header ends, where the UDP header ends, and
// therefore where your image payload begins and ends (via the UDP Length
// field, and via `last_out` on the decoded side). There's no other marker;
// it's headers all the way down, same as a real NIC.
//
// HOW MANY BURSTS ("FRAMES") FOR ONE IMAGE
// ------------------------------------------
// Standard Ethernet MTU is 1500B of IP payload. Minus a 20B IP header and
// 8B UDP header, that leaves MAX_UDP_PAYLOAD = 1472 bytes of image data per
// frame. An image of SIZE bytes therefore needs:
//     n_frames = ceil(SIZE / 1472)
// This testbench computes that automatically -- it just walks the byte
// buffer in 1472-byte (or smaller, for the last one) chunks, wrapping each
// chunk in its own Ethernet/IP/UDP frame with an incrementing IP ID field.
//
// IMPORTANT CAVEAT ABOUT THE DUT AS PASTED
// ------------------------------------------
// In the Chip_Top_DSP_ETH you pasted, `data_in/valid_in/last_in` (the MAC's
// TX-side stream) and `ready_out` (flow control for the MAC's RX-side
// decoded stream) are internal wires that are never driven -- there's a
// blank gap in the module where that loopback/glue logic presumably used
// to be. Since none of those are top-level ports, this testbench can't
// drive them from outside without a hierarchical reference. So:
//   - We force `ready_out` high so the MAC's decoded RX stream is never
//     back-pressured and actually flows (see `initial force` block below).
//   - We only exercise/verify the RX->decode path (network in, data_out
//     out), not the data_in->TX path, since nothing drives data_in in your
//     current top level. If you wire up a real loopback (data_out -> a FIFO
//     -> data_in) I can extend this testbench to also capture and check
//     the RMII TX pins.
//==============================================================================

module tb_chip_top_eth;

    // ---------------------------------------------------------------------
    // Config
    // ---------------------------------------------------------------------
    localparam int MAX_UDP_PAYLOAD = 1472;          // 1500 MTU - 20 (IP) - 8 (UDP)
    localparam realtime CLK_PERIOD  = 10ns;          // 100 MHz board oscillator on `clk`
    localparam int      IFG_CYCLES  = 48;            // 96 bit-times / 2 bits-per-cycle (RMII)

    // Test "remote host" identity (the PC sending the image)
    localparam logic [47:0] SRC_MAC  = 48'h02_00_00_00_00_02;
    localparam logic [31:0] SRC_IP   = {8'd192, 8'd168, 8'd1, 8'd10};
    localparam logic [15:0] SRC_PORT = 16'd50000;

    // DUT identity -- must match the parameters given to Chip_Top_DSP_ETH below
    localparam logic [47:0] DUT_MAC  = 48'h02_00_00_00_00_01;
    localparam logic [31:0] DUT_IP   = {8'd192, 8'd168, 8'd1, 8'd2};
    localparam logic [15:0] DUT_PORT = 16'd5000;

    // string IMAGE_FILE      = "image_payload.bin";

    string IMAGE_FILE = "C:/Users/Meitar Shimoni/Desktop/FPGA Design/ETH_DSP/verification/image_payload.bin";
    string CAPTURED_FILE   = "captured_image.bin";

    // ---------------------------------------------------------------------
    // DUT hookup
    // ---------------------------------------------------------------------
    logic clk;
    logic rst_n;
    logic [1:0] rmii_rxd;
    logic       rmii_crs_dv;
    logic [1:0] rmii_txd;
    logic       rmii_tx_en;
    logic       eth_refclk;
    logic       eth_rstn;
    logic [6:0] cathodes_out;
    logic [7:0] anodes;

    Chip_Top_DSP_ETH_pipeline #(
        .MAC_ADDR    (DUT_MAC),
        .OUR_IP      (DUT_IP),
        .LISTEN_PORT (DUT_PORT),
        .FIFO_DEPTH  (2048),
        .PHY_RST_W   (8),         // shrunk from 20 just for sim speed -- restore
                                   // to your synthesis value for the real bitstream
        .IMAGE_SIZE  (64)          // must match image_payload.bin: prepare_image.py's
                                   // default is 64x64 grayscale (4096 bytes) -- the
                                   // DUT's default IMAGE_SIZE(256) expects 65536 bytes
                                   // and frame_done would never fire against this file
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .rmii_rxd     (rmii_rxd),
        .rmii_crs_dv  (rmii_crs_dv),
        .rmii_txd     (rmii_txd),
        .rmii_tx_en   (rmii_tx_en),
        .eth_refclk   (eth_refclk),
        .eth_rstn     (eth_rstn),
        .cathodes_out (cathodes_out),
        .anodes       (anodes)
    );

    // Force the MAC's decoded-RX-stream ready signal high (see caveat above).
    // Hierarchical reference into the DUT's internal wire, since it's not a port.
    initial force dut.ready_out = 1'b1;

    // ---------------------------------------------------------------------
    // Clock / reset
    // ---------------------------------------------------------------------
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    initial begin
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
    end

    // ---------------------------------------------------------------------
    // CRC32 (Ethernet FCS) -- standard reflected poly 0xEDB88320,
    // init 0xFFFFFFFF, final invert. Matches Python's zlib.crc32.
    // ---------------------------------------------------------------------
    function automatic logic [31:0] crc32(input byte data[]);
        logic [31:0] crc;
        crc = 32'hFFFFFFFF;
        foreach (data[i]) begin
            crc = crc ^ {24'h0, data[i]};
            for (int b = 0; b < 8; b++) begin
                if (crc[0]) crc = (crc >> 1) ^ 32'hEDB88320;
                else        crc = crc >> 1;
            end
        end
        return ~crc;
    endfunction

    // IPv4 header checksum: one's-complement sum of 16-bit words,
    // called with the checksum field itself zeroed.
    function automatic logic [15:0] ip_checksum(input byte hdr[]);
        logic [31:0] sum;
        sum = 32'h0;
        for (int i = 0; i < hdr.size(); i += 2)
            sum = sum + {hdr[i], hdr[i+1]};
        while (sum[31:16] != 16'h0)
            sum = {16'h0, sum[15:0]} + {16'h0, sum[31:16]};
        return ~sum[15:0];
    endfunction

    // ---------------------------------------------------------------------
    // Low-level RMII bit pusher: drives one byte as 4 dibits (2 bits/cycle),
    // LSB-first, synchronized to the DUT's internal 50 MHz clk50 (hierarchical
    // reference -- clk50 isn't a top-level port, it's generated inside the DUT
    // by clk_wiz_0). Driving on the negedge gives the DUT's posedge-sampling
    // logic a full half period of setup margin.
    // ---------------------------------------------------------------------
    task automatic rmii_send_byte(input byte data);
        for (int i = 0; i < 4; i++) begin
            @(negedge dut.clk50);
            rmii_rxd <= data[2*i +: 2];
        end
    endtask

    // Drives a full byte array as one RMII frame: asserts crs_dv, streams
    // every byte (preamble/SFD/headers/payload/FCS all already baked into
    // `frame`), then deasserts crs_dv and idles for the interframe gap.
    task automatic rmii_drive_frame(input byte frame[]);
        @(negedge dut.clk50);
        rmii_crs_dv <= 1'b1;
        foreach (frame[i]) rmii_send_byte(frame[i]);
        @(negedge dut.clk50);
        rmii_crs_dv <= 1'b0;
        rmii_rxd    <= 2'b00;
        repeat (IFG_CYCLES) @(negedge dut.clk50);
    endtask

    // ---------------------------------------------------------------------
    // Builds one Ethernet+IPv4+UDP frame carrying `payload`, computes FCS,
    // and drives it out over RMII. `ip_id` should increment per frame.
    // ---------------------------------------------------------------------
    task automatic send_udp_frame(input byte payload[], input int ip_id);
        byte eth_hdr[14];
        byte ip_hdr[20];
        byte udp_hdr[8];
        byte mac_frame[];
        byte full_frame[];
        byte fcs_bytes[4];
        logic [31:0] fcs;
        logic [15:0] ip_total_len, udp_len;
        int pad_len;
        int mac_len;

        // --- Ethernet header ---
        {eth_hdr[0], eth_hdr[1], eth_hdr[2], eth_hdr[3], eth_hdr[4], eth_hdr[5]} = DUT_MAC;
        {eth_hdr[6], eth_hdr[7], eth_hdr[8], eth_hdr[9], eth_hdr[10], eth_hdr[11]} = SRC_MAC;
        {eth_hdr[12], eth_hdr[13]} = 16'h0800; // EtherType = IPv4

        // --- IPv4 header ---
        udp_len      = 16'(8 + payload.size());
        ip_total_len = 16'(20 + udp_len);

        ip_hdr[0]  = 8'h45;                 // version 4, IHL 5 (20B, no options)
        ip_hdr[1]  = 8'h00;                 // DSCP/ECN
        {ip_hdr[2], ip_hdr[3]}   = ip_total_len;
        {ip_hdr[4], ip_hdr[5]}   = 16'(ip_id);
        {ip_hdr[6], ip_hdr[7]}   = 16'h0000; // flags/fragment offset: none
        ip_hdr[8]  = 8'h40;                 // TTL 64
        ip_hdr[9]  = 8'h11;                 // protocol = UDP (17)
        {ip_hdr[10], ip_hdr[11]} = 16'h0000; // checksum placeholder
        {ip_hdr[12], ip_hdr[13], ip_hdr[14], ip_hdr[15]} = SRC_IP;
        {ip_hdr[16], ip_hdr[17], ip_hdr[18], ip_hdr[19]} = DUT_IP;
        {ip_hdr[10], ip_hdr[11]} = ip_checksum(ip_hdr);

        // --- UDP header --- (checksum left as 0: optional over IPv4)
        {udp_hdr[0], udp_hdr[1]} = SRC_PORT;
        {udp_hdr[2], udp_hdr[3]} = DUT_PORT;
        {udp_hdr[4], udp_hdr[5]} = udp_len;
        {udp_hdr[6], udp_hdr[7]} = 16'h0000;

        // --- Assemble dst_mac..payload, then pad to the 60B minimum frame size ---
        mac_frame = {eth_hdr, ip_hdr, udp_hdr, payload};
        pad_len   = (mac_frame.size() < 60) ? (60 - mac_frame.size()) : 0;
        if (pad_len > 0) begin
            byte pad[];
            pad = new[pad_len];
            foreach (pad[i]) pad[i] = 8'h00;
            mac_frame = {mac_frame, pad};
        end

        // --- FCS over dst_mac..pad, appended little-endian (LSB byte first) ---
        fcs = crc32(mac_frame);
        fcs_bytes[0] = fcs[7:0];
        fcs_bytes[1] = fcs[15:8];
        fcs_bytes[2] = fcs[23:16];
        fcs_bytes[3] = fcs[31:24];

        // --- Preamble + SFD + frame + FCS ---
        full_frame = {8'h55, 8'h55, 8'h55, 8'h55, 8'h55, 8'h55, 8'h55, 8'hD5,
                      mac_frame, fcs_bytes};

        rmii_drive_frame(full_frame);
    endtask

    // ---------------------------------------------------------------------
    // Capture whatever the MAC decodes out on data_out/valid_out/last_out
    // (hierarchical reference into ethernet_core, same reasoning as ready_out
    // above -- these aren't top-level ports either).
    // ---------------------------------------------------------------------
    byte rx_captured_q[$];
    int  frames_decoded;

    always_ff @(posedge dut.clk50 or negedge rst_n) begin
        if (!rst_n) begin
            frames_decoded <= 0;
        end else if (dut.ethernet_core.valid_out && dut.ready_out) begin
            rx_captured_q.push_back(dut.ethernet_core.data_out);
            if (dut.ethernet_core.last_out)
                frames_decoded <= frames_decoded + 1;
        end
    end

    // ---------------------------------------------------------------------
    // Full end-to-end check: pixels actually accepted into the input SRAM
    // (post eth_udp_payload_filter, i.e. with Ethernet/IP/UDP headers and
    // any non-pixel traffic like ARP already stripped out), plus whether
    // the DSP core ever actually starts/finishes convolution.
    // ---------------------------------------------------------------------
    byte sram_written_q[$];
    int  frame_done_count;
    int  calc_done_count;

    always_ff @(posedge dut.clk50 or negedge rst_n) begin
        if (!rst_n) begin
            frame_done_count <= 0;
            calc_done_count  <= 0;
        end else begin
            if (dut.sram_we)
                sram_written_q.push_back(dut.wm_data_out);
            if (dut.frame_done)
                frame_done_count <= frame_done_count + 1;
            if (dut.calc_done)
                calc_done_count <= calc_done_count + 1;
        end
    end

    // ---------------------------------------------------------------------
    // Main stimulus: read the prepared image, chunk it into MAX_UDP_PAYLOAD
    // pieces, and send one UDP frame per chunk.
    // ---------------------------------------------------------------------
    byte img_bytes[];
    int  fd, fsize, code;

    initial begin
        rmii_rxd    = 2'b00;
        rmii_crs_dv = 1'b0;

        if ($value$plusargs("IMAGE_FILE=%s", IMAGE_FILE))
            $display("[TB] Using image file from plusarg: %s", IMAGE_FILE);

        // Wait for PLL lock + PHY reset release before touching the link
        wait (dut.locked === 1'b1);
        wait (eth_rstn === 1'b1);
        repeat (50) @(posedge clk);
        $display("[TB] PLL locked, PHY reset released, link ready");

        // --- Load the image payload prepared by prepare_image.py ---
        fd = $fopen(IMAGE_FILE, "rb");
        if (fd == 0) begin
            $fatal(1, "[TB] Could not open %s -- run prepare_image.py first", IMAGE_FILE);
        end
        void'($fseek(fd, 0, 2));           // seek to end
        fsize = $ftell(fd);
        
        $display("Image Size = %d", fsize);
        void'($fseek(fd, 0, 0));           // back to start
        img_bytes = new[fsize];
        code = $fread(img_bytes, fd);
        $fclose(fd);
        $display("[TB] Loaded %0d bytes from %s", fsize, IMAGE_FILE);

        // --- Chunk and send ---
        begin
            int offset;
            int frame_id;
            int chunk_len;
            offset   = 0;
            frame_id = 0;
            while (offset < img_bytes.size()) begin
                byte chunk[];
                chunk_len = (img_bytes.size() - offset > MAX_UDP_PAYLOAD)
                            ? MAX_UDP_PAYLOAD : (img_bytes.size() - offset);
                chunk = new[chunk_len];
                for (int i = 0; i < chunk_len; i++) chunk[i] = img_bytes[offset+i];

                $display("[TB] Sending frame %0d: offset=%0d len=%0d",
                          frame_id, offset, chunk_len);
                send_udp_frame(chunk, frame_id);

                offset += chunk_len;
                frame_id++;
            end
            $display("[TB] Done. Sent %0d frame(s) for %0d total bytes.",
                      frame_id, img_bytes.size());
        end

        // Let the pipeline drain -- wait for convolution to actually finish
        // (calc_done pulses once), or bail out after a generous timeout so
        // a hung pipeline is reported instead of hanging the simulation.
        fork
            begin
                wait (calc_done_count > 0);
            end
            begin
                repeat (200000) @(posedge clk);
            end
        join_any
        disable fork;

        // --- Report + dump captured bytes for visual verification ---
        begin
            int pmism;
            int pn;
            int out_fd;
            int expected_mac_bytes;

            // rx_captured_q is the raw link-layer capture: ethernet_mac does
            // not strip Ethernet/IP/UDP headers (see eth_udp_payload_filter.sv),
            // so it's expected to be img_bytes plus 42 header bytes per frame --
            // NOT a byte-for-byte match against img_bytes. It's informational
            // only; the pixel-level check below is the real correctness gate.
            expected_mac_bytes = img_bytes.size() + frames_decoded * 42;

            pmism = 0;
            pn = (sram_written_q.size() < img_bytes.size())
                 ? sram_written_q.size() : img_bytes.size();
            for (int i = 0; i < pn; i++)
                if (sram_written_q[i] != img_bytes[i]) pmism++;

            $display("--------------------------------------------------");
            $display("[TB] Sent bytes            : %0d", img_bytes.size());
            $display("[TB] Frames decoded        : %0d", frames_decoded);
            $display("[TB] Captured bytes (MAC)  : %0d (expected %0d = payload + %0d hdr bytes/frame)",
                      rx_captured_q.size(), expected_mac_bytes, 42);
            $display("[TB] Pixels into SRAM      : %0d (post udp_filter)", sram_written_q.size());
            $display("[TB] Pixel mismatches      : %0d (over %0d compared)", pmism, pn);
            $display("[TB] frame_done pulses     : %0d", frame_done_count);
            $display("[TB] calc_done pulses      : %0d", calc_done_count);
            if (sram_written_q.size() == img_bytes.size() && pmism == 0 && calc_done_count > 0)
                $display("[TB] RESULT: PASS - all pixels reached SRAM and convolution completed");
            else
                $display("[TB] RESULT: FAIL - pixel pipeline did not complete, see counts above");
            $display("--------------------------------------------------");

            out_fd = $fopen(CAPTURED_FILE, "wb");
            foreach (rx_captured_q[i]) $fwrite(out_fd, "%c", rx_captured_q[i]);
            $fclose(out_fd);
            $display("[TB] Wrote %s (%0d bytes) -- reconstruct with view_captured_image.py",
                      CAPTURED_FILE, rx_captured_q.size());
        end

        // $finish;
    end

endmodule
