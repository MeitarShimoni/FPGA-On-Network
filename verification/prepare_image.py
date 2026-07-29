#!/usr/bin/env python3
"""
prepare_image.py
----------------
Resize/convert a normal image (jpg/png/...) into a RAW byte stream that the
SystemVerilog testbench (tb_chip_top_eth.sv) can push into the FPGA over
simulated RMII.

Why this lives in Python and not in the testbench:
SystemVerilog has no image codec and no resampling filter. The right split
of work is: Python does decode + resize (real interpolation, real color
handling), and produces a flat, headerless byte buffer. The testbench's
only job is to move bytes reliably across the wire -- it never needs to
know what a pixel is.

Output format:
    A raw binary file containing exactly WIDTH*HEIGHT*(1 or 3) bytes,
    row-major, no header, no metadata. Mode 'L' = 1 byte/pixel grayscale,
    mode 'RGB' = 3 bytes/pixel (R,G,B interleaved).

Usage:
    python3 prepare_image.py input.jpg image_payload.bin --width 64 --height 64 --mode L
"""
import argparse
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("This script needs Pillow: pip install pillow")

MAX_UDP_PAYLOAD = 1472  # 1500 MTU - 20 (IP) - 8 (UDP)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input_image")
    ap.add_argument("output_bin")
    ap.add_argument("--width", type=int, default=64)
    ap.add_argument("--height", type=int, default=64)
    ap.add_argument("--mode", choices=["L", "RGB"], default="L",
                     help="L = 8-bit grayscale (1 B/px), RGB = 24-bit color (3 B/px)")
    args = ap.parse_args()

    img = Image.open(args.input_image).convert(args.mode)
    img = img.resize((args.width, args.height), Image.LANCZOS)

    raw = img.tobytes()
    with open(args.output_bin, "wb") as f:
        f.write(raw)

    n_frames = (len(raw) + MAX_UDP_PAYLOAD - 1) // MAX_UDP_PAYLOAD

    print(f"Wrote {args.output_bin}")
    print(f"  {args.width}x{args.height}, mode={args.mode}, {len(raw)} bytes")
    print(f"  -> testbench will need {n_frames} Ethernet/UDP frame(s) "
          f"at {MAX_UDP_PAYLOAD} B payload/frame")
    print(f"  Pass these to the testbench (edit plusargs / parameters):")
    print(f"    +IMAGE_FILE={args.output_bin}")
    print(f"  Keep width/height/mode noted somewhere -- you'll need them again")
    print(f"  in view_captured_image.py to turn the captured bytes back into a picture.")


if __name__ == "__main__":
    main()
