# Summary

## Does `ethernet_mac` handle UDP, on RX and TX?

No — `ethernet_mac` is Ethernet-only (Layer 2) in **both** directions. It
never implements UDP/IP itself.

Evidence, from `MyIPs/Ethernet_MAC/src/ethernet_mac.sv`:

```systemverilog
module ethernet_mac #(
    parameter logic [47:0] MAC_ADDR    = 48'h02_00_00_00_00_01,
    parameter logic [31:0] OUR_IP      = {8'd192, 8'd168, 8'd1, 8'd2},
    parameter logic [15:0] LISTEN_PORT = 16'd5000,
    parameter int          FIFO_DEPTH  = 2048
)( ... );

    rx_ethernet #(.MAC_ADDR(MAC_ADDR), .FIFO_DEPTH(FIFO_DEPTH)) u_rx ( ... );
    tx_ethernet #(.SRC_MAC(MAC_ADDR)) u_tx ( ... );
```

`OUR_IP` and `LISTEN_PORT` are declared as module parameters (which is why
it *looks* like it should be UDP-aware), but neither `rx_ethernet` nor
`tx_ethernet` ever receives them — they're **dead parameters**, accepted
but never wired to anything.

- **RX "UDP" only works because of a bolt-on module in this project, not
  inside `ethernet_mac`.** `rx_ethernet` hands out raw, CRC-verified
  Ethernet frame bytes — whatever's inside them, headers and all. It has
  no notion of IP or UDP. The illusion that RX is "UDP" comes entirely
  from `designs/eth_udp_payload_filter.sv`, a separate module in *this*
  repo that manually walks those raw bytes afterward and picks out the
  ones that happen to sit inside a well-formed IPv4/UDP packet the PC
  sent. `ethernet_mac` itself never parses an IP or UDP header.

- **TX has no equivalent bolt-on.** `tx_ethernet` just wraps whatever
  bytes `sram_to_uart_packet_manager.sv` hands it in a bare
  `[dst MAC][src MAC][EtherType][payload][FCS]` — no IP header, no UDP
  header. And the `dst_mac`/`ether_type` it uses aren't even the
  `OUR_IP`/`LISTEN_PORT` parameters — they're separate hardcoded constants
  in `ethernet_mac.sv` (`PC_MAC_ADDR = E8:9C:25:0E:24:0E`,
  `ether_type = 0x88B5`). Nobody ever wrote a TX-side equivalent of
  `eth_udp_payload_filter.sv` (something to prepend real IP/UDP headers
  before pixel bytes reach `tx_ethernet`), so the reply comes out as raw
  Ethernet, not UDP.

**Bottom line**: UDP exists on the RX path only because this project
bolted on a parser for it after the fact; nobody bolted on the TX-side
equivalent (a header *builder*), so the reply direction stayed raw
Ethernet with a custom EtherType (`0x88B5`).

## Session summary: getting the FPGA↔PC image round trip working

Starting point: TX was known to be slow (4x bandwidth wasted on inherited
UART/ASCII framing) and untested on real hardware.

1. **Rewrote `sram_to_uart_packet_manager.sv`** to stream raw pixel bytes
   directly to the MAC's TX port instead of padding 4 real pixels into a
   16-byte `{p0,p1,p2,p3,,XXXX,,XXXX}` UART-style message (75% of every
   transmitted byte had been filler). Removed the intermediate
   `eth_tx_msg_streamer` staging module and wired the packet reader
   straight to `ethernet_mac`'s TX port, chunked at 1472B/frame.

2. **Built `script/eth_bandwidth_test.py`** to actually exercise this on
   hardware: resize an image, send it, receive the processed image back,
   and report bandwidth/latency/loss stats.

3. **First real-hardware attempts timed out with zero reply.** Diagnosed
   step by step:
   - Confirmed physical link was up (100 Mbps) and traffic was leaving the
     PC's NIC correctly addressed (Scapy capture showed 45/45 outgoing
     frames), ruling out cabling.
   - Found the PC had no ARP entry for the FPGA's IP, and this design
     implements no ARP responder — packets were being silently dropped by
     the OS before ever reaching the wire. Fixed with a static ARP entry
     (`New-NetNeighbor`).
   - Even after that, no reply ever arrived. Traced `ethernet_mac`'s
     actual source (outside this repo, at `MyIPs/Ethernet_MAC/src/`) and
     discovered the reply path is raw Ethernet with EtherType `0x88B5`
     to a hardcoded destination MAC — not UDP at all (see above). A
     `socket.SOCK_DGRAM` receiver could never have worked.
   - Separately, the seven-segment `pixel_in_counter` showed RX stalling
     partway through the image on some attempts. Read through the entire
     RX chain (`eth_frame_rx`, `mac_filter`, `eth_packet_fifo`,
     `eth_udp_payload_filter`, `write_manager`) without finding a logic
     bug; suspected the RX packet FIFO (2048B, barely more than one
     MTU-sized frame) was being overrun by back-to-back full-size chunks
     from a fast PC NIC.

