#!/usr/bin/env python3
"""
eth_video_live.py
------------------
Stream frames from a video file (or a webcam) through the FPGA, one frame
at a time, and watch the FPGA's reply build live next to the source frame.

Same protocol as eth_bandwidth_test.py / eth_live_view.py:
  PC -> FPGA : plain UDP/IP datagrams, payload = raw pixel bytes, row-major.
  FPGA -> PC : raw Ethernet II frames (no IP/UDP), src MAC = FPGA_MAC,
               ethertype = 0x88B5, payload = raw pixel bytes.

For each source frame: resize/convert to --width x --height / --mode, send
it over UDP, show a black "waiting" panel, then block until the reply
completes (or times out) and swap in the FULL finished frame -- no partial
pixel-by-pixel reveal, just image / black / image / black as each frame
completes. Moves on to the next frame once the current one completes (or
times out). Prints include the achieved FPS.

Requires: opencv-python, scapy (+ Npcap on Windows), numpy
    pip install opencv-python scapy numpy

Usage:
    # from a video file
    python3 eth_video_live.py AirRefuling.mp4 --width 256 --height 256 --mode L

    # from a webcam (camera index instead of a path)
    python3 eth_video_live.py 0 --width 128 --height 128 --mode RGB

    # save the side-by-side comparison to a new video file
    python3 eth_video_live.py clip.mp4 --width 128 --height 128 \\
        --mode L --record compare.mp4

    # untethered send (no PC-side throttling) -- sustained 29-32 FPS in
    # testing at 256x256/mode L with no observed RX stalling; see the
    # --gap-ms/--chunk-size help below before assuming this always works
    python3 eth_video_live.py clip.mp4 --width 256 --height 256 \\
        --mode L --gap-ms 0 --chunk-size 1472
"""
import argparse
import socket
import sys
import threading
import time

import numpy as np

try:
    import cv2
except ImportError:
    sys.exit("This script needs OpenCV: pip install opencv-python")

try:
    from scapy.all import AsyncSniffer, Ether
except ImportError:
    sys.exit("This script needs Scapy + Npcap: pip install scapy (and install Npcap)")

MAX_UDP_PAYLOAD = 1472
DEFAULT_CHUNK_SIZE = 512

DEFAULT_TARGET_IP   = "192.168.1.2"
DEFAULT_TARGET_PORT = 5000
DEFAULT_LOCAL_PORT  = 50000
DEFAULT_IFACE       = "FPGA Nexys A7"
DEFAULT_FPGA_MAC    = "02:00:00:00:00:01"
DEFAULT_ETHERTYPE   = 0x88B5


def bytes_per_pixel(mode: str) -> int:
    return 1 if mode == "L" else 3


def chunk_bytes(data, max_len):
    for i in range(0, len(data), max_len):
        yield data[i:i + max_len]


def frame_to_payload(bgr_frame, width, height, mode):
    """Resize a cv2 BGR frame to (width,height) and pack it into raw
    row-major bytes matching the FPGA's expected pixel format."""
    resized = cv2.resize(bgr_frame, (width, height), interpolation=cv2.INTER_AREA)
    if mode == "L":
        gray = cv2.cvtColor(resized, cv2.COLOR_BGR2GRAY)
        return gray.tobytes(), resized
    else:  # RGB, R,G,B interleaved to match the FPGA/PIL convention
        rgb = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
        return rgb.tobytes(), resized


class LiveFrame:
    """Shared pixel buffer that fills in as raw Ethernet reply frames arrive
    for the CURRENT source frame. reset() between frames."""

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
        with self.lock:
            arr = np.frombuffer(bytes(self.buf), dtype=np.uint8)
            pos = self.write_pos
        if self.mode == "L":
            img = arr.reshape(self.height, self.width)
            return cv2.cvtColor(img, cv2.COLOR_GRAY2BGR), pos
        else:
            img = arr.reshape(self.height, self.width, 3)
            return cv2.cvtColor(img, cv2.COLOR_RGB2BGR), pos


class ReplyCollector:
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
        time.sleep(0.3)

    def stop(self):
        self._sniffer.stop()


def send_payload(sock, payload, target, chunk_size, gap_ms):
    for chunk in chunk_bytes(payload, chunk_size):
        sock.sendto(chunk, target)
        if gap_ms > 0:
            time.sleep(gap_ms / 1000.0)


