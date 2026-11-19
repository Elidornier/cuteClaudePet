// 小 Claude (ApprovalPet) — the Claude Code pixel crab as a desktop pet; it hops and waves when Claude Code needs your approval.
//
//   ApprovalPet               run the pet (normally launched for you via `open`)
//   ApprovalPet hook          Claude Code hook entry point (reads the hook JSON on stdin)
//   ApprovalPet demo          fake an approval request for a few seconds
//   ApprovalPet demo-done     fake a "chat finished" reminder for a few seconds
//   ApprovalPet clear         forget every pending request
//   ApprovalPet snapshot F    render a preview strip of every mood into PNG file F

import AppKit
import Foundation

// MARK: - Shared state on disk

let fm = FileManager.default
let baseDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/approval-pet", isDirectory: true)
let pendingDir = baseDir.appendingPathComponent("pending", isDirectory: true)
let activityFile = baseDir.appendingPathComponent("activity")
let logFile = baseDir.appendingPathComponent("events.log")
let petBundleID = "local.claude.approval-pet"
let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

/// One file per (session, agent) that is currently waiting on the user.
struct Pending: Codable {
    var session: String
    var agent: String?
    var kind: String          // permission | question | plan
    var tool: String?
    var digest: String?       // tool name + input, to match the PostToolUse that resolves it
    var toolUseId: String?
    var app: String?          // bundle id of the app hosting that Claude session
    var project: String?
    var time: Double
    var host: String? = nil   // Claude desktop chat id (local_…), used to jump straight to that chat
}

func now() -> Double { Date().timeIntervalSince1970 }

func safeName(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.map {
        (CharacterSet.alphanumerics.contains($0) || $0 == "-") ? $0 : "_"
    }))
}

func slotURL(session: String, agent: String?) -> URL {
    pendingDir.appendingPathComponent("\(safeName(session))__\(safeName(agent ?? "main")).json")
}

func readPending(_ url: URL) -> Pending? {
    guard let d = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Pending.self, from: d)
}

func writePending(_ p: Pending, to url: URL) {
    guard let d = try? JSONEncoder().encode(p) else { return }
    try? d.write(to: url, options: .atomic)
}

func allPending() -> [(URL, Pending)] {
    guard let items = try? fm.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil) else { return [] }
    return items.filter { $0.pathExtension == "json" }.compactMap { u in readPending(u).map { (u, $0) } }
}

func clearSession(_ session: String, keepDone: Bool = false) {
    let prefix = safeName(session) + "__"
    for (u, p) in allPending() where u.lastPathComponent.hasPrefix(prefix) && !(keepDone && p.kind == "done") {
        try? fm.removeItem(at: u)
    }
}

func doneURL(_ session: String) -> URL {
    pendingDir.appendingPathComponent("\(safeName(session))__done.json")
}

func clearAllPending() {
    for (u, _) in allPending() { try? fm.removeItem(at: u) }
}

func fnv(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return String(h, radix: 16)
}

func digestOf(tool: String?, input: Any?) -> String? {
    guard let tool else { return nil }
    var s = tool
    if let input, JSONSerialization.isValidJSONObject(input),
       let d = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) {
        s += "|" + (String(data: d, encoding: .utf8) ?? "")
    }
    return fnv(s)
}

func toolFromMessage(_ m: String) -> String? {
    guard let r = m.range(of: #"use [A-Za-z0-9_\-]+"#, options: .regularExpression) else { return nil }
    return String(m[r].dropFirst(4))
}

func projectName(_ cwd: String?) -> String? {
    guard let cwd, !cwd.isEmpty else { return nil }
    if cwd == fm.homeDirectoryForCurrentUser.path { return nil }
    let name = (cwd as NSString).lastPathComponent
    if name.isEmpty || name == "/" || name.hasPrefix("scratch-") { return nil }
    return name
}

func logLine(_ s: String) {
    if let size = (try? fm.attributesOfItem(atPath: logFile.path))?[.size] as? Int, size > 256_000 {
        try? fm.removeItem(at: logFile)
    }
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: logFile) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: logFile)
    }
}

func ensurePetRunning() {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: petBundleID)
        .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
    if !others.isEmpty { return }
    let bundleURL = Bundle.main.bundleURL
    guard bundleURL.pathExtension == "app" else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", bundleURL.path]
    try? p.run()
    p.waitUntilExit()
}

// MARK: - Hook entry point

