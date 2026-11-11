# Plan: Bike navigation display on the Cheeko Gotchi

## Goal

A black-and-white navigation screen on the Cheeko Gotchi, driven by an iPhone
app over Bluetooth:

- Your position is a **fixed arrow** near the bottom of the screen. The **map
  rotates and slides under it** (heading-up), so the arrow appears to move
  along the road.
- The **route** is drawn as a thick line, with **nearby side roads** as thin
  lines, so junctions are easy to read.
- On top: the **next turn** (icon + distance, e.g. "↱ 250 m"), the **street
  name**, and the **ETA**.
- Works with the phone **locked in a pocket**. No Google Maps needed.

Not in scope: a full map with labels, buildings or satellite imagery. Using
Google's maps. Touch controls while riding.

---

## How it works

```
iPhone app (Swift)                              Cheeko Gotchi (Arduino C++)
──────────────────────────────                  ──────────────────────────────
Search destination  (Apple MapKit search)
Route + turn list   (Apple MapKit directions)
Side roads          (OpenStreetMap, once per route)
GPS position + heading, 1×/sec                  Stores route + side roads
Off-route check → re-route                      Smooths position between fixes
Next-turn distance, ETA            ───BLE───▶   Rotates map to heading, draws
                                                 arrow, route, roads, turn info
                                   ◀──BLE────   "ready" / "need route again"
```

**Division of work:** the **phone does the thinking** (routing, GPS,
off-route detection, distances). The **device draws**. This keeps the
firmware simple and puts the logic where it's easy to change and debug.

### Why this is fast enough (measured)

Pip's full-screen redraw on this device: draw 7.4 ms + send to screen 42.5 ms
= **20 fps**. A map frame (≈200 line segments, rotated) costs about the same to
draw. If it feels choppy, background (DMA) screen transfer should reach ~30 fps.

### Data sent over Bluetooth

The phone converts GPS coordinates into **metres east/north of a route origin**
before sending, so the device never deals with latitude/longitude.

| Message | When | Contents | Size |
| --- | --- | --- | --- |
| `ROUTE` | New route / re-route | origin, list of points (x, y in decimetres) | few KB, sent in chunks |
| `ROADS` | After route | side-road polylines near the route | few KB, chunked |
| `POS` | 1×/sec | x, y, heading, speed, accuracy | ~16 bytes |
| `TURN` | When it changes | maneuver type, distance, street name | ~40 bytes |
| `TRIP` | 1×/sec | ETA, distance remaining | ~8 bytes |
| `STATE` | On change | navigating / arrived / rerouting / lost GPS | 1 byte |
| `HELLO` (device → phone) | On connect / after a restart | "send me the route again" | 1 byte |

The same message format also works over **USB serial**, so the device can be
tested with a Mac script before the iPhone app exists.

---

## Phases

Each phase ends with something you can see working. We don't start the next
until the current one is accepted.

### Phase 0: Groundwork ✅ done 2026-11-06
- Move the board code shared with Pip (display, touch, buttons, sound, power)
  into a shared library `lib/cheeko_board/`, so Pip and the navigator use the
  same tested code.
- New firmware sketch `nav/`. Pip keeps working as before.

**Done when:** Pip still builds and runs from the shared library, and `nav`
boots to a blank navigation screen.

### Phase 1: Navigation screen with a simulated ride (device only)
- Heading-up renderer: route line, side roads, fixed arrow, turn banner,
  bottom bar with street and ETA.
- Built-in demo route that "rides" itself in a loop.
- Smooth motion between position updates (interpolation).
- Auto-zoom: zoomed out when fast, zoomed in approaching a turn.
- Mac script `tools/sim_ride.py`: sends a real route (from a GPX file) over
  USB in the Bluetooth message format, to test with real roads.

**Done when:** on the device, the arrow follows the road through turns at
≥ 20 fps, and you're happy with how it looks (line widths, text size, icons).

**Status (2026-11-06): built, waiting on your look + outdoor check.**
- 22.7 fps measured (drawing and screen transfer now overlap).
- Real-route test: 6.9 km across Bengaluru via `tools/sim_ride.py`, all turns shown.
- Found: routers skip 90° bends where the road keeps its name. The sender now
  adds sharp bends from the road shape. **The iPhone app must do the same.**
