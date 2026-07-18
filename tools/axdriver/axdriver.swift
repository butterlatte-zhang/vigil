// axdriver — macOS Accessibility driver CLI (the AI agent's hands)
// Drives the real app by element (accessibilityIdentifier; see the dotted-id contract in app/ACCESSIBILITY_IDS.md), not by coordinates.
// Build: swiftc -O -o axdriver axdriver.swift
// Usage: see README.md in this directory.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Basics

func die(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func requireAXTrust() {
    guard !AXIsProcessTrusted() else { return }
    die(
        """
        axdriver: missing Accessibility permission; cannot read/drive other apps' elements.
        Grant it: System Settings → Privacy & Security → Accessibility → enable the toggle for the host running axdriver (Terminal / iTerm / IDE).
        Restart that terminal after changing the permission, then re-run this command.
        """, code: 2)
}

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v
}

func str(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }

func frame(_ el: AXUIElement) -> CGRect? {
    guard let pv = attr(el, kAXPositionAttribute), let sv = attr(el, kAXSizeAttribute) else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)  // global screen coordinates, top-left origin (consistent with CGEvent)
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

// MARK: - Target app resolution

/// With multiple instances, pick the most recently launched one and warn (common in dev: a new instance the agent
/// started vs. the old one the user is using; driving the user's instance by mistake is risky — when unsure, use --app <pid>).
func pick(_ matches: [NSRunningApplication], _ what: String) -> NSRunningApplication? {
    guard matches.count > 1 else { return matches.first }
    let chosen = matches.max { a, b in
        if let la = a.launchDate, let lb = b.launchDate, la != lb { return la < lb }
        return a.processIdentifier < b.processIdentifier  // launchDate may be nil (e.g. launched directly via nohup); fall back to pid
    }!
    let pids = matches.map { String($0.processIdentifier) }.joined(separator: ", ")
    FileHandle.standardError.write(
        "axdriver: ⚠️ \(matches.count) processes match \(what) (pid: \(pids)); picked the most recently launched pid \(chosen.processIdentifier); if wrong, specify explicitly with --app <pid>\n"
            .data(using: .utf8)!)
    return chosen
}

func resolveApp(_ spec: String?) -> NSRunningApplication {
    let apps = NSWorkspace.shared.runningApplications
    if let spec {
        if let pid = pid_t(spec), let a = NSRunningApplication(processIdentifier: pid) { return a }
        if let a = pick(apps.filter { $0.bundleIdentifier == spec || $0.localizedName == spec }, "\"\(spec)\"") {
            return a
        }
        die("axdriver: no running app found for \"\(spec)\" (accepts bundle id / pid / process name)")
    }
    if let a = pick(apps.filter { $0.localizedName == "VigilApp" || ($0.bundleIdentifier?.lowercased().contains("vigil") ?? false) }, "VigilApp") {
        return a
    }
    die("axdriver: no --app given and no running VigilApp found. Run `swift run VigilApp` first, or specify the target with --app <bundle-id|pid|process-name>.")
}

// MARK: - Element tree / lookup

func nodeJSON(_ el: AXUIElement, depth: Int, maxDepth: Int) -> [String: Any] {
    var d: [String: Any] = [:]
    d["role"] = str(el, kAXRoleAttribute) ?? "?"
    if let t = str(el, kAXTitleAttribute), !t.isEmpty { d["title"] = t }
    if let i = str(el, "AXIdentifier"), !i.isEmpty { d["id"] = i }
    if let desc = str(el, kAXDescriptionAttribute), !desc.isEmpty { d["desc"] = desc }
    if let v = attr(el, kAXValueAttribute) as? String, !v.isEmpty { d["value"] = String(v.prefix(200)) }
    if let f = frame(el) { d["frame"] = [Int(f.origin.x), Int(f.origin.y), Int(f.width), Int(f.height)] }
    if depth < maxDepth {
        let kids = children(el).map { nodeJSON($0, depth: depth + 1, maxDepth: maxDepth) }
        if !kids.isEmpty { d["children"] = kids }
    }
    return d
}

/// id match contract: exact equality, or prefix match (covers dynamic ids like rail.node.<id>: querying "rail.node." hits every node row).
func matches(_ identifier: String, query: String) -> Bool {
    identifier == query || identifier.hasPrefix(query)
}

func collectMatches(_ el: AXUIElement, query: String, into out: inout [AXUIElement], depth: Int = 0) {
    if depth > 80 { return }
    if let i = str(el, "AXIdentifier"), matches(i, query: query) { out.append(el) }
    for c in children(el) { collectMatches(c, query: query, into: &out, depth: depth + 1) }
}

/// Polling lookup (the UI may not be fully rendered yet), default 3-second timeout.
func waitFind(appEl: AXUIElement, query: String, timeout: TimeInterval = 3) -> [AXUIElement] {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        var out: [AXUIElement] = []
        collectMatches(appEl, query: query, into: &out)
        if !out.isEmpty || Date() > deadline { return out }
        usleep(300_000)
    }
}

func printJSON(_ obj: Any) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

// MARK: - Actions

