// Claude Buddy for macOS: a menu bar app that gives the Cheeko Gotchi
// "Claude Buddy" firmware (../buddy) a live view of Claude Code on this Mac.
//
//   * what Claude is doing: Claude Code hooks (installed into ~/.claude/settings.json)
//     append their events to ~/.claude-buddy/events.log, which this app reads
//   * plan usage: GET api.anthropic.com/api/oauth/usage with Claude Code's own
//     sign-in from the Keychain (read only, never refreshed)
//   * today's stats: the transcripts in ~/.claude/projects
//   * all of it goes to the device over Bluetooth LE, as text lines (../buddy/PROTOCOL.md)
//
// Build with ./build.sh. No dependencies beyond macOS 12+.

import AppKit
import CoreBluetooth
import CryptoKit
import ServiceManagement

// MARK: - Paths and helpers

let home = FileManager.default.homeDirectoryForCurrentUser
let buddyDir = home.appendingPathComponent(".claude-buddy")
let eventsURL = buddyDir.appendingPathComponent("events.log")
let logURL = buddyDir.appendingPathComponent("buddy.log")
let defaultClaudeDir = home.appendingPathComponent(".claude")

/// Every Claude Code config folder on this Mac: ~/.claude, plus CLAUDE_CONFIG_DIR
/// (from this process, or from the login shell when started from Finder), plus
/// any listed in ~/.claude-buddy/config.json as {"claudeConfigDirs": [...]}.
let claudeDirs: [URL] = {
    var paths: [String] = []
    if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] { paths.append(env) }
    if let shell = loginShellValue("CLAUDE_CONFIG_DIR") { paths.append(shell) }
    if let data = try? Data(contentsOf: buddyDir.appendingPathComponent("config.json")),
       let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        paths += o["claudeConfigDirs"] as? [String] ?? []
    }
    var dirs = [defaultClaudeDir]
    for p in paths where !p.isEmpty {
        let expanded = (p as NSString).expandingTildeInPath
        let trimmed = expanded.count > 1 && expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
        let url = URL(fileURLWithPath: trimmed)
        if !dirs.contains(where: { $0.path == url.path }) { dirs.append(url) }
    }
    return dirs
}()

/// A variable as the user's login shell sets it (apps opened from Finder don't inherit shell setup).
func loginShellValue(_ name: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
    p.arguments = ["-lic", "printf '\\n__claude_buddy__%s\\n' \"$\(name)\""]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let deadline = Date().addingTimeInterval(4)
    while p.isRunning && Date() < deadline { usleep(50_000) }
    if p.isRunning { p.terminate(); return nil }
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let line = text.components(separatedBy: "\n").last { $0.hasPrefix("__claude_buddy__") }
    let value = line.map { String($0.dropFirst("__claude_buddy__".count)) } ?? ""
    return value.isEmpty ? nil : value
}

/// Claude Code's Keychain item for a config folder: "Claude Code-credentials" for ~/.claude,
/// otherwise suffixed with the first 8 hex digits of the SHA-256 of the folder path.
func keychainService(for dir: URL) -> String {
    if dir.path == defaultClaudeDir.path { return "Claude Code-credentials" }
    let hash = SHA256.hash(data: Data(dir.path.precomposedStringWithCanonicalMapping.utf8))
    return "Claude Code-credentials-" + hash.prefix(4).map { String(format: "%02x", $0) }.joined()
}

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(to: logURL, atomically: false, encoding: .utf8)
    }
}

/// Printable ASCII only (the device's fonts), no field separators, at most `max` characters.
func ascii(_ s: String, max: Int = 60) -> String {
    var out = ""
    let swaps: [Character: String] = ["\u{2019}": "'", "\u{2018}": "'", "\u{201C}": "\"", "\u{201D}": "\"",
                                      "\u{2014}": "-", "\u{2013}": "-", "\u{2026}": "...", "|": "/"]
    for ch in s {
        if let r = swaps[ch] { out += r }
        else if ch == "\n" || ch == "\t" || ch == "\r" { out += " " }
        else if let a = ch.asciiValue, a >= 32, a < 127 { out.append(ch) }
        if out.count >= max { break }
    }
    return String(out.prefix(max)).trimmingCharacters(in: .whitespaces)
}

func duration(_ t: TimeInterval) -> String {
    let s = Int(max(0, t))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    if s < 86400 { return "\(s / 3600)h \(s / 60 % 60)m" }
    return "\(s / 86400)d \(s / 3600 % 24)h"
}

func baseName(_ path: String?) -> String {
    guard let p = path, !p.isEmpty else { return "" }
    return URL(fileURLWithPath: p).lastPathComponent
}

// MARK: - Claude Code hooks

