# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An FPGA image pipeline (Nexys A7 / Artix-7) that receives a grayscale image over raw Ethernet, runs it through a configurable convolution filter, and streams the result back — no OS, no soft core, no full network stack, just hand-written SystemVerilog from RMII pins to RMII pins. `README.md` has the full architecture diagram, wire-protocol byte layouts, and measured hardware performance — read it before making protocol-level changes. `summary.md` is a running session log of past debugging (read it before re-diagnosing something that may already have been root-caused). `Docs/Portfolio_Summary.md` is a narrative write-up, not a technical reference.

**`ethernet_mac` (RMII front end, frame parsing, CRC, packet FIFO, MAC filter) lives outside this repo**, in a separate personal IP library at `MyIPs/Ethernet_MAC/src/` (sibling directory: `FPGA Design/MyIPs/Ethernet_MAC/src/`). It is Ethernet-only (Layer 2) in both directions and has no IP/UDP awareness — `OUR_IP`/`LISTEN_PORT` are accepted as module parameters but never wired to anything inside it (dead parameters). When debugging anything below the UDP payload level (headers, EtherType, hardcoded MACs, FIFO overflow behavior), the real source is there, not in this tree.

## Commands

### Simulation (behavioral, Vivado xsim)

The project's simulation set (`tb_chip_top_eth.sv` in `verification/`, DUT = `Chip_Top_DSP_ETH`) already has generated batch scripts under `vivado/project_1/project_1.sim/sim_1/behav/xsim/`:

```
compile.bat     # xvlog: compile sources
elaborate.bat   # xelab: elaborate the testbench
simulate.bat    # xsim: run it, opens tb_chip_top_eth_behav.wcfg waveform
```

