# Cheeko Gotchi + Pip: User Manual

> **Now running: Claude Buddy** (since 2026-11-11). Pip and Navigation are no
> longer flashed. Claude Buddy has three pages; swipe left/right or press + / -
> to move between them:
> 1. **The buddy**: shows what Claude Code is doing on your Mac. Cooking (chef
>    hat), "Your turn!" (waves, chimes), all done (confetti), or napping
>    (nightcap). Tap it to make it giggle, shake it to make it dizzy, tilt it to
>    make it look around.
> 2. **Usage**: 5-hour session and weekly plan limits, with reset times and a
>    pace marker.
> 3. **Today**: lines written, prompts, tool calls, tokens, activity by hour,
>    and the latest actions.
>
> The time is at the top. Touch and hold anywhere for 1 second to turn sound
> on or off. The Mac side is the **Claude Buddy** menu bar app (`mac/README.md`).
> To go back to Pip + Navigation, run `./pet.sh flash cheeko`. The rest of this
> manual describes that older firmware.

The Cheeko Gotchi is a small handheld computer (an ESP32-S3 chip) with a touch
screen, a speaker, two microphones, a motion sensor, Wi-Fi and Bluetooth. It
came with no manual, so this one covers the device as we found it and **Pip**,
the virtual pet we put on it.

Items marked **(to verify)** come from the circuit design but haven't been
tested on this unit yet.

---

## 1. The outside of the device

| Part | What it is |
| --- | --- |
| Touch screen | 2-inch colour screen, 240 × 296 pixels, responds to taps |
| **+ button** | Volume-up key. In Pip: **feed** |
| **− button** | Volume-down key. In Pip: **play** |
| **Middle button** | **Power switch:** long press = on/off, short press = nothing. Apps don't use it |
| Two USB-C ports | Unlabelled = main port; "UART" = backup/debug port. See below |
| Speaker | Plays Pip's sounds |
| Microphones | Two, not used by Pip yet |

There is also a hidden **BOOT** button on the circuit board, usually not
reachable through the case. You only need it for deep recovery, and there is a
way around it (see Troubleshooting).

### The two USB-C ports

**Port 1: unlabelled, the main port (use this one).** It connects straight to
the chip's built-in USB. On the Mac it appears as `/dev/cu.usbmodem101`. It
handles everything: charging, flashing Pip, and Pip's text console (`stats`,
`feed`, …). `./pet.sh` uses this port.

**Port 2: labelled "UART", the backup/debug port.** It goes through a small
USB-to-serial converter chip to the processor's basic serial line. On the Mac
it would show up with a different name, e.g. `/dev/cu.usbserial-…` or
`/dev/cu.wchusbserial-…` **(to verify)**. What it's good for:

- **Seeing startup and crash messages.** The chip prints its boot log and any
  crash report here. The main USB port drops out briefly whenever the device
  restarts, so crash messages are often lost there. The UART port keeps
  listening through restarts.
- **Recovery flashing.** If a bad program stops the main USB port from working,
  you can usually still flash through the UART port, which doesn't depend on
  the program running **(to verify)**.
- **Charging,** probably **(to verify)**.

What it's **not** for: talking to Pip. Pip's console lives on the main port, so
typing `stats` into the UART port does nothing.

**Day to day: use the main (unlabelled) port.** Use UART only when debugging or
recovering. A charge-only *cable* (common with cheap cables) shows no port on
either, so use a cable you know carries data.

---

## 2. Power

### Turning it on and off
The **middle button is a hardware power switch**. Apps never see it.

- **Long press (about 2–3 s): switches the device on, or off.**
- **Short press: does nothing.**
- Plugged into USB, it also turns on by itself.
- Switching off cuts power straight away. Pip saves its stats every minute, so
  at most a minute of progress is lost.

### Can I unplug it and carry it around?
The board has a battery charger built in, so it is designed to run on a
battery. Confirmed on this unit: it keeps running when unplugged.