enum Hooks {
    static let script = buddyDir.appendingPathComponent("hook.sh")
    static let command = "sh \"$HOME/.claude-buddy/hook.sh\""
    static let marker = ".claude-buddy/hook.sh"
    static let toolEvents = ["PreToolUse", "PostToolUse"]
    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                         "Notification", "Stop"]
    static let managedSettings = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")

    static let scriptText = """
    #!/bin/sh
    # Claude Buddy: hands Claude Code hook events to the Claude Buddy menu bar app.
    # Prints nothing and always succeeds, so it never gets in Claude's way.
    d="$HOME/.claude-buddy"
    pid=; read pid < "$d/app.pid" 2>/dev/null
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || { cat >/dev/null; exit 0; }
    { tr -d '\\n\\r'; echo; } >> "$d/events.log" 2>/dev/null
    exit 0

    """

    static func settingsURL(_ dir: URL) -> URL { dir.appendingPathComponent("settings.json") }

    static func loadJSON(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ClaudeBuddy", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.path) isn't a JSON object"])
        }
        return root
    }

    /// Why Claude Code won't run our hooks, if a setting says so (company policy or the user's own).
    static var blockedBySettings: String? {
        if let m = try? loadJSON(managedSettings) {
            if m["allowManagedHooksOnly"] as? Bool == true { return "Your organisation only allows its own hooks" }
            if m["disableAllHooks"] as? Bool == true { return "Your organisation turned hooks off" }
        }
        for dir in claudeDirs {
            if (try? loadJSON(settingsURL(dir)))?["disableAllHooks"] as? Bool == true { return "Hooks are turned off in Claude Code settings" }
        }
        return nil
    }

    static func ours(_ entry: Any) -> Bool {
        let hooks = (entry as? [String: Any])?["hooks"] as? [[String: Any]] ?? []
        return hooks.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    static func installed(in dir: URL) -> Bool {
        guard let root = try? loadJSON(settingsURL(dir)), let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { ev in (hooks[ev] as? [Any])?.contains(where: ours) == true }
    }

    static var installed: Bool {
        FileManager.default.fileExists(atPath: script.path) && claudeDirs.allSatisfy(installed(in:))
    }

    static func save(_ root: [String: Any], in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = settingsURL(dir)
        let backup = dir.appendingPathComponent("settings.json.before-claude-buddy")
        if FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// Adds our hook to each event in every config folder, keeping everything else in settings.json as it was.
    static func install() throws {
        try scriptText.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        for dir in claudeDirs where !installed(in: dir) {
            var root = try loadJSON(settingsURL(dir))
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for ev in events {
                var list = (hooks[ev] as? [Any] ?? []).filter { !ours($0) }
                var entry: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
                if toolEvents.contains(ev) { entry["matcher"] = "*" }
                list.append(entry)
                hooks[ev] = list
            }
            root["hooks"] = hooks
            try save(root, in: dir)
            log("installed Claude Code hooks in \(settingsURL(dir).path)")
        }
    }

    static func uninstall() throws {
        for dir in claudeDirs {
            var root = try loadJSON(settingsURL(dir))
            guard var hooks = root["hooks"] as? [String: Any] else { continue }
            for (ev, value) in hooks {
                let list = (value as? [Any] ?? []).filter { !ours($0) }
                if list.isEmpty { hooks[ev] = nil } else { hooks[ev] = list }
            }
            root["hooks"] = hooks.isEmpty ? nil : hooks
            try save(root, in: dir)
            log("removed Claude Code hooks from \(settingsURL(dir).path)")
        }
    }
}

// MARK: - What Claude is doing, from hook events

enum Mood: Int { case idle = 0, working, waiting, done }

final class Session {
    let id: String
    var mood = Mood.idle
    var since = Date()      // when this mood started
    var turnStart: Date?    // when the current prompt was sent
    var last = Date()       // last event
    var project = ""
    var detail = ""
    init(_ id: String) { self.id = id }
}

final class Tracker {
    var sessions: [String: Session] = [:]
    private(set) var lastActivity = Date.distantPast
    var feed: [String] = []  // "A|hh:mm|text" lines, newest last
    var onFeed: ((String) -> Void)?
    var onStop: (() -> Void)?
    private let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    private func set(_ s: Session, _ mood: Mood, _ detail: String) {
        if s.mood != mood { s.since = Date() }
        s.mood = mood
        s.detail = ascii(detail, max: 60)
    }

    private func addFeed(_ text: String) {
        let line = "A|\(clock.string(from: Date()))|\(ascii(text, max: 46))"
        feed.append(line)
        if feed.count > 4 { feed.removeFirst() }
        onFeed?(line)
    }

    static func describe(_ tool: String, _ input: [String: Any]) -> (detail: String, feed: String) {
        let file = baseName(input["file_path"] as? String ?? input["notebook_path"] as? String)
        switch tool {
        case "Bash":
            let cmd = ascii((input["command"] as? String ?? "").components(separatedBy: "\n").first ?? "", max: 40)
            let what = (input["description"] as? String).map { ascii($0, max: 40) } ?? cmd
            return ("Running: \(what)", "Bash: \(cmd)")
        case "Edit", "MultiEdit": return ("Editing \(file)", "Edit \(file)")
        case "Write": return ("Writing \(file)", "Write \(file)")
        case "NotebookEdit": return ("Editing \(file)", "Edit \(file)")
        case "Read": return ("Reading \(file)", "Read \(file)")
        case "Grep", "Glob":
            let pattern = ascii(input["pattern"] as? String ?? "", max: 30)
            return ("Searching for \(pattern)", "Search \(pattern)")
        case "WebFetch":
            let host = URL(string: input["url"] as? String ?? "")?.host ?? "the web"
            return ("Reading \(host)", "Fetch \(host)")
        case "WebSearch": return ("Searching the web", "Web search")
        case "Task", "Agent": return ("Briefing a helper agent", "Agent: \(ascii(input["description"] as? String ?? "", max: 30))")
        case "TodoWrite", "TaskCreate", "TaskUpdate": return ("Planning next steps", "Updated the plan")
        case "Skill": return ("Using skill \(input["skill"] as? String ?? "")", "Skill \(input["skill"] as? String ?? "")")
        default:
            let short = tool.hasPrefix("mcp__") ? String(tool.split(separator: "_").last ?? "") : tool
            return ("Using \(short)", short)
        }
    }

    func handle(_ e: [String: Any]) {
        guard let id = e["session_id"] as? String, let ev = e["hook_event_name"] as? String else { return }
        if ev == "SessionEnd" { sessions[id] = nil; return }
        let s = sessions[id] ?? Session(id)
        sessions[id] = s
        s.last = Date()
        lastActivity = s.last
        if let cwd = e["cwd"] as? String { s.project = ascii(baseName(cwd), max: 28) }
        let tool = e["tool_name"] as? String ?? ""
        let input = e["tool_input"] as? [String: Any] ?? [:]

        switch ev {
        case "SessionStart":
            if s.mood != .working { set(s, .idle, "") }
        case "UserPromptSubmit":
            s.turnStart = Date()
            set(s, .working, "Thinking")
            addFeed("You sent a prompt")
        case "PreToolUse":
            if tool == "AskUserQuestion" {
                set(s, .waiting, "Claude has a question for you")
                addFeed("Asked you a question")
            } else if tool == "ExitPlanMode" {
                set(s, .waiting, "Plan ready for your review")
                addFeed("Plan ready")
            } else {
                let d = Tracker.describe(tool, input)
                set(s, .working, d.detail)
                addFeed(d.feed)
            }
        case "PostToolUse":
            if s.mood != .working { set(s, .working, "Thinking") }
        case "Notification":
            let type = e["notification_type"] as? String
            let message = e["message"] as? String ?? ""
            if type == "permission_prompt" || (type == nil && message.lowercased().contains("permission")) {
                var detail = "Needs your permission"
                if let r = message.range(of: "permission to use ") { detail = "Needs permission: " + message[r.upperBound...] }
                set(s, .waiting, detail)
                addFeed(detail)
            } else if type == "elicitation_dialog" {
                set(s, .waiting, "Claude has a question for you")
            }
        case "Stop":
            let took = s.turnStart.map { "Finished in " + duration(Date().timeIntervalSince($0)) } ?? "Finished"
            set(s, .done, took)
            addFeed("Done")
            s.turnStart = nil
            onStop?()
        default:
            break
        }
    }

    /// The transcript says the user pressed Esc: no Stop hook comes for that.
    func interrupted(_ id: String) {
        guard let s = sessions[id], s.mood == .working || s.mood == .waiting else { return }
        set(s, .idle, "Interrupted")
        s.turnStart = nil
        addFeed("Interrupted")
    }

    /// The one line the device shows: the session that most needs attention.
    func status() -> String {
        let now = Date()
        for (id, s) in sessions {
            let quiet = now.timeIntervalSince(s.last)
            if quiet > 6 * 3600 { sessions[id] = nil; continue }
            if s.mood == .done && now.timeIntervalSince(s.since) > 90 { set(s, .idle, "") }
            if s.mood == .working && quiet > 15 * 60 { set(s, .idle, "") }  // missed the end of the turn
            if s.mood == .waiting && quiet > 30 * 60 { set(s, .idle, "") }
        }
        // Sessions we only know from their transcripts: no "waiting" (that needs hooks).
        var all = Array(sessions.values)
        hooklessActive = 0
        for (id, l) in live where sessions[id] == nil {
            let s = Session(id)
            s.project = l.project
            s.last = l.last
            lastActivity = max(lastActivity, l.last)
            if l.working && now.timeIntervalSince(l.last) < 10 * 60 {
                s.mood = .working
                s.detail = l.detail
                s.turnStart = l.turnStart
                s.since = l.turnStart ?? l.last
                hooklessActive += 1
            } else if let end = l.endedAt, now.timeIntervalSince(end) < 90 {
                s.mood = .done
                s.since = end
                s.detail = l.turnStart.map { "Finished in " + duration(end.timeIntervalSince($0)) } ?? "Finished"
            } else {
                s.since = l.endedAt ?? l.last
            }
            all.append(s)
        }
        if hooklessActive != lastHooklessActive {
            log("sessions working without hook events (followed through their transcripts): \(hooklessActive)")
            lastHooklessActive = hooklessActive
        }
        let rank: [Mood: Int] = [.waiting: 3, .working: 2, .done: 1, .idle: 0]
        guard let top = all.max(by: { (rank[$0.mood]!, $0.last) < (rank[$1.mood]!, $1.last) }) else {
            return "S|0|0|0||"
        }
        let start = top.mood == .working ? (top.turnStart ?? top.since) : top.since
        return "S|\(top.mood.rawValue)|\(Int(now.timeIntervalSince(start)))|\(all.count)|\(top.project)|\(top.detail)"
    }

    /// Transcript-only sessions, refreshed by the app from TodayScanner.
    var live: [String: LiveSession] = [:]
    /// How many sessions are working without sending hook events (for the menu's hint).
    private(set) var hooklessActive = 0
    private var lastHooklessActive = 0

    /// Hands over what the hook script appended since last time.
    func drainEvents() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: eventsURL.path))?[.size] as? Int, size > 0 else { return }
        let taken = buddyDir.appendingPathComponent("events.reading")
        try? fm.removeItem(at: taken)
        guard (try? fm.moveItem(at: eventsURL, to: taken)) != nil else { return }
        // A hook that opened the file just before the rename finishes its write within milliseconds.
        usleep(30_000)
        guard let data = try? Data(contentsOf: taken) else { return }
        try? fm.removeItem(at: taken)
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { handle(obj) }
        }
    }
}

// MARK: - Plan usage

/// One bar on the device's usage page.
struct Meter {
    var label: String
    var pct: Int
    var start: Date?   // when the window began, for the pace marker
    var reset: Date?   // nil = not started
    var dated = false  // show the reset as a date ("Resets Dec 1") instead of a countdown
}

/// What the usage endpoint's answer means for the device. Account shapes, after Clawdmeter:
///  * Pro / Max / Team: a 5-hour window and a weekly one
///  * weekly only (e.g. top Max tiers): "five_hour": null next to "seven_day"
///  * spend-capped Enterprise: a spend limit in "limits", or only in the top-level
///    "spend" / "extra_usage" objects, with every window null
enum UsageParse {
    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    static func number(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }

    static func firstOfNextMonthUTC(_ now: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        return cal.date(byAdding: .month, value: 1, to: start)!
    }

    static func spendMeter(group: String?, pct: Int, reset: Date?, now: Date) -> Meter {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let (label, unit): (String, Calendar.Component) = {
            switch group {
            case "daily": return ("Daily spend", .day)
            case "weekly": return ("Weekly spend", .weekOfYear)
            default: return ("Monthly spend", .month)
            }
        }()
        let r = reset ?? firstOfNextMonthUTC(now)
        return Meter(label: label, pct: pct, start: cal.date(byAdding: unit, value: -1, to: r), reset: r, dated: unit != .day)
    }