func runHook() -> Int32 {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return 0 }
    try? fm.createDirectory(at: pendingDir, withIntermediateDirectories: true)
    try? Data().write(to: activityFile)   // "Claude is doing something" — keeps the pet awake

    let event = obj["hook_event_name"] as? String ?? "?"
    let session = obj["session_id"] as? String ?? "unknown"
    let agent = obj["agent_id"] as? String
    let tool = obj["tool_name"] as? String
    let input = obj["tool_input"]
    let toolUseId = obj["tool_use_id"] as? String
    let ntype = obj["notification_type"] as? String ?? ""
    let message = obj["message"] as? String ?? ""
    let app = ProcessInfo.processInfo.environment["__CFBundleIdentifier"]
    let host = ProcessInfo.processInfo.environment["CLAUDE_CODE_HOST_SESSION_ID"]
    let slot = slotURL(session: session, agent: agent)

    logLine("\(event) tool=\(tool ?? "-") ntype=\(ntype.isEmpty ? "-" : ntype) agent=\(agent ?? "-") session=\(session.prefix(8)) host=\(host ?? "-") app=\(app ?? "-")")

    var raised = false
    func raise(_ kind: String, _ toolName: String?, keepExisting: Bool = false) {
        if keepExisting && fm.fileExists(atPath: slot.path) { return }
        var k = kind
        if toolName == "AskUserQuestion" { k = "question" } else if toolName == "ExitPlanMode" { k = "plan" }
        let p = Pending(session: session, agent: agent, kind: k, tool: toolName,
                        digest: digestOf(tool: tool, input: input), toolUseId: toolUseId,
                        app: app, project: projectName(obj["cwd"] as? String), time: now(), host: host)
        writePending(p, to: slot)
        raised = true
    }

    switch event {
    case "PermissionRequest":
        raise("permission", tool)
    case "Notification":
        if ntype == "permission_prompt" || (ntype.isEmpty && message.lowercased().contains("permission")) {
            raise("permission", toolFromMessage(message), keepExisting: true)
        } else if ntype == "elicitation_dialog" {
            raise("question", nil, keepExisting: true)
        }
    case "PreToolUse":
        if tool == "AskUserQuestion" || tool == "ExitPlanMode" { raise("question", tool) }
    case "PostToolUse", "PostToolUseFailure":
        if let p = readPending(slot) {
            let d = digestOf(tool: tool, input: input)
            let same = (p.toolUseId != nil && p.toolUseId == toolUseId)
                || (p.digest != nil && p.digest == d)
                || (p.digest == nil && p.tool == tool)
            // A different tool finishing well after the request means Claude moved on (e.g. you said no).
            if same || now() - p.time > 8 { try? fm.removeItem(at: slot) }
        }
    case "PermissionDenied":
        try? fm.removeItem(at: slot)
    case "SubagentStop":
        if agent != nil { try? fm.removeItem(at: slot) }
    case "UserPromptSubmit", "StopFailure":
        clearSession(session)
    case "SessionEnd":
        clearSession(session, keepDone: true)
    case "Stop":
        // the chat finished its turn: drop its approval requests, leave a "done" note
        clearSession(session)
        let p = Pending(session: session, agent: nil, kind: "done", tool: nil, digest: nil, toolUseId: nil,
                        app: app, project: projectName(obj["cwd"] as? String), time: now(), host: host)
        writePending(p, to: doneURL(session))
        raised = true
    default:
        break
    }

    if raised || event == "SessionStart" { ensurePetRunning() }
    return 0
}

// MARK: - Look & feel

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let petColor = rgb(0xD97757)    // Claude orange
let eyeInk = rgb(0x1E1A18)
let ink = rgb(0x3A2620)
let subInk = rgb(0x8A6F66)
let accent = rgb(0xD9623F)
let mouthRed = rgb(0x9A3434)
let blushColor = rgb(0xF4A391)
let bubbleFill = rgb(0xFFFDFB)

func roundedFont(_ size: CGFloat, _ w: NSFont.Weight) -> NSFont {
    let f = NSFont.systemFont(ofSize: size, weight: w)
    if let d = f.fontDescriptor.withDesign(.rounded), let r = NSFont(descriptor: d, size: size) { return r }
    return f
}

enum Mood { case idle, sleepy, alert, done, happy, petted }

typealias Line = (text: String, font: NSFont, color: NSColor)

func wantPhrase(_ tool: String?) -> String? {
    guard let tool else { return nil }
    switch tool {
    case "Bash": return "想跑个命令"
    case "Write": return "想写个文件"
    case "Edit", "MultiEdit": return "想改个文件"
    case "NotebookEdit": return "想改笔记本"
    case "Read": return "想读个文件"
    case "WebFetch": return "想打开网页"
    case "WebSearch": return "想上网搜搜"
    case "AskUserQuestion", "ExitPlanMode": return nil
    default:
        if tool.hasPrefix("mcp__") { return "想用 " + (tool.components(separatedBy: "__").last ?? tool) }
        return "想用 " + tool
    }
}

