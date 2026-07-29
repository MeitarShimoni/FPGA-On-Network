#!/usr/bin/env python3
"""
view_captured_image.py
-----------------------
Takes the raw bytes the testbench captured off dut.ethernet_core.data_out
(written to captured_image.bin by tb_chip_top_eth.sv) and turns them back
into a viewable PNG, so you can eyeball whether the round trip through the
MAC preserved the image. Also byte-compares against the original payload
file if you pass it in.

Usage:
    python3 view_captured_image.py captured_image.bin --width 64 --height 64 --mode L \
        --reference image_payload.bin --out reconstructed.png
"""
import argparse
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("This script needs Pillow: pip install pillow")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("captured_bin")
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)
    ap.add_argument("--mode", choices=["L", "RGB"], default="L")
    ap.add_argument("--reference", help="original image_payload.bin to diff against")
    ap.add_argument("--out", default="reconstructed.png")
    args = ap.parse_args()

    with open(args.captured_bin, "rb") as f:
        data = f.read()

    bpp = 1 if args.mode == "L" else 3
    expected = args.width * args.height * bpp

    print(f"Captured {len(data)} bytes, expected {expected} bytes")
    if len(data) < expected:
        print("WARNING: fewer bytes captured than expected -- padding with 0 to render")
        data = data + b"\x00" * (expected - len(data))
    elif len(data) > expected:
        print("WARNING: more bytes captured than expected -- truncating to render")
        data = data[:expected]

    img = Image.frombytes(args.mode, (args.width, args.height), data)
    img.save(args.out)
    print(f"Wrote {args.out}")

    if args.reference:
        with open(args.reference, "rb") as f:
            ref = f.read()
        n = min(len(ref), len(data))
        mismatches = sum(1 for i in range(n) if ref[i] != data[i])
        print(f"Byte compare vs {args.reference}: "
              f"{mismatches} mismatches out of {n} common bytes "
              f"(len ref={len(ref)}, len captured={len(data)})")


if __name__ == "__main__":
    main()