    /// The meters to show (at most two) and a line explaining anything unusual, or nil if there's nothing to show.
    static func meters(_ v: [String: Any], now: Date) -> (meters: [Meter], note: String)? {
        func window(_ key: String, label: String, length: TimeInterval) -> Meter? {
            guard let w = v[key] as? [String: Any] else { return nil }
            let pct = Int((number(w["utilization"]) ?? 0).rounded())
            guard let reset = date(w["resets_at"]), reset > now else {
                return Meter(label: label, pct: 0, start: nil, reset: nil)  // the window hasn't started
            }
            return Meter(label: label, pct: pct, start: reset.addingTimeInterval(-length), reset: reset)
        }
        let session = window("five_hour", label: "Session  5h", length: 5 * 3600)
        let week = window("seven_day", label: "Weekly", length: 7 * 86400)

        var spend: Meter?
        let limits = v["limits"] as? [[String: Any]] ?? []
        if let l = limits.first(where: { $0["kind"] as? String == "spend" }), let pct = number(l["percent"]) {
            spend = spendMeter(group: l["group"] as? String, pct: Int(pct.rounded()), reset: date(l["resets_at"]), now: now)
        } else if session == nil && week == nil {
            // Spend cap only in the top-level objects: it counts only with a cap to measure against.
            let extra = (v["extra_usage"] as? [String: Any]).flatMap { $0["is_enabled"] as? Bool == true ? $0 : nil }
            let top = (v["spend"] as? [String: Any]).flatMap { $0["enabled"] as? Bool == false ? nil : $0 }
            let capped = !(extra?["monthly_limit"] is NSNull || extra?["monthly_limit"] == nil)
                || !(top?["limit"] is NSNull || top?["limit"] == nil)
            if capped, var pct = number(top?["percent"]) ?? number(extra?["utilization"]) {
                if extra?["spend_limit_reached"] as? Bool == true { pct = max(pct, 100) }
                spend = spendMeter(group: "monthly", pct: Int(min(9999, pct.rounded())), reset: nil, now: now)
            }
        }

        var shown = [session, week, spend].compactMap { $0 }
        if shown.count > 2 { shown = [spend!, week!] }  // a cap on a subscription: the cap matters most
        if shown.isEmpty { return nil }
        var note = ""
        if session == nil && week != nil && v["five_hour"] is NSNull { note = "No 5-hour limit on this plan" }
        else if spend != nil && week == nil && session == nil { note = "Spend limit set by your organisation" }
        return (shown, note)
    }
}

final class UsagePoller {
    var message = "U|0|0||Asking Claude for usage"
    var summary = "Usage: waiting"
    private var fetchedAt: Date?
    private var reading: (meters: [Meter], note: String, plan: String)?
    private var note = ""
    private var nextAllowed = Date.distantPast
    private var inFlight = false
    var onChange: (() -> Void)?
    /// Config folders in the order to try their sign-in (the most recently used first).
    var preferredDirs: () -> [URL] = { claudeDirs }

    struct Token { let access: String; let expires: Date?; let plan: String }

    static func keychainBlob(_ service: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let s = String(data: data, encoding: .utf8) else { return nil }
        // `security -w` prints a secret with odd bytes as one hex string
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count % 2 == 0, !t.isEmpty, t.allSatisfy(\.isHexDigit) {
            var bytes = [UInt8]()
            var i = t.startIndex
            while i < t.endIndex {
                let j = t.index(i, offsetBy: 2)
                bytes.append(UInt8(t[i..<j], radix: 16)!)
                i = j
            }
            if let decoded = String(bytes: bytes, encoding: .utf8) { return decoded }
        }
        return t
    }

    static func parseToken(_ blob: String) -> Token? {
        guard let v = try? JSONSerialization.jsonObject(with: Data(blob.utf8)) as? [String: Any] else { return nil }
        let o = v["claudeAiOauth"] as? [String: Any] ?? v
        guard let access = o["accessToken"] as? String, !access.isEmpty else { return nil }
        let exp = (o["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Token(access: access, expires: exp, plan: (o["subscriptionType"] as? String ?? "").capitalized)
    }

    /// The first unexpired sign-in among the config folders (Keychain first, then a credentials file).
    func readToken() -> Token? {
        var found: [Token] = []
        for dir in preferredDirs() {
            if let b = UsagePoller.keychainBlob(keychainService(for: dir)), let t = UsagePoller.parseToken(b) { found.append(t) }
            if let b = try? String(contentsOf: dir.appendingPathComponent(".credentials.json"), encoding: .utf8), let t = UsagePoller.parseToken(b) { found.append(t) }
        }
        return found.first { ($0.expires ?? .distantFuture) > Date().addingTimeInterval(60) } ?? found.first
    }

    func poll(force: Bool = false) {
        guard !inFlight, Date() >= nextAllowed else { return }
        if !force, let f = fetchedAt, Date().timeIntervalSince(f) < 170 { return }
        guard let token = readToken() else {
            if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil || loginShellValue("ANTHROPIC_API_KEY") != nil {
                fail("API key: no plan limits to show")
            } else {
                fail("Sign in to Claude Code on this Mac")
            }
            nextAllowed = Date().addingTimeInterval(300)
            return
        }
        if let exp = token.expires, exp < Date() {
            fail("Open Claude Code to refresh sign-in")
            nextAllowed = Date().addingTimeInterval(60)
            return
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 20)
        req.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-buddy/1.1", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        inFlight = true
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                self.inFlight = false
                self.nextAllowed = Date().addingTimeInterval(30)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if let err = err { self.fail("Offline: \(err.localizedDescription)"); return }
                if code == 429 {
                    let after = Double((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after") ?? "") ?? 600
                    self.nextAllowed = Date().addingTimeInterval(max(60, after))
                    self.note = "Rate limited, retrying soon"
                    log("usage: 429, retry in \(Int(after))s")
                    self.rebuild()
                    return
                }
                if code == 401 || code == 403 { self.fail("Open Claude Code to refresh sign-in"); return }
                guard code == 200, let data = data,
                      let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.fail("Usage service answered \(code)")
                    return
                }
                guard let parsed = UsageParse.meters(v, now: Date()) else {
                    self.fail("No usage limits on this account")
                    return
                }
                self.reading = (parsed.meters, parsed.note, token.plan)
                self.fetchedAt = Date()
                self.note = ""
                log("usage: " + parsed.meters.map { "\($0.label) \($0.pct)%" }.joined(separator: ", "))
                self.rebuild()
            }
        }.resume()
    }

    private func fail(_ why: String) {
        note = why
        log("usage: \(why)")
        rebuild()
    }

    static func meterField(_ m: Meter, now: Date) -> String {
        var pace = -1
        var resetText = "Not started"
        if let r = m.reset {
            if let s = m.start, r > s { pace = Int((now.timeIntervalSince(s) / r.timeIntervalSince(s) * 1000).rounded()) }
            if m.dated {
                let f = DateFormatter()
                f.dateFormat = "MMM d"
                f.timeZone = TimeZone(identifier: "UTC")
                resetText = "Resets " + f.string(from: r)
            } else {
                resetText = "Resets in " + compactDuration(r.timeIntervalSince(now))
            }
        }
        let clean = { (s: String) in ascii(s, max: 24).replacingOccurrences(of: ";", with: ",") }
        return "\(clean(m.label));\(m.pct);\(max(-1, min(1000, pace)));\(clean(resetText))"
    }

    static func compactDuration(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        if s < 3600 { return "\(max(1, s / 60))m" }
        if s < 86400 { return "\(s / 3600)h \(s / 60 % 60)m" }
        return "\(s / 86400)d \(s / 3600 % 24)h"
    }

    /// The U line for given meters (also used by --parse-usage).
    static func message(ok: Bool, age: Int, plan: String, note: String, meters: [Meter], now: Date) -> String {
        (["U", ok ? "1" : "0", "\(age)", ascii(plan, max: 12), ascii(note, max: 44)]
            + meters.prefix(2).map { meterField($0, now: now) }).joined(separator: "|")
    }

    /// Rebuilt each send so the ages and reset countdowns stay current.
    func rebuild() {
        let now = Date()
        if let r = reading, let at = fetchedAt {
            let shownNote = note.isEmpty ? r.note : note
            message = UsagePoller.message(ok: true, age: Int(now.timeIntervalSince(at)), plan: r.plan, note: shownNote,
                                          meters: r.meters, now: now)
            summary = r.meters.map { "\($0.label.replacingOccurrences(of: "  5h", with: "")) \($0.pct)%" }.joined(separator: "  ·  ")
        } else {
            let n = note.isEmpty ? "Asking Claude for usage" : note
            message = UsagePoller.message(ok: false, age: 0, plan: "", note: n, meters: [], now: now)
            summary = "Usage: \(n)"
        }
        onChange?()
    }
}

// MARK: - Today's stats, from Claude Code transcripts

/// A session as its transcript tells it: used when Claude Code's hooks don't reach us
/// (sessions opened before the app, or hooks blocked by an organisation's settings).
struct LiveSession {
    var project = ""
    var last = Date.distantPast
    var working = false
    var detail = ""
    var turnStart: Date?
    var endedAt: Date?
}

final class TodayScanner {
    private var day = Calendar.current.startOfDay(for: Date())
    private(set) var live: [String: LiveSession] = [:]
    private var lastWrite: [String: Date] = [:]  // per config folder
    private var offsets: [String: UInt64] = [:]
    private var prompts = Set<String>(), tools = Set<String>(), files = Set<String>()
    private var outTokens: [String: Int] = [:]
    private var lines = 0
    private var hours = [Int](repeating: 0, count: 24)
    private var projects: [String: Int] = [:]
    private var firstScan = true
    var onInterrupt: ((String) -> Void)?
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func reset() {
        offsets = [:]; prompts = []; tools = []; files = []; outTokens = [:]; lines = 0
        hours = [Int](repeating: 0, count: 24); projects = [:]
    }