func bubbleLines(mood: Mood, pendings: [Pending], dones: [Pending], pettedLine: String) -> [Line] {
    let titleF = roundedFont(13.5, .bold)
    let subF = roundedFont(11.5, .medium)
    let hintF = roundedFont(10.5, .semibold)
    switch mood {
    case .alert:
        guard let first = pendings.first else { return [] }
        var lines: [Line] = []
        if pendings.count == 1 {
            let title: String
            switch first.kind {
            case "question": title = "Claude 有事想问你！"
            case "plan": title = "计划写好啦，等你批准！"
            default: title = "Claude 需要你批准！"
            }
            lines.append(("✋ " + title, titleF, ink))
            var sub: [String] = []
            if first.kind == "permission", let w = wantPhrase(first.tool) { sub.append(w) }
            if let p = first.project { sub.append(p) }
            if !sub.isEmpty { lines.append((sub.joined(separator: " · "), subF, subInk)) }
        } else {
            lines.append(("✋ 有 \(pendings.count) 件事等你批准！", titleF, ink))
            let projects = Array(Set(pendings.compactMap { $0.project })).sorted()
            if !projects.isEmpty { lines.append((projects.joined(separator: "、"), subF, subInk)) }
        }
        let oldest = pendings.map(\.time).min() ?? now()
        let waited = Int(now() - oldest) / 60
        lines.append((waited >= 1 ? "已经等了 \(waited) 分钟 · 点我过去 →" : "点我过去 →", hintF, accent))
        return lines
    case .done:
        guard !dones.isEmpty else { return [] }
        var lines: [Line] = []
        if dones.count == 1 {
            lines.append(("✅ Claude 做完啦！", titleF, ink))
            if let p = dones[0].project { lines.append((p, subF, subInk)) }
        } else {
            lines.append(("✅ 有 \(dones.count) 个对话做完啦！", titleF, ink))
            let projects = Array(Set(dones.compactMap { $0.project })).sorted()
            if !projects.isEmpty { lines.append((projects.joined(separator: "、"), subF, subInk)) }
        }
        let mins = Int(now() - (dones.map(\.time).max() ?? now())) / 60
        lines.append((mins >= 1 ? "\(mins) 分钟前 · 点我去看看 →" : "点我去看看 →", hintF, accent))
        return lines
    case .happy:
        return [("谢谢你～ ♪", titleF, ink)]
    case .petted:
        return [(pettedLine, titleF, ink)]
    case .idle, .sleepy:
        return []
    }
}

