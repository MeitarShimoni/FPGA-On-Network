# ETH_DSP — FPGA Ethernet Image Pipeline

**A from-scratch RTL image pipeline on a Nexys A7 (Artix-7) that receives a
grayscale image over raw Ethernet, runs it through a configurable
convolution filter, and streams the result back — no OS, no soft core, no
network stack. Everything from RMII pins to RMII pins is hand-written
SystemVerilog.**

```
PC (Python) --UDP/IP--> [RMII/PHY] --> ethernet_mac (RX) --> pixel filter
                                                                   |
                                                                   v
PC (Python) <--raw Ethernet-- [RMII/PHY] <-- ethernet_mac (TX) <-- SRAM <-- ImageConv <-- SRAM <-- write_manager
```

## What I built

- **RTL**: a full receive → convolve → transmit pipeline (`Chip_Top_DSP_ETH_pipeline.sv`)
  gluing together a personal Ethernet MAC IP block, a UDP/IP header parser
  I wrote from the byte layout up (`eth_udp_payload_filter.sv`), dual-port
  SRAM framebuffers, a configurable convolution core (identity / Gaussian /
  sharpen / Sobel), and a packet manager that streams raw pixel bytes back
  out as Ethernet frames.
- **Verification**: a SystemVerilog testbench (`tb_chip_top_eth.sv`) that
  drives the DUT over a *simulated* RMII link, byte-accurate down to
  preamble/SFD/CRC/inter-frame-gap, plus Python helpers to pack/unpack test
  images into the raw byte streams the testbench and hardware both consume.
- **Test infrastructure**: three Python tools built specifically for this
  board (`eth_bandwidth_test.py`, `eth_live_view.py`, `sniff_diag.py`) that
  send real images to the FPGA over UDP, capture the reply with raw packet
  sniffing (Scapy/Npcap), reassemble it into an image, and report
  bandwidth/latency/pixel-accuracy — turning "does it work" into a
  repeatable, numeric hardware-in-the-loop test.

## Timeline

- **~Jun 21 – Jun 30**: core DSP datapath — SRAM framebuffers, async FIFOs,
  read/write managers, the convolution core.
- **Jul 23 – Jul 25 (3 days)**: the Ethernet integration push — wiring the
  MAC into the pipeline, writing the UDP payload filter, rewriting the TX
  packetizer, and the full hardware bring-up/debug cycle described below,
  ending in a verified, bit-exact round trip on real hardware.

## Using Claude Code as the hardware test & debug partner

This was my first project doing FPGA bring-up with an AI coding agent
driving the terminal directly, and it changed the debug loop more than
anything else on the project:

- **Cross-repository root-causing.** The Ethernet MAC is a separate
  personal IP library outside this repo (`MyIPs/Ethernet_MAC/src/`). When
  the reply direction refused to show up on a normal UDP socket, instead of
  guessing I had Claude trace the actual RTL source of `tx_ethernet.sv` and
  `ethernet_mac.sv` end to end. That's how we found the TX path hardcodes a
  destination MAC and uses a non-IP EtherType (`0x88B5`) — a `SOCK_DGRAM`
  receiver could *never* have seen it, no matter how long I waited. That's
  a bug that's very easy to burn hours on by staring at Wireshark; reading
  the actual source found it in minutes.
- **Generating the hardware-in-the-loop test harness.** I described the
  wire protocol and what I wanted to measure, and Claude built the Scapy/Npcap
  packet-sniffing scripts, the `New-NetNeighbor` static-ARP workaround, and
  the CSV/statistics reporting in `eth_bandwidth_test.py` — code that talks
  directly to a live NIC and a live board, not a simulation.
- **Automated regression on real hardware.** Because the test script takes
  `--iterations`, I could re-run the exact same send/receive/compare cycle
  against the physical board after every RTL change and immediately get a
  pixel-diff count and throughput numbers back, instead of eyeballing the
  seven-segment display or re-deriving Wireshark filters by hand each time.
