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

## Plans and accounts

| Account | Buddy + Today pages | Usage page |
| --- | --- | --- |
| Pro, Max, Team | yes | 5-hour session + weekly limit |
| Plans with only a weekly limit | yes | weekly limit, "No 5-hour limit on this plan" |
| Enterprise with a spend cap | yes | monthly spend vs the cap, reset date |
| API key, Bedrock, Vertex | yes | "No usage limits" (there are none to show) |

Usage comes from Claude Code's own sign-in (read only, never refreshed) and
`api.anthropic.com/api/oauth/usage`, the endpoint `/usage` uses. Test answers for
each account shape are in `fixtures/` (`fixtures/test.sh`).

### Company-managed Macs

- If your organisation lets Claude Code run only its own hooks (or turns hooks
  off), Claude Buddy follows Claude through its transcripts instead. Cooking and
  done still work, and so does the Today page, but there are no "Your turn!"
  alerts. The menu says "Limited view" when this happens.
- Claude Code sessions opened before Claude Buddy are followed the same way
  until they're restarted.
- Using a custom Claude folder (`CLAUDE_CONFIG_DIR`)? It's picked up from your
  shell. To add folders by hand, list them in `~/.claude-buddy/config.json` as
  `{"claudeConfigDirs": ["~/work-claude"]}`. Hooks and transcripts cover every
  folder. Usage uses the sign-in of the folder used most recently.
- If IT blocks apps from outside the App Store, Claude Buddy needs an exception.
  It's ad-hoc signed, not notarized.

## What it changes on the Mac

- On first launch it adds a hook to `settings.json` in each Claude folder
  (`~/.claude` by default) for 7 Claude Code events. The hook runs `~/.claude-buddy/hook.sh`, which appends the event
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
