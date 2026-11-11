# Claude Buddy for Mac

A menu bar app that connects your Cheeko Gotchi (running the Claude Buddy
firmware) to Claude Code on a Mac. Whichever Mac runs it, the device shows
that Mac's Claude: what it's doing right now, plan usage, and today's stats.

## Put it on another Mac

1. Download `ClaudeBuddy-mac.zip` from the repo's Releases page (or build it
   with `./build.sh`, which writes `dist/ClaudeBuddy-mac.zip`) and unzip it. Move **Claude Buddy.app** to Applications.
2. Open it. It isn't from the App Store, so the first time macOS blocks it:
   go to **System Settings → Privacy & Security** and click **Open Anyway**
   (or run `xattr -dr com.apple.quarantine "/Applications/Claude Buddy.app"`).
3. Click **Allow** when it asks for Bluetooth.
4. Turn on the device. A ✻ appears in the menu bar, and it turns orange when
   the device is connected.

The Mac needs Claude Code installed and signed in. Usage comes from Claude
Code's own sign-in in the Keychain. If macOS asks whether `security` may read
"Claude Code-credentials", choose **Always Allow**.

The device talks to one Mac at a time. To move it to another Mac, quit Claude
Buddy on the first one (menu ✻ → Quit). The device then shows "Looking for
your Mac" until the other one connects.

## What it changes on the Mac

- On first launch it adds a hook to `~/.claude/settings.json` for 7 Claude
  Code events. The hook runs `~/.claude-buddy/hook.sh`, which appends the event
  to `~/.claude-buddy/events.log`. The app reads the log and deletes it. The
  hook prints nothing and does nothing while the app isn't running.
  The original settings are saved once as `settings.json.before-claude-buddy`.
- Claude Code sessions that were already open only pick up the hook after a
  restart.
- To remove the hooks, untick **Watch Claude Code (hooks)** in the menu.
- **Open at Login** (macOS 13+) starts it automatically.
- The log is in `~/.claude-buddy/buddy.log` (menu → Show Log).

## Build

`./build.sh` makes a universal app (Apple silicon + Intel, macOS 12+) with
`swiftc`, which comes with the Xcode command line tools. No other dependencies.
Everything is in `ClaudeBuddy.swift`. The messages it sends are described in
`../buddy/PROTOCOL.md`.