- **Live visual debugging.** `eth_live_view.py` (built the same way) opens
  an OpenCV window and paints the image in as Ethernet frames arrive in
  real time, in the FPGA's actual streaming order — turned an otherwise
  invisible packet stream into something I could watch scanline-by-scanline
  to see exactly where a stall was happening.
- **Fast, disciplined write-ups.** `summary.md` in this repo is a session
  log Claude and I built together as we debugged — the actual chain of
  hypotheses tried and ruled out, not just the final answer. That's what
  the numbers and bug list below are drawn from.

## Bugs found and fixed

| Bug | How it was found | Fix |
|---|---|---|
| TX bandwidth wasted **75%** on padding — 4 real pixels stuffed into a 16-byte UART-style `{p0,p1,p2,p3,XXXX,XXXX}` message | Reading the inherited packetizer RTL | Rewrote `sram_to_uart_packet_manager.sv` to stream raw pixel bytes straight to the MAC's TX port, chunked at up to 1472B/frame |
| First hardware attempts: **zero reply, indefinite timeout** | Confirmed link was up and 45/45 frames left the PC NIC correctly addressed (Scapy capture) — ruled out cabling | — |
| PC silently dropping every outbound packet | No ARP entry for the FPGA's IP; this design has no ARP responder, so the OS never put the packet on the wire | One-time static ARP entry (`New-NetNeighbor`) |
| Still no reply after ARP fix | Traced `ethernet_mac.sv`'s TX path outside this repo and found it replies with a **hardcoded destination MAC** and **EtherType `0x88B5`**, not IP/UDP | Rewrote the receive side of the test scripts to do a raw Scapy/Npcap sniff filtered on source MAC + EtherType instead of a UDP socket |
| RX pipeline **stalling mid-image** on some runs (seen on the seven-segment pixel counter) | Read the full RX chain (`eth_frame_rx` → `mac_filter` → `eth_packet_fifo` → `eth_udp_payload_filter` → `write_manager`) — no logic bug found; RX FIFO (2048B, barely over one MTU frame) suspected of overrunning under back-to-back full-size chunks from a fast PC NIC | Mitigated by dropping the default send chunk size 1472B → 512B with a small inter-chunk delay (root cause still open — needs a scope/ILA on the RX FIFO) |

## Results — measured on real hardware

Nexys A7, `FILTER_SEL = identity`, 256×256 grayscale image, 512-byte send
chunks, 3 consecutive runs:

| Metric | Mean | Min | Max |
|---|---|---|---|
| Round trip (send start → last reply byte) | 198.62 ms | 198.21 ms | 199.02 ms |
| Response latency (last byte sent → first reply byte) | 0.47 ms | 0.37 ms | 0.52 ms |
| RX throughput (FPGA → PC) | 96.39 Mb/s | 94.74 Mb/s | 99.31 Mb/s |
| TX throughput (PC → FPGA, deliberately throttled) | 2.72 Mb/s | 2.71 Mb/s | 2.73 Mb/s |
| Pixel accuracy | **65,536 / 65,536 bytes exact match, 0 errors — 3/3 runs** |

- Reply direction (unthrottled) sustains **96% of the 100 Mb/s RMII line
  rate**.
- Sub-millisecond response latency shows the convolution core is not the
  bottleneck — the ~198 ms round trip is ~99% intentional PC-side pacing
  (a mitigation for the RX FIFO issue above), not FPGA processing time.
- Rewriting the TX packetizer to drop the inherited UART-style padding was
  a **4x reduction in bytes-on-the-wire per pixel transmitted**.
- Full receive → convolve → transmit pipeline verified **bit-exact
  end-to-end** — no corruption anywhere in the datapath.

## Takeaway

The biggest shift from working with an AI agent in the terminal wasn't
writing RTL faster — it was collapsing the loop between "the PHY doesn't
look connected" and "we know exactly which line of which module is wrong."
Being able to say "trace where this reply actually comes from" and get a
real answer pulled from the IP block's own source, in the same session as
building the packet-sniffing test rig to prove it, is what took this from
a multi-day trial-and-error bring-up to a three-day push with a fully
measured, reproducible result.
