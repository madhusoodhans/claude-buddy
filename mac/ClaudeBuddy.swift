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
import ServiceManagement

// MARK: - Paths and helpers

let home = FileManager.default.homeDirectoryForCurrentUser
let buddyDir = home.appendingPathComponent(".claude-buddy")
let claudeDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
    ?? home.appendingPathComponent(".claude")
let eventsURL = buddyDir.appendingPathComponent("events.log")
let logURL = buddyDir.appendingPathComponent("buddy.log")

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
    static var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }

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

    static func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ClaudeBuddy", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(settingsURL.path) isn't a JSON object"])
        }
        return root
    }

    static func ours(_ entry: Any) -> Bool {
        let hooks = (entry as? [String: Any])?["hooks"] as? [[String: Any]] ?? []
        return hooks.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    static var installed: Bool {
        guard let root = try? loadSettings(), let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { ev in (hooks[ev] as? [Any])?.contains(where: ours) == true }
            && FileManager.default.fileExists(atPath: script.path)
    }

    static func save(_ root: [String: Any]) throws {
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let backup = claudeDir.appendingPathComponent("settings.json.before-claude-buddy")
        if FileManager.default.fileExists(atPath: settingsURL.path),
           !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Adds our hook to each event, keeping everything else in settings.json as it was.
    static func install() throws {
        try scriptText.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var root = try loadSettings()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for ev in events {
            var list = (hooks[ev] as? [Any] ?? []).filter { !ours($0) }
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
            if toolEvents.contains(ev) { entry["matcher"] = "*" }
            list.append(entry)
            hooks[ev] = list
        }
        root["hooks"] = hooks
        try save(root)
        log("installed Claude Code hooks in \(settingsURL.path)")
    }

    static func uninstall() throws {
        var root = try loadSettings()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (ev, value) in hooks {
            let list = (value as? [Any] ?? []).filter { !ours($0) }
            if list.isEmpty { hooks[ev] = nil } else { hooks[ev] = list }
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try save(root)
        log("removed Claude Code hooks")
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
        let rank: [Mood: Int] = [.waiting: 3, .working: 2, .done: 1, .idle: 0]
        guard let top = sessions.values.max(by: { (rank[$0.mood]!, $0.last) < (rank[$1.mood]!, $1.last) }) else {
            return "S|0|0|0||"
        }
        let start = top.mood == .working ? (top.turnStart ?? top.since) : top.since
        return "S|\(top.mood.rawValue)|\(Int(now.timeIntervalSince(start)))|\(sessions.count)|\(top.project)|\(top.detail)"
    }

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

final class UsagePoller {
    var message = "U|0|0|-1|0|-1||0|Asking Claude for usage"
    var summary = "Usage: waiting"
    private var fetchedAt: Date?
    private var reading: (s: Int, sr: Date?, w: Int, wr: Date?, plan: String)?
    private var note = ""
    private var nextAllowed = Date.distantPast
    private var inFlight = false
    var onChange: (() -> Void)?

    struct Token { let access: String; let expires: Date?; let plan: String }

    static func readToken() -> Token? {
        var blobs: [String] = []
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0, let s = String(data: data, encoding: .utf8) { blobs.append(s) }
        }
        if let s = try? String(contentsOf: claudeDir.appendingPathComponent(".credentials.json")) { blobs.append(s) }
        var found: [Token] = []
        for blob in blobs {
            guard let v = try? JSONSerialization.jsonObject(with: Data(blob.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) as? [String: Any]
            else { continue }
            let o = v["claudeAiOauth"] as? [String: Any] ?? v
            guard let access = o["accessToken"] as? String, !access.isEmpty else { continue }
            let exp = (o["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            found.append(Token(access: access, expires: exp, plan: (o["subscriptionType"] as? String ?? "").capitalized))
        }
        return found.first { ($0.expires ?? .distantFuture) > Date().addingTimeInterval(60) } ?? found.first
    }

    func poll(force: Bool = false) {
        guard !inFlight, Date() >= nextAllowed else { return }
        if !force, let f = fetchedAt, Date().timeIntervalSince(f) < 170 { return }
        guard let token = UsagePoller.readToken() else {
            fail("Sign in to Claude Code on this Mac")
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
        req.setValue("claude-buddy/1.0", forHTTPHeaderField: "User-Agent")
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
                self.parse(v, plan: token.plan)
            }
        }.resume()
    }

    private func parse(_ v: [String: Any], plan: String) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        func window(_ key: String) -> (Int, Date?) {
            guard let w = v[key] as? [String: Any] else { return (0, nil) }
            let pct = Int(((w["utilization"] as? Double) ?? 0).rounded())
            let reset = (w["resets_at"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
            return (pct, reset)
        }
        let s = window("five_hour"), w = window("seven_day")
        reading = (s.0, s.1, w.0, w.1, plan)
        fetchedAt = Date()
        note = ""
        log("usage: session \(s.0)% weekly \(w.0)%")
        rebuild()
    }

    private func fail(_ why: String) {
        note = why
        log("usage: \(why)")
        rebuild()
    }

    /// Rebuilt each send so the ages and reset countdowns stay current.
    func rebuild() {
        let now = Date()
        func minutes(_ d: Date?) -> Int { d.map { max(0, Int($0.timeIntervalSince(now) / 60)) } ?? -1 }
        if let r = reading, let at = fetchedAt {
            let age = Int(now.timeIntervalSince(at))
            message = "U|1|\(r.s)|\(minutes(r.sr))|\(r.w)|\(minutes(r.wr))|\(ascii(r.plan, max: 12))|\(age)|\(ascii(note, max: 40))"
            summary = "Session \(r.s)%  ·  Weekly \(r.w)%"
        } else {
            message = "U|0|0|-1|0|-1||0|\(ascii(note.isEmpty ? "Asking Claude for usage" : note, max: 40))"
            summary = note.isEmpty ? "Usage: waiting" : "Usage: \(note)"
        }
        onChange?()
    }
}

// MARK: - Today's stats, from Claude Code transcripts

final class TodayScanner {
    private var day = Calendar.current.startOfDay(for: Date())
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
        let root = claudeDir.appendingPathComponent("projects")
        guard let it = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return }
        for case let url as URL in it where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let mod = values?.contentModificationDate, mod >= day, let size = values?.fileSize else { continue }
            let from = offsets[url.path] ?? 0
            if UInt64(size) <= from { continue }
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            h.seek(toFileOffset: from)
            let data = h.readDataToEndOfFile()
            try? h.close()
            guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { continue }
            let session = url.deletingPathExtension().lastPathComponent
            for line in data[..<lastNewline].split(separator: UInt8(ascii: "\n")) { process(Data(line), session: session) }
            offsets[url.path] = from + UInt64(lastNewline + 1)
        }
        firstScan = false
    }

    private static func lineCount(_ s: String?) -> Int {
        guard let s = s, !s.isEmpty else { return 0 }
        return s.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private func process(_ line: Data, session: String) {
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
                if !firstScan && Date().timeIntervalSince(ts) < 120 { onInterrupt?(session) }
                return
            }
            guard o["isMeta"] as? Bool != true, let text = texts.first, !text.hasPrefix("<"),
                  o["isSidechain"] as? Bool != true else { return }
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
            for item in content as? [[String: Any]] ?? [] where item["type"] as? String == "tool_use" {
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
        log("Claude Buddy started (pid \(getpid()))")
        if !Hooks.installed || (try? String(contentsOf: Hooks.script)) != Hooks.scriptText {
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