Run them from that directory (requires Vivado's `xvlog`/`xelab`/`xsim` on `PATH`), or open `vivado/project_1/project_1.xpr` in the Vivado GUI and use "Run Simulation". The testbench reads a fixed absolute path (`verification/image_payload.bin`) — regenerate it first with `prepare_image.py` (below) if you change image size/content.

There's a second, independent testbench for just the DSP datapath: `designs/dsp/imag_conv/top_level_tb.sv`.

### Building a test image / checking simulation output

```
python verification/prepare_image.py <input_image> verification/image_payload.bin --width 256 --height 256 --mode L
python verification/view_captured_image.py   # turns captured_image.bin back into a viewable image
```
`--width`/`--height` must multiply out to exactly `IMAGE_SIZE * IMAGE_SIZE` for whatever `IMAGE_SIZE` the DUT/bitstream was built with (currently 256).

### Synthesis / implementation / bitstream

Open `vivado/project_1/project_1.xpr` in Vivado; top module is `Chip_Top_DSP_ETH_pipeline` (the active/current top — `Chip_Top_DSP_ETH` is an earlier, incomplete version kept in-tree, not the one built). Constraints: `designs/Nexys_A7_EthernetDSP.xdc` (board) and `designs/eth/Nexys_A7_Ethernet.xdc`.

### Hardware-in-the-loop testing (after programming the board)

```
python script/eth_bandwidth_test.py <image> --width 256 --height 256 --mode L --iterations 5 --csv results.csv --out result.png
python script/eth_video_live.py <video-file-or-camera-index> --width 256 --height 256 --mode L
python script/sniff_diag.py
```
Requires Scapy + Npcap on the PC, and a one-time static ARP entry for the FPGA (the design has no ARP responder):
```powershell
New-NetNeighbor -InterfaceAlias "<your FPGA adapter>" -IPAddress 192.168.1.2 -LinkLayerAddress "02-00-00-00-00-01" -State Permanent
```
`--iface` defaults to a Windows adapter named `"FPGA Nexys A7"` — check `Get-NetAdapter` if the local interface name differs.

## Architecture

```
PC (Python) --UDP/IP--> [RMII/PHY] --> ethernet_mac (RX) --> pixel filter
                                                                   |
                                                                   v
PC (Python) <--raw Ethernet-- [RMII/PHY] <-- ethernet_mac (TX) <-- SRAM <-- ImageConv <-- SRAM <-- write_manager
```

Top level: `designs/Chip_Top_DSP_ETH_pipeline.sv`. Everything downstream of the clocking block runs on **clk50** (50 MHz RMII reference clock from `clk_wiz_0`, generated off the board's 100 MHz `clk`) — there is no clock-domain crossing anywhere in the pixel path. This differs from the older `Chip_Top_DSP`, which ran the whole pipeline on the 100 MHz `clk`.

Pipeline stages, in order:
1. `ethernet_mac` (external, `MyIPs/Ethernet_MAC/src/`) — RMII front end, frame parsing/CRC/MAC filtering only.
2. `eth_udp_payload_filter.sv` — the only IP/UDP-aware code in the RX path; walks raw Ethernet frames and hands out only the UDP payload bytes addressed to `OUR_IP:LISTEN_PORT`. Without this module, `ethernet_mac`'s output is raw post-MAC-filter Ethernet frames, headers and all.
3. `write_manager.sv` (`designs/FIFOs/`) — counts incoming bytes 1:1 into the input `sram_32bit`, pulses `frame_done` once `TOTAL_PIXELS` (`IMAGE_SIZE^2`) have landed. No coordinates/sequence numbers — a pixel's identity is purely its position in the byte count since the last wraparound.
4. `read_manager_dsp` → `ImageConv` (`designs/dsp/imag_conv/`) — the convolution core; filter is identity/Gaussian/sharpen/Sobel, live-selected via board buttons through a latched register (`filter_l`) rather than the `FILTER_SEL` compile-time parameter (which is now otherwise unused at runtime).
5. `write_manager_dsp` → output `sram_32bit`.
6. `sram_to_uart_packet_manager.sv` (`designs/FIFOs/`, name is legacy from an earlier UART-based design) — streams raw pixel bytes straight to `ethernet_mac`'s TX port, chunked at up to 1472 B/frame. No intermediate staging module.
7. `ethernet_mac` (TX) — wraps whatever bytes it's given in a bare Ethernet II frame with a **hardcoded** destination MAC and a **non-IP EtherType (`0x88B5`)** — see `tx_ethernet.sv` inside the external MAC repo.

**The wire protocol is asymmetric — this is the most important thing to know before touching this code.** PC→FPGA is real UDP/IP (parsed by this repo's own `eth_udp_payload_filter.sv`, since `ethernet_mac` itself has no IP/UDP awareness). FPGA→PC is raw Ethernet with a custom EtherType and a hardcoded destination MAC — not UDP, never reaches a normal socket, requires a raw packet sniff (Scapy/Npcap) to receive. See `README.md`'s "Wire protocol" section for exact byte layouts.

### Known sharp edges (don't re-diagnose these from scratch — see `README.md`/`summary.md` for the full trail)

- No ARP responder on the FPGA; PC needs a static ARP entry.
- No sequence numbers/checksums at the pixel-protocol level in either direction.
- RX FIFO (`eth_packet_fifo.sv`, `FIFO_DEPTH=2048`) is only slightly bigger than one MTU frame; back-to-back full-size chunks were observed to stall RX. Current mitigation is PC-side throttling (`--chunk-size`/`--gap-ms` in the Python scripts), which dominates measured round-trip time — not a confirmed root-cause fix.
- `eth_packet_fifo.sv`'s newer "rev B" design produces `frame_dropped`/`mac_reject` signals, but they dead-end inside `ethernet_mac.sv` (referenced without being declared in its own port list) and never reach the top level or any LED/counter.
- `dst_mac` on TX is hardcoded to one specific PC NIC; testing from a different machine requires rebuilding the bitstream.
- `--width`/`--height` passed to the Python scripts must exactly match the synthesized `IMAGE_SIZE` (check `vivado/project_1/project_1.runs/synth_1/runme.log` if unsure) — `write_manager.sv`'s frame counter only pulses `frame_done` at exactly `IMAGE_SIZE^2` bytes, so a mismatched size means frames silently never complete.