// MARK: - The pet view

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PetView: NSView {
    var t: Double = 0
    var mood: Mood = .idle
    var moodStart: Double = 0
    var alertKick: Double = 0
    var doneKick: Double = 0
    var bubble: [Line] = []
    var bubbleStart: Double = 0
    var clearsBackground = true

    var blinkUntil: Double = 0
    var nextBlink: Double = 2.5
    var look: CGFloat = 0
    var lookTarget: CGFloat = 0
    var nextLook: Double = 4

    weak var controller: Controller?
    private var downScreen: NSPoint = .zero
    private var downOrigin: NSPoint = .zero
    private var dragged = false

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func step(_ dt: Double) {
        if t > nextBlink { blinkUntil = t + 0.13; nextBlink = t + Double.random(in: 2.5...5.5) }
        if t > nextLook { lookTarget = [-3, 0, 0, 3].randomElement()!; nextLook = t + Double.random(in: 2...5) }
        look += (lookTarget - look) * CGFloat(min(1, dt * 8))
    }

    // Interaction: click = go approve / pet me, drag = move, right-click = menu.
    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control) { rightMouseDown(with: e); return }
        downScreen = NSEvent.mouseLocation
        downOrigin = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with e: NSEvent) {
        let p = NSEvent.mouseLocation
        let dx = p.x - downScreen.x, dy = p.y - downScreen.y
        if !dragged && hypot(dx, dy) < 3 { return }
        dragged = true
        window?.setFrameOrigin(NSPoint(x: downOrigin.x + dx, y: downOrigin.y + dy))
    }

    override func mouseUp(with e: NSEvent) {
        if e.modifierFlags.contains(.control) { return }
        if dragged { controller?.savePosition() } else { controller?.petClicked() }
    }

    override func rightMouseDown(with e: NSEvent) {
        guard let menu = controller?.makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: e, for: self)
    }

    // MARK: drawing

    func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: x - w / 2, y: y - h / 2, width: w, height: h))
    }

    override func draw(_ dirtyRect: NSRect) {
        if clearsBackground { NSColor.clear.set(); bounds.fill(using: .copy) }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cx = bounds.midX
        let ground: CGFloat = 18
        var hop: CGFloat = 0
        switch mood {
        case .alert:
            let since = max(0, t - alertKick)
            let ph = since.truncatingRemainder(dividingBy: 0.44) / 0.44
            hop = CGFloat(sin(ph * .pi)) * (since < 1.8 ? 24 : 9)
        case .happy, .petted:
            hop = CGFloat(abs(sin((t - moodStart) * 7.5))) * 9
        case .done:
            let since = max(0, t - doneKick)
            if since < 2 { hop = CGFloat(abs(sin(since * 7.5))) * 12 }
            else {
                let c = (since - 2).truncatingRemainder(dividingBy: 5)   // a little hop every 5s
                if c < 0.45 { hop = CGFloat(sin(c / 0.45 * .pi)) * 7 }
            }
        case .idle, .sleepy:
            break
        }
        hop = hop.rounded()

        // ground shadow
        rgb(0x000000, 0.16 * max(0.2, 1 - hop / 60)).setFill()
        oval(cx, ground + 1, 84 * (1 - hop / 70), 9).fill()

        ctx.saveGState()
        ctx.translateBy(x: cx, y: ground + hop)
        drawPet(ctx)
        ctx.restoreGState()

        drawExtras(cx: cx, ground: ground, hop: hop)
        if !bubble.isEmpty { drawBubble(ctx, cx: cx) }
    }

    /// The Claude Code pixel crab, built from its terminal block art
    ///    ▐▛███▜▌
    ///   ▝▜█████▛▘
    ///     ▘▘ ▝▝
    /// One block quadrant = u wide × 2u tall. Local origin = ground point under it, y up.
    func drawPet(_ ctx: CGContext) {
        let u: CGFloat = 6, rowH: CGFloat = 12
        var bodyLift: CGFloat = 0, armL: CGFloat = 0, armR: CGFloat = 0
        var legA: CGFloat = 0, legB: CGFloat = 0
        switch mood {
        case .idle:
            bodyLift = sin(t * 2.2) > 0.3 ? 2 : 0                       // breathing
            if t.truncatingRemainder(dividingBy: 6.5) < 1.0 {             // a little shuffle now and then
                let s = sin(t * 14) > 0; legA = s ? 3 : 0; legB = s ? 0 : 3
            }
        case .sleepy:
            bodyLift = sin(t * 1.3) > 0 ? 0 : -2
        case .alert:
            let s = sin(t * 16) > 0
            armL = s ? 9 : 0; armR = s ? 0 : 9                            // waving both claws
            let l = sin(t * 20) > 0
            legA = l ? 3 : 0; legB = l ? 0 : 3                            // tapping feet
        case .happy, .petted:
            armL = sin((t - moodStart) * 12) > 0 ? 6 : 0; armR = armL
        case .done:
            if t - doneKick < 2 { let s = sin(t * 14) > 0; armL = s ? 9 : 3; armR = s ? 3 : 9 }   // cheering
            else { bodyLift = sin(t * 2.2) > 0.3 ? 2 : 0 }
        }

        let legTop = rowH
        let by = bodyLift
        petColor.setFill()
        // legs: columns 4,6,11,13 (pairs alternate)
        for (col, lift) in [(4, legA), (6, legB), (11, legA), (13, legB)] {
            NSRect(x: CGFloat(col - 9) * u, y: lift, width: u, height: legTop - lift + by + 1).fill()
        }
        // body: columns 3…14, four rows
        NSRect(x: -6 * u, y: legTop + by, width: 12 * u, height: 4 * rowH).fill()
        // arms: row 2, columns 1–2 and 15–16
        NSRect(x: -8 * u, y: legTop + rowH + by + armL, width: 2 * u, height: rowH).fill()
        NSRect(x: 6 * u, y: legTop + rowH + by + armR, width: 2 * u, height: rowH).fill()

        // eyes: row 1, columns 5 and 12
        let eyeMood: Mood = mood == .done ? (t - doneKick < 2 ? .happy : .idle) : mood
        let eyeY = legTop + 2 * rowH + by
        for (i, ex) in [-4 * u, 3 * u].enumerated() {
            let r = NSRect(x: ex, y: eyeY, width: u, height: rowH)
            switch eyeMood {
            case .idle, .done:
                eyeInk.setFill()
                if t < blinkUntil { NSRect(x: ex, y: eyeY + 4.5, width: u, height: 3).fill() } else { r.fill() }
            case .alert:
                eyeInk.setFill(); r.insetBy(dx: -1, dy: -1).fill()
                NSColor.white.setFill(); NSRect(x: ex + u - 3, y: eyeY + rowH - 4, width: 2.5, height: 2.5).fill()
            case .sleepy:
                eyeInk.setFill(); NSRect(x: ex - 1, y: eyeY + 3, width: u + 2, height: 2.5).fill()
            case .happy, .petted:
                eyeInk.setFill()
                // pixel ^ : 5 blocks wide, 3 tall
                let s: CGFloat = 3, x0 = ex + u / 2 - 7.5, y0 = eyeY + 2
                for (bx, byy) in [(2, 2), (1, 1), (3, 1), (0, 0), (4, 0)] {
                    NSRect(x: x0 + CGFloat(bx) * s, y: y0 + CGFloat(byy) * s, width: s, height: s).fill()
                }
            }
            if eyeMood != .idle && eyeMood != .sleepy && eyeMood != .done {
                blushColor.setFill()
                NSRect(x: i == 0 ? ex - u : ex + u, y: eyeY - 1, width: u, height: 3).fill()
            }
        }
        if mood == .alert {
            let o: CGFloat = sin(t * 12) > 0 ? 1 : 0
            mouthRed.setFill(); NSRect(x: -3 - o / 2, y: eyeY + 1, width: 6 + o, height: 4 + o).fill()
        }
    }

    func drawHeart(_ c: NSPoint, _ s: CGFloat, _ color: NSColor) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x, y: c.y - s * 0.45))
        p.curve(to: NSPoint(x: c.x - s * 0.5, y: c.y + s * 0.15),
                controlPoint1: NSPoint(x: c.x - s * 0.2, y: c.y - s * 0.2), controlPoint2: NSPoint(x: c.x - s * 0.5, y: c.y - s * 0.1))
        p.curve(to: NSPoint(x: c.x, y: c.y + s * 0.3),
                controlPoint1: NSPoint(x: c.x - s * 0.5, y: c.y + s * 0.5), controlPoint2: NSPoint(x: c.x - s * 0.05, y: c.y + s * 0.5))
        p.curve(to: NSPoint(x: c.x + s * 0.5, y: c.y + s * 0.15),
                controlPoint1: NSPoint(x: c.x + s * 0.05, y: c.y + s * 0.5), controlPoint2: NSPoint(x: c.x + s * 0.5, y: c.y + s * 0.5))
        p.curve(to: NSPoint(x: c.x, y: c.y - s * 0.45),
                controlPoint1: NSPoint(x: c.x + s * 0.5, y: c.y - s * 0.1), controlPoint2: NSPoint(x: c.x + s * 0.2, y: c.y - s * 0.2))
        color.setFill(); p.fill()
    }

    func drawExtras(cx: CGFloat, ground: CGFloat, hop: CGFloat) {
        switch mood {
        case .sleepy:
            for i in 0..<3 {
                let ph = (t * 0.45 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let x = cx + 30 + CGFloat(ph) * 20 + CGFloat(sin(ph * 6)) * 3
                let y = ground + 64 + CGFloat(ph) * 40
                let a = CGFloat(sin(ph * .pi))
                NSAttributedString(string: "z", attributes: [
                    .font: roundedFont(9 + CGFloat(ph) * 7, .heavy),
                    .foregroundColor: rgb(0x6E6390, a),
                ]).draw(at: NSPoint(x: x, y: y))
            }
        case .happy, .petted:
            let xs: [CGFloat] = [-30, 30, 4]
            for i in 0..<3 {
                let ph = ((t - moodStart) * 0.9 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
                let x = cx + xs[i] + CGFloat(sin(ph * 8 + Double(i))) * 4
                let y = ground + hop + 70 + CGFloat(ph) * 34
                drawHeart(NSPoint(x: x, y: y), 10 + CGFloat(i) * 2, rgb(0xFF5C7A, CGFloat(sin(ph * .pi))))
            }
        case .done:
            let since = t - doneKick
            guard since < 2.2 else { break }
            let xs: [CGFloat] = [-46, 44, -20, 22]
            for i in 0..<4 {
                let ph = min(1, max(0, since / 1.4 - Double(i) * 0.12))
                NSAttributedString(string: "✦", attributes: [
                    .font: roundedFont(10 + CGFloat(i % 2) * 4, .heavy),
                    .foregroundColor: rgb(0xF2B84B, CGFloat(sin(ph * .pi))),
                ]).draw(at: NSPoint(x: cx + xs[i], y: ground + hop + 56 + CGFloat(ph) * 30))
            }
        case .idle, .alert:
            break
        }
    }

    func drawBubble(_ ctx: CGContext, cx: CGFloat) {
        let padX: CGFloat = 12, padY: CGFloat = 8, gap: CGFloat = 2
        let maxW = bounds.width - 12 - padX * 2
        var strs: [NSAttributedString] = []
        var sizes: [NSSize] = []
        for line in bubble {
            let ps = NSMutableParagraphStyle()
            ps.lineBreakMode = .byTruncatingTail
            ps.alignment = .center
            let s = NSAttributedString(string: line.text, attributes: [.font: line.font, .foregroundColor: line.color, .paragraphStyle: ps])
            var sz = s.size()
            sz.width = min(ceil(sz.width), maxW); sz.height = ceil(sz.height)
            strs.append(s); sizes.append(sz)
        }
        let textW = sizes.map(\.width).max() ?? 0
        let textH = sizes.map(\.height).reduce(0, +) + gap * CGFloat(max(0, sizes.count - 1))
        let w = textW + padX * 2, h = textH + padY * 2
        let baseY: CGFloat = 124
        let x = max(6, min(bounds.width - 6 - w, cx - w / 2))
        let rect = NSRect(x: x, y: baseY, width: w, height: h)

        // little pop when it appears
        let age = (t - bubbleStart) / 0.28
        var k: CGFloat = 1
        if age < 1 {
            let u = CGFloat(max(0.0, age)) - 1
            k = max(0.01, 1 + 2.7 * u * u * u + 1.7 * u * u)
        }

        ctx.saveGState()
        ctx.translateBy(x: cx, y: baseY); ctx.scaleBy(x: k, y: k); ctx.translateBy(x: -cx, y: -baseY)

        let box = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: cx - 8, y: baseY + 2))
        tail.line(to: NSPoint(x: cx - 1, y: baseY - 10))
        tail.line(to: NSPoint(x: cx + 7, y: baseY + 2))
        tail.close()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 7, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        bubbleFill.setFill(); box.fill(); tail.fill()
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        var y = rect.maxY - padY
        for (i, s) in strs.enumerated() {
            y -= sizes[i].height
            s.draw(with: NSRect(x: rect.minX + padX, y: y, width: textW, height: sizes[i].height),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y -= gap
        }
        ctx.restoreGState()
    }
}

