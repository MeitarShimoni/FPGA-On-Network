# ETH_DSP

An FPGA image pipeline (Nexys A7) that receives a grayscale image over raw
Ethernet, runs it through a configurable convolution filter, and streams the
result back out over Ethernet — no OS, no soft core, no full network stack,
just RTL from RMII pins to RMII pins.

```
PC (Python) --UDP/IP--> [RMII/PHY] --> ethernet_mac (RX) --> pixel filter
                                                                   |
                                                                   v
PC (Python) <--raw Ethernet-- [RMII/PHY] <-- ethernet_mac (TX) <-- SRAM <-- ImageConv <-- SRAM <-- write_manager
```

## Architecture

```
                         ┌───────────────────────────── Chip_Top_DSP_ETH_pipeline.sv ─────────────────────────────┐
                         │                                                                                         │
  rmii_rxd/crs_dv ──────►│  ethernet_mac (RX)   eth_udp_payload_filter   write_manager        sram_32bit (in)      │
                         │  [rmii_rx→eth_frame_rx │  strips Eth+IP+UDP  │  1 byte = 1 pixel  │  65536 x 8b         │
                         │   →mac_filter→         │  headers, keeps    │  frame_done at      │                     │
                         │   eth_packet_fifo]     │  only UDP payload  │  TOTAL_PIXELS        │                     │
                         │        │                        │                    │                     │           │
                         │        └────────────────────────┴────────────────────┴─────────────────────┘           │
                         │                                                                    │                    │
                         │                                                     read_manager_dsp                    │
                         │                                                                    │                    │
                         │                                                             ImageConv (filter: identity,  │
                         │                                                             gaussian, sharpen, sobel --   │
                         │                                                             live-selected by board btns) │
                         │                                                                    │                    │
                         │                                                          write_manager_dsp               │
                         │                                                                    │                    │
                         │                                              sram_32bit (out) ──────┘                   │
                         │                                                    │                                    │
                         │                                     sram_to_uart_packet_manager                          │
                         │                                     (raw pixel bytes, 1472B/chunk)                       │
                         │                                                    │                                    │
  rmii_txd/tx_en ◄───────│                                     ethernet_mac (TX)                                   │
                         │                                     [eth_frame_tx→rmii_tx]                              │
                         └─────────────────────────────────────────────────────────────────────────────────────────┘
```

