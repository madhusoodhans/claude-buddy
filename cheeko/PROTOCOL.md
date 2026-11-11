# nav protocol

Messages from the sender (iPhone app, `tools/sim_ride.py`) to the Cheeko
Gotchi. The same bytes travel over both transports:

- **USB serial:** one message per line, `@` + lowercase hex, `\n`. The device
  replies `ok` or `err …` to each. Wait for the reply before sending the next
  line; the USB link drops bytes if you don't.
- **Bluetooth LE:** the device advertises as `Cheeko` with service
  `6e3a0001-6c3f-4b6a-9c2e-8f1d2c3b4a50`. Write each message to RX
  `6e3a0002-…` (write with response for route/roads, without response for
  live data). Subscribe to TX `6e3a0003-…` for notifications. A message must
  fit one write: keep `ROUTE_POINTS`/`ROADS_LINE` to ≤ 28 points (MTU 247).

All integers are **little-endian**. Positions are **decimetres east/north of
the route origin** (`i32`). The sender picks the origin (e.g. the route's
first point) and keeps it until the next `ROUTE_BEGIN`.

| Type | Name | Payload |
| --- | --- | --- |
| `0x01` | ROUTE_BEGIN | — (clears the route and the current turn) |
| `0x02` | ROUTE_POINTS | N × (`i32 x`, `i32 y`), appended; up to 60 per message |
| `0x03` | ROUTE_END | — (route is ready; state becomes Navigating) |
| `0x04` | ROADS_CLEAR | — |
| `0x05` | ROADS_LINE | N × (`i32 x`, `i32 y`), one polyline, 2–60 points |
| `0x10` | POS | `i32 x`, `i32 y`, `u16 heading` (centidegrees, clockwise from north), `u16 speed` (cm/s), optional `u16 accuracy` (dm) |
| `0x11` | TURN | `u8 maneuver`, `u8 roundabout exit` (0 = unknown), `u16 route point index` (`0xffff` = unknown), `u32 distance` (m), street name (UTF-8, rest of message, ≤ 47 bytes) |
| `0x12` | TRIP | `u8 ETA hour`, `u8 ETA minute`, `u32 remaining` (m), `u16 remaining` (min) |
| `0x13` | STATE | `u8 state` |
| `0x14` | RESET | — (forget everything, back to the idle screen) |
| `0x15` | UPCOMING | N × (`u8 maneuver`, `u8 exit`, `u16 route point index`): the turns after `TURN`, up to 2, for the "then" row |
| `0x16` | ROAD | name of the road we're on now (UTF-8), shown under the arrow |

Device to sender:

| Type | Name | Meaning |
| --- | --- | --- |
| `0x20` | HELLO | Device (re)started or the phone just subscribed: send the route and roads again. Over USB it prints the line `@20` |

**Maneuver:** 0 none, 1 straight, 2 slight left, 3 left, 4 sharp left,
5 slight right, 6 right, 7 sharp right, 8 U-turn (round to the right, as in
left-hand traffic), 9 roundabout, 10 arrive, 11 keep left, 12 keep right,
13 U-turn round to the left.

**State:** 0 idle, 1 navigating, 2 rerouting, 3 arrived, 4 no GPS.

## How often

- `POS`, `TURN`, `TRIP`: once per second while navigating.
- `UPCOMING`, `ROAD`: when they change (sending them every second is fine too).
- Route and roads: on start, on re-route, and after a `HELLO`.

The device smooths motion between `POS` messages and computes the distance to
the turn itself from the route point index, so once a second is enough. If no
message arrives for 5 s it shows "Phone lost".