// MARK: - App controller

final class Controller: NSObject, NSApplicationDelegate {
    var panel: PetPanel!
    let view = PetView(frame: NSRect(x: 0, y: 0, width: 240, height: 234))
    var timer: Timer?
    let t0 = Date()
    var lastTick: Double = 0
    var lastPoll: Double = 0
    var pendings: [Pending] = []
    var dones: [Pending] = []
    var prevCount = 0
    var prevDone = 0
    var lastRemind: Double = 0
    var reminds = 0
    var happyUntil: Double = 0
    var pettedUntil: Double = 0
    var pettedLine = "嘿嘿～"
    var lastInteraction: Double = now()
    var lastActivity: Double = now()
    let defaults = UserDefaults.standard

    var muted: Bool {
        get { defaults.bool(forKey: "muted") }
        set { defaults.set(newValue, forKey: "muted") }
    }
    var hideWhenIdle: Bool {
        get { defaults.bool(forKey: "hideWhenIdle") }
        set { defaults.set(newValue, forKey: "hideWhenIdle") }
    }
    var notifyDone: Bool {
        get { !defaults.bool(forKey: "doneOff") }
        set { defaults.set(!newValue, forKey: "doneOff") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? fm.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        panel = PetPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        view.controller = self
        panel.contentView = view
        panel.setFrameOrigin(initialOrigin())
        poll()
        panel.orderFrontRegardless()

        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func defaultOrigin() -> NSPoint {
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vf.maxX - view.frame.width - 10, y: vf.minY + 4)
    }

    func initialOrigin() -> NSPoint {
        guard defaults.object(forKey: "x") != nil else { return defaultOrigin() }
        let p = NSPoint(x: defaults.double(forKey: "x"), y: defaults.double(forKey: "y"))
        let petSpot = NSPoint(x: p.x + view.frame.width / 2, y: p.y + 50)
        return NSScreen.screens.contains { $0.frame.contains(petSpot) } ? p : defaultOrigin()
    }

    func savePosition() {
        defaults.set(Double(panel.frame.origin.x), forKey: "x")
        defaults.set(Double(panel.frame.origin.y), forKey: "y")
        lastInteraction = now()
    }

    func poll() {
        let wall = now()
        var list: [Pending] = []
        for (url, p) in allPending() {
            let age = wall - p.time
            var stale = age > 4 * 3600 || (p.session.hasPrefix("demo") && age > 8)
                || (p.kind == "done" && (age > 3600 || !notifyDone))
            if !stale, let app = p.app, !app.isEmpty,
               NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) != nil,
               NSRunningApplication.runningApplications(withBundleIdentifier: app).isEmpty {
                stale = true   // the app hosting that session is gone
            }
            if stale { try? fm.removeItem(at: url) } else { list.append(p) }
        }
        let sorted = list.sorted { $0.time > $1.time }
        pendings = sorted.filter { $0.kind != "done" }
        dones = sorted.filter { $0.kind == "done" }
        if let d = (try? fm.attributesOfItem(atPath: activityFile.path))?[.modificationDate] as? Date {
            lastActivity = d.timeIntervalSince1970
        }
    }

