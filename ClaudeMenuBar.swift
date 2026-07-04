import AppKit
import Foundation
import UserNotifications

// MARK: - Models

struct Session: Decodable {
    let pid: Int
    let sessionId: String
    let cwd: String
    let startedAt: Double
    let status: String?
}

struct LimitScope: Decodable {
    struct ModelInfo: Decodable {
        let displayName: String?
        enum CodingKeys: String, CodingKey { case displayName = "display_name" }
    }
    let model: ModelInfo?
}

struct Limit: Decodable {
    let kind: String
    let group: String
    let percent: Int
    let resetsAt: String?
    let scope: LimitScope?
    enum CodingKeys: String, CodingKey {
        case kind, group, percent, scope
        case resetsAt = "resets_at"
    }
}

struct UsageResponse: Decodable {
    let limits: [Limit]
}

struct UsageEntry {
    let label: String
    let pct: Int
    let resetsAt: Date?
}

struct UsageData {
    let session: UsageEntry
    let weekly: [UsageEntry]
}

struct ModelInfo {
    let lastUsed: String?
    let mostUsed: String?
}

struct AccountInfo {
    let plan: String
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var refreshTimer: Timer?
    var usageTimer: Timer?
    var previousStatuses: [String: String] = [:]
    var usage: UsageData? = nil
    var modelInfo: ModelInfo? = nil
    var accountInfo: AccountInfo? = nil
    var previousSessionPct: Int = 0
    var modelTimer: Timer?
    let notifyThresholds = [25, 50, 75, 90]

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refresh()
        fetchUsage()
        fetchModelInfo()
        fetchAccountInfo()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15,  repeats: true) { [weak self] _ in self?.refresh() }
        usageTimer   = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.fetchUsage() }
        modelTimer   = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.fetchModelInfo() }
    }

    // MARK: - Keychain + API

    func fetchUsage() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let token = self?.readKeychainToken() else { return }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.timeoutInterval = 10
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let data,
                      let resp = try? JSONDecoder().decode(UsageResponse.self, from: data) else { return }
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                func date(_ s: String?) -> Date? { s.flatMap { iso.date(from: $0) } }

                let sessionLimit = resp.limits.first { $0.group == "session" }
                let weeklyLimits = resp.limits.filter { $0.group == "weekly" }

                let session = UsageEntry(
                    label:    "5h セッション",
                    pct:      sessionLimit?.percent ?? 0,
                    resetsAt: date(sessionLimit?.resetsAt)
                )
                let weekly = weeklyLimits.map { l -> UsageEntry in
                    let name = l.scope?.model?.displayName ?? "週間"
                    let label = name == "週間" ? "週間" : "週間 \(name)"
                    return UsageEntry(label: label, pct: l.percent, resetsAt: date(l.resetsAt))
                }
                let parsed = UsageData(session: session, weekly: weekly)
                DispatchQueue.main.async {
                    self?.checkUsageThresholds(newPct: parsed.session.pct)
                    self?.usage = parsed
                    self?.refresh()
                }
            }.resume()
        }
    }

    func readKeychainToken() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-a", NSUserName(), "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        return token
    }

    // MARK: - Sessions

    func loadSessions() -> [Session] {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Session.self, from: Data(contentsOf: $0)) }
            .filter { kill(pid_t($0.pid), 0) == 0 }
            .sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Launch at Login

    var launchAgentPlistPath: String {
        "\(NSHomeDirectory())/Library/LaunchAgents/com.kota.claude-menu-bar.plist"
    }

    var isLaunchAtLoginEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentPlistPath)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            let binary = Bundle.main.executablePath ?? (Bundle.main.bundlePath + "/Contents/MacOS/ClaudeMenuBar")
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
              "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key><string>com.kota.claude-menu-bar</string>
              <key>ProgramArguments</key>
              <array>
                <string>\(binary)</string>
              </array>
              <key>RunAtLoad</key><true/>
              <key>KeepAlive</key><true/>
            </dict>
            </plist>
            """
            try? plist.write(toFile: launchAgentPlistPath, atomically: true, encoding: .utf8)
            runLaunchctl(["load", launchAgentPlistPath])
        } else {
            runLaunchctl(["unload", launchAgentPlistPath])
            try? FileManager.default.removeItem(atPath: launchAgentPlistPath)
        }
    }

    func runPython(_ script: String) -> String? {
        let candidates = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
        guard let exe = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-c", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func runLaunchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: - Account Info

    func fetchAccountInfo() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let token = self?.readKeychainToken() else { return }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/account")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.timeoutInterval = 10
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let memberships = json["memberships"] as? [[String: Any]] else { return }
                var tier = "Free"
                for m in memberships {
                    guard let org = m["organization"] as? [String: Any],
                          let t = org["rate_limit_tier"] as? String else { continue }
                    let mapped = Self.mapTier(t)
                    if Self.tierRank(mapped) > Self.tierRank(tier) { tier = mapped }
                }
                DispatchQueue.main.async {
                    self?.accountInfo = AccountInfo(plan: tier)
                    self?.buildMenu(sessions: self?.loadSessions() ?? [])
                }
            }.resume()
        }
    }

    static func mapTier(_ raw: String) -> String {
        switch raw {
        case "auto_trust_tier_a", "auto_trust_tier_b": return "Max"
        case "default_claude_ai":                       return "Pro"
        case "free_claude_ai":                          return "Free"
        default:                                        return raw
        }
    }

    static func tierRank(_ t: String) -> Int {
        switch t {
        case "Max":  return 3
        case "Pro":  return 2
        case "Free": return 1
        default:     return 0
        }
    }

    // MARK: - Model Info

    func fetchModelInfo() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let lastScript = """
