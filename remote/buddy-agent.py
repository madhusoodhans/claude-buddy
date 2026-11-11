#!/usr/bin/env python3
"""Claude Buddy remote agent: lets the Claude Buddy Mac app follow Claude Code on
another machine (a Linux dev box, usually) over SSH.

The Mac app copies this file to ~/.claude-buddy/agent.py on the remote and runs it
through `ssh -T <host>` on every connect, so there's nothing to install by hand.
It does on the remote what the Mac app does locally, and prints the same text lines
the device understands (../buddy/PROTOCOL.md) to stdout, plus:

    R|last|hooks|account|host   seconds since Claude was last active here, hook state
                                (on / blocked: why / off), the kind of sign-in, host name
    E|text                      something the Mac's menu should show

  * activity: Claude Code hooks (added to ~/.claude/settings.json, original kept as
    settings.json.before-claude-buddy) append events to ~/.claude-buddy/events.log;
    sessions without hook events are followed through their transcripts
  * usage: GET api.anthropic.com/api/oauth/usage with Claude Code's own sign-in
    (~/.claude/.credentials.json; the Keychain on a Mac), read only, never refreshed
  * today: the transcripts in ~/.claude/projects

Python 3.6+, standard library only. Exits when the SSH connection goes away.
"""
import calendar
import datetime as dt
import glob
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
BUDDY = os.path.join(HOME, ".claude-buddy")
EVENTS = os.path.join(BUDDY, "events.log")
PIDFILE = os.path.join(BUDDY, "app.pid")
HOOK_SCRIPT = os.path.join(BUDDY, "hook.sh")
HOOK_COMMAND = 'sh "$HOME/.claude-buddy/hook.sh"'
HOOK_MARKER = ".claude-buddy/hook.sh"
HOOK_EVENTS = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop"]
TOOL_EVENTS = ["PreToolUse", "PostToolUse"]
MANAGED = ["/etc/claude-code/managed-settings.json", "/Library/Application Support/ClaudeCode/managed-settings.json"]
HOST = socket.gethostname().split(".")[0]

HOOK_TEXT = """#!/bin/sh
# Claude Buddy: hands Claude Code hook events to the Claude Buddy agent.
# Prints nothing and always succeeds, so it never gets in Claude's way.
d="$HOME/.claude-buddy"
pid=; read pid < "$d/app.pid" 2>/dev/null
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || { cat >/dev/null; exit 0; }
{ tr -d '\\n\\r'; echo; } >> "$d/events.log" 2>/dev/null
exit 0
"""

IDLE, WORKING, WAITING, DONE = 0, 1, 2, 3
RANK = {WAITING: 3, WORKING: 2, DONE: 1, IDLE: 0}


# ---------------------------------------------------------------- helpers

def emit(line):
    try:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()
    except (BrokenPipeError, OSError):
        shutdown()


def ascii_text(s, n=60):
    swaps = {"’": "'", "‘": "'", "“": '"', "”": '"', "—": "-", "–": "-",
             "…": "...", "|": "/"}
    out = []
    for ch in s or "":
        ch = swaps.get(ch, ch)
        if ch in "\n\t\r":
            ch = " "
        if all(32 <= ord(c) < 127 for c in ch):
            out.append(ch)
    return "".join(out)[:n].strip()


