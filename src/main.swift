// 小 Claude (ApprovalPet) — the Claude Code pixel crab as a desktop pet; it hops and waves when Claude Code needs your approval.
//
//   ApprovalPet               run the pet (normally launched for you via `open`)
//   ApprovalPet hook          Claude Code hook entry point (reads the hook JSON on stdin)
//   ApprovalPet demo          fake an approval request for a few seconds
//   ApprovalPet demo-done     fake a "chat finished" reminder for a few seconds
//   ApprovalPet demo-work     fake "Claude is working" for a few seconds
//   ApprovalPet trick [NAME]  do a trick now (dance, scratch, coffee, wave, look, stretch, juggle, shades)
//   ApprovalPet clear         forget every pending request
//   ApprovalPet off [MIN]     rest for MIN minutes (no number: until `on`); hooks won't bring it back
//   ApprovalPet on            wake it up
//   ApprovalPet status        show which chat the pet thinks you're looking at
//   ApprovalPet snapshot F    render a preview strip of every mood into PNG file F

import AppKit
import Carbon
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

extension Pending {
    var key: String { "\(session)|\(agent ?? "-")|\(kind)|\(time)" }
}

func now() -> Double { Date().timeIntervalSince1970 }

/// Read one of the pet's switches straight from its settings domain, so the hook
/// (a plain command-line process) sees exactly what the menu wrote.
func petPref(_ key: String) -> Bool {
    CFPreferencesAppSynchronize(petBundleID as CFString)
    return (CFPreferencesCopyAppValue(key as CFString, petBundleID as CFString) as? Bool) ?? false
}

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

func busyURL(_ session: String) -> URL {
    pendingDir.appendingPathComponent("\(safeName(session))__busy.json")
}

// MARK: - Resting (turned off for a while)

let offFile = baseDir.appendingPathComponent("off-until")

/// nil = awake, .infinity = resting until you wake it, otherwise the time (epoch seconds) it wakes up.
func petOffUntil() -> Double? {
    guard let s = try? String(contentsOf: offFile, encoding: .utf8) else { return nil }
    let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if v == "forever" { return .infinity }
    guard let until = Double(v), until > now() else { try? fm.removeItem(at: offFile); return nil }
    return until
}

/// Rest for `minutes` (nil = until woken). Clears current reminders so nothing stale shows up later.
func setPetOff(minutes: Double?) {
    try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
    let v = minutes.map { String(now() + $0 * 60) } ?? "forever"
    try? v.write(to: offFile, atomically: true, encoding: .utf8)
    clearAllPending()
}

func setPetOn() { try? fm.removeItem(at: offFile) }

// MARK: - Global shortcut ⌃⌥⌘P: rest until woken / wake up
// (Carbon hot keys need no Accessibility permission.)

var hotKeyAction: (() -> Void)?
var hotKeyRef: EventHotKeyRef?

@discardableResult
func registerRestHotKey(_ action: @escaping () -> Void) -> OSStatus {
    hotKeyAction = action
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { hotKeyAction?() }
        return noErr
    }, 1, &spec, nil, nil)
    let id = EventHotKeyID(signature: OSType(0x50455421), id: 1)   // 'PET!'
    return RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(cmdKey | optionKey | controlKey), id,
                               GetApplicationEventTarget(), 0, &hotKeyRef)
}

