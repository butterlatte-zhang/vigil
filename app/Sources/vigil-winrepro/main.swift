import AppKit
import Foundation
import VigilRuntime
import VigilGhosttyTerminal

// vigil-winrepro — winsize timing diagnostic (Tier-2 manual, like vigil-parity).
//
// Drives the REAL GhosttyViewBackend → libghostty surface → HostPTY path through an
// off-screen NSWindow, so the surface's resize events (receive_resize / synchronizeMetrics)
// and the forkpty winsize can be traced end-to-end WITHOUT the full app / a visible display.
// Enable TerminalDebugLog(.metrics) below to see every resize dispatch; renderScreen() at
// the end shows the child's actual wrap width. Kept in-tree to reproduce fresh-start terminals
// rendering narrow on a real machine when the GUI timing is reachable. NOT run by
// `swift test` — needs AppKit + a window-server session.
//
// Scenarios (env-driven), all mirror a fresh ROOT session (view attached BEFORE start so
// controller-assign finds an attached, sized view — like a selected node):
//   WIN_W/WIN_H            final window content size          (default 1200x760)
//   START_W/START_H        the view's frame AT start(); GROW to WIN_* after start
//   ATTACH_BEFORE_START=0  worker mimic: view detached at start, attached at t+0.3
//   DETACH_REATTACH=1      mimic SwiftUI view-tree diffing (detach then re-add)
//   SKIP_ORDER_FRONT=1     leave the window un-ordered (backing-scale probe)
//   REPRO_EXE/REPRO_ARGS/REPRO_CWD   child to fork (default /bin/sh 'stty size'); point at
//                          a real agent (claude) to see its alt-screen wrap width
//   REPRO_DUMP_T           seconds before dumping renderScreen and exiting (default 5.5)
//
// The ATTACH GRID BARRIER repro. Proves the replay-on-wrong-grid
// race: a late-attached surface consumes the attach replay on ghostty's transient build-default
// (~46-col) grid before the canonical grid lands (async setSize), wrapping+overprinting the
// frame into scatter (independent of replay size — short-lived cells garble too). Reads the
// SURFACE grid (ghostty_surface_read_text) vs the parser scrape and prints a GARBLE/CLEAN
// verdict (exit 1/0). Self-contained (built-in TUI child) — RED/GREEN toggle on one param set:
//   REPRO_ATTACH_GARBLE=1  enable the scenario (writes a built-in TUI child, dumps surface-vs-
//                          parser diff + verdict). Pair with a canonical-sized window so there
//                          is no post-attach reflow noise.
//   VIGIL_ATTACH_BARRIER_OFF=1  reproduce the race with the barrier disabled (replay immediately) → RED.
// Proven run (GREEN with barrier, RED without), one param set:
//   REPRO_ATTACH_GARBLE=1 ATTACH_BEFORE_START=0 SEED_COLS=140 SEED_ROWS=40 \
//     WIN_W=1190 WIN_H=740 START_W=1190 START_H=740 REPRO_DUMP_T=6 swift run vigil-winrepro

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// Monotonic-ms timestamps on every debug line so the attach-garble
// repro can prove ORDERING — replay call vs the receiveResizeCallback grid reports.
let t0 = ProcessInfo.processInfo.systemUptime
func stampMs() -> String { String(format: "%8.1f", (ProcessInfo.processInfo.systemUptime - t0) * 1000) }
TerminalDebugLog.sink = { msg in err("[\(stampMs())ms] \(msg)") }
TerminalDebugLog.enable(.standard)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let env = ProcessInfo.processInfo.environment
    let w = Double(env["WIN_W"] ?? "1200") ?? 1200
    let h = Double(env["WIN_H"] ?? "760") ?? 760
    // START_W/START_H: the view's frame AT start() (controller-assign). GROW mode grows the
    // view to WIN_W/WIN_H shortly AFTER start — mimicking SwiftUI laying the pane out small
    // first (or 0), then to full width, with pty.start racing in between.
    let sw = Double(env["START_W"] ?? "\(w)") ?? w
    let sh = Double(env["START_H"] ?? "\(h)") ?? h
    // If ATTACH_BEFORE_START=0, mimic a fresh worker (view detached at start).
    let attachBefore = (env["ATTACH_BEFORE_START"] ?? "1") != "0"

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    // Container fixed at full size; the terminal VIEW starts at START_W×START_H (no autoresize
    // so we control its frame explicitly), then we grow it after start.
    let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
    let backend = GhosttyViewBackend(cols: 120, rows: 32)
    // SEED_COLS/SEED_ROWS pre-populate a shared geometry store (as the app
    // does from the on-screen manager), so a worker-mimic (ATTACH_BEFORE_START=0, view detached
    // at fork) forks at the seed width instead of the 24×80 default — its early output is then
    // full-width from birth. Without SEED_*, the store stays empty.
    if let sc = env["SEED_COLS"].flatMap(Int.init), let sr = env["SEED_ROWS"].flatMap(Int.init) {
        let canonical = CanonicalPaneSize()
        // Realistic device px so `seedAttachBaseline` sets a faithful pane size: ghostty's real
        // cell at scale 2 is ~17×37 px (observed). SEED_PXW/SEED_PXH override to model a seed
        // whose pixel size deliberately mismatches the real pane (self-correction scenario).
        let pxw = env["SEED_PXW"].flatMap(Int.init) ?? (sc * 17)
        let pxh = env["SEED_PXH"].flatMap(Int.init) ?? (sr * 37)
        canonical.update(cols: sc, rows: sr, widthPx: pxw, heightPx: pxh)
        backend.canonical = canonical
        err("[REPRO] seeded canonical pane size cols=\(sc) rows=\(sr) px=\(pxw)x\(pxh) (worker forks + converges to this)")
    }
    backend.view.frame = NSRect(x: 0, y: 0, width: sw, height: sh)

    if attachBefore {
        container.addSubview(backend.view)
        window.contentView = container
        if env["SKIP_ORDER_FRONT"] != "1" { window.orderFront(nil) }
        err("[REPRO] window \(Int(w))x\(Int(h)) attached BEFORE start at \(Int(sw))x\(Int(sh)) scale=\(window.backingScaleFactor) orderedFront=\(env["SKIP_ORDER_FRONT"] != "1")")
    } else {
        err("[REPRO] view DETACHED at start (worker mimic)")
    }

    // Built-in TUI child for the attach-garble repro, so the scenario
    // is self-contained (no external script). It draws a full known frame with ABSOLUTE cursor
    // positioning (\e[r;1H) at the seed width, then goes quiet — so the only bytes the surface
    // ever sees are the attach REPLAY. If replay runs on ghostty's transient build-default grid
    // (~46 cols) the wide lines wrap+overprint into scatter; on the correct grid they don't.
    var garbleExe: String?
    if env["REPRO_ATTACH_GARBLE"] == "1" && env["REPRO_EXE"] == nil {
        let path = NSTemporaryDirectory() + "vigil_winrepro_tui_\(getpid()).py"
        let py = """
        import sys, time
        W = 130
        ROWS = 38
        o = sys.stdout
        o.write("\\x1b[2J")
        for r in range(1, ROWS + 1):
            o.write("\\x1b[%d;1H" % r)
            label = "ROW-%02d " % r
            o.write(label + "".join(chr(65 + ((r + c) % 26)) for c in range(W - len(label))))
        o.write("\\x1b[%d;1HFINAL-FRAME-DONE" % (ROWS + 1))
        o.flush()
        time.sleep(30)
        """
        try? py.write(toFile: path, atomically: true, encoding: .utf8)
        garbleExe = path
        err("[REPRO] built-in TUI child written to \(path)")
    }

    let exe = env["REPRO_EXE"] ?? (garbleExe != nil ? "/usr/bin/python3" : "/bin/sh")
    let args: [String]
    let childEnv: [String: String]
    if let garbleExe {
        args = [garbleExe]
        childEnv = ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
    } else if exe == "/bin/sh" {
        args = ["-c", "sleep 1; echo STTY:; stty size; sleep 4"]
        childEnv = ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
    } else {
        // Real agent: inherit the full environment (HOME/PATH/config) + TERM.
        args = (env["REPRO_ARGS"] ?? "").split(separator: " ").map(String.init)
        var e = env
        e["TERM"] = "xterm-256color"
        childEnv = e
    }
    err("[REPRO] exec \(exe) args=\(args)")
    backend.start(executable: exe, args: args, env: childEnv, cwd: env["REPRO_CWD"] ?? "/tmp",
                  onEnd: { code in err("[REPRO] onEnd code=\(String(describing: code))") })

    if !attachBefore {
        // Attach ~0.3s after start, mimicking "spawn then select".
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                container.addSubview(backend.view)
                window.contentView = container
                window.orderFront(nil)
                err("[REPRO] view attached AFTER start (t+0.3s)")
            }
        }
    } else if sw != w || sh != h {
        // GROW: after start, lay the view out to full size (SwiftUI's final layout pass).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                backend.view.frame = NSRect(x: 0, y: 0, width: w, height: h)
                err("[REPRO] view GROWN to \(Int(w))x\(Int(h)) (t+0.3s, post-start)")
            }
        }
    }

    // Pump the runloop and dump the scrape screen so we can read the child's stty size.
    // DETACH_REATTACH: mimic SwiftUI diffing removing then re-adding the terminal view.
    if env["DETACH_REATTACH"] == "1" {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated {
                backend.view.removeFromSuperview()
                err("[REPRO] view DETACHED (t+0.2, mimic SwiftUI diff)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            MainActor.assumeIsolated {
                backend.view.frame = container.bounds
                container.addSubview(backend.view)
                err("[REPRO] view RE-ATTACHED (t+0.45)")
            }
        }
    }

    let dumpT = Double(env["REPRO_DUMP_T"] ?? "5.5") ?? 5.5
    DispatchQueue.main.asyncAfter(deadline: .now() + dumpT) {
        MainActor.assumeIsolated {
            err("=== renderScreen (host parser — the TRUE grid) ===")
            let parserText = backend.renderScreen()
            err(parserText)
            err("=== end renderScreen ===")

            // The attach garble lives in the SURFACE grid (replay
            // consumed on the wrong grid), NEVER in the parser. Diff the two line-by-line —
            // any mismatch after settle is the garble (overprint / scattered words).
            if env["REPRO_ATTACH_GARBLE"] == "1" {
                let surfaceText = backend.surfaceViewportText() ?? "<no surface>"
                err("=== surfaceViewportText (ghostty surface — what the USER sees) ===")
                err(surfaceText)
                err("=== end surfaceViewportText ===")

                func norm(_ s: String) -> [String] {
                    s.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { line -> String in
                            var t = String(line)
                            while t.hasSuffix(" ") { t.removeLast() }
                            return t
                        }
                        // drop trailing all-blank lines so row-count padding differences don't
                        // masquerade as garble.
                        .reversed().drop(while: { $0.isEmpty }).reversed().map { $0 }
                }
                let p = norm(parserText), s = norm(surfaceText)
                var mismatches = 0
                let n = max(p.count, s.count)
                for i in 0..<n {
                    let pl = i < p.count ? p[i] : "<none>"
                    let sl = i < s.count ? s[i] : "<none>"
                    if pl != sl {
                        mismatches += 1
                        if mismatches <= 12 {
                            err("DIFF row \(String(format: "%02d", i)):")
                            err("  parser : [\(pl)]")
                            err("  surface: [\(sl)]")
                        }
                    }
                }
                if mismatches == 0 {
                    err("REPRO VERDICT: CLEAN — surface grid matches parser (no attach garble)")
                    exit(0)
                } else {
                    err("REPRO VERDICT: GARBLE — \(mismatches) row(s) differ between surface and parser (attach replay on wrong grid)")
                    exit(1)
                }
            }
            exit(0)
        }
    }
    app.run()
}
