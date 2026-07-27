import AppKit
import Foundation
import VigilRuntime
import VigilGhosttyTerminal

// vigil-colorflip — mounted-surface theme-flip diagnostic (Tier-2 manual, like vigil-winrepro).
//
// 2026-07-27 theme-flip-residue investigation, round 2: round 1 (4a3e8f6) only nudged a
// BACKGROUND cell (hasSurface == false) on a live theme flip, on the assumption that a MOUNTED
// cell needs no host help because "a surface existing means its own per-surface broadcast owns
// the report." This tool drove the REAL production call path (`TerminalController.
// setColorScheme`, exactly what `VGGhosttyTheme.apply` calls on every real flip) against a real,
// ATTACHED `GhosttyViewBackend` surface, with a synthetic PTY child that subscribes to DEC mode
// 2031 and logs every byte + signal it actually receives.
//
// CONFIRMED FINDING (not a harness artifact — see the ruled-out alternatives below): across
// repeated dark→light→dark flips, with the resolved config's own background line genuinely
// alternating (212121/F7F7F7 — printed by `flip()` below) and with the real macOS
// NSApp.appearance forced both ways (`COLORFLIP_FORCE_DARK_APPEARANCE=1`), the surface's own
// unsolicited `CSI ?997;n` push to the child PTY was observed STUCK at `;2n` (light) on every
// single flip regardless of the requested scheme, and no SIGWINCH ever reached the child. Ruled
// out as explanations: (a) `AppTerminalView.viewDidChangeEffectiveAppearance` racing our push —
// its call path logs through `TerminalSurface.setColorScheme` and never appeared; (b) the
// report tracking the real OS appearance instead of our push — forcing NSApp.appearance to
// darkAqua did not change the observed `;2n`. This is upstream libghostty 1.2.8 behavior Vigil
// cannot influence by reordering its own calls; the fix (see `ColorSchemeReport.shouldSend`'s
// doc) is to stop trusting a mounted surface's own broadcast and always send the host push.
//
// Kept in-tree as a regression probe: rerun after any libghostty version bump to confirm this
// upstream behavior hasn't changed (which would make the unconditional host push merely
// redundant rather than load-bearing, not wrong either way).
//
// Usage:
//   swift run vigil-colorflip
//   COLORFLIP_LOG=/tmp/x.log COLORFLIP_AT=2.5 COLORFLIP_WAIT=2.5 swift run vigil-colorflip
//   COLORFLIP_FORCE_DARK_APPEARANCE=1 swift run vigil-colorflip   # rule out real-OS-appearance theory

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let t0 = ProcessInfo.processInfo.systemUptime
func stampMs() -> String { String(format: "%8.1f", (ProcessInfo.processInfo.systemUptime - t0) * 1000) }
TerminalDebugLog.sink = { msg in err("[\(stampMs())ms] \(msg)") }
TerminalDebugLog.enable(.standard)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if ProcessInfo.processInfo.environment["COLORFLIP_FORCE_DARK_APPEARANCE"] == "1" {
        app.appearance = NSAppearance(named: .darkAqua)
        err("[COLORFLIP] forced NSApp.appearance = darkAqua (probing whether the 997 report tracks real AppKit appearance instead of our explicit setColorScheme push)")
    }

    let env = ProcessInfo.processInfo.environment
    let logPath = env["COLORFLIP_LOG"] ?? (NSTemporaryDirectory() + "vigil_colorflip_\(getpid()).log")
    let atSeconds = Double(env["COLORFLIP_AT"] ?? "2.0") ?? 2.0
    let waitSeconds = Double(env["COLORFLIP_WAIT"] ?? "2.5") ?? 2.5

    // Synthetic PTY child: subscribes to DEC mode 2031, then raw-reads stdin and logs
    // EVERY chunk (with a timestamp) plus every SIGWINCH it receives, to `logPath`.
    let childPath = NSTemporaryDirectory() + "vigil_colorflip_child_\(getpid()).py"
    let py = """
    import sys, os, time, signal, termios, tty

    LOG = \(pyStringLiteral(logPath))
    logf = open(LOG, "ab", buffering=0)
    def wr(s):
        logf.write(s.encode())

    wr("BOOT t=%.3f\\n" % time.time())
    os.write(1, b"\\x1b[?2031h")  # subscribe DEC mode 2031 (color-scheme-update reports)
    wr("SUBSCRIBED-2031 t=%.3f\\n" % time.time())

    fd = sys.stdin.fileno()
    tty.setraw(fd)

    def on_winch(signum, frame):
        wr("SIGWINCH t=%.3f\\n" % time.time())
    signal.signal(signal.SIGWINCH, on_winch)

    deadline = time.time() + \(waitSeconds + atSeconds + 5.0)
    while time.time() < deadline:
        try:
            r = os.read(fd, 4096)
        except OSError:
            break
        if not r:
            break
        wr("DATA t=%.3f len=%d bytes=%r\\n" % (time.time(), len(r), r))
    wr("EXIT t=%.3f\\n" % time.time())
    """
    try? py.write(toFile: childPath, atomically: true, encoding: .utf8)
    try? FileManager.default.removeItem(atPath: logPath)
    err("[COLORFLIP] child script: \(childPath)")
    err("[COLORFLIP] log path:    \(logPath)")

    let w = 900.0, h = 600.0
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
    let backend = GhosttyViewBackend(cols: 120, rows: 32)
    backend.view.frame = NSRect(x: 0, y: 0, width: w, height: h)
    container.addSubview(backend.view)
    window.contentView = container
    window.orderFront(nil)
    err("[COLORFLIP] window attached BEFORE start (mounted surface from the moment it builds)")

    let childEnv = ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
    backend.start(executable: "/usr/bin/python3", args: [childPath], env: childEnv, cwd: "/tmp",
                  onEnd: { code in err("[COLORFLIP] onEnd code=\(String(describing: code))") })

    @MainActor
    func flip(_ scheme: TerminalColorScheme) {
        let controller = TerminalController.shared
        err("[COLORFLIP] t=\(stampMs())ms BEFORE-call effectiveColorScheme=\(controller.effectiveColorScheme)")
        err("[COLORFLIP] t=\(stampMs())ms calling TerminalController.shared.setColorScheme(\(scheme)) — mirrors VGGhosttyTheme.apply's real call, surface IS mounted (hasSurface=true)")
        controller.setColorScheme(scheme)
        err("[COLORFLIP] t=\(stampMs())ms AFTER-call effectiveColorScheme=\(controller.effectiveColorScheme)")
        let bgLine = controller.renderedConfig.split(separator: "\n").first { $0.hasPrefix("background") }
        err("[COLORFLIP] t=\(stampMs())ms renderedConfig background line: \(bgLine.map(String.init) ?? "<none>")")
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + atSeconds) {
        MainActor.assumeIsolated { flip(.dark) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + atSeconds + 1.0) {
        MainActor.assumeIsolated { flip(.light) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + atSeconds + 2.0) {
        MainActor.assumeIsolated { flip(.dark) }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + atSeconds + 2.0 + waitSeconds) {
        MainActor.assumeIsolated {
            err("=== child log (\(logPath)) ===")
            if let contents = try? String(contentsOfFile: logPath, encoding: .utf8) {
                err(contents)
            } else {
                err("<no log file>")
            }
            err("=== end child log ===")

            let raw = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            let got997 = raw.contains("997")
            let gotWinch = raw.contains("SIGWINCH")
            // Extract every distinct `;Nn` value actually seen — the expected sequence for
            // dark→light→dark is {1, 2, 1}; a single constant value across all three flips is
            // the confirmed-bug signature (see the file header).
            let nValues = raw.split(separator: "\n")
                .compactMap { line -> String? in
                    guard let range = line.range(of: "997;") else { return nil }
                    return String(line[range.upperBound...].prefix(1))
                }
            err("VERDICT: CSI-997-observed=\(got997) SIGWINCH-observed=\(gotWinch) n-values-seen=\(nValues)")
            exit(0)
        }
    }

    app.run()
}

func pyStringLiteral(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