- It charges whenever it's plugged in, through either port.
- **There is no battery-level gauge.** The circuit has no way to measure the
  charge left. It has a "charging" signal, but that pin is shared with the
  chip's memory, so Pip can't read it. When the battery runs out it just stops.
  Pip saves its state every minute, so at most a minute of progress is lost.
  (Checked: GPIO 18, the only spare voltage-measuring pin, reads a constant
  maximum, so no battery sensor is wired there.)
- **Work-arounds:** look for a small charging LED near the ports, or time one
  full battery run. For a real percentage, add two 100kΩ resistors from the
  battery + wire to GPIO 18 and from GPIO 18 to ground; Pip's code could then
  read the battery voltage.

---

## 3. Wi-Fi and Bluetooth

The hardware has both, but **Pip uses neither**: the radios are off and the
device doesn't connect to anything. Pip runs entirely on the device, and
nothing it does needs the internet. Wi-Fi features (weather, time, cloud voice)
could be added later.

---

## 4. Switching apps

The device has two apps in one firmware: **Pip** (the pet) and **Navigation**
(the bike navigator).

- **Hold + and − together for about 1 second** to switch. "switching app..."
  shows while you hold; then the new app's name pops up.
- It powers on into whichever app you used last.
- Pip keeps getting hungry while you're in Navigation (quietly: no whining
  there), so check on it when you switch back.
- When a route arrives from the Mac (or later the phone), the device switches
  to Navigation by itself.
- + and − act when you **let go**, not when you press, so a two-button hold
  never feeds or plays by accident.

## 5. Using Pip

### Buttons

| Button | Single press | Double press | Hold |
| --- | --- | --- | --- |
| **+** | Feed Pip a cookie | Two feedings (the 2nd is often "I'm full!") | Same as one press |
| **−** | Play (Pip bounces) | Two play sessions | Same as one press |
| **+ and − together** | | | **~1 s = switch to Navigation** |
| **Middle** | Nothing | Nothing | **Long press = power on/off** |

- **Sleep:** press and hold on Pip for about 1 second. **Wake:** tap Pip (or
  press + or −). Pip also wakes by itself when its energy is full.