- Screen layout keeps text out of the rounded glass corners (`board::SAFE_X`).

### Phase 2: Bluetooth link + iPhone app skeleton
- Device: Bluetooth Low Energy "peripheral" with one custom service.
- iPhone app (SwiftUI): finds and connects to the device, sends live GPS.
- Auto-reconnect on both sides; device shows "phone disconnected".
- Works with the phone locked (iOS background location + Bluetooth).

**Done when:** walking around with the phone locked, the arrow on the device
tracks you live.

**Status (2026-11-07): built, waiting on install + test walk.**
- Device: Bluetooth LE as `Cheeko` (service in `cheeko/PROTOCOL.md`), free-ride
  screen (speed, GPS accuracy, trail). Tested from the Mac with `tools/ble_test.py`.
- iPhone app `ios/CheekoNav` (SwiftUI, one screen, styled after the post the
  user shared): connects/reconnects, sends POS 1×/s with the phone locked,
  reverse-geocodes the current road. Builds; runs in the simulator.

### Phase 3: Routing and turn-by-turn
- App: destination search, route preview, Start/Stop button.
- Sends route + turns; updates next-turn distance and ETA.
- Off-route (≈ 40 m away for ~5 s) → re-route automatically.
- Arrival screen. Optional choices: avoid highways / tolls.

**Done when:** a real ride (as passenger, or a short test) navigates to a
destination, including one deliberate wrong turn that triggers a re-route.

### Phase 4: Side roads and polish
- Fetch side roads along the route from OpenStreetMap at route start.
- White-on-black theme tuned for daylight (contrast, line widths).
- Large high-contrast turn icons. Haptic/sound cue before turns (optional).

**Done when:** junctions are easy to tell apart at a glance on a ride.

### Phase 5: Ride-ready
- Long-ride test: 1+ hour, phone locked, Bluetooth dropouts recovered.
- Battery run-time measurement. Recommend powering from the bike's USB.
- Mount and weather protection (your choice of case).

**Done when:** you'd trust it on a normal ride.

### Later (optional)
- Wi-Fi flashing (OTA) so updates don't need a cable.

---

## What you'll need

| Item | Status |
| --- | --- |
| Mac with Xcode | ✅ Xcode 26.6 installed |
| Apple ID for installing on your iPhone | Free works, but the app must be reinstalled from Xcode **every 7 days**. $99/yr Apple Developer account removes that |
| iPhone with Bluetooth + GPS | ✅ |
| Bike USB power + mount/case | Phase 5 |

---

## Risks and how we handle them

| Risk | Impact | Plan |
| --- | --- | --- |
| **Hard to read in bright sun** (LCD, not a sunlight display) | High | Black-on-white day theme, full brightness, big shapes; test outdoors in Phase 1 before going further |
| iOS stops the app in the background | High | Use the official background modes for navigation (location + Bluetooth); verify in Phase 2 |
| Bluetooth drops mid-ride | Medium | Auto-reconnect; device keeps showing the last route and "reconnecting"; phone resends route on reconnect |
| Apple routing is for cars, not motorcycles | Low | Fine for most roads; offer avoid-highways/tolls options |
| OpenStreetMap service rate limits | Low | One request per route, cached; side roads are optional (route still works without them) |
| No battery gauge | Medium | Power from bike USB; measure run-time once |
| Safety | High | Glanceable only: no touch needed while riding, big turn icon, no text you have to read carefully |

---

## Decisions (made 2026-11-06)

1. **Theme: white on black**, like the product. We still check readability in
   sun during Phase 1, and tune line widths and brightness there.
2. **Pip stays**, in the same firmware as the navigator (390 KB of a 4 MB app
   slot). Hold + and − together to switch.
3. **Free Apple account to start** (reinstall from Xcode every 7 days).

## Files this will create

```
diy-pet/
├── plan.md               this file
├── lib/cheeko_board/     shared board code (Phase 0)
├── cheeko/               one firmware: Pip + Navigation, hold + and - to switch
├── tools/sim_ride.py     Mac route simulator (Phase 1)
└── ios/CheekoNav/        iPhone app (Phases 2-4)
```
