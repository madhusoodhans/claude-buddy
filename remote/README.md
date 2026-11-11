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

- **SSH login with a key, without a password prompt.** The app uses
  `BatchMode`, so it can't answer prompts. If your key has a passphrase, add
  it to the agent once (`ssh-add --apple-use-keychain ~/.ssh/id_ed25519`). If
  `ssh <host>` works in Terminal without typing anything, the app works too.
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
