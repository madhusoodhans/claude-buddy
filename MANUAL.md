# Claude Buddy: device manual

Claude Buddy runs on a **Cheeko Gotchi**: a small handheld computer (an ESP32-S3
chip) with a 2-inch touch screen, a speaker, a motion sensor and Bluetooth. It
came with no manual, so this one covers the hardware as we found it and how
Claude Buddy uses it. Setting up the Mac side is in [mac/README.md](mac/README.md).

Items marked **(to verify)** come from the circuit design but haven't been
tested on this unit yet.

---

## 1. The outside of the device

| Part | What it is |
| --- | --- |
| Touch screen | 2-inch colour screen, 240 × 296 pixels. Swipe between pages, tap the buddy, hold for sound on/off |
| **+ button** | Next page |
| **− button** | Previous page |
| **Middle button** | **Power switch:** long press = on/off, short press = nothing. Claude Buddy never sees it |
| Two USB-C ports | Unlabelled = main port; "UART" = backup/debug port. See below |
| Speaker | Chimes when Claude needs you or finishes |
| Motion sensor | Tilt to make the buddy look around, shake to make it dizzy |

The screen's corners are rounded under the case, so nothing important is drawn
near them.

There is also a hidden **BOOT** button on the circuit board, usually not
reachable through the case. You only need it for deep recovery, and there is a
way around it (see Troubleshooting).

### The two USB-C ports

**Port 1: unlabelled, the main port (use this one).** It connects straight to
the chip's built-in USB. On the Mac it appears as `/dev/cu.usbmodem101`. It
handles charging, flashing, and the text console (`./pet.sh monitor`).

**Port 2: labelled "UART", the backup/debug port.** It goes through a small
USB-to-serial chip to the processor's basic serial line. On the Mac it shows up
with a different name, e.g. `/dev/cu.usbserial-…` **(to verify)**. It's useful
for:

- **Startup and crash messages.** The main port drops out whenever the device
  restarts, so crash reports are often lost there. The UART port keeps
  listening through restarts.
- **Recovery flashing,** when a bad program stops the main port from working
  **(to verify)**.

A charge-only cable shows no port at all. Use a cable you know carries data.

---

## 2. Power

- **Long press the middle button (about 2–3 s)** to switch the device on or off.
  Plugged into USB, it also turns on by itself, and it can't be switched off
  until it's unplugged.
- **Battery:** it charges whenever it's plugged in and keeps running unplugged.
  There's no battery gauge (no pin can measure the charge), so when the battery
  runs out it just stops.
- Claude Buddy keeps nothing important on the device. The Mac resends
  everything when it reconnects.

---

## 3. Using Claude Buddy

Swipe left or right (or press + / −) between three pages. The time is at the
top of each, with a spark that shows Claude's state on the left and the
Bluetooth link on the right (blue = connected to a Mac).

1. **The buddy** acts out what Claude Code is doing:
   - **Cooking:** chef hat, plus what Claude is working on right now.
   - **Your turn!:** waves and chimes when Claude needs permission, has a
     question, or has a plan for you. The device jumps to this page.
   - **All done!:** confetti and a jingle when a turn finishes.
   - **Napping:** nightcap and Zzz while nothing is happening.
   - **Looking for your Mac:** no Mac is connected.
2. **Usage:** your plan's limits, depending on the account: 5-hour session +
   weekly, weekly alone, or an organisation's monthly spend cap. Each bar has a
   pace marker. Green means behind pace, amber ahead of it, red means the limit
   is hit.
3. **Today:** lines written, prompts, tool calls, output tokens, activity by
   hour, and the latest actions, added up over every machine the Mac follows.

**Touch and hold anywhere for 1 second** to turn sound on or off.

The device connects to one Mac at a time: whichever Mac runs the Claude Buddy
app and finds it first. To move it to another Mac, quit the app on the first
one.

---

## 4. For tinkering (on the Mac)

```bash
./pet.sh flash      # build and upload the firmware (main port, not UART)
./pet.sh monitor    # text console, Ctrl-C to quit
```

Console commands: `page 1|2|3`, `demo` (cycle through every mood with made-up
data), `demo off`, `sound`, `status`, `shot` (used by `tools/screenshot.py`), or
any protocol line from [buddy/PROTOCOL.md](buddy/PROTOCOL.md).

To see every screen without the device, run `tools/buddy_sim/render.sh`.

---

## 5. Troubleshooting

| Problem | Fix |
| --- | --- |
| Screen stays dark after flashing | Unplug USB and plug it back in |
| Mac doesn't see the device over USB | Use the main (unlabelled) port and a data cable; turn the device on |
| Device says "Looking for your Mac" | Open Claude Buddy on the Mac. If another Mac has it, quit the app there |
| Main port won't flash at all | Try the UART port: `./pet.sh` won't find it, so flash with esptool using its `/dev/cu.usbserial…` name |
| Device keeps restarting and you can't see why | Plug into the UART port and watch its log: crash messages show up there |
| Port name looks like `/dev/cu.usbmodem68EE8F…` (long) | The device is in recovery mode. Run `.venv/bin/python -c "import serial; serial.Serial('/dev/cu.usbmodemXXXX', 1200).close()"` with that name, wait 4 s, flash again |
| Won't power off | It's on USB power. Unplug first |
| Device shuts off by itself | Battery is empty. Plug it in |
