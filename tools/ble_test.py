#!/usr/bin/env python3
"""Talk to the Cheeko over Bluetooth from the Mac, the way the iPhone app will.

  .venv/bin/python tools/ble_test.py          # walk a 60 m square in free-ride mode

Finds the device advertising as "Cheeko", subscribes to its notifications
(expects HELLO), sends RESET, then a POS every second around a square.
"""
import asyncio
import math
import struct

from bleak import BleakClient, BleakScanner

SERVICE = "6e3a0001-6c3f-4b6a-9c2e-8f1d2c3b4a50"
RX = "6e3a0002-6c3f-4b6a-9c2e-8f1d2c3b4a50"
TX = "6e3a0003-6c3f-4b6a-9c2e-8f1d2c3b4a50"


def pos(x, y, heading, speed, accuracy):
    return struct.pack("<BiiHHH", 0x10, int(x * 10), int(y * 10), int(heading % 360 * 100),
                       int(speed * 100), int(accuracy * 10))


async def main():
    print("scanning for Cheeko...")
    device = await BleakScanner.find_device_by_filter(
        lambda d, adv: SERVICE in [u.lower() for u in adv.service_uuids] or d.name == "Cheeko", timeout=15)
    if not device:
        raise SystemExit("Cheeko not found: is the nav firmware running and nothing else connected?")
    print(f"found {device.name} ({device.address})")

    async with BleakClient(device) as client:
        hello = asyncio.Event()

        def on_notify(_, data: bytearray):
            print(f"notify: {data.hex()}" + ("  (HELLO)" if data[:1] == b"\x20" else ""))
            if data[:1] == b"\x20":
                hello.set()

        await client.start_notify(TX, on_notify)
        try:
            await asyncio.wait_for(hello.wait(), 3)
        except asyncio.TimeoutError:
            print("no HELLO after subscribing")
        print(f"MTU {client.mtu_size}")

        await client.write_gatt_char(RX, b"\x14", response=True)  # RESET -> navigator, free ride
        # A 60 m square at 4 m/s (a brisk walk), one fix per second.
        corners = [(0, 0), (0, 60), (60, 60), (60, 0), (0, 0)]
        for (ax, ay), (bx, by) in zip(corners, corners[1:]):
            heading = math.degrees(math.atan2(bx - ax, by - ay))
            for i in range(15):
                t = i / 15
                await client.write_gatt_char(RX, pos(ax + (bx - ax) * t, ay + (by - ay) * t, heading, 4.0, 6),
                                             response=False)
                await asyncio.sleep(1)
        print("done")


if __name__ == "__main__":
    asyncio.run(main())
