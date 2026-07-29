#!/usr/bin/env python3
"""
eth_bandwidth_test.py
----------------------
Resize an image, send it to the FPGA over UDP/Ethernet, receive the
processed image back, and report bandwidth/latency/performance stats.

PC -> FPGA (send): real UDP/IP, confirmed against eth_udp_payload_filter.sv.
    No custom framing/command protocol -- the UDP payload IS the pixel
    stream, one byte per pixel, row-major. mode 'L' = grayscale (1 B/px),
    'RGB' = 3 B/px interleaved. Sent as plain UDP datagrams to
    192.168.1.2:5000 (OUR_IP/LISTEN_PORT in Chip_Top_DSP_ETH_pipeline.sv),
    chunked at --chunk-size bytes (default 512, NOT the 1472 MTU max -- see
    note below).

FPGA -> PC (reply): NOT UDP/IP. Confirmed by reading the actual MAC source
(MyIPs/Ethernet_MAC/src/ethernet_mac.sv + tx_ethernet.sv), which isn't part
of this repo. ethernet_mac.sv hardcodes:
    dst_mac    = E8:9C:25:0E:24:0E   (a fixed PC NIC MAC, not the sender's)
    ether_type = 0x88B5              (IEEE 802 local experimental)
i.e. the reply is a raw Ethernet II frame, no IP/UDP headers at all. A
socket.SOCK_DGRAM can never see this -- it never reaches the IP stack. This
script instead sniffs the raw link with Scapy/Npcap for frames with
src == the FPGA's MAC_ADDR (02:00:00:00:00:01 by default) and
ethertype == 0x88B5, and treats the bytes after the 14-byte Ethernet header
as the pixel stream (frame boundaries set by tx_ethernet.sv's pl_last, which
closes exactly one Ethernet frame per pulse -- matches MAX_MSG_BYTES chunking
in sram_to_uart_packet_manager.sv).

Requires Scapy + Npcap installed (both were already present when this was
written) and the Windows interface name that's actually wired to the FPGA
(--iface, default "FPGA Nexys A7" -- check `Get-NetAdapter` if yours differs).

Why --chunk-size defaults to 512 instead of the 1472 MTU max: the FPGA's RX
packet FIFO (FIFO_DEPTH=2048 in eth_packet_fifo.sv) only has room for
roughly one MTU-sized frame (~1514B on the wire) at a time. Back-to-back
full-size frames from a fast PC NIC were observed to overrun it after the
first frame or two (diagnosed via the seven-segment pixel_in_counter
stalling partway through frame 2). Smaller chunks mean smaller on-wire
frames (~558B at the default), leaving much more FIFO headroom for the next
frame to start arriving before the previous one has fully drained. This is
a mitigation, not a confirmed fix -- if transfers still stall, the root
cause is most likely still in the RX chain (eth_frame_rx/mac_filter/
eth_packet_fifo) and needs a scope/ILA to pin down further, not more
Python-side tuning.

Update: eth_video_live.py run with --gap-ms 0 --chunk-size 1472 (no
throttling at all, 256x256 mode L) sustained 29-32 FPS with no observed
stalling -- so the overrun above may be specific to this script's workload
(one image sent as 128 back-to-back chunks in a tight loop) rather than a
hard limit that applies to every send pattern. The 512/1ms default here is
left unchanged pending a scope/ILA-confirmed root cause, but if you're
chasing throughput on this script specifically, --gap-ms 0 --chunk-size
1472 is worth trying rather than assuming it will stall.

This is raw best-effort UDP (PC->FPGA) and raw best-effort Ethernet
(FPGA->PC), with no sequence numbers in either direction (matching the
FPGA's own protocol) -- dropped/reordered frames will corrupt or shorten
the reassembled image. Loss is reported, not corrected.

Usage:
    python3 eth_bandwidth_test.py messi.png --width 256 --height 256 --mode L

    python3 eth_bandwidth_test.py messi.png --width 256 --height 256 \\
        --iterations 10 --csv results.csv --out result.png
"""
import argparse
import csv
import socket
import statistics
import sys
import threading
import time
from dataclasses import dataclass, field

try:
    from PIL import Image
except ImportError:
    sys.exit("This script needs Pillow: pip install pillow")

try:
    from scapy.all import AsyncSniffer, Ether
except ImportError:
    sys.exit("This script needs Scapy + Npcap: pip install scapy (and install Npcap)")