    func scan() {
        let start = Calendar.current.startOfDay(for: Date())
        if start != day { day = start; reset() }
        for dir in claudeDirs {
            let root = dir.appendingPathComponent("projects")
            guard let it = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            else { continue }
            for case let url as URL in it where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let mod = values?.contentModificationDate, mod >= day, let size = values?.fileSize else { continue }
                lastWrite[dir.path] = max(lastWrite[dir.path] ?? .distantPast, mod)
                let from = offsets[url.path] ?? 0
                if UInt64(size) <= from { continue }
                guard let h = try? FileHandle(forReadingFrom: url) else { continue }
                h.seek(toFileOffset: from)
                let data = h.readDataToEndOfFile()
                try? h.close()
                guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { continue }
                // subagent transcripts count toward the day, but aren't sessions of their own
                let session = url.path.contains("/subagents/") ? nil : url.deletingPathExtension().lastPathComponent
                for line in data[..<lastNewline].split(separator: UInt8(ascii: "\n")) { process(Data(line), session: session) }
                offsets[url.path] = from + UInt64(lastNewline + 1)
            }
        }
        live = live.filter { Date().timeIntervalSince($0.value.last) < 1800 }
        firstScan = false
    }

    /// When Claude last wrote a transcript on this Mac.
    var lastActivity: Date { lastWrite.values.max() ?? .distantPast }

    /// Config folders, the most recently used first (whose sign-in to read usage with).
    var dirsByUse: [URL] {
        claudeDirs.sorted { (lastWrite[$0.path] ?? .distantPast) > (lastWrite[$1.path] ?? .distantPast) }
    }

    private func touch(_ session: String?, _ ts: Date, _ project: String, _ change: (inout LiveSession) -> Void) {
        guard let id = session, Date().timeIntervalSince(ts) < 1800 else { return }
        var l = live[id] ?? LiveSession()
        if ts < l.last { return }
        l.last = ts
        if !project.isEmpty { l.project = ascii(project, max: 28) }
        change(&l)
        live[id] = l
    }

    private static func lineCount(_ s: String?) -> Int {
        guard let s = s, !s.isEmpty else { return 0 }
        return s.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private func process(_ line: Data, session: String?) {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let ts = (o["timestamp"] as? String).flatMap({ iso.date(from: $0) }), ts >= day,
              let msg = o["message"] as? [String: Any] else { return }
        let hour = Calendar.current.component(.hour, from: ts)
        let project = baseName(o["cwd"] as? String)
        let content = msg["content"]
        let texts: [String] = (content as? String).map { [$0] }
            ?? (content as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }

        if o["type"] as? String == "user" {
            if texts.contains(where: { $0.hasPrefix("[Request interrupted") }) {
                if let id = session, !firstScan && Date().timeIntervalSince(ts) < 120 { onInterrupt?(id) }
                touch(session, ts, project) { $0.working = false; $0.endedAt = nil; $0.turnStart = nil }
                return
            }
            let toolResult = (content as? [[String: Any]] ?? []).contains { $0["type"] as? String == "tool_result" }
            if toolResult { touch(session, ts, project) { $0.working = true } }
            guard o["isMeta"] as? Bool != true, let text = texts.first, !text.hasPrefix("<"),
                  o["isSidechain"] as? Bool != true else { return }
            touch(session, ts, project) { $0.working = true; $0.turnStart = ts; $0.detail = "Thinking"; $0.endedAt = nil }
            let key = o["promptId"] as? String ?? o["uuid"] as? String ?? UUID().uuidString
            if prompts.insert(key).inserted {
                hours[hour] += 1
                if !project.isEmpty { projects[project, default: 0] += 1 }
            }
        } else if o["type"] as? String == "assistant" {
            let id = msg["id"] as? String ?? UUID().uuidString
            if outTokens[id] == nil { hours[hour] += 1 }
            let usage = msg["usage"] as? [String: Any]
            outTokens[id] = max(outTokens[id] ?? 0, usage?["output_tokens"] as? Int ?? 0)
            let items = content as? [[String: Any]] ?? []
            if let lastTool = items.last(where: { $0["type"] as? String == "tool_use" }) {
                let d = Tracker.describe(lastTool["name"] as? String ?? "", lastTool["input"] as? [String: Any] ?? [:])
                touch(session, ts, project) { $0.working = true; $0.detail = d.detail }
            }
            if msg["stop_reason"] as? String == "end_turn" {
                touch(session, ts, project) { $0.working = false; $0.endedAt = ts }
            }
            for item in items where item["type"] as? String == "tool_use" {
                guard let tid = item["id"] as? String, tools.insert(tid).inserted else { continue }
                if !project.isEmpty { projects[project, default: 0] += 1 }
                let input = item["input"] as? [String: Any] ?? [:]
                let path = input["file_path"] as? String ?? input["notebook_path"] as? String
                switch item["name"] as? String ?? "" {
                case "Edit": lines += TodayScanner.lineCount(input["new_string"] as? String)
                case "Write": lines += TodayScanner.lineCount(input["content"] as? String)
                case "NotebookEdit": lines += TodayScanner.lineCount(input["new_source"] as? String)
                case "MultiEdit":
                    for e in input["edits"] as? [[String: Any]] ?? [] { lines += TodayScanner.lineCount(e["new_string"] as? String) }
                default: continue
                }
                if let p = path { files.insert(p) }
            }
        }
    }

    var message: String {
        let top = projects.max { $0.value < $1.value }?.key ?? ""
        let tokens = outTokens.values.reduce(0, +)
        return "D|\(prompts.count)|\(tools.count)|\(files.count)|\(lines)|\(tokens)|"
            + hours.map(String.init).joined(separator: ",") + "|\(ascii(top, max: 28))"
    }

    var summary: String { "Today: \(prompts.count) prompts, \(tools.count) tool calls, \(lines) lines" }
}

// MARK: - Bluetooth link to the device

final class DeviceLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "c1a0de01-b0d7-4c1a-9e5e-6275646479a1")
    static let rxUUID = CBUUID(string: "c1a0de02-b0d7-4c1a-9e5e-6275646479a1")
    static let txUUID = CBUUID(string: "c1a0de03-b0d7-4c1a-9e5e-6275646479a1")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    var status = "Starting Bluetooth"
    var connected: Bool { rx != nil }
    var onReady: (() -> Void)?
    var onChange: (() -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func setStatus(_ s: String) {
        if s != status { log("bluetooth: \(s)") }
        status = s
        onChange?()
    }

    private func scan() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        if let p = central.retrieveConnectedPeripherals(withServices: [DeviceLink.service]).first {
            connect(p)
            return
        }
        central.scanForPeripherals(withServices: [DeviceLink.service])
        setStatus("Looking for Claude Buddy")
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        central.connect(p)
        setStatus("Connecting")
    }

    private func lost(_ why: String) {
        peripheral = nil
        rx = nil
        setStatus(why)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.scan() }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: scan()
        case .unauthorized: setStatus("Allow Bluetooth in System Settings > Privacy")
        case .poweredOff: setStatus("Bluetooth is off")
        case .unsupported: setStatus("No Bluetooth LE on this Mac")
        default: setStatus("Starting Bluetooth")
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        log("found \(p.name ?? "device") rssi \(rssi)")
        connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([DeviceLink.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        lost("Couldn't connect, retrying")
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        lost("Disconnected, looking again")
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == DeviceLink.service }) else {
            central.cancelPeripheralConnection(p)
            return
        }
        p.discoverCharacteristics([DeviceLink.rxUUID, DeviceLink.txUUID], for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        for c in svc.characteristics ?? [] {
            if c.uuid == DeviceLink.rxUUID { rx = c }
            if c.uuid == DeviceLink.txUUID { p.setNotifyValue(true, for: c) }
        }
        if rx != nil {
            setStatus("Connected to \(p.name ?? "Claude Buddy")")
            onReady?()
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if c.value == Data("H".utf8) { onReady?() }
    }

    func send(_ line: String) {
        guard let p = peripheral, let rx = rx else { return }
        let data = Data(line.utf8)
        p.writeValue(data.prefix(min(250, p.maximumWriteValueLength(for: .withResponse))), for: rx, type: .withResponse)
    }
}

// MARK: - Remote machines (Claude Code over SSH)

/// ~/.claude-buddy/config.json, read and written without losing keys we don't know.
enum Config {
    static let url = buddyDir.appendingPathComponent("config.json")

    static func load() -> [String: Any] {
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    static func save(_ o: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? d.write(to: url, options: .atomic)
        }
    }

