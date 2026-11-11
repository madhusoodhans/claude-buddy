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

// MARK: - The app

final class AppDelegate: NSObject, NSApplicationDelegate {
    let tracker = Tracker()
    let usage = UsagePoller()
    let today = TodayScanner()
    var link: DeviceLink!
    var item: NSStatusItem!
    var lastStatus = "", lastToday = ""
    var timers: [Timer] = []

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
        usage.onChange = { [weak self] in self?.refreshMenu() }
        tracker.onFeed = { [weak self] line in self?.link.send(line) }
        tracker.onStop = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.usage.poll() }
        }
        today.onInterrupt = { [weak self] id in self?.tracker.interrupted(id) }
        usage.preferredDirs = { [weak self] in self?.today.dirsByUse ?? claudeDirs }

        today.scan()
        usage.poll(force: true)
        every(0.5) { [weak self] in self?.tick() }
        every(3) { [weak self] in self?.scanToday() }
        every(10) { [weak self] in self?.sendAll(includeFeed: false) }
        every(60) { [weak self] in self?.usage.poll() }
        refreshMenu()
    }

    func applicationWillTerminate(_ n: Notification) {
        try? FileManager.default.removeItem(at: buddyDir.appendingPathComponent("app.pid"))
    }

    private func every(_ s: TimeInterval, _ f: @escaping () -> Void) {
        let t = Timer(timeInterval: s, repeats: true) { _ in f() }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    private func tick() {
        tracker.drainEvents()
        let s = tracker.status()
        // The seconds field ticks; only push when something else changed.
        let key = s.split(separator: "|", omittingEmptySubsequences: false).enumerated().filter { $0.offset != 2 }.map { String($0.element) }.joined(separator: "|")
        if key != lastStatus {
            lastStatus = key
            link.send(s)
            log("status \(s)")
            refreshMenu()
        }
    }

    private func scanToday() {
        today.scan()
        tracker.live = today.live
        let d = today.message
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
        link.send(usage.message)
        link.send(tracker.status())
        link.send(today.message)
        if includeFeed { tracker.feed.forEach(link.send) }
    }

    // MARK: Menu

    private func moodText() -> String {
        let f = tracker.status().split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let detail = f.count > 5 && !f[5].isEmpty ? " – \(f[5])" : ""
        switch Int(f[1]) ?? 0 {
        case 1: return "Claude is cooking" + detail
        case 2: return "Claude needs you" + detail
        case 3: return "Claude is done" + detail
        default: return "Claude is napping"
        }
    }

    func refreshMenu() {
        guard let button = item?.button else { return }
        let mood = Int(tracker.status().split(separator: "|")[1]) ?? 0
        let colors: [NSColor] = [.secondaryLabelColor, NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1), .systemOrange, .systemGreen]
        let title = NSMutableAttributedString(string: "✻", attributes: [.foregroundColor: link.connected ? colors[mood] : NSColor.tertiaryLabelColor,
                                                                         .font: NSFont.systemFont(ofSize: 15, weight: .bold)])
        button.attributedTitle = title
        button.toolTip = "Claude Buddy"

        let menu = NSMenu()
        func info(_ s: String) { let m = NSMenuItem(title: s, action: nil, keyEquivalent: ""); m.isEnabled = false; menu.addItem(m) }
        info("Device: \(link.status)")
        info(moodText())
        info(usage.summary)
        info(today.summary)
        if let why = Hooks.blockedBySettings {
            info("Limited view: \(why)")
            info("    (no \"Your turn\" alerts; activity comes from transcripts)")
        } else if tracker.hooklessActive > 0 {
            info("Restart Claude sessions opened before Claude Buddy for full detail")
        }
        if claudeDirs.count > 1 {
            info("Claude folders: " + claudeDirs.map { $0.path.replacingOccurrences(of: home.path, with: "~") }.joined(separator: ", "))
        }
        menu.addItem(.separator())
        let hooks = NSMenuItem(title: "Watch Claude Code (hooks)", action: #selector(toggleHooks), keyEquivalent: "")
        hooks.state = Hooks.installed ? .on : .off
        hooks.target = self
        menu.addItem(hooks)
        if #available(macOS 13.0, *) {
            let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            login.target = self
            menu.addItem(login)
        }
        let refresh = NSMenuItem(title: "Refresh Usage Now", action: #selector(refreshUsage), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let showLog = NSMenuItem(title: "Show Log", action: #selector(openLog), keyEquivalent: "")
        showLog.target = self
        menu.addItem(showLog)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Buddy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    @objc func toggleHooks() {
        do { if Hooks.installed { try Hooks.uninstall() } else { try Hooks.install() } }
        catch { log("hooks: \(error.localizedDescription)") }
        refreshMenu()
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
    @objc func openLog() { NSWorkspace.shared.open(logURL) }
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