MAX_UDP_PAYLOAD = 1472       # 1500 MTU - 20 (IP) - 8 (UDP): hard ceiling for --chunk-size
DEFAULT_CHUNK_SIZE = 512     # see module docstring: smaller to avoid overrunning the RX FIFO
LINE_RATE_BPS = 100e6        # RMII/100Base-T reference point for the "% of line rate" figure

DEFAULT_TARGET_IP   = "192.168.1.2"
DEFAULT_TARGET_PORT = 5000
DEFAULT_LOCAL_PORT  = 50000
DEFAULT_IFACE       = "FPGA Nexys A7"
DEFAULT_FPGA_MAC    = "02:00:00:00:00:01"
DEFAULT_ETHERTYPE   = 0x88B5


def bytes_per_pixel(mode: str) -> int:
    return 1 if mode == "L" else 3


def load_image_bytes(path: str, width: int, height: int, mode: str) -> bytes:
    img = Image.open(path).convert(mode)
    img = img.resize((width, height), Image.LANCZOS)
    return img.tobytes()


def chunk_bytes(data: bytes, max_len: int):
    for i in range(0, len(data), max_len):
        yield data[i:i + max_len]


@dataclass
class IterationResult:
    bytes_sent: int = 0
    packets_sent: int = 0
    bytes_received: int = 0
    packets_received: int = 0
    t_send_start: float = 0.0
    t_send_end: float = 0.0
    t_recv_first: float = None
    t_recv_last: float = None
    timed_out: bool = False
    received: bytes = field(default=b"", repr=False)

    @property
    def send_duration(self):
        return self.t_send_end - self.t_send_start

    @property
    def response_latency(self):
        """Time from last byte sent to first byte of the reply -- FPGA + link latency."""
        if self.t_recv_first is None:
            return None
        return self.t_recv_first - self.t_send_end

    @property
    def receive_duration(self):
        if self.t_recv_first is None or self.t_recv_last is None:
            return None
        return max(self.t_recv_last - self.t_recv_first, 1e-9)

    @property
    def round_trip(self):
        if self.t_recv_last is None:
            return None
        return self.t_recv_last - self.t_send_start

    @property
    def tx_throughput_bps(self):
        return 8 * self.bytes_sent / max(self.send_duration, 1e-9)

    @property
    def rx_throughput_bps(self):
        if self.t_recv_first is None:
            return 0.0
        return 8 * self.bytes_received / self.receive_duration


class ReplyCollector:
    """Sniffs the raw link for the FPGA's non-IP Ethernet reply frames
    (see module docstring) and buffers (timestamp, payload) pairs. Runs for
    the whole session -- started once before the first send, stopped at
    the end -- so no reply can be missed between iterations."""

    def __init__(self, iface: str, fpga_mac: str, ethertype: int):
        self.fpga_mac = fpga_mac.lower()
        self.ethertype = ethertype
        self._lock = threading.Lock()
        self._chunks = []  # list of (perf_counter_timestamp, payload_bytes)
        self._sniffer = AsyncSniffer(iface=iface, prn=self._on_packet, store=False)

    def _on_packet(self, pkt):
        if not pkt.haslayer(Ether):
            return
        eth = pkt[Ether]
        if eth.src.lower() != self.fpga_mac or eth.type != self.ethertype:
            return
        payload = bytes(eth.payload)
        with self._lock:
            self._chunks.append((time.perf_counter(), payload))

    def start(self):
        self._sniffer.start()
        time.sleep(0.3)  # let the capture actually attach before anyone sends

    def stop(self):
        self._sniffer.stop()

    def chunk_count(self) -> int:
        with self._lock:
            return len(self._chunks)

    def drain_since(self, start_index: int):
        with self._lock:
            new = self._chunks[start_index:]
            total = len(self._chunks)
        return new, total


def send_image(sock: socket.socket, raw: bytes, target, chunk_size: int, gap_ms: float) -> tuple:
    t_start = time.perf_counter()
    n_packets = 0
    for chunk in chunk_bytes(raw, chunk_size):
        sock.sendto(chunk, target)
        n_packets += 1
        if gap_ms > 0:
            time.sleep(gap_ms / 1000.0)
    t_end = time.perf_counter()
    return t_start, t_end, n_packets


def receive_image(collector: ReplyCollector, expected_len: int, timeout_s: float) -> IterationResult:
    result = IterationResult()
    buf = bytearray()
    start_idx = collector.chunk_count()
    deadline = time.perf_counter() + timeout_s

    while len(buf) < expected_len and time.perf_counter() < deadline:
        new_chunks, start_idx = collector.drain_since(start_idx)
        for ts, payload in new_chunks:
            if result.t_recv_first is None:
                result.t_recv_first = ts
            result.t_recv_last = ts
            buf += payload
            result.packets_received += 1
        if len(buf) < expected_len:
            time.sleep(0.005)

    if len(buf) < expected_len:
        result.timed_out = True

    result.bytes_received = len(buf)
    if len(buf) < expected_len:
        buf += bytes(expected_len - len(buf))
    elif len(buf) > expected_len:
        buf = buf[:expected_len]
    result.received = bytes(buf)
    return result


