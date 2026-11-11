# Remote machines

When Claude Code runs on another machine (a Linux dev box you SSH into, often
through VS Code Remote-SSH), the Claude Buddy Mac app can follow it there too.

## Set it up

In the ✻ menu, choose **Add Remote Machine** and pick the host. The list comes
from your `~/.ssh/config`. You can also choose **Other…** and type what you'd
type after `ssh`. That's all.

On every connect the app copies `buddy-agent.py` to `~/.claude-buddy/agent.py`
on the remote and runs it with `python3`. Nothing needs installing there.

## What the remote needs

- **SSH login with a key.** A key with a passphrase is fine:
  - **When it asks:** right after you add the machine, the app asks for the
    passphrase in a Mac dialog. Later, use **Unlock SSH Key…** in the
    machine's menu.
  - **What happens to it:** the key is unlocked in your Mac's SSH agent, and
    the passphrase is saved in your login Keychain. It's the same as running
    `ssh-add --apple-use-keychain` in Terminal, and it's how the app
    reconnects after sleep or a restart without asking again.
  - **Password logins** (no key) aren't supported, since the app can't type a
    password at every reconnect.
- **python3**, version 3.6 or later. Most Linux systems have it.
- **Claude Code signed in there**, for the usage page. The menu shows which
  account it found under the machine (claude.ai Enterprise/Team/Pro, API key,
  Bedrock or Vertex). API key, Bedrock and Vertex setups have no plan limits
  to show; the activity and Today pages still work.

## What it does on the remote

- **Hooks:** adds the same hook as on the Mac to `~/.claude/settings.json`,
  backing up the original as `settings.json.before-claude-buddy`. VS Code's
  Claude Code extension runs Claude Code on the remote, so its sessions are
  covered too.
- **Activity, usage and Today:** reads the hook events and the transcripts,
  and fetches usage with the remote's own sign-in. That's
  `~/.claude/.credentials.json`, read only and never refreshed or sent
  anywhere else.
- **What it sends back over SSH:** only what the device shows. That's
  percentages, counts, project names and one-line tool summaries ("Editing
  routes.py"). No file contents and no prompts.
- **When the connection ends:** the agent exits and the hook goes quiet.
- **Removing the machine:** **Remove** in its submenu takes the hooks back out.

## What you see

Sessions from every machine are pooled. The buddy shows whichever needs you
most (waiting, then cooking, then done), with the machine's name in front of
the project ("devbox: api-server"). Usage comes from the machine where Claude
was used most recently. The Today page adds up all machines.

## Protocol additions

The agent prints the device's own lines (`../buddy/PROTOCOL.md`), plus two
that only the Mac app reads:

| Line | Meaning |
| --- | --- |
| `R\|last\|hooks\|account\|host` | Seconds since Claude was last active there, hook state (`on`, `partly`, `blocked: why`), the sign-in found, its host name |
| `E\|text` | A note for the menu (hooks added, python missing, ...) |