def open_source(video_source):
    # camera index if the arg is a plain integer, else treat as a file path
    if video_source.isdigit():
        cap = cv2.VideoCapture(int(video_source))
        is_camera = True
    else:
        cap = cv2.VideoCapture(video_source)
        is_camera = False
    if not cap.isOpened():
        sys.exit(f"Could not open video source: {video_source}")
    return cap, is_camera


def make_canvas(src_bgr, fpga_bgr, disp_w, disp_h, label_left, label_right):
    left = cv2.resize(src_bgr, (disp_w, disp_h), interpolation=cv2.INTER_NEAREST)
    right = cv2.resize(fpga_bgr, (disp_w, disp_h), interpolation=cv2.INTER_NEAREST)
    canvas = np.hstack([left, right])
    cv2.putText(canvas, label_left, (10, 25), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)
    cv2.putText(canvas, label_right, (disp_w + 10, 25), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)
    return canvas


def run(args):
    cap, is_camera = open_source(args.video_source)
    src_fps = cap.get(cv2.CAP_PROP_FPS) or 0
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT)) if not is_camera else -1
    print(f"Opened {'camera ' + args.video_source if is_camera else args.video_source} "
          f"(source fps={src_fps:.1f}, frames={total_frames if total_frames > 0 else 'unknown'})")

    expected_len = args.width * args.height * bytes_per_pixel(args.mode)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((args.local_ip, args.local_port))
    target = (args.target_ip, args.target_port)

    live = LiveFrame(args.width, args.height, args.mode)
    collector = ReplyCollector(args.iface, args.fpga_mac, args.ethertype, live)
    collector.start()

    win_name = "Source | FPGA output (Q to quit)"
    disp_w = max(args.width * args.scale, 64)
    disp_h = max(args.height * args.scale, 64)
    cv2.namedWindow(win_name, cv2.WINDOW_NORMAL)
    cv2.resizeWindow(win_name, disp_w * 2, disp_h)

    writer = None
    if args.record:
        fourcc = cv2.VideoWriter_fourcc(*"mp4v")
        out_fps = src_fps if src_fps > 1 else 15
        writer = cv2.VideoWriter(args.record, fourcc, out_fps, (disp_w * 2, disp_h))
        print(f"Recording comparison video to {args.record}")

    frame_idx = 0
    sent_idx = 0
    quit_requested = False

    run_start = time.perf_counter()
    last_report_time = run_start
    last_report_idx = 0

    try:
        while not quit_requested:
            ok, frame = cap.read()
            if not ok:
                if args.loop and not is_camera:
                    cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                    frame_idx = 0
                    continue
                break

            frame_idx += 1
            if args.frame_skip > 1 and (frame_idx % args.frame_skip) != 0:
                continue
            if args.max_frames and sent_idx >= args.max_frames:
                break
            sent_idx += 1

            t_stage0 = time.perf_counter()
            payload, src_resized = frame_to_payload(frame, args.width, args.height, args.mode)
            t_stage1 = time.perf_counter()  # end of decode+resize

            live.reset()
            # Deliberately do NOT touch the display here. The window keeps
            # showing the previous completed frame -- untouched, not black --
            # right up until the new one is fully in (or times out) below.
            # cv2.waitKey still needs to run periodically to pump the GUI
            # event queue and catch 'q', it just doesn't imshow anything.
            key = cv2.waitKey(1) & 0xFF
            if key in (ord("q"), 27):
                quit_requested = True
                break

            t_send_start = time.perf_counter()
            send_payload(sock, payload, target, args.chunk_size, args.gap_ms)
            t_send_end = time.perf_counter()  # end of network send

            deadline = time.perf_counter() + args.frame_timeout
            while time.perf_counter() < deadline and not live.done.is_set():
                key = cv2.waitKey(15) & 0xFF
                if key in (ord("q"), 27):
                    quit_requested = True
                    break
            t_stage2 = time.perf_counter()  # end of network wait/receive

            # Swap in the new frame ONLY now that it's fully arrived (or timed
            # out) -- this is the single point where the FPGA panel changes.
            fpga_bgr, pos = live.as_bgr_image()
            status = "OK" if live.done.is_set() else "TIMEOUT"
            pct = 100.0 * pos / expected_len
            canvas = make_canvas(
                src_resized, fpga_bgr, disp_w, disp_h,
                f"source [{sent_idx}]", f"FPGA {pct:.0f}% [{status}]",
            )
            cv2.imshow(win_name, canvas)
            if writer:
                writer.write(canvas)
            if quit_requested:
                cv2.waitKey(1)
                break
            cv2.waitKey(1)
            t_stage3 = time.perf_counter()  # end of final display

            if args.timing_every and sent_idx % args.timing_every == 0:
                interval_frames = sent_idx - last_report_idx
                interval_s = t_stage3 - last_report_time
                interval_fps = interval_frames / interval_s if interval_s > 0 else 0.0
                decode_ms = (t_stage1 - t_stage0) * 1000
                net_ms = (t_stage2 - t_send_start) * 1000
                disp_ms = (t_stage3 - t_stage2) * 1000
                total_ms = (t_stage3 - t_stage0) * 1000
                lat = (live.first_byte_time - t_send_end) * 1000 if live.first_byte_time else None
                print(f"  frame {sent_idx}: {status} | decode/resize={decode_ms:5.1f}ms  "
                      f"network={net_ms:6.1f}ms  display={disp_ms:5.1f}ms  "
                      f"total={total_ms:6.1f}ms  fps={interval_fps:4.1f}  "
                      f"{'(1st byte lat %.1fms)' % lat if lat is not None else '(no reply)'}")
                last_report_time = t_stage3
                last_report_idx = sent_idx

    finally:
        collector.stop()
        sock.close()
        cap.release()
        if writer:
            writer.release()
        cv2.destroyAllWindows()

    elapsed = time.perf_counter() - run_start
    avg_fps = sent_idx / elapsed if elapsed > 0 else 0.0
    print(f"\nDone. Sent {sent_idx} frame(s) in {elapsed:.1f}s (avg {avg_fps:.1f} fps).")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("video_source", help="path to a video file, or a camera index e.g. '0'")
    ap.add_argument("--width", type=int, default=128)
    ap.add_argument("--height", type=int, default=128)
    ap.add_argument("--mode", choices=["L", "RGB"], default="L")
    ap.add_argument("--target-ip", default=DEFAULT_TARGET_IP)
    ap.add_argument("--target-port", type=int, default=DEFAULT_TARGET_PORT)
    ap.add_argument("--local-ip", default="0.0.0.0")
    ap.add_argument("--local-port", type=int, default=DEFAULT_LOCAL_PORT)
    ap.add_argument("--chunk-size", type=int, default=DEFAULT_CHUNK_SIZE,
                     help="bytes per UDP chunk sent to the FPGA (max 1472). Default is "
                          "conservative to protect the FPGA's RX FIFO, but --gap-ms 0 "
                          "--chunk-size 1472 has sustained 29-32 FPS at 256x256/mode L "
                          "with no observed stalling -- worth trying if you want more FPS")
    ap.add_argument("--gap-ms", type=float, default=1.0,
                     help="delay between UDP chunks, to avoid bursting the FPGA's input FIFO")
    ap.add_argument("--frame-timeout", type=float, default=3.0,
                     help="max seconds to wait for each frame's reply before moving on")
    ap.add_argument("--frame-skip", type=int, default=1,
                     help="only send every Nth frame from the source (speeds up long videos)")
    ap.add_argument("--max-frames", type=int, default=0,
                     help="stop after this many sent frames (0 = no limit)")
    ap.add_argument("--loop", action="store_true",
                     help="loop the video file when it ends (ignored for cameras)")
    ap.add_argument("--iface", default=DEFAULT_IFACE)
    ap.add_argument("--fpga-mac", default=DEFAULT_FPGA_MAC)
    ap.add_argument("--ethertype", type=lambda s: int(s, 0), default=DEFAULT_ETHERTYPE)
    ap.add_argument("--scale", type=int, default=3,
                     help="display window scale factor per side (nearest-neighbor upscale)")
    ap.add_argument("--record", default=None,
                     help="save the source|FPGA side-by-side comparison to this video file "
                          "(one recorded frame per finished/timed-out source frame)")
    ap.add_argument("--timing-every", type=int, default=10,
                     help="print a decode/network/display timing breakdown every N frames "
                          "(0 to disable) -- use this to see where choppiness is actually coming from")
    args = ap.parse_args()

    if not (0 < args.chunk_size <= MAX_UDP_PAYLOAD):
        sys.exit(f"--chunk-size must be between 1 and {MAX_UDP_PAYLOAD}")

    run(args)


if __name__ == "__main__":
    main()