def run_iteration(sock, collector, raw_in, target, expected_len, chunk_size, gap_ms, timeout_s) -> IterationResult:
    t_start, t_end, n_sent = send_image(sock, raw_in, target, chunk_size, gap_ms)
    result = receive_image(collector, expected_len, timeout_s)
    result.bytes_sent = len(raw_in)
    result.packets_sent = n_sent
    result.t_send_start = t_start
    result.t_send_end = t_end
    return result


def save_image(raw: bytes, width: int, height: int, mode: str, out_path: str):
    img = Image.frombytes(mode, (width, height), raw)
    img.save(out_path)
    print(f"Wrote {out_path}")


def fmt_ms(seconds):
    return "n/a" if seconds is None else f"{seconds * 1000:.2f} ms"


def fmt_mbps(bps):
    return f"{bps / 1e6:.2f} Mb/s"


def print_iteration(i: int, r: IterationResult, expected_len: int):
    loss = expected_len - r.bytes_received
    print(f"  [{i}] sent {r.bytes_sent}B/{r.packets_sent}pkt in {fmt_ms(r.send_duration)} "
          f"({fmt_mbps(r.tx_throughput_bps)})  |  "
          f"response latency {fmt_ms(r.response_latency)}  |  "
          f"recv {r.bytes_received}B/{r.packets_received}pkt in "
          f"{fmt_ms(r.receive_duration) if r.t_recv_first else 'n/a'} "
          f"({fmt_mbps(r.rx_throughput_bps)})  |  "
          f"round trip {fmt_ms(r.round_trip)}"
          + (f"  |  LOST {loss}B" if loss > 0 else "")
          + ("  |  TIMED OUT" if r.timed_out else ""))


def summarize(results, expected_len):
    ok = [r for r in results if r.t_recv_first is not None]
    print("\n--- Summary " + "-" * 50)
    print(f"Iterations: {len(results)}  (complete replies: {len(ok)}, "
          f"timeouts/no-reply: {len(results) - len(ok)})")

    if not ok:
        print("No successful replies -- nothing to summarize. Check --iface matches the "
              "adapter wired to the FPGA, --fpga-mac/--ethertype match the board, and "
              "that the RX side actually completes (see the FIFO-overrun note in the "
              "module docstring -- try a smaller --chunk-size or bigger --gap-ms).")
        return

    def stats_line(label, values, fmt):
        values = [v for v in values if v is not None]
        if not values:
            return
        mean = statistics.mean(values)
        lo, hi = min(values), max(values)
        sd = statistics.stdev(values) if len(values) > 1 else 0.0
        print(f"  {label:22s} mean={fmt(mean):>12s}  min={fmt(lo):>12s}  "
              f"max={fmt(hi):>12s}  stdev={fmt(sd):>12s}")

    stats_line("Send duration", [r.send_duration for r in ok], fmt_ms)
    stats_line("Response latency", [r.response_latency for r in ok], fmt_ms)
    stats_line("Receive duration", [r.receive_duration for r in ok], fmt_ms)
    stats_line("Round trip", [r.round_trip for r in ok], fmt_ms)
    stats_line("TX throughput", [r.tx_throughput_bps for r in ok], fmt_mbps)
    stats_line("RX throughput", [r.rx_throughput_bps for r in ok], fmt_mbps)

    mean_rx_bps = statistics.mean(r.rx_throughput_bps for r in ok)
    print(f"  RX throughput is {100 * mean_rx_bps / LINE_RATE_BPS:.1f}% of a "
          f"100 Mb/s reference line rate (informational only -- actual PHY/RMII "
          f"link speed isn't confirmed by this script)")

    total_expected = expected_len * len(results)
    total_received = sum(r.bytes_received for r in results)
    if total_received < total_expected:
        print(f"  Data loss: {total_expected - total_received} bytes missing "
              f"across all iterations ({100 * (total_expected - total_received) / total_expected:.2f}%)")