- When Pip is **asleep**, + and − just wake it up (they don't feed or play
  until it's awake).
- Pip refuses some things: food when it's already full ("I'm full!"), and play
  when energy is very low ("too sleepy..."). You'll hear a low "nope" sound.

### Touch and motion

| Action | What Pip does |
| --- | --- |
| Tap Pip's body | Gets petted: hearts, blush, happy chirp |
| Tap anywhere else | Looks at the spot you tapped |
| **Hold Pip ~1 s** | **Goes to sleep** (night scene, floating z's) |
| Tap while asleep | Wakes up (only when tapping Pip itself) |
| Shake the device | Gets dizzy: spinning X eyes, stars around its head |
| Tilt the device | Eyes follow the tilt |

Sliding a finger does nothing more; holding on Pip puts it to sleep.

### The screen

- **Top bars:** FOOD, FUN, ENERGY. Green = good (above 50), yellow = getting
  low, red = needs attention (25 or below).
- **Under the bars:** Pip's name and age (time it's been switched on).
- **Bottom:** reminder of the controls.
- **Night scene** (dark sky, stars, floating z's) = Pip is asleep.

### How Pip's needs change

| | Awake | Asleep |
| --- | --- | --- |
| Food | drops ~1.5 per minute (full to empty in about an hour) | drops slowly (0.5/min) |
| Fun | drops ~1.2 per minute | doesn't change |
| Energy | drops ~0.6 per minute | **refills** ~4 per minute |

| You do | Effect |
| --- | --- |
| Feed | Food +25 |
| Play | Fun +20, Energy −8, Food −4 |
| Pet | Fun +6 |
| Shake | Fun −3 |

- Pip **wakes up on its own** when energy is full.
- Below 25 food it whines and says "I'm hungry...".
- Its face shows its mood: sad eyebrows when hungry or bored, heavy eyelids when
  tired, blushing cheeks when happy and well fed.
- Pip remembers its stats when switched off.

---

## 6. Using Navigation

| Button | Does |
| --- | --- |
| **+** | Start / stop the built-in demo ride |
| **+ and − together, ~1 s** | Switch to Pip |
| **Middle, long press** | Power on/off |

Ride a real route from the Mac (see below), or, after Phase 2, from the iPhone.

## 7. For tinkering (on the Mac)

Everything lives in `~/madhu/diy-pet`:

| Path | What |
| --- | --- |
| `buddy/` | Claude Buddy firmware (the default): `main.cpp` (pages, touch, clock, console), `face/meters/day.cpp` (the three pages) |
| `mac/` | Claude Buddy menu bar app for the Mac (`build.sh`, `README.md`) |
| `cheeko/` | The older firmware: `main.cpp` (app switcher, buttons, console), `pip.cpp` (Pip), `nav_app.cpp` + `model/view/demo.cpp` (Navigation) |
| `lib/cheeko_board/` | Shared hardware code (screen, touch, buttons, sound, power) |
| `tools/sim_ride.py` | Ride a real route on the device from the Mac |
| `tools/screenshot.py` | Save what's on the device's screen as a PNG |
| `tools/buddy_sim/render.sh` | Draw every Claude Buddy screen on the Mac, no device needed |
| `pet.sh` | Build / flash / console helper |
| `backup/factory_16MB.bin` | Full copy of the device as it shipped (local only, not in git) |
| `cheeko-gotchi/` | Vendor's code and hardware notes (`SKILL.md`); clone of [ALTIO-AI-PRIVATE-LIMITED/cheeko-gotchi](https://github.com/ALTIO-AI-PRIVATE-LIMITED/cheeko-gotchi), not in git |

```bash
cd ~/madhu/diy-pet
./pet.sh flash          # put Claude Buddy on the device (main port, not UART)
./pet.sh flash cheeko   # or the older Pip + Navigation firmware
./pet.sh monitor    # text console, Ctrl-C to quit
```

Claude Buddy console commands: `page 1|2|3`, `demo` (cycle every mood with
fake data), `demo off`, `sound`, `status`, `shot`, or any protocol line from
`buddy/PROTOCOL.md`.

Older firmware console commands: `help`, `app pip`, `app nav`, `fps`,
`shot`. In Pip: `stats`, `feed`, `play`, `pet`, `sleep`, `dizzy`, `reset`
(start Pip over), `touch` (print tap positions), `adc` (voltage on GPIO 18,
for the battery mod). In Navigation: `demo`, `stop`, `status`.

Ride a real route (coordinates from Google Maps, long-press a spot):
```bash
.venv/bin/python tools/sim_ride.py --from 12.824566,80.078958 --to 12.844632,80.061871 --kmh 60
```
Opening the console restarts the device; that's normal.

**Restore the original factory software:**
```bash
.venv/bin/esptool.py --chip esp32s3 -p /dev/cu.usbmodem101 write_flash 0x0 backup/factory_16MB.bin
```

---

## 6. Troubleshooting

| Problem | Fix |
| --- | --- |
| Screen stays dark after flashing | Unplug USB and plug it back in |
| Mac doesn't see the device | Use the main (unlabelled) port and a data cable; turn the device on |
| Main port won't flash at all | Try the UART port: `./pet.sh` won't find it, so flash with esptool using its `/dev/cu.usbserial…` name |
| Device keeps restarting and you can't see why | Plug into the UART port and watch its log: crash messages show up there |
| Port name looks like `/dev/cu.usbmodem68EE8F…` (long) | The device is in recovery mode. Run `.venv/bin/python -c "import serial; serial.Serial('/dev/cu.usbmodemXXXX', 1200).close()"` with that name, wait 4 s, flash again |
| Won't power off | It's on USB power. Unplug first |
| Device shuts off by itself | Battery is empty. Plug it in |
| Pip's needs feel too fast or slow | Rates are in `updateNeeds()` in `cheeko/pip.cpp` |
