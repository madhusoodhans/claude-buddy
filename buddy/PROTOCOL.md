# Claude Buddy protocol

The Mac helper (`../mac/ClaudeBuddy.swift`) connects over Bluetooth LE to the
device named **Claude Buddy** (service and characteristic UUIDs in `bt_link.h`)
and writes one ASCII text message per write to RX. Fields are separated by
`|`; text fields never contain `|` (the Mac replaces it). The same lines can be
typed on the USB console for testing.

When the Mac subscribes to TX, the device notifies `H`. The Mac then sends
every message again. It also resends them every 10 seconds as a heartbeat.

| Message | Fields |
| --- | --- |
| `T\|epoch\|tz\|h24\|host` | Unix time, UTC offset in seconds, `1` for a 24-hour clock, the Mac's name. |
| `U\|ok\|s\|sr\|w\|wr\|plan\|age\|note` | Usage. `ok` `0` means no reading (then `note` says why). `s`/`w` = 5-hour session and weekly % used, `sr`/`wr` = minutes until each resets (`-1` unknown), `plan` e.g. `Pro`, `age` = seconds since the reading. |
| `S\|mood\|since\|sessions\|project\|detail` | What Claude is doing. `mood`: `0` idle, `1` working, `2` waiting for you, `3` just finished. `since` = seconds in this mood, `sessions` = open Claude Code sessions, `project` = folder name, `detail` e.g. `Editing main.cpp`. |
| `A\|hh:mm\|text` | One line for the activity feed (newest last). |
| `D\|prompts\|tools\|files\|lines\|tokens\|h0,..,h23\|top` | Today so far: prompts sent, tool calls, files edited, lines written, output tokens, 24 per-hour activity counts, the busiest project. |