def write_csv(path, results, expected_len):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["iteration", "bytes_sent", "packets_sent", "send_ms",
                    "response_latency_ms", "bytes_received", "packets_received",
                    "receive_ms", "round_trip_ms", "tx_mbps", "rx_mbps",
                    "bytes_lost", "timed_out"])
        for i, r in enumerate(results):
            w.writerow([
                i, r.bytes_sent, r.packets_sent, r.send_duration * 1000,
                r.response_latency * 1000 if r.response_latency is not None else "",
                r.bytes_received, r.packets_received,
                r.receive_duration * 1000 if r.receive_duration is not None else "",
                r.round_trip * 1000 if r.round_trip is not None else "",
                r.tx_throughput_bps / 1e6, r.rx_throughput_bps / 1e6,
                expected_len - r.bytes_received, r.timed_out,
            ])
    print(f"Wrote {path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input_image")
    ap.add_argument("--width", type=int, default=256)
    ap.add_argument("--height", type=int, default=256)
    ap.add_argument("--mode", choices=["L", "RGB"], default="L")
    ap.add_argument("--target-ip", default=DEFAULT_TARGET_IP)
    ap.add_argument("--target-port", type=int, default=DEFAULT_TARGET_PORT)
    ap.add_argument("--local-ip", default="0.0.0.0")
    ap.add_argument("--local-port", type=int, default=DEFAULT_LOCAL_PORT)
    ap.add_argument("--chunk-size", type=int, default=DEFAULT_CHUNK_SIZE,
                     help=f"PC->FPGA UDP payload bytes/datagram, max {MAX_UDP_PAYLOAD} "
                          f"(default {DEFAULT_CHUNK_SIZE}, smaller to protect the FPGA's RX FIFO)")
    ap.add_argument("--gap-ms", type=float, default=1.0,
                     help="delay between UDP chunks, to avoid bursting the FPGA's input FIFO")
    ap.add_argument("--timeout", type=float, default=10.0,
                     help="seconds to wait for the full processed image before giving up")
    ap.add_argument("--iterations", type=int, default=1,
                     help="repeat the round trip N times to gather latency/bandwidth stats")
    ap.add_argument("--iface", default=DEFAULT_IFACE,
                     help="Windows adapter name wired to the FPGA, for sniffing the reply")
    ap.add_argument("--fpga-mac", default=DEFAULT_FPGA_MAC,
                     help="FPGA's MAC_ADDR parameter (source MAC of its reply frames)")
    ap.add_argument("--ethertype", type=lambda s: int(s, 0), default=DEFAULT_ETHERTYPE,
                     help="EtherType of the FPGA's reply frames (default 0x88b5)")
    ap.add_argument("--out", default="result.png", help="where to save the last received image")
    ap.add_argument("--save-each", action="store_true",
                     help="save every iteration's received image (result_0.png, result_1.png, ...)")
    ap.add_argument("--csv", help="write per-iteration metrics to this CSV file")
    args = ap.parse_args()

    if not (0 < args.chunk_size <= MAX_UDP_PAYLOAD):
        sys.exit(f"--chunk-size must be between 1 and {MAX_UDP_PAYLOAD}")

    bpp = bytes_per_pixel(args.mode)
    expected_len = args.width * args.height * bpp
    raw_in = load_image_bytes(args.input_image, args.width, args.height, args.mode)
    print(f"Loaded {args.input_image} -> {args.width}x{args.height} {args.mode} "
          f"({len(raw_in)} bytes, {(len(raw_in) + args.chunk_size - 1) // args.chunk_size} "
          f"UDP datagram(s) out)")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((args.local_ip, args.local_port))
    target = (args.target_ip, args.target_port)
    print(f"Bound locally on {args.local_ip}:{args.local_port}, sending to "
          f"{target[0]}:{target[1]}, sniffing '{args.iface}' for replies from "
          f"{args.fpga_mac} (ethertype 0x{args.ethertype:04x})\n")

    collector = ReplyCollector(args.iface, args.fpga_mac, args.ethertype)
    collector.start()

    results = []
    try:
        for i in range(args.iterations):
            r = run_iteration(sock, collector, raw_in, target, expected_len,
                               args.chunk_size, args.gap_ms, args.timeout)
            print_iteration(i, r, expected_len)
            results.append(r)
            if args.save_each and r.t_recv_first is not None:
                save_image(r.received, args.width, args.height, args.mode,
                           f"result_{i}.png")
    finally:
        collector.stop()
        sock.close()

    summarize(results, expected_len)

    last_ok = next((r for r in reversed(results) if r.t_recv_first is not None), None)
    if last_ok is not None and not args.save_each:
        save_image(last_ok.received, args.width, args.height, args.mode, args.out)

    if args.csv:
        write_csv(args.csv, results, expected_len)


if __name__ == "__main__":
    main()