Everything downstream of the PLL runs on **clk50** (the 50 MHz RMII reference
clock, generated from the board's 100 MHz `clk` via `clk_wiz_0`) — there is
no clock-domain crossing anywhere in the pixel path.

`ethernet_mac` (RMII front end, frame parsing, CRC, packet FIFO, MAC address
filter) is a separate personal IP library, **not part of this repo**:
`MyIPs/Ethernet_MAC/src/`. It only does Ethernet framing (preamble/SFD/CRC/
MAC-address filtering) — it has no IP/UDP awareness at all in either
direction. Everything IP/UDP-related is built or parsed by this repo's own
RTL (`eth_udp_payload_filter.sv` on RX; nothing on TX — see below).

## Wire protocol

The two directions are **not symmetric** — this is the single most
important thing to know before touching this code.

### PC → FPGA (receive): real UDP/IP

The host sends the image as one grayscale byte per pixel, row-major, as the
payload of plain UDP datagrams to `192.168.1.2:5000` (`OUR_IP`/`LISTEN_PORT`
in `Chip_Top_DSP_ETH_pipeline.sv`). `eth_udp_payload_filter.sv` parses the
real Ethernet+IPv4+UDP headers and hands `write_manager` only the payload
bytes.

```
byte:   0        6        12   14                  34       42                    42+N
        ┌────────┬────────┬────┬────────────────────┬────────┬─────────────────────┐
        │ dst MAC│ src MAC│Type│   IPv4 header (20B) │  UDP   │  PIXEL0 PIXEL1 ...   │
        │  (6B)  │  (6B)  │0800│  ...  proto=17 ...  │hdr(8B) │      PIXELN          │
        └────────┴────────┴────┴────────────────────┴────────┴─────────────────────┘
                                  ^ proto@23    ^ dst IP@30-33   ^ dst port@36-37
```

- `dst MAC` = FPGA's `MAC_ADDR` (`02:00:00:00:00:01`)
- `EtherType` = `0x0800` (IPv4)
- IPv4 `protocol` = `17` (UDP), `dst IP` = `192.168.1.2`
- UDP `dst port` = `5000`
- Payload = up to 1472 bytes of raw pixel data (`--chunk-size` in the test
  script; the FPGA doesn't care about chunk size on RX, only total byte
  count)
- No sequence numbers, no per-chunk header, no coordinates — a pixel's
  identity is purely "the Nth valid payload byte since the counter last hit
  `TOTAL_PIXELS` and wrapped" (`write_manager.sv`)

### FPGA → PC (reply): raw Ethernet, no IP/UDP at all

This surprised us during bring-up — `ethernet_mac`'s TX side
(`tx_ethernet.sv`) builds a bare Ethernet II frame with a **hardcoded**
destination MAC and a **custom, non-IP EtherType**:

```systemverilog
parameter logic [47:0] PC_MAC_ADDR = 48'hE8_9C_25_0E_24_0E;
assign dst_mac    = PC_MAC_ADDR;
assign ether_type = 16'h88B5;  // IEEE 802 local experimental ethertype
```

```
byte:   0        6        12    14                                  14+N
        ┌────────┬────────┬─────┬─────────────────────────────────────┐
        │ dst MAC│ src MAC│Type │      PIXEL0  PIXEL1  ...  PIXELN     │
        │  (6B)  │  (6B)  │88B5 │        (raw bytes, no headers)       │
        └────────┴────────┴─────┴─────────────────────────────────────┘
```

- `dst MAC` = hardcoded PC NIC address (`E8:9C:25:0E:24:0E` — must match
  whatever machine is actually connected; there's no ARP/discovery)
- `src MAC` = FPGA's `MAC_ADDR` (`02:00:00:00:00:01`)
- `EtherType` = `0x88B5` (not IPv4 — a normal UDP/IP socket can never
  receive this frame; it never reaches the OS's IP stack)
- Payload = up to 1472 raw pixel bytes per frame (`MAX_MSG_BYTES` in
  `sram_to_uart_packet_manager.sv`); `last` closes exactly one Ethernet
  frame per pulse (padding/FCS/IFG all handled by `tx_ethernet.sv`)

Because of this, receiving the reply on a PC requires a raw packet capture
(Scapy + Npcap on Windows), filtering on source MAC + EtherType — see
`script/eth_bandwidth_test.py`.

## Runtime controls

`FILTER_SEL` used to be a synthesis-time-only parameter (comment in
`Chip_Top_DSP_ETH_pipeline.sv` still says so, but the wiring has moved on).
The convolution filter is now switched live, on real hardware, with three
board buttons feeding a latched register (`filter_l`) that drives
`ImageConv` instead of the `FILTER_SEL` parameter:

| Button | Filter |
|---|---|
| (power-on / reset default) | Identity |
| `btn_c` | Gaussian |
| `btn_l` | Sharpen |
| `btn_r` | Sobel |

There's no "release to go back to identity" behavior -- whichever button
was pressed most recently stays selected until another one is pressed.

A 16-LED chase/scanner pattern (`led_arr`) also runs whenever the TX side
is streaming a reply out (`mac_valid_in`), as a simple "the board is
sending something back" activity indicator, independent of the
send/receive byte counters on the seven-segment display.

## Testing it

```
python script/eth_bandwidth_test.py <image> --width 256 --height 256 --mode L \
    --iterations 5 --csv results.csv --out result.png
```

- Sends the (resized, grayscale) image to the FPGA over real UDP.
- Sniffs the link (Scapy/Npcap) for the FPGA's raw-Ethernet reply and
  reassembles it back into an image.
- Reports per-iteration and aggregate send/receive duration, round-trip
  latency, and throughput; `--csv` dumps per-iteration numbers for further
  analysis.
- One-time setup on the PC: a static ARP entry for the FPGA's IP, since
  nothing in this design implements an ARP responder:
  ```powershell
  New-NetNeighbor -InterfaceAlias "<your FPGA adapter>" -IPAddress 192.168.1.2 `
      -LinkLayerAddress "02-00-00-00-00-01" -State Permanent
  ```

### Live video

```
python script/eth_video_live.py <video-file-or-camera-index> \
    --width 256 --height 256 --mode L
```

Streams a video file (or webcam) through the FPGA one frame at a time --
same UDP-send / raw-Ethernet-sniff protocol as above -- and shows the
source frame next to the FPGA's processed reply in a live window.

- `--width`/`--height` **must** multiply out (× bytes/pixel) to exactly
  `IMAGE_SIZE * IMAGE_SIZE` (65536 for the default 256×256 grayscale
  build) -- `write_manager.sv`'s hardware frame counter only pulses
  `frame_done` at that exact byte count, so any other size means most
  sent frames never complete on the FPGA side at all (the send just
  silently accumulates toward the next threshold crossing).
- The display only updates once per frame, exactly when that frame's
  reply is either fully received or times out -- the previous completed
  frame stays on screen, untouched, for the whole send+wait window, so
  there's no partial/pixel-by-pixel reveal to watch.
- Prints a periodic decode/network/display timing breakdown plus
  achieved FPS (`--timing-every`, default every 10 frames), and an
  average FPS for the whole run at the end.
- FPS is currently dominated by the same intentional PC-side send
  throttling described below (`--gap-ms` / `--chunk-size`), not by FPGA
  processing -- see "Known limitations".

## Performance results

Measured on real hardware (Nexys A7, `FILTER_SEL=identity`, 256×256
grayscale image, `--chunk-size 512`, 3 iterations):

| Metric | Mean | Min | Max |
|---|---|---|---|
| Send duration (PC→FPGA) | 192.71 ms | 192.33 ms | 193.22 ms |
| Response latency (last byte sent → first reply byte) | 0.47 ms | 0.37 ms | 0.52 ms |
| Receive duration (FPGA→PC) | 5.44 ms | 5.28 ms | 5.53 ms |
| Round trip (send start → last reply byte) | 198.62 ms | 198.21 ms | 199.02 ms |
| TX throughput | 2.72 Mb/s | 2.71 Mb/s | 2.73 Mb/s |
| RX throughput | 96.39 Mb/s | 94.74 Mb/s | 99.31 Mb/s |

- **Pixel accuracy: 65536/65536 bytes exact match (0 diff)** against the
  source image across all 3 runs — the full receive → convolve → transmit
  pipeline is bit-exact end to end.
- **TX throughput looks slow because it's intentionally paced**: the test
  script sleeps `--gap-ms` (default 1 ms) between each of the 128 outgoing
  512-byte chunks as a mitigation for a suspected RX-FIFO-overrun issue
  found during bring-up (see below) — the 192 ms send time is ~99% waiting,
  not link-limited. The reply direction, which the FPGA sends back-to-back
  with no artificial pacing, reaches 96% of the 100 Mb/s RMII reference
  rate.
- Response latency of well under 1 ms confirms the DSP convolution itself
  is fast relative to the Ethernet transfer time — the round trip is almost
  entirely dominated by the deliberately-throttled send side, not FPGA
  processing.

## Known limitations / open items

- **No ARP responder** on the FPGA — the PC-side static ARP entry above is
  required every time the PC's ARP cache is cleared (e.g. reboot).
- **No sequence numbers or checksums at the pixel-protocol level** in
  either direction — a dropped or reordered frame silently shifts or
  corrupts every pixel after it, with no way for either side to detect it.
- **RX FIFO headroom**: `eth_packet_fifo`'s `FIFO_DEPTH` (2048 bytes) is
  only slightly larger than one MTU-sized frame (~1514 bytes on the wire).
  Sending full 1472-byte chunks back-to-back from a fast PC NIC was
  observed to stall the RX pipeline partway through; sending smaller
  chunks (512 bytes, the test script's default) with a small inter-packet
  delay (`--gap-ms`) avoids it in practice, but the underlying root cause
  hasn't been root-caused with a scope/ILA. **This throttling is currently
  ~97% of the measured round trip** (192 ms of the 198 ms total at
  256×256) -- the FPGA side itself is sub-millisecond, so this is the
  single biggest lever for higher FPS on the video-streaming path.
  `eth_packet_fifo.sv` has since been reworked into a "rev B" commit/
  rewind design that cleanly drops a whole overflowing frame (`frame_dropped`
  pulse) instead of corrupting data mid-frame, which may mean the original
  512B/1ms throttling is now more conservative than necessary -- but this
  can't currently be confirmed either way: `frame_dropped` and `mac_reject`
  are produced by `rx_ethernet.sv` but dead-end inside `ethernet_mac.sv`
  (used as connections there without being declared in its own port list),
  so neither signal reaches `Chip_Top_DSP_ETH_pipeline.sv` or any
  LED/counter. Wiring those two signals out is the prerequisite for safely
  tuning `--gap-ms`/`--chunk-size` down instead of guessing.
  **Update:** `eth_video_live.py --width 256 --height 256 --mode L
  --gap-ms 0 --chunk-size 1472` (i.e. no throttling at all) sustained
  29-32 FPS over a full video with no observed stalling -- suggesting the
  overrun risk found on `eth_bandwidth_test.py`'s single-image transfer may
  be workload-dependent (one long back-to-back burst vs. video's
  naturally-paced per-frame sends) rather than a hard FIFO limit that
  always applies. This is one good run, not a scope/ILA-confirmed fix --
  the conservative 512B/1ms default is left as-is pending `frame_dropped`/
  `mac_reject` visibility, but untethered `1472`/`0ms` is now known to work
  at least for continuous video streaming at this image size.
- **`dst_mac` on TX is hardcoded** (`tx_ethernet.sv`) to one specific PC's
  NIC address — swapping test machines requires rebuilding the bitstream.
- **`led1_green`/`led2_blue` may no longer light up**: both branches of
  their driving `always_ff` in `Chip_Top_DSP_ETH_pipeline.sv` currently
  assign `1'b0` (`read_done` -> `led1_green <= 1'b0`, `calc_done` ->
  `led2_blue <= 1'b0`) where they previously latched `1'b1`. Unless these
  LEDs are wired active-low on this board, this looks like an unintentional
  regression from the same edit that added the button-driven filter select
  and the `led_arr` chase animation -- worth a quick check on hardware.
