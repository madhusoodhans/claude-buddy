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
| `U\|ok\|age\|plan\|note\|meter\|meter` | Usage. `ok` `0` = nothing to show (then `note` says why: signed out, API key account, ...). `age` = seconds since the reading, `plan` e.g. `Pro`, `Team`, `Enterprise`. `note` explains anything unusual (`No 5-hour limit on this plan`). Then 0-2 meters, each `label;pct;pace;reset`: `pace` = how much of the window has gone by in 1/1000 (`-1` unknown), `reset` = the text to show (`Resets in 2h 54m`, `Resets Dec 1`, `Not started`). The Mac picks the meters: 5-hour session + weekly for most plans, weekly alone when there is no 5-hour limit, the monthly spend for spend-capped Enterprise accounts. |
| `S\|mood\|since\|sessions\|project\|detail` | What Claude is doing. `mood`: `0` idle, `1` working, `2` waiting for you, `3` just finished. `since` = seconds in this mood, `sessions` = open Claude Code sessions, `project` = folder name, `detail` e.g. `Editing main.cpp`. |
| `A\|hh:mm\|text` | One line for the activity feed (newest last). |
| `D\|prompts\|tools\|files\|lines\|tokens\|h0,..,h23\|top` | Today so far: prompts sent, tool calls, files edited, lines written, output tokens, 24 per-hour activity counts, the busiest project. |