    static var remotes: [[String: Any]] {
        get { load()["remotes"] as? [[String: Any]] ?? [] }
        set { var o = load(); o["remotes"] = newValue; save(o) }
    }
}

/// Host aliases from ~/.ssh/config (no wildcard patterns), for the Add Remote Machine menu.
func sshConfigHosts() -> [String] {
    guard let text = try? String(contentsOf: home.appendingPathComponent(".ssh/config"), encoding: .utf8) else { return [] }
    var hosts: [String] = []
    for line in text.components(separatedBy: .newlines) {
        let parts = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
        guard parts.count > 1, parts[0].lowercased() == "host" else { continue }
        for h in parts.dropFirst() where !h.contains("*") && !h.contains("?") && !h.hasPrefix("!") && !hosts.contains(String(h)) {
            hosts.append(String(h))
        }
    }
    return hosts
}

/// Passphrase-protected SSH keys. The app connects with BatchMode (it can't answer prompts), so a
/// locked key is unlocked into the Mac's ssh-agent with the passphrase saved in the login Keychain,
/// exactly like `ssh-add --apple-use-keychain`. The passphrase dialog is this app itself, run by
/// ssh-add as its SSH_ASKPASS helper (see askpass() at the bottom).
enum SSHKeys {
    static func run(_ path: String, _ args: [String], env extra: [String: String] = [:], timeout: TimeInterval = 120) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        extra.forEach { env[$0.key] = $0.value }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "") }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, text)
    }

    /// Loads keys whose passphrases are already in the Keychain (no prompt). After a restart the agent is empty.
    static func loadFromKeychain() {
        _ = run("/usr/bin/ssh-add", ["--apple-load-keychain"], timeout: 10)
    }

    /// The key files ssh would offer to this host (from ~/.ssh/config, or the defaults), that exist.
    static func identityFiles(_ host: String) -> [String] {
        let testConfig = ProcessInfo.processInfo.environment["CLAUDE_BUDDY_SSH_CONFIG"].map { ["-F", $0] } ?? []  // tests only
        let (_, text) = run("/usr/bin/ssh", testConfig + ["-G", host], timeout: 10)
        var files: [String] = []
        for line in text.components(separatedBy: .newlines) where line.lowercased().hasPrefix("identityfile ") {
            let f = (String(line.dropFirst("identityfile ".count)) as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: f) && !files.contains(f) { files.append(f) }
        }
        return files
    }

    /// Asks for each key's passphrase and adds it to the agent + Keychain. Calls back on the main queue.
    static func unlock(host: String, done: @escaping (Bool, String) -> Void) {
        DispatchQueue.global().async {
            let files = identityFiles(host)
            var ok = false, message = files.isEmpty ? "No SSH key found for \(host)" : ""
            for f in files {
                let (code, text) = run("/usr/bin/ssh-add", ["--apple-use-keychain", f], env: [
                    "SSH_ASKPASS": Bundle.main.executablePath ?? "", "SSH_ASKPASS_REQUIRE": "force",
                    "DISPLAY": ":0", "CLAUDE_BUDDY_ASKPASS": "1"])
                if code == 0 { ok = true; message = "Unlocked \((f as NSString).lastPathComponent)" }
                else if message.isEmpty { message = ascii(text.trimmingCharacters(in: .whitespacesAndNewlines), max: 80) }
            }
            log("ssh key unlock for \(host): \(ok ? "ok" : "failed") \(message)")
            DispatchQueue.main.async { done(ok, message) }
        }
    }
}

/// One machine where Claude Code runs, followed over SSH. The app sends ../remote/buddy-agent.py
/// with every connect (so it always matches the app) and reads the agent's protocol lines back.
final class RemoteSource {
    let host: String
    private let testHome: String?  // tests only: run the agent here with this HOME instead of over SSH
    var state = "Connecting"
    var connected = false
    var status = "S|0|0|0||"
    var usage: String?
    var today: String?
    var lastActivity = Date.distantPast
    var account = ""
    var hooks = ""
    var note = ""
    var onFeed: ((String) -> Void)?
    var onChange: (() -> Void)?
    /// The login failed because the SSH key is locked: the menu offers Unlock SSH Key.
    var needsUnlock = false
    var onNeedsUnlock: ((RemoteSource) -> Void)?
    var unlockedOnce = false
    private var triedKeychain = false

    private var process: Process?
    private var stdin: Pipe?
    private var buffer = Data()
    private var errorText = ""
    private var retry: TimeInterval = 5
    private var lastLine = Date()
    private var stopped = false
    private var watchdog: Timer?

    init(host: String, testHome: String? = nil) {
        self.host = host
        self.testHome = testHome
    }

    static var agentScript: Data? {
        Bundle.main.url(forResource: "buddy-agent", withExtension: "py").flatMap { try? Data(contentsOf: $0) }
    }

    func start() {
        guard !stopped, process == nil else { return }
        guard let script = RemoteSource.agentScript else {
            state = "Agent missing from the app bundle"
            onChange?()
            return
        }
        let inner = "mkdir -p \"$HOME/.claude-buddy\" && head -c \(script.count) > \"$HOME/.claude-buddy/agent.py\" && "
            + "{ command -v python3 >/dev/null 2>&1 || { echo \"E|python3 is not installed there\"; exit 3; }; } && "
            + "exec python3 -u \"$HOME/.claude-buddy/agent.py\""
        let p = Process()
        if let testHome = testHome {
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", inner]
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = testHome
            p.environment = env
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            // sh -c keeps it working whatever the login shell is (bash, zsh, fish)
            p.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15",
                           "-o", "ServerAliveCountMax=3", host, "sh -c '\(inner)'"]
        }
        let out = Pipe(), err = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = input
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async { self?.received(d) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let text = String(data: d, encoding: .utf8) else { return }
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let last = lines.last { DispatchQueue.main.async { self?.errorText = last } }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.ended(proc.terminationStatus) }
        }
        errorText = ""
        state = connected ? "Reconnecting" : "Connecting"
        do {
            try p.run()
        } catch {
            state = "Couldn't start ssh: \(error.localizedDescription)"
            onChange?()
            return
        }
        process = p
        stdin = input
        input.fileHandleForWriting.write(script)  // the agent's copy; the stream then stays open
        lastLine = Date()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self = self, let p = self.process else { return }
            if Date().timeIntervalSince(self.lastLine) > 45 { log("\(self.host): no word for 45s, reconnecting"); p.terminate() }
        }
        log("\(host): connecting")
        onChange?()
    }

    func stop() {
        stopped = true
        watchdog?.invalidate()
        process?.terminate()
    }

    func reconnect() {
        retry = 5
        if let p = process { p.terminate() } else { start() }
    }

    /// Removing a machine: take our hooks back out of its Claude Code settings.
    func uninstallHooks() {
        guard testHome == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host,
                       "sh -c 'python3 \"$HOME/.claude-buddy/agent.py\" --uninstall-hooks; rm -f \"$HOME/.claude-buddy/hook.sh\"'"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private func received(_ d: Data) {
        guard !d.isEmpty else { return }
        buffer.append(d)
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        lastLine = Date()
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let kind = f.first else { return }
        if !connected && kind != "E" {
            connected = true
            needsUnlock = false
            triedKeychain = false
            retry = 5
            state = "Connected"
            log("\(host): connected")
        }
        switch kind {
        case "S": status = line
        case "U": usage = line
        case "D": today = line
        case "A" where f.count >= 3: onFeed?("A|\(f[1])|\(ascii(host, max: 12)): \(f[2])")
        case "R" where f.count >= 5:
            if let ago = Double(f[1]), ago >= 0 { lastActivity = Date().addingTimeInterval(-ago) }
            hooks = f[2]
            account = f[3]
        case "E":
            note = f.dropFirst().joined(separator: "|")
            log("\(host): \(note)")
        default: break
        }
        onChange?()
    }

    private func ended(_ code: Int32) {
        process = nil
        stdin = nil
        connected = false
        status = "S|0|0|0||"
        watchdog?.invalidate()
        if stopped { return }
        let e = errorText
        if note.hasPrefix("python3 is not installed") { state = "python3 isn't installed there" }
        else if e.contains("Permission denied") && testHome == nil {
            if !triedKeychain {  // after a restart the agent is empty, but the passphrase may be saved
                triedKeychain = true
                state = "Unlocking SSH key"
                DispatchQueue.global().async { [weak self] in
                    SSHKeys.loadFromKeychain()
                    DispatchQueue.main.async { self?.start() }
                }
                onChange?()
                return
            }
            if unlockedOnce {
                state = "SSH login refused: is this key allowed on \(host)?"
            } else {
                state = "SSH key is locked: choose Unlock SSH Key"
                needsUnlock = true
                onNeedsUnlock?(self)
            }
        }
        else if e.contains("Could not resolve hostname") { state = "Unknown host" }
        else if e.contains("timed out") || e.contains("No route") || e.contains("Network is unreachable") { state = "Can't reach it (VPN?)" }
        else if e.contains("Host key verification failed") { state = "Host key not trusted yet: ssh to it once in Terminal" }
        else if e.contains("passphrase") { state = "SSH key is locked: choose Unlock SSH Key"; needsUnlock = true; onNeedsUnlock?(self) }
        else if !e.isEmpty { state = ascii(e, max: 70) }
        else { state = "Disconnected" }
        log("\(host): ended (\(code)) \(e)")
        let wait = retry
        retry = min(retry * 2, 120)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.start() }
        onChange?()
    }
}

