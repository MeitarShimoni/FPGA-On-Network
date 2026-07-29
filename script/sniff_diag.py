#!/usr/bin/env python3
"""
sniff_diag.py
--------------
One-shot diagnostic: sniff the FPGA link with Scapy while sending an image
over the normal UDP path, and report exactly what hit the wire in both
directions -- independent of anything the FPGA's seven-segment display
shows. Needed because ethernet_mac's reply path (see
MyIPs/Ethernet_MAC/src/ethernet_mac.sv) uses a raw non-IP EtherType
(0x88B5) to a hardcoded destination MAC, not UDP/IP -- a normal socket can
never see it, so this checks at the NIC/driver level instead.
"""
import socket
import sys
import threading
import time

from scapy.all import sniff, Ether  # noqa: E402

IFACE = "FPGA Nexys A7"
FPGA_MAC = "02:00:00:00:00:01"
TARGET_IP = "192.168.1.2"
TARGET_PORT = 5000
LOCAL_PORT = 50000
MAX_UDP_PAYLOAD = 1472

captured = []


def on_packet(pkt):
    captured.append((time.perf_counter(), pkt))


def send_image(raw: bytes):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", LOCAL_PORT))
    n = 0
    for i in range(0, len(raw), MAX_UDP_PAYLOAD):
        sock.sendto(raw[i:i + MAX_UDP_PAYLOAD], (TARGET_IP, TARGET_PORT))
        n += 1
        time.sleep(0.001)
    sock.close()
    print(f"[send] {len(raw)} bytes in {n} UDP datagrams")


def main():
    width = height = 256
    try:
        from PIL import Image
        raw = Image.open("messi.png").convert("L").resize((width, height)).tobytes()
    except Exception as e:
        print(f"Could not load messi.png ({e}); using synthetic data instead")
        raw = bytes((i % 256) for i in range(width * height))

    stop_evt = threading.Event()

    def sniffer():
        sniff(iface=IFACE, prn=on_packet, store=False,
              stop_filter=lambda p: stop_evt.is_set())

    t = threading.Thread(target=sniffer, daemon=True)
    t.start()
    time.sleep(0.5)  # let sniff() actually attach before we send

    t_send = time.perf_counter()
    send_image(raw)

    print("[sniff] capturing for 8s after send finishes...")
    time.sleep(8.0)
    stop_evt.set()
    time.sleep(0.5)

    print(f"\n[sniff] captured {len(captured)} frames total\n")

    to_fpga = [p for _, p in captured if p.haslayer(Ether) and p[Ether].dst.lower() == FPGA_MAC]
    from_fpga = [p for _, p in captured if p.haslayer(Ether) and p[Ether].src.lower() == FPGA_MAC]

    print(f"Frames TO FPGA MAC ({FPGA_MAC}):   {len(to_fpga)}")
    print(f"Frames FROM FPGA MAC ({FPGA_MAC}): {len(from_fpga)}")

    if from_fpga:
        print("\n--- Frames from the FPGA ---")
        for ts, p in captured:
            if p.haslayer(Ether) and p[Ether].src.lower() == FPGA_MAC:
                ether = p[Ether]
                print(f"  t={ts - t_send:+.4f}s  dst={ether.dst}  "
                      f"ethertype=0x{ether.type:04x}  len={len(p)}")
    else:
        print("\nNo frames at all came from the FPGA's MAC address during the "
              "capture window -- the reply never left the board (or never made "
              "it onto the wire), independent of any EtherType/UDP question.")

    if to_fpga:
        first = min(ts for ts, p in captured if p.haslayer(Ether) and p[Ether].dst.lower() == FPGA_MAC)
        last = max(ts for ts, p in captured if p.haslayer(Ether) and p[Ether].dst.lower() == FPGA_MAC)
        print(f"\nOutgoing frames to FPGA: first at t={first - t_send:+.4f}s, "
              f"last at t={last - t_send:+.4f}s ({len(to_fpga)} total, expected "
              f"{(len(raw) + MAX_UDP_PAYLOAD - 1) // MAX_UDP_PAYLOAD})")


if __name__ == "__main__":
    main()