def duration(t):
    s = int(max(0, t))
    if s < 60:
        return "%ds" % s
    if s < 3600:
        return "%dm %ds" % (s // 60, s % 60)
    if s < 86400:
        return "%dh %dm" % (s // 3600, s // 60 % 60)
    return "%dd %dh" % (s // 86400, s // 3600 % 24)


def compact(t):
    s = int(max(0, t))
    if s < 3600:
        return "%dm" % max(1, s // 60)
    if s < 86400:
        return "%dh %dm" % (s // 3600, s // 60 % 60)
    return "%dd %dh" % (s // 86400, s // 3600 % 24)


def parse_iso(s):
    """ISO 8601 with Z or +hh:mm and any fraction -> unix seconds (fromisoformat is 3.7+/3.11+)."""
    if not isinstance(s, str) or len(s) < 19:
        return None
    try:
        base = calendar.timegm(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return None
    rest = s[19:]
    frac = 0.0
    if rest.startswith("."):
        digits = ""
        for c in rest[1:]:
            if not c.isdigit():
                break
            digits += c
        frac = float("0." + digits) if digits else 0.0
        rest = rest[1 + len(digits):]
    offset = 0
    if rest and rest[0] in "+-" and len(rest) >= 6:
        offset = (int(rest[1:3]) * 3600 + int(rest[4:6]) * 60) * (1 if rest[0] == "+" else -1)
    return base + frac - offset


def basename(p):
    return os.path.basename(p.rstrip("/")) if isinstance(p, str) and p else ""


def load_json(path):
    try:
        with open(path) as f:
            data = f.read()
        return json.loads(data) if data.strip() else {}
    except FileNotFoundError:
        return {}


def claude_dirs():
    dirs = [os.path.join(HOME, ".claude")]
    extra = [os.environ.get("CLAUDE_CONFIG_DIR", "")]
    try:  # set in a shell profile, which an SSH command doesn't always read
        out = subprocess.run(["bash", "-lc", 'printf "\\n%s" "$CLAUDE_CONFIG_DIR"'], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, timeout=4).stdout
        extra.append(out.decode(errors="replace").split("\n")[-1].strip())
    except Exception:
        pass
    try:
        extra += load_json(os.path.join(BUDDY, "config.json")).get("claudeConfigDirs", [])
    except Exception:
        pass
    for p in extra:
        if p:
            p = os.path.expanduser(p).rstrip("/")
            if p not in dirs:
                dirs.append(p)
    return dirs


DIRS = claude_dirs()


# ---------------------------------------------------------------- hooks

def hooks_blocked():
    for path in MANAGED:
        try:
            m = load_json(path)
        except Exception:
            continue
        if m.get("allowManagedHooksOnly") is True:
            return "organisation allows only its own hooks"
        if m.get("disableAllHooks") is True:
            return "organisation turned hooks off"
    for d in DIRS:
        try:
            if load_json(os.path.join(d, "settings.json")).get("disableAllHooks") is True:
                return "hooks turned off in settings"
        except Exception:
            pass
    return None


def ours(entry):
    return any(HOOK_MARKER in (h.get("command") or "") for h in (entry or {}).get("hooks", []) if isinstance(h, dict))


def install_hooks():
    os.makedirs(BUDDY, exist_ok=True)
    with open(HOOK_SCRIPT, "w") as f:
        f.write(HOOK_TEXT)
    os.chmod(HOOK_SCRIPT, 0o755)
    for d in DIRS:
        path = os.path.join(d, "settings.json")
        try:
            root = load_json(path)
        except ValueError:
            emit("E|%s isn't valid JSON; hooks not added there" % ascii_text(path, 80))
            continue
        hooks = root.get("hooks") or {}
        if all(any(ours(e) for e in hooks.get(ev, [])) for ev in HOOK_EVENTS):
            continue
        for ev in HOOK_EVENTS:
            entries = [e for e in hooks.get(ev, []) if not ours(e)]
            entry = {"hooks": [{"type": "command", "command": HOOK_COMMAND, "timeout": 5}]}
            if ev in TOOL_EVENTS:
                entry["matcher"] = "*"
            entries.append(entry)
            hooks[ev] = entries
        root["hooks"] = hooks
        os.makedirs(d, exist_ok=True)
        backup = os.path.join(d, "settings.json.before-claude-buddy")
        if os.path.exists(path) and not os.path.exists(backup):
            shutil.copy2(path, backup)
        tmp = path + ".claude-buddy-tmp"
        with open(tmp, "w") as f:
            json.dump(root, f, indent=2)
        os.replace(tmp, path)
        emit("E|added Claude Code hooks in %s" % ascii_text(path.replace(HOME, "~"), 80))


def uninstall_hooks():
    for d in DIRS:
        path = os.path.join(d, "settings.json")
        root = load_json(path)
        hooks = root.get("hooks")
        if not hooks:
            continue
        for ev in list(hooks):
            kept = [e for e in hooks[ev] if not ours(e)]
            if kept:
                hooks[ev] = kept
            else:
                del hooks[ev]
        if hooks:
            root["hooks"] = hooks
        else:
            root.pop("hooks", None)
        with open(path, "w") as f:
            json.dump(root, f, indent=2)
        print("removed Claude Buddy hooks from " + path)


# ---------------------------------------------------------------- activity

def describe(tool, inp):
    inp = inp if isinstance(inp, dict) else {}
    f = basename(inp.get("file_path") or inp.get("notebook_path"))
    if tool == "Bash":
        cmd = ascii_text((inp.get("command") or "").split("\n")[0], 40)
        what = ascii_text(inp.get("description") or "", 40) or cmd
        return "Running: " + what, "Bash: " + cmd
    if tool in ("Edit", "MultiEdit", "NotebookEdit"):
        return "Editing " + f, "Edit " + f
    if tool == "Write":
        return "Writing " + f, "Write " + f
    if tool == "Read":
        return "Reading " + f, "Read " + f
    if tool in ("Grep", "Glob"):
        p = ascii_text(inp.get("pattern") or "", 30)
        return "Searching for " + p, "Search " + p
    if tool == "WebFetch":
        host = (inp.get("url") or "").split("/")[2] if (inp.get("url") or "").count("/") >= 2 else "the web"
        return "Reading " + host, "Fetch " + host
    if tool == "WebSearch":
        return "Searching the web", "Web search"
    if tool in ("Task", "Agent"):
        return "Briefing a helper agent", "Agent: " + ascii_text(inp.get("description") or "", 30)
    if tool in ("TodoWrite", "TaskCreate", "TaskUpdate"):
        return "Planning next steps", "Updated the plan"
    short = tool.split("__")[-1] if tool.startswith("mcp__") else tool
    return "Using " + short, short


class Session(object):
    def __init__(self):
        self.mood = IDLE
        self.since = time.time()
        self.turn_start = None
        self.last = time.time()
        self.project = ""
        self.detail = ""
        self.from_hooks = True

    def set(self, mood, detail):
        if mood != self.mood:
            self.since = time.time()
        self.mood = mood
        self.detail = ascii_text(detail, 60)


class Tracker(object):
    """Hook events in, one status line out (the session that most needs attention)."""

    def __init__(self):
        self.sessions = {}
        self.last_activity = 0.0

    def feed(self, text):
        emit("A|%s|%s" % (time.strftime("%H:%M"), ascii_text(text, 46)))

    def handle(self, e):
        sid, ev = e.get("session_id"), e.get("hook_event_name")
        if not sid or not ev:
            return
        if ev == "SessionEnd":
            self.sessions.pop(sid, None)
            return
        s = self.sessions.setdefault(sid, Session())
        s.last = self.last_activity = time.time()
        if e.get("cwd"):
            s.project = ascii_text(basename(e["cwd"]), 28)
        tool, inp = e.get("tool_name") or "", e.get("tool_input") or {}
        if ev == "SessionStart":
            if s.mood != WORKING:
                s.set(IDLE, "")
        elif ev == "UserPromptSubmit":
            s.turn_start = time.time()
            s.set(WORKING, "Thinking")
            self.feed("You sent a prompt")
        elif ev == "PreToolUse":
            if tool == "AskUserQuestion":
                s.set(WAITING, "Claude has a question for you")
                self.feed("Asked you a question")
            elif tool == "ExitPlanMode":
                s.set(WAITING, "Plan ready for your review")
                self.feed("Plan ready")
            else:
                detail, short = describe(tool, inp)
                s.set(WORKING, detail)
                self.feed(short)
        elif ev == "PostToolUse":
            if s.mood != WORKING:
                s.set(WORKING, "Thinking")
        elif ev == "Notification":
            kind, msg = e.get("notification_type"), e.get("message") or ""
            if kind == "permission_prompt" or (kind is None and "permission" in msg.lower()):
                detail = "Needs your permission"
                if "permission to use " in msg:
                    detail = "Needs permission: " + msg.split("permission to use ", 1)[1]
                s.set(WAITING, detail)
                self.feed(detail)
            elif kind == "elicitation_dialog":
                s.set(WAITING, "Claude has a question for you")
        elif ev == "Stop":
            took = ("Finished in " + duration(time.time() - s.turn_start)) if s.turn_start else "Finished"
            s.set(DONE, took)
            s.turn_start = None
            self.feed("Done")

    def interrupted(self, sid):
        s = self.sessions.get(sid)
        if s and s.mood in (WORKING, WAITING):
            s.set(IDLE, "Interrupted")
            s.turn_start = None
            self.feed("Interrupted")

    def status(self, live):
        now = time.time()
        for sid in list(self.sessions):
            s = self.sessions[sid]
            quiet = now - s.last
            if quiet > 6 * 3600:
                del self.sessions[sid]
                continue
            if s.mood == DONE and now - s.since > 90:
                s.set(IDLE, "")
            if s.mood == WORKING and quiet > 15 * 60:
                s.set(IDLE, "")
            if s.mood == WAITING and quiet > 30 * 60:
                s.set(IDLE, "")
        everyone = list(self.sessions.values())
        hookless = 0
        for sid, l in live.items():  # transcript-only sessions: no "waiting" without hooks
            if sid in self.sessions:
                continue
            s = Session()
            s.project, s.last, s.from_hooks = l["project"], l["last"], False
            if l["working"] and now - l["last"] < 600:
                s.mood, s.detail, s.turn_start = WORKING, l["detail"], l["turn_start"]
                s.since = l["turn_start"] or l["last"]
                hookless += 1
            elif l["ended"] and now - l["ended"] < 90:
                s.mood, s.since = DONE, l["ended"]
                s.detail = ("Finished in " + duration(l["ended"] - l["turn_start"])) if l["turn_start"] else "Finished"
            else:
                s.since = l["ended"] or l["last"]
            everyone.append(s)
            self.last_activity = max(self.last_activity, l["last"])
        if not everyone:
            return "S|0|0|0||", hookless
        top = max(everyone, key=lambda s: (RANK[s.mood], s.last))
        start = (top.turn_start or top.since) if top.mood == WORKING else top.since
        line = "S|%d|%d|%d|%s|%s" % (top.mood, int(now - start), len(everyone), top.project, top.detail)
        return line, hookless

    def drain(self):
        try:
            if os.path.getsize(EVENTS) == 0:
                return
        except OSError:
            return
        taken = os.path.join(BUDDY, "events.reading")
        try:
            os.replace(EVENTS, taken)
        except OSError:
            return
        time.sleep(0.03)  # a hook that opened the file just before the rename finishes its write
        try:
            with open(taken, "rb") as f:
                data = f.read()
            os.remove(taken)
        except OSError:
            return
        for raw in data.split(b"\n"):
            try:
                self.handle(json.loads(raw.decode("utf-8", "replace")))
            except ValueError:
                pass


# ---------------------------------------------------------------- today's stats + live sessions

class Today(object):
    def __init__(self, on_interrupt):
        self.on_interrupt = on_interrupt
        self.day = self.midnight()
        self.reset()
        self.live = {}
        self.first = True
        self.last_write = 0.0

    @staticmethod
    def midnight():
        t = time.localtime()
        return time.mktime((t.tm_year, t.tm_mon, t.tm_mday, 0, 0, 0, 0, 0, -1))

    def reset(self):
        self.offsets, self.prompts, self.tools, self.files = {}, set(), set(), set()
        self.out_tokens, self.lines, self.hours, self.projects = {}, 0, [0] * 24, {}

    def scan(self):
        m = self.midnight()
        if m != self.day:
            self.day = m
            self.reset()
        for d in DIRS:
            for path in glob.glob(os.path.join(d, "projects", "**", "*.jsonl"), recursive=True):
                try:
                    st = os.stat(path)
                except OSError:
                    continue
                if st.st_mtime < self.day:
                    continue
                self.last_write = max(self.last_write, st.st_mtime)
                start = self.offsets.get(path, 0)
                if st.st_size <= start:
                    continue
                with open(path, "rb") as f:
                    f.seek(start)
                    data = f.read()
                end = data.rfind(b"\n")
                if end < 0:
                    continue
                session = None if "/subagents/" in path else os.path.splitext(os.path.basename(path))[0]
                for raw in data[:end].split(b"\n"):
                    try:
                        self.process(json.loads(raw.decode("utf-8", "replace")), session)
                    except ValueError:
                        pass
                self.offsets[path] = start + end + 1
        now = time.time()
        self.live = {k: v for k, v in self.live.items() if now - v["last"] < 1800}
        self.first = False

    def touch(self, session, ts, project, **change):
        if not session or time.time() - ts > 1800:
            return
        l = self.live.setdefault(session, {"project": "", "last": 0.0, "working": False, "detail": "",
                                           "turn_start": None, "ended": None})
        if ts < l["last"]:
            return
        l["last"] = ts
        if project:
            l["project"] = ascii_text(project, 28)
        l.update(change)

    @staticmethod
    def count_lines(s):
        return s.count("\n") + 1 if isinstance(s, str) and s else 0

    def process(self, o, session):
        msg = o.get("message")
        ts = parse_iso(o.get("timestamp"))
        if not isinstance(msg, dict) or ts is None or ts < self.day:
            return
        hour = time.localtime(ts).tm_hour
        project = basename(o.get("cwd"))
        content = msg.get("content")
        items = content if isinstance(content, list) else []
        texts = [content] if isinstance(content, str) else \
            [i.get("text", "") for i in items if isinstance(i, dict) and i.get("type") == "text"]

        if o.get("type") == "user":
            if any(t.startswith("[Request interrupted") for t in texts):
                if session and not self.first and time.time() - ts < 120:
                    self.on_interrupt(session)
                self.touch(session, ts, project, working=False, ended=None, turn_start=None)
                return
            if any(isinstance(i, dict) and i.get("type") == "tool_result" for i in items):
                self.touch(session, ts, project, working=True)
            if o.get("isMeta") or o.get("isSidechain") or not texts or texts[0].startswith("<"):
                return
            self.touch(session, ts, project, working=True, turn_start=ts, detail="Thinking", ended=None)
            key = o.get("promptId") or o.get("uuid") or repr(ts)
            if key not in self.prompts:
                self.prompts.add(key)
                self.hours[hour] += 1
                if project:
                    self.projects[project] = self.projects.get(project, 0) + 1
        elif o.get("type") == "assistant":
            mid = msg.get("id") or repr(ts)
            if mid not in self.out_tokens:
                self.hours[hour] += 1
            self.out_tokens[mid] = max(self.out_tokens.get(mid, 0), int((msg.get("usage") or {}).get("output_tokens") or 0))
            uses = [i for i in items if isinstance(i, dict) and i.get("type") == "tool_use"]
            if uses:
                self.touch(session, ts, project, working=True, detail=describe(uses[-1].get("name") or "", uses[-1].get("input"))[0])
            if msg.get("stop_reason") == "end_turn":
                self.touch(session, ts, project, working=False, ended=ts)
            for u in uses:
                tid = u.get("id")
                if not tid or tid in self.tools:
                    continue
                self.tools.add(tid)
                if project:
                    self.projects[project] = self.projects.get(project, 0) + 1
                inp = u.get("input") if isinstance(u.get("input"), dict) else {}
                name = u.get("name")
                if name == "Edit":
                    self.lines += self.count_lines(inp.get("new_string"))
                elif name == "Write":
                    self.lines += self.count_lines(inp.get("content"))
                elif name == "NotebookEdit":
                    self.lines += self.count_lines(inp.get("new_source"))
                elif name == "MultiEdit":
                    for e in inp.get("edits") or []:
                        self.lines += self.count_lines((e or {}).get("new_string"))
                else:
                    continue
                path = inp.get("file_path") or inp.get("notebook_path")
                if path:
                    self.files.add(path)

    def message(self):
        top = max(self.projects.items(), key=lambda kv: kv[1])[0] if self.projects else ""
        return "D|%d|%d|%d|%d|%d|%s|%s" % (len(self.prompts), len(self.tools), len(self.files), self.lines,
                                         sum(self.out_tokens.values()), ",".join(map(str, self.hours)),
                                         ascii_text(top, 28))


# ---------------------------------------------------------------- usage

def first_of_next_month_utc(now):
    t = time.gmtime(now)
    y, m = (t.tm_year + 1, 1) if t.tm_mon == 12 else (t.tm_year, t.tm_mon + 1)
    return calendar.timegm((y, m, 1, 0, 0, 0))


def months_back(ts, n):
    t = time.gmtime(ts)
    y, m = t.tm_year, t.tm_mon - n
    while m < 1:
        y, m = y - 1, m + 12
    return calendar.timegm((y, m, min(t.tm_mday, 28), t.tm_hour, t.tm_min, t.tm_sec))


def spend_meter(group, pct, reset, now):
    r = reset or first_of_next_month_utc(now)
    if group == "daily":
        return {"label": "Daily spend", "pct": pct, "start": r - 86400, "reset": r, "dated": False}
    if group == "weekly":
        return {"label": "Weekly spend", "pct": pct, "start": r - 7 * 86400, "reset": r, "dated": True}
    return {"label": "Monthly spend", "pct": pct, "start": months_back(r, 1), "reset": r, "dated": True}


def usage_meters(v, now):
    """Same account shapes as the Mac app's UsageParse (after Clawdmeter)."""
    def window(key, label, length):
        w = v.get(key)
        if not isinstance(w, dict):
            return None
        pct = int(round(float(w.get("utilization") or 0)))
        reset = parse_iso(w.get("resets_at"))
        if not reset or reset <= now:
            return {"label": label, "pct": 0, "start": None, "reset": None, "dated": False}
        return {"label": label, "pct": pct, "start": reset - length, "reset": reset, "dated": False}

    session = window("five_hour", "Session  5h", 5 * 3600)
    week = window("seven_day", "Weekly", 7 * 86400)
    spend = None
    limit = next((l for l in v.get("limits") or [] if isinstance(l, dict) and l.get("kind") == "spend"), None)
    if limit is not None and limit.get("percent") is not None:
        spend = spend_meter(limit.get("group"), int(round(float(limit["percent"]))), parse_iso(limit.get("resets_at")), now)
    elif session is None and week is None:
        extra = v.get("extra_usage") if isinstance(v.get("extra_usage"), dict) and v["extra_usage"].get("is_enabled") is True else None
        top = v.get("spend") if isinstance(v.get("spend"), dict) and v["spend"].get("enabled") is not False else None
        capped = (extra is not None and extra.get("monthly_limit") is not None) or (top is not None and top.get("limit") is not None)
        pct = (top or {}).get("percent")
        if pct is None:
            pct = (extra or {}).get("utilization")
        if capped and pct is not None:
            pct = float(pct)
            if (extra or {}).get("spend_limit_reached") is True:
                pct = max(pct, 100.0)
            spend = spend_meter("monthly", int(min(9999, round(pct))), None, now)
    shown = [m for m in (session, week, spend) if m]
    if len(shown) > 2:
        shown = [spend, week]
    if not shown:
        return None
    note = ""
    if session is None and week is not None and "five_hour" in v and v["five_hour"] is None:
        note = "No 5-hour limit on this plan"
    elif spend is not None and week is None and session is None:
        note = "Spend limit set by your organisation"
    return shown, note


def meter_field(m, now):
    pace, text = -1, "Not started"
    if m["reset"]:
        if m["start"] and m["reset"] > m["start"]:
            pace = int(round((now - m["start"]) / (m["reset"] - m["start"]) * 1000))
        if m["dated"]:
            t = time.gmtime(m["reset"])
            text = "Resets %s %d" % (time.strftime("%b", t), t.tm_mday)
        else:
            text = "Resets in " + compact(m["reset"] - now)
    clean = lambda s: ascii_text(s, 24).replace(";", ",")
    return "%s;%d;%d;%s" % (clean(m["label"]), m["pct"], max(-1, min(1000, pace)), clean(text))


def usage_message(ok, age, plan, note, meters, now):
    return "|".join(["U", "1" if ok else "0", str(int(age)), ascii_text(plan, 12), ascii_text(note, 44)]
                    + [meter_field(m, now) for m in meters[:2]])


class Usage(object):
    def __init__(self):
        self.reading = None  # (meters, note, plan)
        self.fetched = 0.0
        self.note = ""
        self.next_allowed = 0.0
        self.account = "unknown"

    def token(self):
        found = []
        blobs = []
        for d in DIRS:
            try:
                with open(os.path.join(d, ".credentials.json")) as f:
                    blobs.append(f.read())
            except OSError:
                pass
        if sys.platform == "darwin":  # a Mac as the remote: the sign-in is in the Keychain
            try:
                out = subprocess.run(["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
                if out.returncode == 0:
                    blobs.insert(0, out.stdout.decode(errors="replace"))
            except Exception:
                pass
        for b in blobs:
            try:
                v = json.loads(b)
            except ValueError:
                continue
            o = v.get("claudeAiOauth", v) if isinstance(v, dict) else {}
            if o.get("accessToken"):
                exp = o.get("expiresAt")
                found.append((o["accessToken"], exp / 1000.0 if exp else None, (o.get("subscriptionType") or "").capitalize()))
        fresh = [t for t in found if not t[1] or t[1] > time.time() + 60]
        return (fresh or found or [None])[0]

    def other_sign_in(self):
        """How Claude Code is set up when there's no claude.ai sign-in (API key, Bedrock, Vertex)."""
        env = dict(os.environ)
        for d in DIRS:
            try:
                env.update(load_json(os.path.join(d, "settings.json")).get("env") or {})
            except Exception:
                pass
        if str(env.get("CLAUDE_CODE_USE_BEDROCK", "")).lower() in ("1", "true"):
            return "Amazon Bedrock"
        if str(env.get("CLAUDE_CODE_USE_VERTEX", "")).lower() in ("1", "true"):
            return "Google Vertex"
        if env.get("ANTHROPIC_API_KEY") or env.get("ANTHROPIC_AUTH_TOKEN"):
            return "API key"
        return None

    def poll(self, force=False):
        now = time.time()
        if now < self.next_allowed or (not force and now - self.fetched < 170):
            return
        self.next_allowed = now + 30
        tok = self.token()
        if not tok:
            other = self.other_sign_in()
            self.account = other or "not signed in"
            self.note = ("%s: no plan limits" % other) if other else "Sign in to Claude Code here"
            self.reading = None
            self.next_allowed = now + 300
            return
        access, exp, plan = tok
        self.account = (plan or "Claude") + " (claude.ai)"
        if exp and exp < now:
            self.note = "Sign-in expired: open Claude Code"
            self.next_allowed = now + 60
            return
        req = urllib.request.Request("https://api.anthropic.com/api/oauth/usage", headers={
            "Authorization": "Bearer " + access, "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-buddy-agent/1.2", "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                v = json.loads(r.read().decode("utf-8", "replace"))
        except urllib.error.HTTPError as e:
            if e.code == 429:
                try:
                    after = float(e.headers.get("retry-after") or 600)
                except ValueError:
                    after = 600
                self.next_allowed = now + max(60, after)
                self.note = "Rate limited, retrying soon"
            elif e.code in (401, 403):
                self.note = "Sign-in expired: open Claude Code"
            else:
                self.note = "Usage service answered %d" % e.code
            return
        except Exception as e:
            self.note = "Offline: " + ascii_text(str(e), 30)
            return
        parsed = usage_meters(v, now) if isinstance(v, dict) else None
        if not parsed:
            self.reading, self.note = None, "No usage limits on this account"
            return
        self.reading = (parsed[0], parsed[1], plan)
        self.fetched = now
        self.note = ""

    def message(self):
        now = time.time()
        if self.reading:
            meters, note, plan = self.reading
            return usage_message(True, now - self.fetched, plan, self.note or note, meters, now)
        return usage_message(False, 0, "", self.note or "Asking Claude for usage", [], now)


# ---------------------------------------------------------------- main loop

def shutdown(*_):
    try:
        with open(PIDFILE) as f:
            if f.read().strip() == str(os.getpid()):
                os.remove(PIDFILE)  # the hook goes quiet again
    except OSError:
        pass
    os._exit(0)


def take_over():
    """One agent per machine: a new SSH connection replaces an older agent still running."""
    os.makedirs(BUDDY, exist_ok=True)
    try:
        with open(PIDFILE) as f:
            old = int(f.read().strip() or 0)
        if old and old != os.getpid():
            os.kill(old, signal.SIGTERM)
    except (OSError, ValueError):
        pass
    with open(PIDFILE, "w") as f:
        f.write("%d\n" % os.getpid())


def main():
    if "--uninstall-hooks" in sys.argv:
        uninstall_hooks()
        return
    if "--parse-usage" in sys.argv:  # for tests: python3 buddy-agent.py --parse-usage answer.json [ISO time]
        i = sys.argv.index("--parse-usage")
        v = load_json(sys.argv[i + 1])
        now = parse_iso(sys.argv[i + 2]) if len(sys.argv) > i + 2 else time.time()
        r = usage_meters(v, now)
        print(usage_message(True, 0, "Test", r[1], r[0], now) if r else
              usage_message(False, 0, "", "No usage limits on this account", [], now))
        return
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, shutdown)
    take_over()
    blocked = hooks_blocked()
    if blocked:
        emit("E|hooks blocked on %s (%s): following transcripts" % (HOST, blocked))
    try:
        install_hooks()
    except Exception as e:
        emit("E|couldn't add hooks: " + ascii_text(str(e), 60))

    tracker = Tracker()
    today = Today(tracker.interrupted)
    usage = Usage()
    today.scan()
    usage.poll(force=True)
    last_status, last_today, last_beat, last_scan = None, None, 0.0, 0.0
    while True:
        now = time.time()
        tracker.drain()
        if now - last_scan >= 3:
            last_scan = now
            today.scan()
            d = today.message()
            if d != last_today:
                last_today = d
                emit(d)
        line, hookless = tracker.status(today.live)
        key = line.split("|")
        key = "|".join(key[:2] + key[3:])
        if key != last_status:
            last_status = key
            emit(line)
        if now - last_beat >= 10:
            last_beat = now
            usage.poll()
            last = max(tracker.last_activity, today.last_write)
            hooks = "blocked: " + blocked if blocked else ("partly" if hookless else "on")
            emit("R|%d|%s|%s|%s" % (now - last if last else -1, ascii_text(hooks, 50), ascii_text(usage.account, 30), ascii_text(HOST, 24)))
            emit(usage.message())
            emit(line)
            emit(today.message())
        time.sleep(0.5)


if __name__ == "__main__":
    main()