func clickCenter(of el: AXUIElement) {
    guard let f = frame(el) else { die("axdriver: element has no frame; cannot click by coordinates") }
    let pt = CGPoint(x: f.midX, y: f.midY)
    for (type, btn) in [(CGEventType.leftMouseDown, CGMouseButton.left), (.leftMouseUp, .left)] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: btn)?
            .post(tap: .cghidEventTap)
        usleep(60_000)
    }
}

func typeText(_ text: String) {
    // Inject unicode via CGEvent in 16-char chunks (works even for terminals / elements without AXValue)
    var chars = Array(text.utf16)
    while !chars.isEmpty {
        let chunk = Array(chars.prefix(16))
        chars.removeFirst(chunk.count)
        for keyDown in [true, false] {
            let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown)
            ev?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            ev?.post(tap: .cghidEventTap)
        }
        usleep(30_000)
    }
}

func frontWindowID(pid: pid_t) -> CGWindowID? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else { return nil }
    for w in list
    where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
        return (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }
    return nil
}

// MARK: - Argument parsing

var args = Array(CommandLine.arguments.dropFirst())
let usage = """
Usage: axdriver <subcommand> [args] [--app <bundle-id|pid|process-name>]
  tree [<app>] [--max-depth N]     dump the element tree (role/title/id/frame, JSON)
  find <id> [--timeout secs]       find element by accessibilityIdentifier (exact or prefix match)
  click <id>                       click element (prefers AXPress, falls back to center-coordinate click)
  type <id> <text>                 focus the element, then type text
  screenshot [--out path]          screenshot the target app's front window (screencapture -l)
The target app defaults to auto-finding a running VigilApp; tree also accepts a positional arg to specify the target.
"""
guard !args.isEmpty else { die(usage) }
let cmd = args.removeFirst()
if cmd == "help" || cmd == "--help" || cmd == "-h" { print(usage); exit(0) }

func takeFlag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

let appSpec = takeFlag("--app")
let outPath = takeFlag("--out")
let maxDepth = Int(takeFlag("--max-depth") ?? "60") ?? 60
let timeout = TimeInterval(takeFlag("--timeout") ?? "3") ?? 3

requireAXTrust()

switch cmd {
case "tree":
    let app = resolveApp(appSpec ?? args.first)
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    printJSON([
        "app": app.localizedName ?? "?", "pid": Int(app.processIdentifier),
        "bundleId": app.bundleIdentifier ?? NSNull() as Any,
        "tree": children(appEl).map { nodeJSON($0, depth: 0, maxDepth: maxDepth) },
    ])

case "find":
    guard let query = args.first else { die("usage: axdriver find <id>") }
    let app = resolveApp(appSpec)
    let found = waitFind(appEl: AXUIElementCreateApplication(app.processIdentifier), query: query, timeout: timeout)
    if found.isEmpty { die("axdriver: no element found with id matching \"\(query)\" (exact or prefix)", code: 3) }
    printJSON(found.map { nodeJSON($0, depth: 0, maxDepth: 0) })

case "click":
    guard let query = args.first else { die("usage: axdriver click <id>") }
    let app = resolveApp(appSpec)
    let found = waitFind(appEl: AXUIElementCreateApplication(app.processIdentifier), query: query, timeout: timeout)
    guard let el = found.first else { die("axdriver: not found \"\(query)\"", code: 3) }
    if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success {
        print("clicked \(query) (AXPress)")
    } else {
        app.activate()
        usleep(200_000)
        clickCenter(of: el)
        print("clicked \(query) (coordinate-click fallback)")
    }

case "type":
    guard args.count >= 2 else { die("usage: axdriver type <id> <text>") }
    let (query, text) = (args[0], args[1])
    let app = resolveApp(appSpec)
    let found = waitFind(appEl: AXUIElementCreateApplication(app.processIdentifier), query: query, timeout: timeout)
    guard let el = found.first else { die("axdriver: not found \"\(query)\"", code: 3) }
    app.activate()
    usleep(200_000)
    AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(150_000)
    var settable = DarwinBoolean(false)
    AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
    if settable.boolValue, AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString) == .success {
        print("typed into \(query) (AXValue)")
    } else {
        typeText(text)
        print("typed into \(query) (CGEvent typing)")
    }

case "screenshot":
    let app = resolveApp(appSpec ?? args.first)
    let path = outPath ?? "axdriver-shot.png"
    func capture() -> Bool {
        guard let winID = frontWindowID(pid: app.processIdentifier) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(winID)", path]
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
    var ok = capture()
    if !ok {  // The window may be on another Space: activate to bring it to the front and retry once
        app.activate()
        usleep(600_000)
        ok = capture()
    }
    guard ok else {
        die("""
        axdriver: window screenshot failed (pid \(app.processIdentifier)). Possible causes:
        - missing Screen Recording permission: System Settings → Privacy & Security → Screen Recording → enable the terminal running axdriver
        - the target window is not on screen (minimized / another Space)
        """, code: 4)
    }
    print("screenshot -> \(path)")

default:
    die(usage)
}