4. **Rewrote `eth_bandwidth_test.py`** to actually match reality: keep
   real UDP for the PC→FPGA send direction, but switch the receive side to
   a Scapy/Npcap raw sniff filtering on the FPGA's source MAC + EtherType
   `0x88B5`; also dropped the default send chunk size from 1472B to 512B
   to reduce RX FIFO pressure.

5. **Result: full round trip working, 100% pixel-exact**, confirmed over
   3 consecutive runs. See `README.md` for the architecture, wire-protocol
   diagrams, and full performance numbers.

## Final verified result

- 65536/65536 bytes round-tripped, **0 pixel differences** vs. the source
  image (3/3 runs).
- ~198 ms round trip (dominated by an intentionally throttled send side,
  not FPGA processing).
- <1 ms response latency from last byte sent to first reply byte.
- Reply direction alone reaches ~96% of the 100 Mb/s RMII reference rate.

## Session 2: video streaming (`eth_video_live.py`) — bring-up, bottleneck, display artifacts

Starting point: the still-image round trip above worked, so the next step
was streaming live video frames through the same pipeline instead of one
image at a time.

1. **"Stuck between frames" bug.** The new test appeared to hang for a long
   stretch between frames — much longer than the reply itself ever takes —
   while the seven-segment `pixel_in_counter` kept incrementing. Root
   cause: `eth_video_live.py` defaulted to `--width 128 --height 128`
   (16384 bytes/frame), but the synthesized bitstream is built with
   `IMAGE_SIZE=256` (confirmed via
   `vivado/project_1/project_1.runs/synth_1/runme.log`), so
   `write_manager.sv`'s hardware pixel counter only pulses `frame_done`
   after **exactly** 65536 bytes. That counter has no concept of "one
   video frame" — it just keeps counting across sends — so it took 4 of
   the script's 128×128 frames to cross the threshold: 3 out of 4 timed
   out waiting for a reply that could never arrive at that size, and the
   eventual reply was a scrambled composite of parts of 4 different
   frames. Fixed by matching `--width`/`--height` to `IMAGE_SIZE`
   (256×256) and adding a startup check that refuses to run on any other
   size, with an explanation of why.

2. **What's actually limiting FPS.** Per-frame timing breakdown showed the
   FPGA side is essentially free (sub-ms response latency, and the
   FPGA→PC reply alone reaches 96% of the 100 Mb/s line rate). The ~198 ms
   round trip is ~97% one thing: the PC-side send loop deliberately
   sleeping `--gap-ms` between every `--chunk-size` UDP chunk, a
   mitigation added earlier for a suspected RX FIFO overrun. Investigating
   further: `eth_packet_fifo.sv` has since been reworked into a "rev B"
   commit/rewind design that cleanly drops a whole bad/overflowing frame
   (`frame_dropped` pulse) instead of corrupting data — but `frame_dropped`
   and `mac_reject` dead-end inside `ethernet_mac.sv` (referenced as
   connections there without ever being declared in its own port list), so
   neither one reaches the top level or any LED/counter. There is
   currently no way to confirm on hardware whether the original
   512B/1ms throttling is still necessary or now overly conservative —
   wiring those two signals out is the next concrete step before tuning
   `--gap-ms`/`--chunk-size` down.

3. **Display artifacts, unrelated to the network.** Independent of the FPS
   question, the live window was visibly redrawing the FPGA-side panel
   every ~15 ms while the reply buffer filled in, plus flashing to black
   on every `live.reset()` — a pixel-by-pixel "scan reveal" effect that
   was never actually requested. Fixed by touching the display exactly
   once per frame, only when that frame's data is either fully received
   or has timed out; the previous completed frame now stays on screen,
   untouched, for the entire send+wait window instead of clearing to
   black or repainting mid-fill. Also added an achieved-FPS figure
   (interval and whole-run average) to the script's periodic stats print.

4. **Unrelated hardware changes noticed along the way** (made directly on
   `Chip_Top_DSP_ETH_pipeline.sv`, not part of this debugging thread): the
   convolution filter is now switched live via three board buttons
   (`btn_c`=Gaussian, `btn_l`=Sharpen, `btn_r`=Sobel, default=Identity)
   instead of only the compile-time `FILTER_SEL` parameter, and a 16-LED
   chase animation now runs while the TX side is streaming a reply. In the
   same edit, `led1_green`/`led2_blue` started latching `1'b0` in both of
   their driving branches (previously `1'b1`) — worth confirming on
   hardware that this wasn't an unintentional regression.
