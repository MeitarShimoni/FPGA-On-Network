#!/usr/bin/env python3
"""
eth_live_view.py
-----------------
Send an image to the FPGA over UDP/Ethernet and watch the processed image
build live, pixel-by-pixel, as the raw Ethernet reply frames arrive.

Protocol is identical to eth_bandwidth_test.py (same board/repo):
  PC -> FPGA : plain UDP/IP datagrams, payload = raw pixel bytes, row-major.
  FPGA -> PC : raw Ethernet II frames (no IP/UDP), src MAC = FPGA_MAC,
               ethertype = 0x88B5, payload = raw pixel bytes.

Where this differs from eth_bandwidth_test.py: that script buffers the
whole reply and only shows you the finished image at the end. This one
writes each arriving Ethernet frame straight into a shared pixel buffer
and redraws an OpenCV window ~30x/sec, so you watch the image fill in
top-to-bottom in real time, in the same order the FPGA actually streams
the bytes out.

Requires: pillow, scapy (+ Npcap on Windows), opencv-python, numpy
    pip install pillow scapy opencv-python numpy

Usage:
    python3 eth_live_view.py messi.png --width 256 --height 256 --mode L
    python3 eth_live_view.py messi.png --width 256 --height 256 --mode RGB \
        --iterations 5 --scale 3
"""
import argparse
import socket
import sys
import threading
import time

import numpy as np

try:
    from PIL import Image
except ImportError:
    sys.exit("This script needs Pillow: pip install pillow")

try:
    from scapy.all import AsyncSniffer, Ether
except ImportError:
    sys.exit("This script needs Scapy + Npcap: pip install scapy (and install Npcap)")

try:
    import cv2
except ImportError:
    sys.exit("This script needs OpenCV: pip install opencv-python")

MAX_UDP_PAYLOAD = 1472       # 1500 MTU - 20 (IP) - 8 (UDP)
DEFAULT_CHUNK_SIZE = 512     # kept small to protect the FPGA's RX FIFO, same as eth_bandwidth_test.py

DEFAULT_TARGET_IP   = "192.168.1.2"
DEFAULT_TARGET_PORT = 5000
DEFAULT_LOCAL_PORT  = 50000
DEFAULT_IFACE       = "FPGA Nexys A7"
DEFAULT_FPGA_MAC    = "02:00:00:00:00:01"
DEFAULT_ETHERTYPE   = 0x88B5


def bytes_per_pixel(mode: str) -> int:
    return 1 if mode == "L" else 3


def load_image_bytes(path, width, height, mode):
    img = Image.open(path).convert(mode)
    img = img.resize((width, height), Image.LANCZOS)
    return img.tobytes()


def chunk_bytes(data, max_len):
    for i in range(0, len(data), max_len):
        yield data[i:i + max_len]


class LiveFrame:
    """Shared pixel buffer that fills in as raw Ethernet reply frames arrive.
    Written from the sniffer thread, read from the display thread -- a plain
    lock is enough since writes/reads are just bytearray slice ops."""

    def __init__(self, width, height, mode):
        self.width = width
        self.height = height
        self.mode = mode
        self.bpp = bytes_per_pixel(mode)
        self.expected_len = width * height * self.bpp
        self.buf = bytearray(self.expected_len)
        self.write_pos = 0
        self.lock = threading.Lock()
        self.done = threading.Event()
        self.first_byte_time = None
        self.last_byte_time = None

    def reset(self):
        with self.lock:
            self.buf = bytearray(self.expected_len)
            self.write_pos = 0
            self.done.clear()
            self.first_byte_time = None
            self.last_byte_time = None

    def append(self, payload: bytes):
        with self.lock:
            if self.write_pos >= self.expected_len:
                return
            now = time.perf_counter()
            if self.first_byte_time is None:
                self.first_byte_time = now
            self.last_byte_time = now
            n = min(len(payload), self.expected_len - self.write_pos)
            self.buf[self.write_pos:self.write_pos + n] = payload[:n]
            self.write_pos += n
            if self.write_pos >= self.expected_len:
                self.done.set()

    def as_bgr_image(self):
        """Snapshot the current buffer as a displayable BGR numpy array."""
        with self.lock:
            arr = np.frombuffer(bytes(self.buf), dtype=np.uint8)
            pos = self.write_pos
        if self.mode == "L":
            img = arr.reshape(self.height, self.width)
            return cv2.cvtColor(img, cv2.COLOR_GRAY2BGR), pos
        else:  # RGB
            img = arr.reshape(self.height, self.width, 3)
            return cv2.cvtColor(img, cv2.COLOR_RGB2BGR), pos