// MARK: - Updating itself from GitHub releases

/// Checks github.com/madhusoodhans/claude-buddy for a newer release and installs it in place:
/// download the zip, check its SHA-256 against the release's .sha256 file, check the new app's
/// bundle id, version and code signature, then swap it in after this app quits and relaunch it.
final class Updater {
    static let latestURL = URL(string: "https://api.github.com/repos/madhusoodhans/claude-buddy/releases/latest")!
    static let assetName = "ClaudeBuddy-mac.zip"
    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    var available: (version: String, zip: URL, sha: URL?)?
    var state = ""  // shown in the menu while working, or the last problem
    var busy = false
    var onChange: (() -> Void)?

    /// "1.10.0" > "1.9.2"; a leading "v" is ignored.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let n = { (s: String) in s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 } }
        let x = n(a), y = n(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Where the running app lives, if it can be replaced there.
    var installProblem: String? {
        let path = Bundle.main.bundleURL.path
        if !path.hasSuffix(".app") { return "Not running from an app bundle" }
        if path.contains("/AppTranslocation/") { return "Move Claude Buddy to Applications first, then open it from there" }
        if !FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) {
            return "Can't write to \(Bundle.main.bundleURL.deletingLastPathComponent().path)"
        }
        return nil
    }

    func check(done: ((Bool) -> Void)? = nil) {
        var req = URLRequest(url: Updater.latestURL, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("claude-buddy/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard err == nil, code == 200, let data = data,
                      let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = v["tag_name"] as? String else {
                    self.state = err != nil ? "Couldn't check for updates (offline?)" : "Couldn't check for updates (HTTP \(code))"
                    log("update check: \(self.state)")
                    self.onChange?()
                    done?(false)
                    return
                }
                let assets = v["assets"] as? [[String: Any]] ?? []
                func asset(_ name: String) -> URL? {
                    (assets.first { $0["name"] as? String == name }?["browser_download_url"] as? String).flatMap(URL.init(string:))
                }
                let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if Updater.isNewer(version, than: self.current), let zip = asset(Updater.assetName) {
                    if self.available?.version != version { log("update available: \(version) (running \(self.current))") }
                    self.available = (version, zip, asset(Updater.assetName + ".sha256"))
                } else {
                    self.available = nil
                }
                if !self.busy { self.state = "" }
                self.onChange?()
                done?(self.available != nil)
            }
        }.resume()
    }

    private func fail(_ why: String) {
        busy = false
        state = "Update failed: \(why)"
        log(state)
        onChange?()
    }

    /// Downloads, checks and stages the new app, then calls `quit`; a helper swaps the bundles once we've exited.
    func install(relaunch: Bool = true, quit: @escaping () -> Void) {
        guard let up = available, !busy else { return }
        if let problem = installProblem { fail(problem); return }
        busy = true
        state = "Downloading \(up.version)…"
        onChange?()
        let appURL = Bundle.main.bundleURL
        let stage = appURL.deletingLastPathComponent().appendingPathComponent(".claude-buddy-update-\(up.version)")
        DispatchQueue.global().async {
            func finish(_ why: String?) { DispatchQueue.main.async { if let w = why { self.fail(w) } } }
            let fm = FileManager.default
            try? fm.removeItem(at: stage)
            do { try fm.createDirectory(at: stage, withIntermediateDirectories: true) } catch { return finish("can't stage the update: \(error.localizedDescription)") }
            guard let zipData = try? Data(contentsOf: up.zip) else { return finish("download failed") }
            if let shaURL = up.sha {
                guard let shaText = try? String(contentsOf: shaURL, encoding: .utf8) else { return finish("couldn't download the checksum") }
                let want = shaText.split(whereSeparator: { $0 == " " || $0.isNewline }).first.map(String.init)?.lowercased() ?? ""
                let got = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
                guard want == got else { return finish("checksum mismatch, download discarded") }
            }
            let zip = stage.appendingPathComponent(Updater.assetName)
            do { try zipData.write(to: zip) } catch { return finish("can't save the download") }
            DispatchQueue.main.async { self.state = "Installing \(up.version)…"; self.onChange?() }
            let (unzipCode, _) = SSHKeys.run("/usr/bin/ditto", ["-x", "-k", zip.path, stage.path], timeout: 60)
            let newApp = stage.appendingPathComponent("Claude Buddy.app")
            guard unzipCode == 0, fm.fileExists(atPath: newApp.path) else { return finish("the download didn't contain the app") }
            let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { return finish("the download is a different app") }
            guard info?["CFBundleShortVersionString"] as? String == up.version else { return finish("the download's version doesn't match") }
            let (signCode, signText) = SSHKeys.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path], timeout: 60)
            guard signCode == 0 else { return finish("code signature check failed: \(ascii(signText, max: 60))") }
            _ = SSHKeys.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path], timeout: 20)

            // Swap the bundles after we exit, putting the old one back if the move fails; then relaunch.
            let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let old = appURL.path, backup = appURL.path + ".previous"
            let script = """
            #!/bin/sh
            while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
            rm -rf \(q(backup))
            if mv \(q(old)) \(q(backup)) && mv \(q(newApp.path)) \(q(old)); then
              rm -rf \(q(backup)) \(q(stage.path))
            else
              [ -d \(q(backup)) ] && [ ! -d \(q(old)) ] && mv \(q(backup)) \(q(old))
            fi
            \(relaunch ? "open \(q(old))" : "")
            """
            let scriptURL = stage.appendingPathComponent("swap.sh")
            do { try script.write(to: scriptURL, atomically: true, encoding: .utf8) } catch { return finish("can't write the installer") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [scriptURL.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return finish("can't start the installer") }
            log("installing update \(up.version); restarting")
            DispatchQueue.main.async { quit() }
        }
    }
}

// MARK: - The app

final class AppDelegate: NSObject, NSApplicationDelegate {
    let tracker = Tracker()
    let usage = UsagePoller()
    let today = TodayScanner()
    var link: DeviceLink!
    var item: NSStatusItem!
    var remotes: [RemoteSource] = []
    let updater = Updater()
    var lastStatus = "", lastToday = ""
    var usageSource = "This Mac"
    var timers: [Timer] = []
    private var menuDirty = false
    private var justAdded: [String: Date] = [:]  // hosts added from the menu: ask for the key right away
    private var unlocking = Set<String>()