/// A small crab silhouette for the menu bar (template image, so it follows light/dark menu bars).
func crabMenuBarImage() -> NSImage {
    let img = NSImage(size: NSSize(width: 20, height: 14), flipped: false) { _ in
        NSColor.black.setFill()
        let rowH: CGFloat = 2.4
        func cells(_ col: Int, _ w: Int, _ row: Int) {
            NSRect(x: 1 + CGFloat(col), y: 1 + CGFloat(4 - row) * rowH, width: CGFloat(w), height: rowH).fill()
        }
        cells(3, 12, 0)
        cells(3, 2, 1); cells(6, 6, 1); cells(13, 2, 1)     // eye holes at columns 5 and 12
        cells(1, 16, 2)                                      // arms
        cells(3, 12, 3)
        for c in [4, 6, 11, 13] { cells(c, 1, 4) }           // legs
        return true
    }
    img.isTemplate = true
    return img
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
    let mode = obj["permission_mode"] as? String ?? ""
    // you told Claude to go ahead without asking: approval alerts would just be noise
    let quietApprovals = mode == "bypassPermissions"
    let resting = petOffUntil() != nil          // turned off for a while: no reminders, don't bring the pet back
    let slot = slotURL(session: session, agent: agent)

    logLine("\(event) tool=\(tool ?? "-") ntype=\(ntype.isEmpty ? "-" : ntype) agent=\(agent ?? "-") session=\(session.prefix(8)) host=\(host ?? "-") mode=\(mode.isEmpty ? "-" : mode) app=\(app ?? "-")")

    var raised = false
    func raise(_ kind: String, _ toolName: String?, keepExisting: Bool = false) {
        if resting { return }
        if keepExisting && fm.fileExists(atPath: slot.path) { return }
        var k = kind
        if toolName == "AskUserQuestion" { k = "question" } else if toolName == "ExitPlanMode" { k = "plan" }
        let p = Pending(session: session, agent: agent, kind: k, tool: toolName,
                        digest: digestOf(tool: tool, input: input), toolUseId: toolUseId,
                        app: app, project: projectName(obj["cwd"] as? String), time: now(), host: host)
        writePending(p, to: slot)
        raised = true
    }
    // "Claude is working in this chat" — from your message until Stop, refreshed by every tool call
    func markBusy() {
        if resting { return }
        let p = Pending(session: session, agent: nil, kind: "busy", tool: nil, digest: nil, toolUseId: nil,
                        app: app, project: projectName(obj["cwd"] as? String), time: now(), host: host)
        writePending(p, to: busyURL(session))
    }

    switch event {
    case "PermissionRequest":
        if quietApprovals && tool != "AskUserQuestion" && tool != "ExitPlanMode" {
            logLine("  (bypass mode: no approval alert)")
        } else {
            raise("permission", tool)
        }
    case "Notification":
        if ntype == "permission_prompt" || (ntype.isEmpty && message.lowercased().contains("permission")) {
            if !quietApprovals { raise("permission", toolFromMessage(message), keepExisting: true) }
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
        markBusy()
    case "PermissionDenied":
        try? fm.removeItem(at: slot)
    case "SubagentStop":
        if agent != nil { try? fm.removeItem(at: slot) }
    case "UserPromptSubmit":
        clearSession(session)
        markBusy()
    case "StopFailure":
        clearSession(session)
    case "SessionEnd":
        clearSession(session, keepDone: true)
    case "Stop":
        // the chat finished its turn: drop its approval requests, leave a "done" note
        clearSession(session)
        let p = Pending(session: session, agent: nil, kind: "done", tool: nil, digest: nil, toolUseId: nil,
                        app: app, project: projectName(obj["cwd"] as? String), time: now(), host: host)
        if !resting { writePending(p, to: doneURL(session)); raised = true }
    default:
        break
    }

    if !resting && (raised || event == "SessionStart") { ensurePetRunning() }
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

enum Mood { case idle, sleepy, alert, done, happy, petted, working }

/// Little things the crab does on its own when nothing's going on.
enum Trick: String, CaseIterable {
    case dance, scratch, coffee, wave, look, stretch, juggle, shades
    var duration: Double {
        switch self {
        case .dance: return 4.5
        case .scratch: return 3.5
        case .coffee: return 5.0
        case .wave: return 2.6
        case .look: return 3.4
        case .stretch: return 3.0
        case .juggle: return 4.5
        case .shades: return 4.0
        }
    }
}

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
    case .idle, .sleepy, .working:
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
    var hiddenPet = false           // resting / hidden: draw nothing at all
    var walkDir = 0                 // -1 left, 0 standing, 1 right
    var mouseIsDown = false
    var trick: Trick?
    var trickStart: Double = 0

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

    // Render each frame on the CPU into a plain image and hand it to the layer. The default
    // GPU-accelerated drawing path can block the main thread for seconds when macOS gives a
    // background app's GPU work low priority — which made the pet miss rest/wake changes.
    private var frameCtx: CGContext?
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let layer else { return }
        let scale = window?.backingScaleFactor ?? 2
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        // draw straight in the screen's color space and native BGRA layout, so nothing gets converted per frame
        let space = window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if frameCtx == nil || frameCtx!.width != w || frameCtx!.height != h || frameCtx!.colorSpace != space {
            frameCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        }
        guard let ctx = frameCtx else { return }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        draw(bounds)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
        layer.drawsAsynchronously = false
        layer.contentsScale = scale
        layer.contents = ctx.makeImage()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func step(_ dt: Double) {
        if t > nextBlink { blinkUntil = t + 0.13; nextBlink = t + Double.random(in: 2.5...5.5) }
        if t > nextLook { lookTarget = [-3, 0, 0, 3].randomElement()!; nextLook = t + Double.random(in: 2...5) }
        look += (lookTarget - look) * CGFloat(min(1, dt * 8))
    }

    // Interaction: click = go approve / pet me, drag = move, right-click = menu.
    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control) { rightMouseDown(with: e); return }
        mouseIsDown = true
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
        mouseIsDown = false
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
        if hiddenPet { return }
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
        case .idle, .sleepy, .working:
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
            if walkDir != 0 {                                             // scuttling sideways
                let s = sin(t * 18) > 0; legA = s ? 3 : 0; legB = s ? 0 : 3
                bodyLift = s ? 1 : 0
            } else {
                bodyLift = sin(t * 2.2) > 0.3 ? 2 : 0                   // breathing
                if t.truncatingRemainder(dividingBy: 6.5) < 1.0 {         // a little shuffle now and then
                    let s = sin(t * 14) > 0; legA = s ? 3 : 0; legB = s ? 0 : 3
                }
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
        case .working:                                                    // claws tapping the keyboard
            let s = sin(t * 20) > 0
            armL = s ? -13 : -9; armR = s ? -9 : -13
        }

        // idle tricks override the pose
        var sway: CGFloat = 0, lookDX: CGFloat = 0, lookDY: CGFloat = 0
        var trickEyes: Mood? = nil
        var trickMouth = 0                                   // 1 small "o", 2 big yawn
        let tr: Trick? = mood == .idle ? trick : nil
        let tt = t - trickStart
        if let tr {
            legA = 0; legB = 0
            switch tr {
            case .dance:
                let s = sin(tt * 2.5 * .pi)
                sway = s > 0 ? 4 : -4
                bodyLift = abs(s) > 0.7 ? 2 : 0
                armL = s > 0 ? 12 : 2; armR = s > 0 ? 2 : 12
                legA = s > 0 ? 3 : 0; legB = s > 0 ? 0 : 3
                trickEyes = .happy
            case .scratch:
                armR = -16 + (sin(tt * 30) > 0 ? 2 : 0)      // claw round the back, scratch scratch
                sway = 2; legB = 2
                trickEyes = .sleepy                           // bliss
            case .coffee:
                let k = max(0, min(1, min(tt / 0.4, (tr.duration - tt) / 0.4)))
                armR = (14 * CGFloat(k)).rounded()
                let sipping = (tt > 1.0 && tt < 2.0) || (tt > 2.8 && tt < 3.8)
                trickEyes = sipping ? .sleepy : .idle
            case .wave:
                armR = sin(tt * 18) > 0 ? 16 : 10
                trickMouth = 1
            case .look:
                lookDX = tt < 0.9 ? -2.5 : (tt < 1.3 ? 0 : (tt < 2.3 ? 2.5 : 0))
            case .stretch:
                let k = CGFloat(max(0, min(1, min(tt / 0.6, (tr.duration - tt) / 0.6))))
                armL = (16 * k).rounded(); armR = armL; bodyLift = (3 * k).rounded()
                trickEyes = .sleepy; trickMouth = k > 0.5 ? 2 : 0
            case .juggle:
                let s = sin(tt * 2 * .pi / 1.1 * 3) > 0
                armL = s ? 6 : 0; armR = s ? 0 : 6
                lookDY = 1.5                                  // eyes on the balls
            case .shades:
                if tt > 0.6 && tt < tr.duration - 0.6 { bodyLift = sin(tt * 8) > 0 ? 2 : 0 }   // bobbing to the beat
            }
        }
        ctx.translateBy(x: sway, y: 0)

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

        if mood == .working {                                             // screen light on its face
            rgb(0xDDF0FF, 0.22).setFill()
            NSRect(x: -26, y: 28 + by, width: 52, height: 7).fill()
        }
        // eyes: row 1, columns 5 and 12
        let eyeMood: Mood = trickEyes ?? (mood == .done ? (t - doneKick < 2 ? .happy : .idle) : mood)
        let eyeY = legTop + 2 * rowH + by + lookDY
        for (i, ex) in [-4 * u, 3 * u].enumerated() {
            let ex = ex + (eyeMood == .idle ? CGFloat(walkDir) * 1.5 + lookDX : 0)   // look where you're going
            let r = NSRect(x: ex, y: eyeY, width: u, height: rowH)
            switch eyeMood {
            case .idle, .done:
                eyeInk.setFill()
                if t < blinkUntil { NSRect(x: ex, y: eyeY + 4.5, width: u, height: 3).fill() } else { r.fill() }
            case .working:                                                // looking down at the screen
                eyeInk.setFill()
                if t < blinkUntil { NSRect(x: ex, y: eyeY + 1, width: u, height: 2.5).fill() }
                else { NSRect(x: ex, y: eyeY, width: u, height: 8).fill() }
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
            if eyeMood != .idle && eyeMood != .sleepy && eyeMood != .done && eyeMood != .working {
                blushColor.setFill()
                NSRect(x: i == 0 ? ex - u : ex + u, y: eyeY - 1, width: u, height: 3).fill()
            }
        }
        if mood == .alert {
            let o: CGFloat = sin(t * 12) > 0 ? 1 : 0
            mouthRed.setFill(); NSRect(x: -3 - o / 2, y: eyeY + 1, width: 6 + o, height: 4 + o).fill()
        }
        if mood == .working { drawLaptop() }
        if let tr { drawTrickProps(tr, tt: tt, by: by, eyeY: eyeY, mouth: trickMouth) }
    }

    /// A tiny laptop in front of the crab; we see the back of its lid.
    func drawLaptop() {
        rgb(0x8E96A1).setFill(); NSRect(x: -26, y: 6, width: 52, height: 22).fill()      // lid
        rgb(0xAEB5BE).setFill(); NSRect(x: -26, y: 26, width: 52, height: 2).fill()      // lid edge
        petColor.setFill()                                                               // little orange plus on the lid
        NSRect(x: -1.5, y: 12.5, width: 3, height: 9).fill()
        NSRect(x: -4.5, y: 15.5, width: 9, height: 3).fill()
        rgb(0xC7CCD3).setFill(); NSRect(x: -34, y: 2, width: 68, height: 5).fill()       // base
        rgb(0x9AA1AB).setFill(); NSRect(x: -34, y: 2, width: 68, height: 1.5).fill()
    }

    /// Props and little effects for idle tricks (local coordinates: y up, origin under its feet).
    func drawTrickProps(_ tr: Trick, tt: Double, by: CGFloat, eyeY: CGFloat, mouth: Int) {
        if mouth == 1 { mouthRed.setFill(); NSRect(x: -2.5, y: eyeY + 1, width: 5, height: 3).fill() }
        if mouth == 2 { mouthRed.setFill(); NSRect(x: -4, y: eyeY - 1, width: 8, height: 7).fill() }
        func label(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: NSColor) {
            NSAttributedString(string: s, attributes: [.font: roundedFont(size, .heavy), .foregroundColor: color])
                .draw(at: NSPoint(x: x, y: y))
        }
        switch tr {
        case .dance:                                                      // music notes
            for i in 0..<2 {
                let ph = (tt * 0.8 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                label(i == 0 ? "♪" : "♫", (i == 0 ? -48 : 38) + CGFloat(sin(ph * 6)) * 3, 58 + by + CGFloat(ph) * 30,
                      12, rgb(0x6E6390, CGFloat(sin(ph * .pi))))
            }
        case .scratch:                                                    // scratch marks by its back end
            if sin(tt * 30) > 0 {
                rgb(0x8A6F66, 0.85).setFill()
                NSRect(x: 51, y: 8 + by, width: 3, height: 2).fill()
                NSRect(x: 53, y: 13 + by, width: 3, height: 2).fill()
                NSRect(x: 50, y: 18 + by, width: 3, height: 2).fill()
            }
        case .coffee:
            let k = max(0, min(1, min(tt / 0.4, (tr.duration - tt) / 0.4)))
            guard k > 0.6 else { break }
            let sipping = (tt > 1.0 && tt < 2.0) || (tt > 2.8 && tt < 3.8)
            let mx: CGFloat = sipping ? 22 : 27, my: CGFloat = 37 + by + (sipping ? 1 : 0)
            rgb(0xF4F1EC).setFill()
            NSRect(x: mx, y: my, width: 8, height: 8).fill()                                  // mug
            NSRect(x: mx + 8, y: my + 2, width: 2, height: 4).fill()                          // handle
            rgb(0x6B4226).setFill(); NSRect(x: mx, y: my + 6.5, width: 8, height: 1.5).fill() // coffee
            for i in 0..<2 {                                                                  // steam
                let ph = (tt * 0.9 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                rgb(0xFFFFFF, 0.75 * CGFloat(1 - ph)).setFill()
                NSRect(x: mx + 2 + CGFloat(i) * 3 + CGFloat(sin(ph * 7)) * 1.5, y: my + 9 + CGFloat(ph) * 12,
                       width: 2, height: 2).fill()
            }
        case .look:
            if tt > 1.3 && tt < 2.6 { label("?", 30, 64 + by, 14, rgb(0x6E6390)) }
        case .juggle:
            let colors = [rgb(0xE85D5D), rgb(0xF2B84B), rgb(0x5B9BE8)]
            for i in 0..<3 {
                let p = (tt / 1.1 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                guard p < 0.75 else { continue }                         // back in a claw
                let q = p / 0.75
                colors[i].setFill()
                NSRect(x: 40 - 84 * CGFloat(q), y: 44 + by + 46 * CGFloat(sin(q * .pi)), width: 6, height: 6).fill()
            }
        case .shades:
            let drop = CGFloat(max(0, 1 - tt / 0.5)) + CGFloat(max(0, (tt - (tr.duration - 0.5)) / 0.5))
            let y = eyeY + 1 + 40 * drop
            rgb(0x141414).setFill()
            NSRect(x: -30, y: y, width: 18, height: 11).fill()                // left lens
            NSRect(x: 12, y: y, width: 18, height: 11).fill()                 // right lens
            NSRect(x: -12, y: y + 7, width: 24, height: 3).fill()             // bridge
            NSRect(x: -34, y: y + 8, width: 4, height: 2).fill()              // arms of the glasses
            NSRect(x: 30, y: y + 8, width: 4, height: 2).fill()
            NSColor.white.setFill()
            NSRect(x: -27, y: y + 6, width: 4, height: 2).fill()              // glints
            NSRect(x: 15, y: y + 6, width: 4, height: 2).fill()
        case .wave, .stretch:
            break
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
        case .working:                                                    // bits of code floating up
            let glyphs = ["{ }", "</>", "01", ";", "( )", "✓"]
            let xs: [CGFloat] = [-22, 4, 20]
            for i in 0..<3 {
                let cyc = t * 0.55 + Double(i) / 3
                let ph = cyc.truncatingRemainder(dividingBy: 1)
                NSAttributedString(string: glyphs[(Int(cyc) * 2 + i) % glyphs.count], attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: rgb(0x5B7DB1, 0.9 * CGFloat(sin(ph * .pi))),
                ]).draw(at: NSPoint(x: cx + xs[i] + CGFloat(sin(cyc * 3)) * 3, y: ground + 62 + CGFloat(ph) * 36))
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

// MARK: - Which chat are you looking at?

/// The Claude desktop app logs `LocalSessions.setFocusedSession: sessionId=…` whenever you switch chats.
/// We follow the end of that log to know which chat is on screen.
final class FocusWatcher {
    let url = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Claude/main.log")
    private(set) var focused: String?
    private var offset: UInt64 = 0
    private var inode: UInt64?
    private let marker = "setFocusedSession: sessionId="

    func refresh() {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        let ino = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        if ino != inode || size < offset {               // first look, or the log was rotated
            inode = ino
            offset = size > 1_048_576 ? size - 1_048_576 : 0
        }
        guard size > offset, let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        h.seek(toFileOffset: offset)
        let data = h.readData(ofLength: Int(size - offset))
        guard let lastNL = data.lastIndex(of: 0x0A) else { return }   // only read whole lines
        offset += UInt64(lastNL - data.startIndex + 1)
        let text = String(decoding: data[data.startIndex...lastNL], as: UTF8.self)
        if let r = text.range(of: marker, options: .backwards) {
            let id = text[r.upperBound...].prefix { !$0.isWhitespace && $0 != "," }
            focused = id == "null" ? nil : String(id)
        }
    }
}

func userIdleSeconds() -> Double {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
}

// MARK: - App controller

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panel: PetPanel!
    let view = PetView(frame: NSRect(x: 0, y: 0, width: 240, height: 234))
    var timer: Timer?
    let t0 = Date()
    var lastTick: Double = 0
    var lastPoll: Double = 0
    var pendings: [Pending] = []
    var dones: [Pending] = []
    var busy: [Pending] = []        // chats Claude is working in
    let focus = FocusWatcher()
    var viewing: String?            // desktop chat you're looking at right now (local_…)
    var seen = Set<String>()        // approval requests you already had on screen
    var home: NSPoint = .zero       // where you put it; it wanders around here
    var walkTarget: CGFloat?
    var nextWanderAt: Double = 600
    var strollLegsLeft = 0          // a stroll is a few short walks in a row
    var nextTrickAt: Double = 180
    var lastTrick: Trick?
    var statusItem: NSStatusItem?    // menu-bar crab, only while resting
    var activity: NSObjectProtocol?  // keeps macOS from napping the pet while it's hidden
    var lastVisCheck: Double = 0
    var petShown = true
    var restHeader: NSMenuItem?
    var resting = false
    var trickForced = false         // you asked for it: plays even while working or sleeping
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
    var skipViewed: Bool {
        get { !defaults.bool(forKey: "remindViewedToo") }
        set { defaults.set(!newValue, forKey: "remindViewedToo") }
    }
    /// Seconds between strolls: 0 = keep strolling, -1 = never. Defaults to every 10 minutes.
    var wanderEvery: Double {
        get {
            if defaults.object(forKey: "wanderEvery") == nil { return defaults.bool(forKey: "noWander") ? -1 : 600 }
            return defaults.double(forKey: "wanderEvery")
        }
        set { defaults.set(newValue, forKey: "wanderEvery") }
    }
    var wanderEnabled: Bool { wanderEvery >= 0 }

    /// Seconds between little tricks: -1 = never. Defaults to about every 3 minutes.
    var trickEvery: Double {
        get { defaults.object(forKey: "trickEvery") == nil ? 180 : defaults.double(forKey: "trickEvery") }
        set { defaults.set(newValue, forKey: "trickEvery") }
    }
    func trickRest() -> Double { trickEvery <= 0 ? 600 : trickEvery * Double.random(in: 0.7...1.3) }

    func updateTrick(t: Double, mood: Mood) {
        if let tr = view.trick {
            if mood != .idle || t - view.trickStart > tr.duration {
                view.trick = nil; trickForced = false; nextTrickAt = t + trickRest()
            }
            return
        }
        guard mood == .idle, trickEvery > 0, view.walkDir == 0, walkTarget == nil, t > nextTrickAt else { return }
        startTrick(nil, t: t)
    }

    func startTrick(_ which: Trick?, t: Double, forced: Bool = false) {
        trickForced = forced
        var pick = which ?? Trick.allCases.randomElement()!
        if which == nil, pick == lastTrick { pick = Trick.allCases.filter { $0 != lastTrick }.randomElement()! }
        lastTrick = pick
        walkTarget = nil; view.walkDir = 0
        view.trick = pick; view.trickStart = t
    }

    /// How long to rest before the next stroll (±20% so it doesn't feel mechanical).
    func restInterval() -> Double {
        let every = wanderEvery
        return every <= 0 ? Double.random(in: 3...10) : every * Double.random(in: 0.8...1.2)
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
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        panel.contentView = view
        home = initialOrigin()
        panel.setFrameOrigin(home)
        nextWanderAt = restInterval()
        nextTrickAt = trickRest()
        panel.orderFrontRegardless()
        poll()

        // App Nap would slow the pet's timers to a crawl while it's in the background, delaying wake-ups.
        defaults.set(true, forKey: "NSAppSleepDisabled")
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                          reason: "desktop pet reminders")
        // Monitors plugged in / unplugged: make sure the pet still stands on a screen.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.keepOnScreen() }
        let hk = registerRestHotKey { [weak self] in self?.toggleRest() }
        logLine("pet started; rest shortcut ⌃⌥⌘P \(hk == noErr ? "registered" : "failed (\(hk))")")

        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.tick() }
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

    // MARK: resting

    func enterRest() {
        resting = true
        view.trick = nil; trickForced = false; walkTarget = nil; view.walkDir = 0
        pendings = []; dones = []; busy = []; prevCount = 0; prevDone = 0
        setShown(false)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = crabMenuBarImage()
        item.button?.toolTip = "小 Claude 在休息"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let wake = NSMenuItem(title: "现在叫醒小 Claude", action: #selector(wakeUp), keyEquivalent: "p")
        wake.keyEquivalentModifierMask = [.control, .option, .command]
        wake.target = self
        menu.addItem(wake)
        item.menu = menu
        statusItem = item
        restHeader = header
        updateRestHeader()
    }

    func updateRestHeader() {
        guard let until = petOffUntil() else { restHeader?.title = "小 Claude 醒啦"; return }
        if until == .infinity { restHeader?.title = "小 Claude 在休息，等你叫醒它"; return }
        let mins = max(1, Int(ceil((until - now()) / 60)))
        restHeader?.title = mins >= 60 ? "小 Claude 在休息 · 还有 \(mins / 60) 小时 \(mins % 60) 分钟"
                                       : "小 Claude 在休息 · 还有 \(mins) 分钟"
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem?.menu { updateRestHeader() }
    }

    func leaveRest() {
        resting = false
        if let s = statusItem { NSStatusBar.system.removeStatusItem(s) }
        statusItem = nil; restHeader = nil
        lastInteraction = now()
        nextWanderAt = lastTick + restInterval()
        nextTrickAt = lastTick + trickRest()
        pettedLine = "我回来啦～"
        pettedUntil = lastTick + 2.0
        setShown(true)
    }

    @objc func wakeUp() { setPetOn(); poll() }

    @objc func toggleRest() {
        if resting { wakeUp() } else { setPetOff(minutes: nil); poll() }
    }

    @objc func restFor(_ sender: NSMenuItem) {
        guard let mins = sender.representedObject as? Double else { return }
        setPetOff(minutes: mins < 0 ? nil : mins)
        poll()
    }

    /// Opening the app again (Spotlight, Finder, `open`) wakes it up.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if resting { wakeUp() }
        return false
    }

    /// Show / hide the pet. The window itself never moves or leaves the screen (macOS doesn't reliably
    /// bring a hidden background panel back); a hidden pet just draws nothing, so the window is fully
    /// transparent and clicks go straight through it.
    func setShown(_ v: Bool) {
        guard v != petShown else { return }
        petShown = v
        logLine("pet: \(v ? "shown" : "hidden")")
        view.hiddenPet = !v
        view.needsDisplay = true
        if v { keepOnScreen() }
    }

    /// If the pet's spot isn't on any connected screen any more, move it home to the default corner.
    func keepOnScreen() {
        let f = panel.frame
        let spot = NSPoint(x: f.midX, y: f.minY + 50)
        if !NSScreen.screens.contains(where: { $0.frame.contains(spot) }) {
            walkTarget = nil; view.walkDir = 0
            home = defaultOrigin()
            panel.setFrameOrigin(home)
        }
    }

    func savePosition() {
        defaults.set(Double(panel.frame.origin.x), forKey: "x")
        defaults.set(Double(panel.frame.origin.y), forKey: "y")
        lastInteraction = now()
        home = panel.frame.origin; walkTarget = nil; strollLegsLeft = 0; nextWanderAt = lastTick + restInterval()
    }

    /// Idle crab: scuttle sideways around its home corner, pause, repeat. Freezes while you hover over it.
    func wander(t: Double, dt: Double, mood: Mood) {
        let f = panel.frame
        let petRect = NSRect(x: f.minX + 66, y: f.minY + 4, width: 108, height: 100)
        let free = wanderEnabled && mood == .idle && petShown && !view.mouseIsDown && view.trick == nil
        guard free, !petRect.contains(NSEvent.mouseLocation) else {
            view.walkDir = 0
            if !free { walkTarget = nil; nextWanderAt = max(nextWanderAt, t + 4) }
            return
        }
        guard let target = walkTarget else {
            if t > nextWanderAt {
                if strollLegsLeft <= 0 { strollLegsLeft = wanderEvery > 0 ? Int.random(in: 2...3) : 1 }
                walkTarget = pickWanderTarget(from: f.minX)
                if walkTarget == nil { strollLegsLeft = 0; nextWanderAt = t + max(8, restInterval()) }
            }
            return
        }
        let dx = target - f.minX
        let step = CGFloat(45 * dt)
        if abs(dx) <= step {
            panel.setFrameOrigin(NSPoint(x: target, y: f.minY))
            walkTarget = nil; view.walkDir = 0
            strollLegsLeft -= 1
            nextWanderAt = t + (strollLegsLeft > 0 ? Double.random(in: 2...4) : restInterval())
        } else {
            let x = ((f.minX + (dx > 0 ? step : -step)) * 2).rounded() / 2
            panel.setFrameOrigin(NSPoint(x: x, y: f.minY))
            view.walkDir = dx > 0 ? 1 : -1
        }
    }

    /// A spot within ~200pt of home that keeps the whole window (and its speech bubble) on screen.
    func pickWanderTarget(from x: CGFloat) -> CGFloat? {
        let anchor = NSPoint(x: home.x + view.frame.width / 2, y: home.y + 40)
        guard let vf = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame else { return nil }
        let lo = max(vf.minX, home.x - 200), hi = min(vf.maxX - view.frame.width, home.x + 200)
        guard hi - lo > 60 else { return nil }
        for _ in 0..<6 {
            let c = CGFloat.random(in: lo...hi).rounded()
            if abs(c - x) > 50 { return c }
        }
        return nil
    }

    func poll() {
        let wall = now()
        var list: [Pending] = []
        let off = petOffUntil()
        if off != nil && !resting { enterRest() } else if off == nil && resting { leaveRest() }
        if resting { return }
        let req = baseDir.appendingPathComponent("trick-request")
        if let name = try? String(contentsOf: req, encoding: .utf8) {
            try? fm.removeItem(at: req)
            lastInteraction = wall
            startTrick(Trick(rawValue: name.trimmingCharacters(in: .whitespacesAndNewlines)), t: lastTick, forced: true)
        }
        focus.refresh()
        viewing = nil
        if skipViewed, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeDesktopBundleID,
           userIdleSeconds() < 120 {
            viewing = focus.focused
        }
        if seen.count > 500 { seen.removeAll() }
        for (url, p) in allPending() {
            let age = wall - p.time
            var stale = age > 4 * 3600 || (p.session.hasPrefix("demo") && age > 8)
                || (p.kind == "done" && (age > 3600 || !notifyDone))
                || (p.kind == "busy" && age > 600)
            if !stale, let app = p.app, !app.isEmpty,
               NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) != nil,
               NSRunningApplication.runningApplications(withBundleIdentifier: app).isEmpty {
                stale = true   // the app hosting that session is gone
            }
            if stale { try? fm.removeItem(at: url); continue }
            if p.kind == "busy" { list.append(p); continue }
            if let v = viewing, p.host == v {
                // you're looking at this chat: it finished in front of you, or its prompt is on your screen
                if p.kind == "done" { try? fm.removeItem(at: url) } else { seen.insert(p.key) }
                continue
            }
            list.append(p)
        }
        let sorted = list.sorted { $0.time > $1.time }
        pendings = sorted.filter { $0.kind != "done" && $0.kind != "busy" }
        dones = sorted.filter { $0.kind == "done" }
        busy = sorted.filter { $0.kind == "busy" }
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
        if resting { return }

        let count = pendings.count
        if count > prevCount {
            view.alertKick = t; view.bubbleStart = t
            lastRemind = wall; reminds = 0; lastInteraction = wall
            // no sound for a request you already saw in its chat (it shows up quietly when you leave)
            if !muted && pendings.contains(where: { !seen.contains($0.key) }) { NSSound(named: "Glass")?.play() }
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
        else if trickForced && view.trick != nil { mood = .idle }
        else if !busy.isEmpty { mood = .working }
        else if wall - max(lastActivity, lastInteraction) > 300 { mood = .sleepy }
        else { mood = .idle }
        if mood != view.mood {
            view.mood = mood; view.moodStart = t
            if mood == .happy || mood == .petted || mood == .done { view.bubbleStart = t }
        }
        view.bubble = bubbleLines(mood: mood, pendings: pendings, dones: dones, pettedLine: pettedLine)
        view.t = t
        view.step(dt)
        updateTrick(t: t, mood: mood)
        wander(t: t, dt: min(dt, 0.1), mood: mood)

        let show = !(hideWhenIdle && (mood == .idle || mood == .sleepy || mood == .working))
        setShown(show)
        if petShown { view.needsDisplay = true }
        // self-heal: the window should always be up and on a screen (it never hides itself)
        if wall - lastVisCheck > 2 {
            lastVisCheck = wall
            if !panel.isVisible || !NSScreen.screens.contains(where: { $0.frame.intersects(panel.frame) }) {
                keepOnScreen()
                panel.orderFrontRegardless()
            }
        }
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
        add("试一下：陪 Claude 干活", #selector(demoWork))
        if !pendings.isEmpty || !dones.isEmpty { add("清除当前提醒", #selector(clearAll)) }
        m.addItem(.separator())
        add("静音提示音", #selector(toggleMute), on: muted)
        add("对话做完了也提醒我", #selector(toggleDone), on: notifyDone)
        add("正在看的对话就不提醒", #selector(toggleSkipViewed), on: skipViewed)
        add("平时躲起来，只在需要你时出现", #selector(toggleHide), on: hideWhenIdle)
        let walk = NSMenuItem(title: "溜达频率", action: nil, keyEquivalent: "")
        let walkMenu = NSMenu()
        walkMenu.autoenablesItems = false
        let choices: [(String, Double)] = [("一直溜达", 0), ("每 1 分钟", 60), ("每 5 分钟", 300), ("每 10 分钟", 600), ("不溜达", -1)]
        for (title, secs) in choices {
            let i = NSMenuItem(title: title, action: #selector(setWanderEvery(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = secs
            i.state = wanderEvery == secs ? .on : .off
            walkMenu.addItem(i)
        }
        walk.submenu = walkMenu
        m.addItem(walk)
        let tricks = NSMenuItem(title: "小动作频率", action: nil, keyEquivalent: "")
        let trickMenu = NSMenu()
        trickMenu.autoenablesItems = false
        let trickChoices: [(String, Double)] = [("经常（约 45 秒）", 45), ("偶尔（约 3 分钟）", 180), ("很少（约 10 分钟）", 600), ("不做", -1)]
        for (title, secs) in trickChoices {
            let i = NSMenuItem(title: title, action: #selector(setTrickEvery(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = secs
            i.state = trickEvery == secs ? .on : .off
            trickMenu.addItem(i)
        }
        tricks.submenu = trickMenu
        m.addItem(tricks)
        add("表演一个", #selector(performTrick))
        add("回到屏幕右下角", #selector(resetPosition))
        m.addItem(.separator())
        let rest = NSMenuItem(title: "休息一会儿", action: nil, keyEquivalent: "")
        let restMenu = NSMenu()
        restMenu.autoenablesItems = false
        let restChoices: [(String, Double)] = [("30 分钟", 30), ("1 小时", 60), ("2 小时", 120), ("4 小时", 240), ("直到我叫醒它", -1)]
        for (title, mins) in restChoices {
            let i = NSMenuItem(title: title, action: #selector(restFor(_:)), keyEquivalent: mins < 0 ? "p" : "")
            if mins < 0 { i.keyEquivalentModifierMask = [.control, .option, .command] }
            i.target = self
            i.representedObject = mins
            restMenu.addItem(i)
        }
        rest.submenu = restMenu
        m.addItem(rest)
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
    @objc func toggleSkipViewed() { skipViewed.toggle(); poll() }
    @objc func setWanderEvery(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? Double else { return }
        wanderEvery = secs
        walkTarget = nil; view.walkDir = 0; strollLegsLeft = 0
        if secs < 0 { panel.setFrameOrigin(home) }
        nextWanderAt = lastTick + (secs == 0 ? 0.5 : restInterval())
    }
    @objc func setTrickEvery(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? Double else { return }
        trickEvery = secs
        nextTrickAt = lastTick + trickRest()
    }
    @objc func performTrick() {
        lastInteraction = now()
        startTrick(nil, t: lastTick, forced: true)
    }
    @objc func demoDone() { writeDemoDone(); poll() }
    @objc func demoWork() { writeDemoWork(); poll() }
    @objc func resetPosition() {
        home = defaultOrigin(); walkTarget = nil
        panel.setFrameOrigin(home)
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

func writeDemoWork() {
    try? fm.createDirectory(at: pendingDir, withIntermediateDirectories: true)
    let p = Pending(session: "demo-work", agent: nil, kind: "busy", tool: nil, digest: nil, toolUseId: nil,
                    app: nil, project: nil, time: now())
    writePending(p, to: busyURL("demo-work"))
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
        (.working, 0.30, []),
        (.working, 1.13, []),
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

func renderTricks(to path: String) {
    _ = NSApplication.shared
    let W: CGFloat = 240, H: CGFloat = 150
    let shots: [(Trick, Double)] = [(.dance, 0.25), (.scratch, 0.5), (.coffee, 1.4), (.wave, 0.3),
                                    (.look, 1.8), (.stretch, 1.2), (.juggle, 0.55), (.shades, 1.6)]
    let n = CGFloat(shots.count)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * n * 2), pixelsHigh: Int(H * 2),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = NSSize(width: W * n, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(starting: rgb(0xD6DEE9), ending: rgb(0xA9BACD))?.draw(in: NSRect(x: 0, y: 0, width: W * n, height: H), angle: -90)
    let ctx = NSGraphicsContext.current!.cgContext
    for (i, shot) in shots.enumerated() {
        let v = PetView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        v.clearsBackground = false
        v.mood = .idle; v.trick = shot.0; v.trickStart = 0; v.t = shot.1
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
    case "demo-work":
        writeDemoWork(); ensurePetRunning(); exit(0)
    case "trick":
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? (args.count > 2 ? args[2] : "random").write(to: baseDir.appendingPathComponent("trick-request"),
                                                         atomically: true, encoding: .utf8)
        ensurePetRunning(); exit(0)
    case "snapshot-tricks":
        renderTricks(to: args.count > 2 ? args[2] : "pet-tricks.png"); exit(0)
    case "clear":
        clearAllPending(); exit(0)
    case "off":
        let mins = args.count > 2 ? Double(args[2]) : nil
        setPetOff(minutes: mins)
        print(mins.map { "小 Claude 休息 \($0) 分钟（ApprovalPet on 可以提前叫醒）" } ?? "小 Claude 休息中，运行 ApprovalPet on 叫醒它")
        exit(0)
    case "on":
        setPetOn(); ensurePetRunning()
        print("小 Claude 醒啦"); exit(0)
    case "status":
        let f = FocusWatcher(); f.refresh()
        print("focused chat:  \(f.focused ?? "-")")
        print("frontmost app: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
        print("idle seconds:  \(Int(userIdleSeconds()))")
        print("muted:         \(petPref("muted"))")
        let off = petOffUntil()
        print("resting:       \(off == nil ? "no" : (off == .infinity ? "until woken" : "\(Int((off! - now()) / 60)) more min"))")
        print("pending:       \(allPending().map { "\($0.1.kind)@\($0.1.host ?? "-")" })")
        exit(0)
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