class ReplyCollector:
    """Sniffs the raw link for the FPGA's non-IP Ethernet reply frames and
    feeds each payload straight into a LiveFrame as it arrives."""

    def __init__(self, iface, fpga_mac, ethertype, live_frame: LiveFrame):
        self.fpga_mac = fpga_mac.lower()
        self.ethertype = ethertype
        self.live_frame = live_frame
        self._sniffer = AsyncSniffer(iface=iface, prn=self._on_packet, store=False)

    def _on_packet(self, pkt):
        if not pkt.haslayer(Ether):
            return
        eth = pkt[Ether]
        if eth.src.lower() != self.fpga_mac or eth.type != self.ethertype:
            return
        self.live_frame.append(bytes(eth.payload))

    def start(self):
        self._sniffer.start()
        time.sleep(0.3)  # let the capture actually attach before anyone sends

    def stop(self):
        self._sniffer.stop()


def send_image(sock, raw, target, chunk_size, gap_ms):
    t_start = time.perf_counter()
    n_packets = 0
    for chunk in chunk_bytes(raw, chunk_size):
        sock.sendto(chunk, target)
        n_packets += 1
        if gap_ms > 0:
            time.sleep(gap_ms / 1000.0)
    return t_start, time.perf_counter(), n_packets


def sender_thread_fn(sock, raw, target, chunk_size, gap_ms, result_holder):
    t0, t1, n = send_image(sock, raw, target, chunk_size, gap_ms)
    result_holder["t_send_start"] = t0
    result_holder["t_send_end"] = t1
    result_holder["packets_sent"] = n


def _numbered(path, i):
    if "." in path:
        stem, ext = path.rsplit(".", 1)
        return f"{stem}_{i}.{ext}"
    return f"{path}_{i}"