    func applicationDidFinishLaunching(_ n: Notification) {
        try? FileManager.default.createDirectory(at: buddyDir, withIntermediateDirectories: true)
        try? "\(getpid())\n".write(to: buddyDir.appendingPathComponent("app.pid"), atomically: true, encoding: .utf8)
        log("Claude Buddy started (pid \(getpid())), Claude folders: " + claudeDirs.map(\.path).joined(separator: ", "))
        if let why = Hooks.blockedBySettings { log("hooks blocked: \(why); following transcripts instead") }
        if !Hooks.installed || (try? String(contentsOf: Hooks.script, encoding: .utf8)) != Hooks.scriptText {
            do { try Hooks.install() } catch { log("couldn't install hooks: \(error.localizedDescription)") }
        }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        link = DeviceLink()
        link.onReady = { [weak self] in self?.sendAll(includeFeed: true) }
        link.onChange = { [weak self] in self?.refreshMenu() }
        usage.onChange = { [weak self] in self?.menuDirty = true }
        tracker.onFeed = { [weak self] line in self?.link.send(line) }
        tracker.onStop = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.usage.poll() }
        }
        today.onInterrupt = { [weak self] id in self?.tracker.interrupted(id) }
        usage.preferredDirs = { [weak self] in self?.today.dirsByUse ?? claudeDirs }

        for r in Config.remotes { if let host = r["host"] as? String { addRemote(host, testHome: r["testHome"] as? String, save: false) } }

        today.scan()
        tracker.live = today.live
        usage.poll(force: true)
        every(0.5) { [weak self] in self?.tick() }
        every(3) { [weak self] in self?.scanToday() }
        every(10) { [weak self] in self?.sendAll(includeFeed: false) }
        every(60) { [weak self] in self?.usage.poll() }
        updater.onChange = { [weak self] in self?.menuDirty = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.updater.check() }
        every(6 * 3600) { [weak self] in self?.updater.check() }
        every(1) { [weak self] in
            if self?.menuDirty == true { self?.menuDirty = false; self?.refreshMenu() }
        }
        refreshMenu()
    }

    func applicationWillTerminate(_ n: Notification) {
        remotes.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: buddyDir.appendingPathComponent("app.pid"))
    }

    private func every(_ s: TimeInterval, _ f: @escaping () -> Void) {
        let t = Timer(timeInterval: s, repeats: true) { _ in f() }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    // MARK: Machines

    func addRemote(_ host: String, testHome: String? = nil, save: Bool = true) {
        guard !remotes.contains(where: { $0.host == host }) else { return }
        let r = RemoteSource(host: host, testHome: testHome)
        r.onFeed = { [weak self] line in self?.link.send(line) }
        r.onChange = { [weak self] in self?.menuDirty = true }
        r.onNeedsUnlock = { [weak self] r in
            guard let self = self, let added = self.justAdded[r.host], Date().timeIntervalSince(added) < 180 else { return }
            self.justAdded[r.host] = nil
            self.unlockKey(r.host)
        }
        remotes.append(r)
        if save { justAdded[host] = Date() }
        if save {
            var list = Config.remotes
            list.append(["host": host])
            Config.remotes = list
            log("added remote machine \(host)")
        }
        r.start()
    }

    func removeRemote(_ host: String) {
        guard let i = remotes.firstIndex(where: { $0.host == host }) else { return }
        let r = remotes.remove(at: i)
        r.stop()
        r.uninstallHooks()
        Config.remotes = Config.remotes.filter { $0["host"] as? String != host }
        log("removed remote machine \(host)")
        refreshMenu()
    }

    private struct Source {
        let name: String
        let remote: Bool
        let status: [String]  // S line fields
        let last: Date
        let usage: String?
        let today: String?
    }

    private func sources() -> [Source] {
        var all = [Source(name: "This Mac", remote: false, status: fields(tracker.status()),
                          last: max(tracker.lastActivity, today.lastActivity), usage: usage.message, today: today.message)]
        for r in remotes where r.connected {
            all.append(Source(name: r.host, remote: true, status: fields(r.status), last: r.lastActivity, usage: r.usage, today: r.today))
        }
        return all
    }

    private func fields(_ line: String) -> [String] {
        var f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        while f.count < 6 { f.append("") }
        return f
    }

    /// What the device shows: the session that most needs you, on whichever machine.
    func pooledStatus() -> String {
        let all = sources()
        let rank = [2: 3, 1: 2, 3: 1, 0: 0]
        let top = all.max { a, b in
            (rank[Int(a.status[1]) ?? 0] ?? 0, a.last) < (rank[Int(b.status[1]) ?? 0] ?? 0, b.last)
        }!
        let sessions = all.reduce(0) { $0 + (Int($1.status[3]) ?? 0) }
        var project = top.status[4]
        if top.remote { project = ascii(top.name, max: 12) + (project.isEmpty ? "" : ": " + project) }
        return "S|\(top.status[1])|\(top.status[2])|\(sessions)|\(ascii(project, max: 31))|\(top.status[5])"
    }

    /// Usage from the machine where Claude was used most recently (with a reading to show).
    func pooledUsage() -> String {
        let all = sources()
        let readable = all.filter { $0.usage?.hasPrefix("U|1|") == true }
        let pick = (readable.isEmpty ? all.filter { $0.usage != nil } : readable).max { $0.last < $1.last }
        usageSource = pick?.name ?? "This Mac"
        return pick?.usage ?? usage.message
    }

    /// Today's numbers, added up over every machine.
    func pooledToday() -> String {
        var sums = [Int](repeating: 0, count: 5)
        var hours = [Int](repeating: 0, count: 24)
        var top = "", topTools = -1
        for s in sources() {
            guard let d = s.today else { continue }
            let f = fields(d)
            guard f.count >= 8 else { continue }
            for i in 0..<5 { sums[i] += Int(f[i + 1]) ?? 0 }
            for (h, v) in f[6].split(separator: ",").enumerated() where h < 24 { hours[h] += Int(v) ?? 0 }
            if (Int(f[2]) ?? 0) > topTools { topTools = Int(f[2]) ?? 0; top = f[7] }
        }
        return "D|" + sums.map(String.init).joined(separator: "|") + "|" + hours.map(String.init).joined(separator: ",") + "|" + top
    }

    // MARK: Sending

    private func tick() {
        tracker.drainEvents()
        let s = pooledStatus()
        // The seconds field ticks; only push when something else changed.
        let key = fields(s).enumerated().filter { $0.offset != 2 }.map { $0.element }.joined(separator: "|")
        if key != lastStatus {
            lastStatus = key
            link.send(s)
            log("status \(s)")
            menuDirty = true
        }
    }

    private func scanToday() {
        today.scan()
        tracker.live = today.live
        let d = pooledToday()
        if d != lastToday {
            if lastToday.isEmpty { log("today \(d)") }
            lastToday = d
            link.send(d)
        }
    }

    private func timeMessage() -> String {
        let fmt = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "HH"
        let h24 = fmt.contains("a") ? 0 : 1
        let host = ascii(Host.current().localizedName ?? "Mac", max: 30)
        return "T|\(Int(Date().timeIntervalSince1970))|\(TimeZone.current.secondsFromGMT())|\(h24)|\(host)"
    }

    func sendAll(includeFeed: Bool) {
        guard link.connected else { return }
        usage.rebuild()
        link.send(timeMessage())
        link.send(pooledUsage())
        link.send(pooledStatus())
        link.send(pooledToday())
        if includeFeed { tracker.feed.forEach(link.send) }
    }

    // MARK: Menu

    private static func moodWord(_ f: [String]) -> String {
        switch Int(f[1]) ?? 0 {
        case 1: return "cooking"
        case 2: return "needs you"
        case 3: return "done"
        default: return "napping"
        }
    }

    private func moodText() -> String {
        let f = fields(pooledStatus())
        let detail = !f[5].isEmpty ? " – \(f[5])" : ""
        let place = remotes.isEmpty || f[4].isEmpty ? "" : " (\(f[4]))"
        switch Int(f[1]) ?? 0 {
        case 1: return "Claude is cooking" + detail + place
        case 2: return "Claude needs you" + detail + place
        case 3: return "Claude is done" + detail + place
        default: return "Claude is napping"
        }
    }

    private func usageText() -> String {
        let f = fields(pooledUsage())
        guard f[1] == "1" else { return "Usage: " + (f[4].isEmpty ? "waiting" : f[4]) + (remotes.isEmpty ? "" : " (\(usageSource))") }
        let meters = f.dropFirst(5).compactMap { m -> String? in
            let p = m.split(separator: ";").map(String.init)
            return p.count >= 2 ? "\(p[0].replacingOccurrences(of: "  5h", with: "")) \(p[1])%" : nil
        }
        let plan = f[3].isEmpty ? "" : "\(f[3]) · "
        return meters.joined(separator: "  ·  ") + (remotes.isEmpty && f[3].isEmpty ? "" : "  (\(plan)\(usageSource))")
    }

    func refreshMenu() {
        guard let button = item?.button else { return }
        let mood = Int(fields(pooledStatus())[1]) ?? 0
        let colors: [NSColor] = [.secondaryLabelColor, NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1), .systemOrange, .systemGreen]
        button.attributedTitle = NSAttributedString(string: updater.available != nil ? "✻↑" : "✻", attributes: [
            .foregroundColor: link.connected ? colors[min(3, mood)] : NSColor.tertiaryLabelColor,
            .font: NSFont.systemFont(ofSize: 15, weight: .bold)])
        button.toolTip = "Claude Buddy"

        let menu = NSMenu()
        func info(_ s: String, to m: NSMenu? = nil) {
            let i = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            i.isEnabled = false
            (m ?? menu).addItem(i)
        }
        func action(_ title: String, _ sel: Selector, _ rep: Any? = nil, to m: NSMenu? = nil, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self
            i.representedObject = rep
            (m ?? menu).addItem(i)
            return i
        }

        if let up = updater.available, !updater.busy {
            let u = action("Update to Claude Buddy \(up.version)…", #selector(installUpdate))
            u.attributedTitle = NSAttributedString(string: u.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            menu.addItem(.separator())
        }
        if !updater.state.isEmpty { info(updater.state); menu.addItem(.separator()) }
        info("Device: \(link.status)")
        info(moodText())
        info(usageText())
        let t = fields(pooledToday())
        info("Today: \(t[1]) prompts, \(t[2]) tool calls, \(t[4]) lines")
        menu.addItem(.separator())

        // Machines
        info("Machines")
        let local = fields(tracker.status())
        let localItem = NSMenuItem(title: "●  This Mac — \(AppDelegate.moodWord(local))", action: nil, keyEquivalent: "")
        let localSub = NSMenu()
        info(usage.summary, to: localSub)
        if let why = Hooks.blockedBySettings {
            info("Limited view: \(why)", to: localSub)
            info("(no \"Your turn\" alerts; activity comes from transcripts)", to: localSub)
        } else if tracker.hooklessActive > 0 {
            info("Restart Claude sessions opened before Claude Buddy for full detail", to: localSub)
        }
        if claudeDirs.count > 1 {
            info("Claude folders: " + claudeDirs.map { $0.path.replacingOccurrences(of: home.path, with: "~") }.joined(separator: ", "), to: localSub)
        }
        localSub.addItem(.separator())
        let hooks = action("Watch Claude Code here (hooks)", #selector(toggleHooks), to: localSub)
        hooks.state = Hooks.installed ? .on : .off
        localItem.submenu = localSub
        menu.addItem(localItem)

        for r in remotes {
            let word = r.connected ? AppDelegate.moodWord(fields(r.status)) : r.state
            let it = NSMenuItem(title: "\(r.connected ? "●" : "○")  \(r.host) — \(word)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            info(r.connected ? "Connected over SSH" : r.state, to: sub)
            if r.needsUnlock && !unlocking.contains(r.host) {
                _ = action("Unlock SSH Key…", #selector(unlockKeyItem(_:)), r.host, to: sub)
            }
            if !r.account.isEmpty { info("Account: \(r.account)", to: sub) }
            if let u = r.usage, u.hasPrefix("U|1|") {
                let meters = fields(u).dropFirst(5).compactMap { m -> String? in
                    let p = m.split(separator: ";").map(String.init)
                    return p.count >= 2 ? "\(p[0].replacingOccurrences(of: "  5h", with: "")) \(p[1])%" : nil
                }
                info("Usage: " + meters.joined(separator: "  ·  "), to: sub)
            } else if let u = r.usage {
                info("Usage: \(fields(u)[4])", to: sub)
            }
            if r.hooks.hasPrefix("blocked") { info("Limited view: hooks \(r.hooks) (no \"Your turn\" alerts)", to: sub) }
            else if r.hooks == "partly" { info("Some sessions there started before Claude Buddy: restart them for full detail", to: sub) }
            if !r.note.isEmpty { info(r.note, to: sub) }
            sub.addItem(.separator())
            _ = action("Reconnect", #selector(reconnectRemote(_:)), r.host, to: sub)
            _ = action("Remove (and take its hooks out)", #selector(removeRemoteItem(_:)), r.host, to: sub)
            it.submenu = sub
            menu.addItem(it)
        }

        let add = NSMenuItem(title: "Add Remote Machine", action: nil, keyEquivalent: "")
        let addSub = NSMenu()
        let known = Set(remotes.map(\.host))
        let hosts = sshConfigHosts().filter { !known.contains($0) }
        if hosts.isEmpty { info("No hosts in ~/.ssh/config", to: addSub) }
        for h in hosts { _ = action(h, #selector(addRemoteItem(_:)), h, to: addSub) }
        addSub.addItem(.separator())
        _ = action("Other…", #selector(addOtherRemote), to: addSub)
        add.submenu = addSub
        menu.addItem(add)

        menu.addItem(.separator())
        if #available(macOS 13.0, *) {
            let login = action("Open at Login", #selector(toggleLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        _ = action("Refresh Usage Now", #selector(refreshUsage), key: "r")
        _ = action("Check for Updates…  (\(updater.current))", #selector(checkForUpdates))
        _ = action("Show Log", #selector(openLog))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Buddy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    @objc func toggleHooks() {
        do { if Hooks.installed { try Hooks.uninstall() } else { try Hooks.install() } }
        catch { log("hooks: \(error.localizedDescription)") }
        refreshMenu()
    }

    @objc func addRemoteItem(_ sender: NSMenuItem) {
        if let h = sender.representedObject as? String { addRemote(h); refreshMenu() }
    }

    @objc func addOtherRemote() {
        let alert = NSAlert()
        alert.messageText = "Add a remote machine"
        alert.informativeText = "The SSH host where Claude Code runs, as you'd type it after ssh (e.g. devbox or me@10.0.0.5). It needs to log in with a key, without a password prompt."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "devbox"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let h = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !h.isEmpty && !h.contains(" ") && !h.contains("'") { addRemote(h); refreshMenu() }
        }
    }

    @objc func unlockKeyItem(_ sender: NSMenuItem) {
        if let h = sender.representedObject as? String { unlockKey(h) }
    }

    func unlockKey(_ host: String) {
        guard !unlocking.contains(host), let r = remotes.first(where: { $0.host == host }) else { return }
        unlocking.insert(host)
        r.state = "Waiting for your SSH key passphrase"
        refreshMenu()
        SSHKeys.unlock(host: host) { [weak self] ok, message in
            self?.unlocking.remove(host)
            if ok {
                r.unlockedOnce = true
                r.needsUnlock = false
                r.reconnect()
            } else {
                r.state = "Still locked: " + message
            }
            self?.refreshMenu()
        }
    }

    @objc func reconnectRemote(_ sender: NSMenuItem) {
        if let h = sender.representedObject as? String { remotes.first { $0.host == h }?.reconnect() }
    }

    @objc func removeRemoteItem(_ sender: NSMenuItem) {
        if let h = sender.representedObject as? String { removeRemote(h) }
    }

    @objc func toggleLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch { log("login item: \(error.localizedDescription)") }
        }
        refreshMenu()
    }

    @objc func refreshUsage() { usage.poll(force: true) }

    @objc func checkForUpdates() {
        updater.state = "Checking for updates…"
        refreshMenu()
        updater.check { [weak self] found in
            guard let self = self else { return }
            let alert = NSAlert()
            if found, let up = self.updater.available {
                alert.messageText = "Claude Buddy \(up.version) is available"
                alert.informativeText = "You have \(self.updater.current). Install it now? Claude Buddy restarts by itself; your machines and settings stay."
                alert.addButton(withTitle: "Install")
                alert.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { self.installUpdate() }
            } else if self.updater.state.isEmpty {
                alert.messageText = "Claude Buddy is up to date"
                alert.informativeText = "You have the latest version, \(self.updater.current)."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc func installUpdate() {
        updater.install { NSApp.terminate(nil) }
    }
    @objc func openLog() { NSWorkspace.shared.open(logURL) }
}

// Run by ssh-add as SSH_ASKPASS (CLAUDE_BUDDY_ASKPASS=1): ask for a key's passphrase in a dialog,
// print it for ssh-add, and exit. Cancel exits 1, which ssh-add takes as "no".
if ProcessInfo.processInfo.environment["CLAUDE_BUDDY_ASKPASS"] == "1" {
    let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
    if let test = ProcessInfo.processInfo.environment["CLAUDE_BUDDY_ASKPASS_TEST"] { print(test); exit(0) }  // tests only
    let askApp = NSApplication.shared
    askApp.setActivationPolicy(.accessory)
    let alert = NSAlert()
    alert.messageText = "Unlock your SSH key for Claude Buddy"
    alert.informativeText = (prompt.isEmpty ? "Enter the passphrase for your SSH key." : prompt)
        + "\n\nIt's added to your Mac's SSH agent and saved in your login Keychain (like ssh-add --apple-use-keychain), so Claude Buddy can reconnect without asking again."
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    alert.accessoryView = field
    alert.addButton(withTitle: "Unlock")
    alert.addButton(withTitle: "Cancel")
    askApp.activate(ignoringOtherApps: true)
    alert.window.initialFirstResponder = field
    let answer = alert.runModal()
    if answer == .alertFirstButtonReturn {
        print(field.stringValue)
        exit(0)
    }
    exit(1)
}

// `ClaudeBuddy --install-update` checks and installs the latest release into this bundle without
// relaunching (for testing the updater).
if CommandLine.arguments.contains("--install-update") {
    let u = Updater()
    print("running \(u.current)")
    u.onChange = { if !u.state.isEmpty { print(u.state) } }
    u.check { found in
        guard found, let up = u.available else { print("no newer release"); exit(0) }
        print("installing \(up.version)")
        u.install(relaunch: false) { exit(0) }
    }
    RunLoop.main.run()
}

// `ClaudeBuddy --unlock-key <host>` runs the same unlock as the menu (for testing).
if let i = CommandLine.arguments.firstIndex(of: "--unlock-key"), i + 1 < CommandLine.arguments.count {
    let host = CommandLine.arguments[i + 1]
    print("identity files: \(SSHKeys.identityFiles(host))")
    SSHKeys.unlock(host: host) { ok, message in print(ok ? "unlocked: \(message)" : "failed: \(message)"); exit(ok ? 0 : 1) }
    RunLoop.main.run()
}

// `ClaudeBuddy --parse-usage answer.json [ISO-time]` prints the device's usage line for a
// saved usage-endpoint answer (for testing account types we can't sign in to).
if let i = CommandLine.arguments.firstIndex(of: "--parse-usage"), i + 1 < CommandLine.arguments.count {
    let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    let now = i + 2 < CommandLine.arguments.count ? UsageParse.date(CommandLine.arguments[i + 2])! : Date()
    let v = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    if let r = UsageParse.meters(v, now: now) {
        print(UsagePoller.message(ok: true, age: 0, plan: "Test", note: r.note, meters: r.meters, now: now))
    } else {
        print(UsagePoller.message(ok: false, age: 0, plan: "", note: "No usage limits on this account", meters: [], now: now))
    }
    exit(0)
}

// `ClaudeBuddy --uninstall-hooks` removes the hooks without starting the app.
if CommandLine.arguments.contains("--uninstall-hooks") {
    do { try Hooks.uninstall() } catch { print("error: \(error.localizedDescription)"); exit(1) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