import os, json, glob, pathlib
pp = pathlib.Path.home() / '.claude' / 'projects'
files = sorted(glob.glob(str(pp / '**' / '*.jsonl'), recursive=True), key=os.path.getmtime, reverse=True)
last = None
for f in files[:10]:
    try:
        lines = open(f, errors='ignore').readlines()
        for l in reversed(lines[-300:]):
            try:
                d = json.loads(l)
                m = d.get('message', {})
                if isinstance(m, dict) and m.get('model'):
                    last = m['model']
                    break
            except: pass
    except: pass
    if last: break
print(last or '')
"""
            let topScript = """
import json, glob, pathlib, re
pp = pathlib.Path.home() / '.claude' / 'projects'
c = {}
for f in glob.glob(str(pp / '**' / '*.jsonl'), recursive=True):
    try:
        for l in open(f, errors='ignore'):
            m = re.search(r'"model":\\s*"([^"]+)"', l)
            if m: c[m.group(1)] = c.get(m.group(1), 0) + 1
    except: pass
print(max(c, key=c.get) if c else '')
"""
            let last = self?.runPython(lastScript)
            let top  = self?.runPython(topScript)
            DispatchQueue.main.async {
                self?.modelInfo = ModelInfo(
                    lastUsed: last.flatMap { $0.isEmpty ? nil : $0 },
                    mostUsed: top.flatMap  { $0.isEmpty ? nil : $0 }
                )
                self?.buildMenu(sessions: self?.loadSessions() ?? [])
            }
        }
    }

    // MARK: - Threshold Notifications

    func checkUsageThresholds(newPct: Int) {
        for t in notifyThresholds where previousSessionPct < t && newPct >= t {
            let resetStr = usage?.session.resetsAt.map { "（\(formatTimeUntil($0))）" } ?? ""
            notify(title: "Claude Code 使用量 \(t)% 超過",
                   body: "5時間セッション: \(newPct)% 使用済み\(resetStr)")
        }
        previousSessionPct = newPct
    }

    func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: - Formatting

    func adaptiveColor(dark: CGFloat, light: CGFloat) -> NSColor {
        NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: dark,  alpha: 1)
                : NSColor(white: light, alpha: 1)
        }
    }

    func formatDuration(fromMs ms: Double) -> String {
        let s = Int((Date().timeIntervalSince1970 * 1000 - ms) / 1000)
        guard s >= 0 else { return "0s" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s/60)m" }
        let m = (s % 3600) / 60
        return m > 0 ? "\(s/3600)h \(m)m" : "\(s/3600)h"
    }

    func formatTimeUntil(_ date: Date) -> String {
        let s = Int(date.timeIntervalSinceNow)
        guard s > 0 else { return "まもなくリセット" }
        if s < 3600 { return "\(s/60)分後にリセット" }
        let m = (s % 3600) / 60
        return m > 0 ? "\(s/3600)時間\(m)分後にリセット" : "\(s/3600)時間後にリセット"
    }

    func formatModelName(_ raw: String) -> String {
        let s = raw
            .replacingOccurrences(of: "us.anthropic.", with: "")
            .replacingOccurrences(of: "claude-", with: "")
        let parts = s.split(separator: "-")
        guard let first = parts.first else { return raw }
        let name = first.capitalized
        let verParts = parts.dropFirst().prefix(2).filter { $0.allSatisfy(\.isNumber) }
        let ver = verParts.isEmpty ? "" : " \(verParts.joined(separator: "."))"
        return "\(name)\(ver)"
    }

    func usageColor(pct: Int) -> NSColor {
        if pct >= 90 { return NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1) }
        if pct >= 75 { return NSColor(red: 1.0, green: 0.45, blue: 0.0, alpha: 1) }
        if pct >= 50 { return NSColor(red: 1.0, green: 0.75, blue: 0.0, alpha: 1) }
        return NSColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1)
    }

    // MARK: - Donut Icon

    func makeDonutIcon(sessionPct: Int, weeklyPct: Int) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let ctx = NSGraphicsContext.current!.cgContext
            let cx = rect.midX, cy = rect.midY
            let outerR: CGFloat = 7.5
            let ringW: CGFloat = 2.8
            let innerR: CGFloat = outerR - ringW - 1.2
            let start = CGFloat.pi / 2   // 12 o'clock

            func drawRing(radius: CGFloat, pct: Int, color: NSColor) {
                // Background track
                ctx.setLineWidth(ringW)
                ctx.setLineCap(.round)
                ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
                ctx.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                           startAngle: 0, endAngle: .pi * 2, clockwise: false)
                ctx.strokePath()

                // Fill arc
                guard pct > 0 else { return }
                let end = start - CGFloat(pct) / 100.0 * .pi * 2
                ctx.setStrokeColor(color.cgColor)
                ctx.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                           startAngle: start, endAngle: end, clockwise: true)
                ctx.strokePath()
            }

            drawRing(radius: outerR - ringW/2, pct: sessionPct, color: self.usageColor(pct: sessionPct))
            drawRing(radius: innerR - ringW/2, pct: weeklyPct,  color: self.usageColor(pct: weeklyPct))
            return true
        }
    }

    // MARK: - Refresh

    func refresh() {
        let sessions = loadSessions()
        checkStatusChanges(sessions: sessions)
        updateIcon(sessions: sessions)
        buildMenu(sessions: sessions)
    }

    func checkStatusChanges(sessions: [Session]) {
        for s in sessions {
            let curr = s.status ?? "unknown"
            if let prev = previousStatuses[s.sessionId], prev != curr, curr == "idle" {
                notify(title: "Claude Code — idle",
                       body: "\(URL(fileURLWithPath: s.cwd).lastPathComponent) がタスクを完了しました")
            }
            previousStatuses[s.sessionId] = curr
        }
        let ids = Set(sessions.map { $0.sessionId })
        previousStatuses = previousStatuses.filter { ids.contains($0.key) }
    }

    // MARK: - Icon / Title

    func updateIcon(sessions: [Session]) {
        guard let btn = statusItem.button else { return }
        if let u = usage {
            let weeklyPct = u.weekly.first { !$0.label.contains(" ") || $0.label == "週間" }?.pct ?? u.weekly.first?.pct ?? 0
            let icon = makeDonutIcon(sessionPct: u.session.pct, weeklyPct: weeklyPct)
            btn.image = icon
            btn.imagePosition = .imageOnly
            btn.title = ""
            btn.contentTintColor = nil
        } else {
            btn.image = nil
            let busy = sessions.filter { $0.status == "busy" }.count
            btn.title = busy > 0 ? "CC \(busy)" : "CC"
            btn.contentTintColor = busy > 0
                ? NSColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1) : nil
        }
    }

    // MARK: - Menu

    func buildMenu(sessions: [Session]) {
        let menu = NSMenu()

        // Usage
        if let u = usage {
            addHeader(to: menu, text: "Usage")
            addUsageRow(to: menu, label: u.session.label, pct: u.session.pct, resetsAt: u.session.resetsAt)
            for w in u.weekly {
                addUsageRow(to: menu, label: w.label, pct: w.pct, resetsAt: w.resetsAt)
            }
            menu.addItem(.separator())
        }

        // Model
        if modelInfo?.lastUsed != nil || modelInfo?.mostUsed != nil {
            addModelRow(to: menu)
            menu.addItem(.separator())
        }

        // Sessions
        addHeader(to: menu, text: "Sessions")
        if sessions.isEmpty {
            let item = NSMenuItem()
            item.attributedTitle = NSAttributedString(
                string: "  No active sessions",
                attributes: [.foregroundColor: NSColor.tertiaryLabelColor])
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for s in sessions { addSessionRow(to: menu, session: s) }
        }

        menu.addItem(.separator())

        // Launch at Login toggle
        let loginItem = NSMenuItem(
            title: isLaunchAtLoginEnabled ? "✓ ログイン時に起動" : "  ログイン時に起動",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(manualRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func addHeader(to menu: NSMenu, text: String) {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: adaptiveColor(dark: 0.82, light: 0.20)
        ])
        item.isEnabled = false
        menu.addItem(item)
    }

    func addUsageRow(to menu: NSMenu, label: String, pct: Int, resetsAt: Date?) {
        let bar = String(repeating: "█", count: max(0, pct * 14 / 100))
            + String(repeating: "░", count: max(0, 14 - pct * 14 / 100))
        let color = usageColor(pct: pct)

        let item = NSMenuItem()
        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: "  \(bar) ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: color
        ]))
        attr.append(NSAttributedString(string: "\(pct)%", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]))
        attr.append(NSAttributedString(string: "  \(label)", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: adaptiveColor(dark: 0.78, light: 0.25)
        ]))
        item.attributedTitle = attr
        item.isEnabled = false
        menu.addItem(item)

        if let d = resetsAt {
            let sub = NSMenuItem()
            sub.attributedTitle = NSAttributedString(
                string: "     \(formatTimeUntil(d))",
                attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: adaptiveColor(dark: 0.72, light: 0.32)])
            sub.isEnabled = false
            menu.addItem(sub)
        }
    }

    func addModelRow(to menu: NSMenu) {
        guard let m = modelInfo, m.lastUsed != nil || m.mostUsed != nil else { return }
        let item = NSMenuItem()
        let attr = NSMutableAttributedString()
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: adaptiveColor(dark: 0.72, light: 0.32)
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        if let plan = accountInfo?.plan {
            attr.append(NSAttributedString(string: "  Plan  ", attributes: labelAttrs))
            attr.append(NSAttributedString(string: plan, attributes: valueAttrs))
            attr.append(NSAttributedString(string: "   ", attributes: labelAttrs))
        }
        if let last = m.lastUsed {
            attr.append(NSAttributedString(string: "Last  ", attributes: labelAttrs))
            attr.append(NSAttributedString(string: formatModelName(last), attributes: valueAttrs))
            if m.mostUsed == last {
                attr.append(NSAttributedString(string: "  (most used)", attributes: labelAttrs))
            }
        }
        if let top = m.mostUsed, top != m.lastUsed {
            attr.append(NSAttributedString(string: "   Top  ", attributes: labelAttrs))
            attr.append(NSAttributedString(string: formatModelName(top), attributes: valueAttrs))
        }
        item.attributedTitle = attr
        item.isEnabled = false
        menu.addItem(item)
    }

    func addSessionRow(to menu: NSMenu, session: Session) {
        let name = URL(fileURLWithPath: session.cwd).lastPathComponent
        let dur  = formatDuration(fromMs: session.startedAt)
        let dot  = session.status == "busy" ? "●" : "○"
        let dotColor: NSColor = session.status == "busy"
            ? NSColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1)
            : NSColor.secondaryLabelColor

        let item = NSMenuItem()
        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: "  \(dot) ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: dotColor
        ]))
        attr.append(NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]))
        attr.append(NSAttributedString(string: "  \(dur)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: adaptiveColor(dark: 0.72, light: 0.32)
        ]))
        item.attributedTitle = attr
        item.isEnabled = false
        menu.addItem(item)
        menu.addItem(.separator())
    }

    // MARK: - Actions

    @objc func toggleLaunchAtLogin() {
        setLaunchAtLogin(!isLaunchAtLoginEnabled)
        buildMenu(sessions: loadSessions())
    }

    @objc func manualRefresh() { refresh(); fetchUsage() }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