def run_live_view(args):
    bpp = bytes_per_pixel(args.mode)
    raw_in = load_image_bytes(args.input_image, args.width, args.height, args.mode)
    expected_len = args.width * args.height * bpp
    print(f"Loaded {args.input_image} -> {args.width}x{args.height} {args.mode} "
          f"({len(raw_in)} bytes in, expecting {expected_len} bytes back)")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((args.local_ip, args.local_port))
    target = (args.target_ip, args.target_port)

    live = LiveFrame(args.width, args.height, args.mode)
    collector = ReplyCollector(args.iface, args.fpga_mac, args.ethertype, live)
    collector.start()

    win_name = "FPGA live output (Q to quit early)"
    disp_w = max(args.width * args.scale, 64)
    disp_h = max(args.height * args.scale, 64)
    cv2.namedWindow(win_name, cv2.WINDOW_NORMAL)
    cv2.resizeWindow(win_name, disp_w, disp_h)

    try:
        for i in range(args.iterations):
            live.reset()
            print(f"\n[{i}] sending...")
            send_result = {}
            sender = threading.Thread(
                target=sender_thread_fn,
                args=(sock, raw_in, target, args.chunk_size, args.gap_ms, send_result),
            )
            sender.start()

            deadline = time.perf_counter() + args.timeout
            while time.perf_counter() < deadline and not live.done.is_set():
                img_bgr, pos = live.as_bgr_image()
                disp = cv2.resize(img_bgr, (disp_w, disp_h), interpolation=cv2.INTER_NEAREST)
                pct = 100.0 * pos / expected_len
                cv2.putText(disp, f"{pos}/{expected_len} bytes ({pct:.1f}%)",
                            (10, 25), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)
                cv2.imshow(win_name, disp)
                key = cv2.waitKey(30) & 0xFF
                if key in (ord("q"), 27):
                    print("Quit requested.")
                    sender.join(timeout=1.0)
                    collector.stop()
                    sock.close()
                    cv2.destroyAllWindows()
                    return

            sender.join(timeout=1.0)

            # final draw for this iteration, so the finished frame is visible
            # even if the whole thing arrived faster than the redraw loop
            img_bgr, pos = live.as_bgr_image()
            disp = cv2.resize(img_bgr, (disp_w, disp_h), interpolation=cv2.INTER_NEAREST)
            status = "DONE" if live.done.is_set() else "TIMED OUT"
            pct = 100.0 * pos / expected_len
            cv2.putText(disp, f"{pos}/{expected_len} bytes ({pct:.1f}%) [{status}]",
                        (10, 25), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                        (0, 255, 0) if live.done.is_set() else (0, 0, 255), 2)
            cv2.imshow(win_name, disp)
            cv2.waitKey(1)

            if live.done.is_set():
                rt = live.last_byte_time - send_result["t_send_start"]
                lat = live.first_byte_time - send_result["t_send_end"]
                print(f"  [{i}] {status}: round trip {rt*1000:.2f} ms, "
                      f"response latency {lat*1000:.2f} ms")
            else:
                print(f"  [{i}] {status}: got {pos}/{expected_len} bytes before "
                      f"the {args.timeout:.1f}s timeout")

            if args.out:
                out_path = args.out if args.iterations == 1 else _numbered(args.out, i)
                img = Image.frombytes(args.mode, (args.width, args.height), bytes(live.buf))
                img.save(out_path)
                print(f"  Wrote {out_path}")

            if i < args.iterations - 1 and args.pause_ms > 0:
                cv2.waitKey(args.pause_ms)

        print("\nAll iterations done -- window stays open, press any key (or Q) to close.")
        cv2.waitKey(0)
    finally:
        collector.stop()
        sock.close()
        cv2.destroyAllWindows()


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
                     help=f"PC->FPGA UDP payload bytes/datagram, max {MAX_UDP_PAYLOAD}")
    ap.add_argument("--gap-ms", type=float, default=1.0,
                     help="delay between UDP chunks, to avoid bursting the FPGA's input FIFO")
    ap.add_argument("--timeout", type=float, default=10.0,
                     help="seconds to wait for the full processed image before giving up")
    ap.add_argument("--iterations", type=int, default=1,
                     help="repeat the send/watch cycle N times")
    ap.add_argument("--pause-ms", type=int, default=800,
                     help="pause between iterations so you can see the finished frame")
    ap.add_argument("--iface", default=DEFAULT_IFACE,
                     help="Windows adapter name wired to the FPGA, for sniffing the reply")
    ap.add_argument("--fpga-mac", default=DEFAULT_FPGA_MAC,
                     help="FPGA's MAC_ADDR parameter (source MAC of its reply frames)")
    ap.add_argument("--ethertype", type=lambda s: int(s, 0), default=DEFAULT_ETHERTYPE,
                     help="EtherType of the FPGA's reply frames (default 0x88b5)")
    ap.add_argument("--scale", type=int, default=2,
                     help="display window scale factor (nearest-neighbor upscale, keeps pixels blocky)")
    ap.add_argument("--out", default="result.png",
                     help="where to save the received image (pass '' to skip saving)")
    args = ap.parse_args()

    if not (0 < args.chunk_size <= MAX_UDP_PAYLOAD):
        sys.exit(f"--chunk-size must be between 1 and {MAX_UDP_PAYLOAD}")

    run_live_view(args)


if __name__ == "__main__":
    main()