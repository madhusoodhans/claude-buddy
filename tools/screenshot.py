#!/usr/bin/env python3
"""Grab what's on the Cheeko Gotchi screen and save it as a PNG.

  .venv/bin/python tools/screenshot.py out.png [--port /dev/cu.usbmodem101] [--scale 2]

Needs firmware with the `shot` console command (Claude Buddy has it).
"""
import argparse
import glob
import time

import serial
from PIL import Image


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--port", default=None)
    ap.add_argument("--scale", type=int, default=2)
    ap.add_argument("--no-drain", action="store_true", help="skip waiting for the boot log")
    args = ap.parse_args()

    port = args.port or sorted(glob.glob("/dev/cu.usbmodem*"))[0]
    s = serial.Serial(port, 115200, timeout=0.8)
    if not args.no_drain:
        while s.read(4000):  # opening the port resets the board; wait for its log to finish
            pass
        time.sleep(0.5)
    s.reset_input_buffer()
    s.write(b"shot\n")

    while True:
        line = s.readline().decode(errors="replace").strip()
        if not line:
            raise SystemExit("no response to 'shot'")
        if line.startswith("SHOT "):
            break
    _, w, h, n = line.split()
    w, h, n = int(w), int(h), int(n)
    s.timeout = 5
    data = s.read(n)
    if len(data) != n:
        raise SystemExit(f"short read: {len(data)} of {n} bytes")

    img = Image.new("RGB", (w, h))
    px = img.load()
    for i in range(w * h):
        v = data[2 * i] | data[2 * i + 1] << 8
        px[i % w, i // w] = ((v >> 11) << 3, ((v >> 5) & 0x3F) << 2, (v & 0x1F) << 3)
    if args.scale > 1:
        img = img.resize((w * args.scale, h * args.scale), Image.NEAREST)
    img.save(args.out)
    print(f"saved {args.out}")


if __name__ == "__main__":
    main()