    func tick() {
        let t = Date().timeIntervalSince(t0)
        let dt = t - lastTick
        lastTick = t
        let wall = now()
        if wall - lastPoll > 0.4 { poll(); lastPoll = wall }

        let count = pendings.count
        if count > prevCount {
            view.alertKick = t; view.bubbleStart = t
            lastRemind = wall; reminds = 0; lastInteraction = wall
            if !muted { NSSound(named: "Glass")?.play() }
        } else if count == 0 && prevCount > 0 {
            happyUntil = t + 2.2
        }
        if count > 0 && wall - lastRemind > 45 && reminds < 3 {
            lastRemind = wall; reminds += 1; view.alertKick = t
            if !muted { NSSound(named: "Tink")?.play() }
        }
        prevCount = count
        if dones.count > prevDone {
            view.doneKick = t; view.bubbleStart = t; lastInteraction = wall
            if !muted && count == 0 { NSSound(named: "Hero")?.play() }
        }
        prevDone = dones.count

        let mood: Mood
        if count > 0 { mood = .alert }
        else if !dones.isEmpty { mood = .done }
        else if t < happyUntil { mood = .happy }
        else if t < pettedUntil { mood = .petted }
        else if wall - max(lastActivity, lastInteraction) > 300 { mood = .sleepy }
        else { mood = .idle }
        if mood != view.mood {
            view.mood = mood; view.moodStart = t
            if mood == .happy || mood == .petted || mood == .done { view.bubbleStart = t }
        }
        view.bubble = bubbleLines(mood: mood, pendings: pendings, dones: dones, pettedLine: pettedLine)
        view.t = t
        view.step(dt)

        let show = !(hideWhenIdle && (mood == .idle || mood == .sleepy))
        if show != panel.isVisible {
            if show { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        }
        if panel.isVisible { view.needsDisplay = true }
    }

    func petClicked() {
        lastInteraction = now()
        if let p = pendings.first {
            jump(to: p)                                   // newest approval request
        } else if let d = dones.first {
            jump(to: d)                                   // newest finished chat; the next click takes you to the next one
            try? fm.removeItem(at: doneURL(d.session))
            poll()
        } else {
            pettedLine = ["嘿嘿～", "再摸摸！", "我在帮你盯着哦", "(=^･ω･^=)", "Claude 在努力干活～"].randomElement()!
            pettedUntil = Date().timeIntervalSince(t0) + 1.8
        }
    }

    /// Open the exact desktop chat when we know it, otherwise just bring its app forward.
    func jump(to p: Pending) {
        if let host = p.host, host.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil,
           let url = URL(string: "claude://code/continue?session=\(host)") {
            NSWorkspace.shared.open(url)
            openApp(claudeDesktopBundleID)
        } else {
            openApp(p.app ?? claudeDesktopBundleID)
        }
    }

    func openApp(_ bundle: String) {
        let id = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil ? bundle : claudeDesktopBundleID
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
    }

    func makeMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let header = NSMenuItem(title: "小 Claude · 帮你盯着 Claude 的批准请求", action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        m.addItem(.separator())
        func add(_ title: String, _ sel: Selector, on: Bool? = nil) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            if let on { i.state = on ? .on : .off }
            m.addItem(i)
        }
        add("试一下：需要批准", #selector(demo))
        add("试一下：对话做完了", #selector(demoDone))
        if !pendings.isEmpty || !dones.isEmpty { add("清除当前提醒", #selector(clearAll)) }
        m.addItem(.separator())
        add("静音提示音", #selector(toggleMute), on: muted)
        add("对话做完了也提醒我", #selector(toggleDone), on: notifyDone)
        add("平时躲起来，只在需要你时出现", #selector(toggleHide), on: hideWhenIdle)
        add("回到屏幕右下角", #selector(resetPosition))
        m.addItem(.separator())
        add("让小 Claude先下班（有请求时会再回来）", #selector(quit))
        return m
    }

    @objc func demo() {
        writeDemo()
        poll()
    }
    @objc func clearAll() { clearAllPending(); poll() }
    @objc func toggleMute() { muted.toggle() }
    @objc func toggleHide() { hideWhenIdle.toggle() }
    @objc func toggleDone() { notifyDone.toggle(); poll() }
    @objc func demoDone() { writeDemoDone(); poll() }
    @objc func resetPosition() {
        panel.setFrameOrigin(defaultOrigin())
        defaults.removeObject(forKey: "x"); defaults.removeObject(forKey: "y")
    }
    @objc func quit() { NSApp.terminate(nil) }
}

func writeDemoDone() {
    try? fm.createDirectory(at: pendingDir, withIntermediateDirectories: true)
    let p = Pending(session: "demo-done", agent: nil, kind: "done", tool: nil, digest: nil, toolUseId: nil,
                    app: nil, project: "演示", time: now())
    writePending(p, to: doneURL("demo-done"))
}

func writeDemo() {
    try? fm.createDirectory(at: pendingDir, withIntermediateDirectories: true)
    let p = Pending(session: "demo", agent: nil, kind: "permission", tool: "Bash", digest: nil, toolUseId: nil,
                    app: nil, project: "演示", time: now())
    writePending(p, to: slotURL(session: "demo", agent: nil))
}

// MARK: - Preview renderer (used to check the drawings without a screen)

func renderSnapshot(to path: String) {
    _ = NSApplication.shared
    let W: CGFloat = 240, H: CGFloat = 234
    let demoReq = [Pending(session: "s", agent: nil, kind: "permission", tool: "Bash", digest: nil, toolUseId: nil,
                           app: nil, project: "my-project", time: now())]
    let demoDone = [Pending(session: "d", agent: nil, kind: "done", tool: nil, digest: nil, toolUseId: nil,
                            app: nil, project: "my-project", time: now())]
    let scenes: [(Mood, Double, [Line])] = [
        (.idle, 0.4, []),
        (.alert, 0.22, bubbleLines(mood: .alert, pendings: demoReq, dones: [], pettedLine: "")),
        (.alert, 2.05, bubbleLines(mood: .alert, pendings: demoReq + demoReq, dones: [], pettedLine: "")),
        (.done, 0.25, bubbleLines(mood: .done, pendings: [], dones: demoDone, pettedLine: "")),
        (.done, 3.0, bubbleLines(mood: .done, pendings: [], dones: demoDone + demoDone, pettedLine: "")),
        (.happy, 0.12, bubbleLines(mood: .happy, pendings: [], dones: [], pettedLine: "")),
        (.sleepy, 0.9, []),
    ]
    let n = CGFloat(scenes.count)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * n * 2), pixelsHigh: Int(H * 2),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = NSSize(width: W * n, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(starting: rgb(0xD6DEE9), ending: rgb(0xA9BACD))?.draw(in: NSRect(x: 0, y: 0, width: W * n, height: H), angle: -90)
    let ctx = NSGraphicsContext.current!.cgContext
    for (i, sc) in scenes.enumerated() {
        let v = PetView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        v.clearsBackground = false
        v.mood = sc.0; v.t = sc.1; v.bubble = sc.2
        v.alertKick = 0; v.doneKick = 0; v.moodStart = 0; v.bubbleStart = -10
        v.blinkUntil = -1; v.nextBlink = 1e9; v.nextLook = 1e9
        ctx.saveGState()
        ctx.translateBy(x: W * CGFloat(i), y: 0)
        v.draw(v.bounds)
        ctx.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

// MARK: - main

let args = CommandLine.arguments
if args.count > 1 {
    switch args[1] {
    case "hook":
        exit(runHook())
    case "demo":
        writeDemo(); ensurePetRunning(); exit(0)
    case "demo-done":
        writeDemoDone(); ensurePetRunning(); exit(0)
    case "clear":
        clearAllPending(); exit(0)
    case "snapshot":
        renderSnapshot(to: args.count > 2 ? args[2] : "pet-preview.png"); exit(0)
    default:
        FileHandle.standardError.write("usage: ApprovalPet [hook|demo|clear|snapshot FILE]\n".data(using: .utf8)!)
        exit(1)
    }
}

let runningCopies = NSRunningApplication.runningApplications(withBundleIdentifier: petBundleID)
    .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
if !runningCopies.isEmpty { exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.delegate = controller
app.run()
