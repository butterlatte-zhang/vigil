import Foundation
import VigilCore

// GhosttyViewBackend — the visible terminal on the libghostty core.
// Vigil forks the agent itself via `HostPTY` and owns the master fd, while a host-side
// libghostty-vt parser (`HostScreenParser`) holds the scrape screen independently of any
// surface (`.inMemory` HOST_MANAGED backend). Same TerminalBackend contract; RealCell /
// Orchestrator / trust watcher are untouched (CONTRACT §1.2).
//
// Data path:
//   HostPTY.onData  ─┬─▶ HostScreenParser.feed   (scrape source, ALWAYS live — dark-screen
//                    │                             closure: no surface needed to renderScreen)
//                    └─▶ session.receive          (renders pixels iff a surface is attached)
//   send()          → bracketedPasteWrap → session.sendInput → HostPTY.write (host injection,
//                     surface-independent)
//   renderScreen()  → HostScreenParser.renderScreen (NOT surface.readViewportText — that's
//                     kept only for vigil-parity spot-checks)
//   HostPTY.onExit  → session.finish + onEnd(code)  (waitpid real code)
//
// Off-screen cells: host-managed decouples the child process (HostPTY) AND the
// scrape screen (HostScreenParser) from the ghostty surface entirely — a worker that is
// never selected needs no surface at all. So the DISPLAY surface builds LAZILY, the moment
// the view is reparented into a real window with a non-zero size (node selected → center
// pane), via the vendored coordinator's viewDidMoveToWindow→rebuildIfReady path. A child
// forks regardless of any renderer, so no surface-build self-heal is needed; the stall
// TRUTH CHAIN (spawn liveness) lives in the Orchestrator watchdog / SessionStore, not here.

#if os(macOS)
import AppKit
import VigilGhosttyTerminal

// Protocol calls arrive on arbitrary executors (RealCell is nonisolated), but every
// ghostty/AppKit touch must happen on main — the nonisolated protocol methods hop
// (fire-and-forget for Void, main.sync for the one synchronous read).
@MainActor
public final class GhosttyViewBackend: TerminalBackend {
    public let view: AppTerminalView
    private let relay = ExitRelay()
    private let cols: Int
    private let rows: Int
    private var onEnd: ((Int32?) -> Void)?

    /// Host-managed trio, built in startOnMain (never under XCTest — the spawn guard):
    /// Vigil owns the PTY (`hostPTY`), the vendored surface bridge (`session`) renders it
    /// when a surface is attached, and the host-side parser (`parser`) is the scrape source.
    private var hostPTY: HostPTY?
    private var session: InMemoryTerminalSession?
    private var parser: HostScreenParser?
    /// Host-side OSC 10/11 answering whenever the complete query did not reach one
    /// display-surface generation (see OscColorQueryResponder). Ownership comes from
    /// `session.receive` per PTY chunk, so attach gates, rebuilds, and cross-chunk
    /// transitions cannot create a no-answer gap. nil source + nil/nil legacy colors = inert.
    private var oscResponder: OscColorQueryResponder?
    private let terminalColorSource: TerminalColorSource?
    private let foregroundColorSpec: String?
    private let backgroundColorSpec: String?
    /// mode-2031 dark-cell notification: the `TerminalColorSource` observer registration for
    /// this cell, so it can be torn down (never call an observer past cell death). nil when
    /// no color source was supplied (standalone/vigil-parity/tests — unchanged behavior).
    private var colorSchemeObserver: (source: TerminalColorSource,
                                      token: TerminalColorSource.ObserverToken)?
    /// The injection-window gate. The `write:` choke point routes
    /// user/protocol bytes through `gate.ingest`; Vigil injection bypasses it via
    /// `gate.injectDirect`. begin/end bound the window around the inject sequence.
    private var gate: InjectGate?
    private var terminated = false

    /// The session-wide canonical size authority. On `start` this
    /// seeds the fork winsize so a background/off-screen cell is born at the real width instead
    /// of 24×80; every settled resize on THIS cell also writes it back (via the session resize
    /// closure), so whichever cell is on-screen keeps the shared size fresh for the next spawn.
    /// It is also the value the attach sequence converges surface/PTY/parser to. nil = standalone
    /// (vigil-parity / winrepro / tests) → the default-fork path applies.
    public var canonical: CanonicalPaneSize?
    /// Test seam (T1): the fork winsize this cell derived from `canonical` on the last `start`.
    /// Recorded even under the XCTest fork guard (where no real fork happens), so a unit test
    /// can assert the seeding WIRING without a window-server surface. nil = no store / empty.
    private(set) var lastForkSeedForTest: CanonicalGrid?

    public init(cols: Int = 120, rows: Int = 32,
               foregroundColorSpec: String? = nil, backgroundColorSpec: String? = nil,
               terminalColorSource: TerminalColorSource? = nil) {
        self.cols = cols
        self.rows = rows
        self.foregroundColorSpec = foregroundColorSpec
        self.backgroundColorSpec = backgroundColorSpec
        self.terminalColorSource = terminalColorSource
        // cols/rows are advisory here — ghostty derives the grid from pixel size; the
        // host-side parser starts at them and is resized to match the real PTY on attach.
        view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 840, height: 520))
        relay.owner = self
        view.delegate = relay
    }

    // MARK: TerminalBackend (nonisolated entry points → main hop)

    nonisolated public func start(executable: String, args: [String], env: [String: String],
                                  cwd: String, onEnd: @escaping (Int32?) -> Void) {
        onMain { $0.startOnMain(executable: executable, args: args, env: env,
                                cwd: cwd, onEnd: onEnd) }
    }

    nonisolated public func send(_ text: String) {
        onMain { $0.sendOnMain(text) }
    }

    // Bound the injection window (gate + replay). Same nonisolated → main
    // hop as send, so — because performInject enqueues beginInject → send(body) → send(CR) →
    // endInject in order and they run FIFO on main — the gate opens before the injected bytes
    // and flushes buffered user keystrokes right after the injected CR.
    nonisolated public func beginInject() { onMain { $0.gate?.begin() } }
    nonisolated public func endInject() { onMain { $0.gate?.end() } }

    nonisolated public func renderScreen() -> String {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { renderScreenOnMain() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { renderScreenOnMain() }
        }
    }

    nonisolated public func renderAttributed() -> AttributedScreen {
        // Same nonisolated → main hop as renderScreen (the parser call itself is queue-confined).
        if Thread.isMainThread {
            return MainActor.assumeIsolated { renderAttributedOnMain() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { renderAttributedOnMain() }
        }
    }

    nonisolated public func terminate() {
        onMain { $0.terminateOnMain() }
    }

    /// Diagnostic seam (worktree/attach-synthesis): the SURFACE's OWN viewport text
    /// (`ghostty_surface_read_text`), as opposed to `renderScreen()`'s host-parser scrape. The
    /// attach garble lives in the SURFACE grid (replay consumed on the wrong grid), NEVER in the
    /// parser (fed raw bytes at the true grid) — so a repro must diff this against
    /// `renderScreen()`. nil when no surface is attached. Used only by `vigil-winrepro`.
    nonisolated public func surfaceViewportText() -> String? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { session?.readViewportText() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { session?.readViewportText() }
        }
    }

    /// Orphan-reap: the HostPTY child pid. `hostPTY` is main-actor state (assigned in
    /// startOnMain), so hop to main to read it — like renderScreen. Returns nil until the
    /// post-`start()` main hop has forked; the reaper's short poll (RealCell) covers that gap.
    nonisolated public func childProcessID() -> pid_t? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { hostPTY?.childProcessID() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { hostPTY?.childProcessID() }
        }
    }

    /// Fire-and-forget main hop; already-on-main runs synchronously so in-app callers
    /// (trust watcher, UI) keep their ordering guarantees.
    nonisolated private func onMain(_ body: @escaping @MainActor (GhosttyViewBackend) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(self) }
        } else {
            DispatchQueue.main.async { body(self) }
        }
    }

    // MARK: main-actor implementations

    private func startOnMain(executable: String, args: [String], env: [String: String],
                             cwd: String, onEnd: @escaping (Int32?) -> Void) {
        self.onEnd = onEnd

        // The winsize this cell should fork at. A background worker's view is
        // detached when we fork (only the SELECTED node's view is mounted), so without this the
        // fork falls back to 24×80 and the child hard-wraps its banner into scrollback at that
        // width forever. Seeding from the shared store (the manager's on-screen grid) makes the
        // child born full-width. Recorded for the T1 wiring assertion even under the guard.
        let seed = canonical?.current
        lastForkSeedForTest = seed

        // Unit tests (T1) assert on store/view wiring, never on live PTY traffic. XCTest
        // processes have no window-server surface AND must not fork real agents — so the
        // cell honestly does not spawn there. The headless HostPTY path IS exercised by
        // swift test, but directly (HostScrapeIntegrationTests), NOT through this backend.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }

        // Host-side scrape parser — the dark-screen closure source (PLAN §1.1). Fed every
        // PTY byte; owns the screen STATE the attach synthesizer reads. renderScreen() reads
        // THIS, surface or not. Start it at
        // the seed grid (not the 120×32 advisory) so scrape wrapping matches the child from
        // birth; a later surface commit resizes both in lockstep.
        let parser = HostScreenParser(cols: seed?.cols ?? cols, rows: seed?.rows ?? rows)
        self.parser = parser

        // Vigil owns the PTY. Its master fd is the wire the surface's write/resize hooks
        // drive, and its read fan-out feeds both parser (scrape) and session (pixels).
        let pty = HostPTY()
        self.hostPTY = pty

        // The write choke point is gated. Gate writes to the PTY;
        // the `write:` closure feeds user/protocol bytes through it (buffered while a Vigil
        // injection window is open), Vigil injection bypasses via injectDirect (sendOnMain).
        let gate = InjectGate(toPTY: { [weak pty] data in pty?.write(data) })
        self.gate = gate

        let canon = canonical
        let session = InMemoryTerminalSession(
            write: { data in gate.ingest(data) },
            resize: { [weak pty, weak parser] vp in
                let cols = Int(vp.columns), rows = Int(vp.rows)
                let wPx = Int(vp.widthPixels), hPx = Int(vp.heightPixels)
                pty?.resize(cols: cols, rows: rows, widthPx: wPx, heightPx: hPx)
                parser?.resize(cols: cols, rows: rows)
                // Publish this cell's SETTLED grid to the canonical authority so the NEXT
                // spawn forks at the right width. This fires only for non-suppressed (settled)
                // ghostty resize callbacks (the session's attach gate drops transients).
                // Reachable from ghostty's io thread; canonical takes only its own lock, never the
                // surface lock. `canon` is captured by value — no self hop off the io thread.
                canon?.update(cols: cols, rows: rows, widthPx: wPx, heightPx: hPx)
            })
        self.session = session

        // A non-nil surface is not enough to prove ghostty saw a
        // query — the attach gate deliberately holds live bytes until synthesis completes.
        // `onData` below supplies the session's actual receive result for every chunk, and
        // the responder carries that ownership across arbitrary query splits. An injected
        // live source also lets later queries observe theme updates; the legacy fixed color
        // parameters remain the fallback for existing callers.
        let colors = terminalColorSource ??
            ((foregroundColorSpec != nil || backgroundColorSpec != nil)
             ? TerminalColorSource(foreground: foregroundColorSpec,
                                   background: backgroundColorSpec)
             : nil)
        let responder = colors.map { source in
            OscColorQueryResponder(colorSource: source,
                                   respond: { [weak pty] data in pty?.write(data) })
        }
        self.oscResponder = responder

        // mode-2031 dark-cell notification: a live surface answers a scheme flip itself
        // (per-surface broadcast); THIS cell may never build one (surfaces build lazily), so
        // nobody would ever tell the agent the terminal's scheme changed. Gate on the
        // agent's own mode-2031 subscription (parser.colorSchemeReportMode) AND the
        // absence of an attached surface — a surface existing means its own broadcast
        // owns the report, and a host-sent duplicate would be a double notification, not
        // a missing one. weak-captures only (never `[weak self]`): the callback can fire
        // from any thread, and `parser`/`session`/`pty` are the actual thread-safe
        // objects the write touches, not main-actor state on `self`.
        //
        // Stale-background-cell nudge (2026-07-27 root-codex-dark-block investigation): an
        // agent with no mode-2031 subscription (codex, confirmed by a real-binary PTY A/B) can
        // still be told to re-theme via a plain resize — it re-queries OSC 10/11 and repaints
        // its explicit-RGB message boxes on SIGWINCH, the exact nudge `handleSurfaceAttach`
        // already sends on every attach. A background cell that goes long stretches (days) with
        // no attach never gets that nudge on a live flip, so it stays frozen at whatever
        // palette was current at its last attach/boot. `shouldNudgeRedraw` fires this on every
        // real flip regardless of mode-2031 (harmless extra resize for an agent that already
        // got the push) so a long-idle background cell's staleness is bounded to "since the
        // last flip" instead of "since the last attach".
        if let colors {
            let token = colors.addObserver { [weak parser, weak session, weak pty] terminalTheme in
                guard let parser, let session, let pty else { return }
                let hasSurface = session.currentSurface != nil
                if ColorSchemeReport.shouldSend(modeOn: parser.colorSchemeReportMode,
                                                hasSurface: hasSurface) {
                    pty.write(ColorSchemeReport.encode(isDark: terminalTheme == "dark"))
                }
                if ColorSchemeReport.shouldNudgeRedraw(hasSurface: hasSurface) {
                    pty.nudgeRedraw()
                }
            }
            colorSchemeObserver = (colors, token)
        }

        // Configuration BEFORE controller: with no controller the coordinator skips
        // surface builds. HOST_MANAGED — no command / no env for the surface; it never
        // execs (Vigil owns the process). env/PATH belong to HostPTY below.
        view.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session),
            workingDirectory: cwd,
            canonicalPaneSize: canonical
        )
        view.controller = TerminalController.shared
        // The DISPLAY surface builds lazily when the view is
        // reparented into a real window (node selected → center pane). Off-screen workers
        // run with zero surface — HostPTY + HostScreenParser carry process and scrape.

        // Fork the real agent. No login(1) → no path_helper → ensure a usable PATH so the
        // agent and its subtools (git/node/…) resolve (PLAN §1.2d).
        var childEnv = env
        childEnv["PATH"] = Self.ensuredPATH(env["PATH"])
        // Seed the fork winsize BEFORE pty.start. HostPTY remembers a pre-start
        // resize as the forkpty winsize (see HostPTYTests.testResizeBeforeStartSeedsForkSize),
        // so a background cell (no surface → no resize event) is born at the shared full width
        // instead of the 24×80 default. Nothing between here and pty.start touches the surface,
        // so this seed is the authoritative fork size; a post-fork re-assert still converges
        // any size that lands during the fork window.
        if let seed, seed.cols >= 2, seed.rows >= 2 {
            pty.resize(cols: seed.cols, rows: seed.rows,
                       widthPx: seed.widthPx, heightPx: seed.heightPx)
        }
        // parser/session/pty are all internally thread-safe (parser confines to its own
        // serial queue, session guards with a lock) — capture them directly so the read
        // fan-out never has to hop to main for every PTY chunk. HostPTY delivers onData on
        // its serial read queue, so the ordered ①parser.feed ②session.receive is preserved.
        pty.start(executable: executable, args: args, env: childEnv, cwd: cwd,
                  onData: { [weak parser, weak session] data in
                      parser?.feed(data)         // (1) scrape source, always live (dark-screen closure)
                      let surfaceGeneration = session?.receive(data)  // (2) exact display-delivery owner
                      // (3) Host answers unless this complete query really reached ghostty.
                      responder?.feed(data, surfaceGeneration: surfaceGeneration)
                  },
                  onExit: { [weak self, weak parser] code in
                      // waitpid real code → finish (display) + onEnd. Routed through the parser's
                      // feed-queue tail so in-flight bytes land in the scrape grid BEFORE a
                      // consumer reads renderScreen() off onEnd (onData/onExit ordering).
                      let finalize: () -> Void = { self?.onMain { $0.finishOnMain(code) } }
                      if let parser { parser.afterPending(finalize) } else { finalize() }
                  })
    }

    private func finishOnMain(_ code: Int32?) {
        guard !terminated else { return }   // terminate() already fired end; nothing to do
        detachColorSchemeObserver()
        session?.finish(exitCode: UInt32(code ?? 0), runtimeMilliseconds: 0)
        fireEnd(code)
    }

    /// mode-2031 dark-cell notification teardown: unregister this cell's observer so a
    /// dead cell's closure (and its weak captures) doesn't linger in the shared
    /// `TerminalColorSource` for the rest of the app's lifetime. Idempotent — safe to call
    /// from both the natural-exit and kill paths even though only one of them runs per cell.
    private func detachColorSchemeObserver() {
        guard let (source, token) = colorSchemeObserver else { return }
        source.removeObserver(token)
        colorSchemeObserver = nil
    }

    private func sendOnMain(_ text: String) {
        // Host injection: surface-independent (works cold / dark). Bracketed paste is
        // applied HERE from the host-side DEC mode truth, same path as HeadlessBackend.
        // Injection bytes bypass the gate via injectDirect (never buffered), so they land
        // immediately even mid-window, while other user/protocol bytes are gated and
        // buffered during an injection.
        // injectDirect writes the same host-direct PTY bytes sendInput did; echo still comes
        // back through the child PTY → surface.
        guard let parser, let gate else { return }   // not started / XCTest → drop
        let wrapped = bracketedPasteWrap(text, modeOn: parser.bracketedPasteMode)
        gate.injectDirect(Data(wrapped.utf8))
    }

    private func renderScreenOnMain() -> String {
        // The ONE scrape source: the host-side parser holds the grid even after exit and
        // even when no surface ever built (dark screen) — so scrape never goes stale.
        parser?.renderScreen() ?? ""
    }

    private func renderAttributedOnMain() -> AttributedScreen {
        // Same single source as renderScreenOnMain, with per-cell dim.
        parser?.renderAttributed() ?? AttributedScreen(lines: [])
    }

    private func terminateOnMain() {
        terminated = true
        detachColorSchemeObserver()
        hostPTY?.terminate()        // kill the child process group
        view.vigilTerminate()       // frees the display surface (PTY is owned by HostPTY)
        // Kill path only: the node is gone from the tree, the view is unreachable —
        // leaving it parented leaks NSView + CAMetalLayer per killed worker.
        view.removeFromSuperview()
        fireEnd(nil)                // signal death: no exit code
    }

    /// worktree/attach-synthesis: how long the attach replay waits for ghostty to confirm it
    /// applied the canonical surface size before proceeding anyway (bounded fail-open). ~2 render
    /// frames is enough on a live display link; the vigil-winrepro race resolved in ~26 ms.
    static let attachGridTimeout: TimeInterval = 0.5
    /// Pixel slack when matching a `receiveResizeCallback` grid to the requested canonical px:
    /// ghostty rounds the fed px DOWN to whole cells, so the reported px is a fraction of a cell
    /// short (winrepro: 2380→2372, 8 px). 80 px comfortably exceeds one cell at any real DPI
    /// while still rejecting the ~46-col build-default transient. Mirrors the isUsableViewSize
    /// floor (assumedMaxCellPixels × minUsableCells).
    static let attachGridTolerancePx = 80

    /// Attach sequence (INV2/INV3). Fired from the coordinator right after it built the surface
    /// and requested the canonical size via `seedAttachBaseline`. The replay is HELD by the grid
    /// barrier until ghostty confirms (via receiveResizeCallback) that it actually applied the
    /// canonical grid — `setSize` is async, so firing immediately would replay onto ghostty's
    /// transient build-default (~46-col) grid, causing wrap/overprint garble. Once confirmed, on
    /// the PTY read queue (INV2/INV3, ordered with live `onData`):
    ///   1. converge PTY + parser to ghostty's ACTUAL reported grid (more accurate than the seed
    ///      estimate; nil on fail-open → the canonical estimate);
    ///   2. synthesize a clean VT stream from the parser's screen STATE and replay it into the
    ///      now-correctly-sized surface (SOLE display source in the attach window — live bytes
    ///      were held by the session's attach gate; state synthesis is volume-independent, so it
    ///      never head-truncates on long output);
    ///   3. lift the attach gate (live resumes, in order, right after the replay);
    ///   4. nudge a full repaint so a full-screen child redraws at canonical.
    /// No surface lock is taken off any ghostty-callback path: the barrier fires the
    /// continuation on ghostty's io thread, but it only ENQUEUES onto the read queue.
    fileprivate func handleSurfaceAttach(_ surface: TerminalSurface) {
        guard let parser, let session else { return }
        let g = canonical?.current
        let pty = hostPTY
        let run: (@escaping () -> Void) -> Void = pty?.enqueueOnReadQueue ?? { $0() }

        // The converge → replay → lift → nudge body. `reported` = ghostty's actual grid at the
        // barrier; fall back to the canonical estimate (fail-open / standalone).
        let converge: (InMemoryTerminalViewport?) -> Void = { [weak pty] reported in
            let cols = reported.map { Int($0.columns) } ?? g?.cols
            let rows = reported.map { Int($0.rows) } ?? g?.rows
            if let cols, let rows, cols >= 2, rows >= 2 {
                let wPx = reported.map { Int($0.widthPixels) } ?? g?.widthPx ?? 0
                let hPx = reported.map { Int($0.heightPixels) } ?? g?.heightPx ?? 0
                pty?.resize(cols: cols, rows: rows, widthPx: wPx, heightPx: hPx)
                parser.resize(cols: cols, rows: rows)
            }
            // Synthesize a clean VT stream from the parser's CURRENT screen STATE (grid +
            // scrollback + cursor + modes) rather than replaying a raw byte ring. State
            // synthesis is volume-independent, so a long-lived cell whose output exceeds any
            // fixed buffer size never loses its early/scrollback content to head-truncation.
            // INV3: this runs at the SAME cut point a byte-ring snapshot would — on the PTY
            // read queue, ordered with live onData, and parser.feed hops the parser's serial
            // queue while snapshot() reads it under queue.sync, so the snapshot captures
            // exactly the bytes fed up to here; live resumes strictly after.
            let attach = parser.synthesize()
            TerminalDebugLog.log(.output, "attach-synthesize bytes=\(attach.count) grid=\(cols ?? -1)x\(rows ?? -1)")
            if !attach.isEmpty { session.replay(attach) }
            session.endAttachGate()      // live resumes strictly after the replay
            pty?.nudgeRedraw()           // full-screen child repaints its whole screen at canonical
        }

        // Diagnostic kill-switch (vigil-winrepro only): replay immediately, reproducing the
        // pre-barrier race in the SAME binary so the repro toggles RED/GREEN on one parameter set.
        let barrierOff = ProcessInfo.processInfo.environment["VIGIL_ATTACH_BARRIER_OFF"] == "1"
        guard let g, !barrierOff else {
            // Standalone (vigil-parity / tests): no canonical authority, so no async setSize to
            // wait for — replay immediately (pre-barrier behavior preserved).
            run { converge(nil) }
            return
        }
        // Hold the replay until ghostty reports it applied the canonical px (event-driven,
        // bounded fail-open). The continuation runs the converge/replay on the PTY read queue.
        session.awaitCanonicalGrid(widthPx: g.widthPx, heightPx: g.heightPx,
                                   tolerancePx: Self.attachGridTolerancePx,
                                   timeout: Self.attachGridTimeout) { reported in
            run { converge(reported) }
        }
    }

    private func fireEnd(_ code: Int32?) { onEnd?(code); onEnd = nil }

    /// Ensure the child's PATH can resolve its toolchain. Without login(1)'s path_helper
    /// step, a Finder-launched .app (minimal PATH ≈ just the system dirs) would strand the
    /// agent binary (claude/codex live in ~/.local/bin, homebrew, or under a JS runtime
    /// manager) and its subtools (git/node). Merge the common tool dirs in without dropping
    /// whatever the inherited env already had (a `swift run` dev launch keeps its full shell
    /// PATH, so nothing new is appended there — the inherited entries already contain these).
    ///
    /// `extra` is VigilCore.ToolchainPaths — the SAME table CLIProber's detection-side
    /// candidateDirs reads, so a toolchain CLIProber finds (e.g. codex under an nvm glob)
    /// is guaranteed resolvable here too; a shebang like `#!/usr/bin/env node` must resolve
    /// through the same PATH the detector used. `home` is a seam (tests point it at a
    /// throwaway HOME to exercise the nvm glob) — do not read NSHomeDirectory() twice.
    static func ensuredPATH(_ inherited: String?, home: String = NSHomeDirectory()) -> String {
        let extra = VigilCore.ToolchainPaths.candidateDirs(home: home) +
            ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var parts = (inherited?.split(separator: ":").map(String.init)) ?? []
        for dir in extra where !parts.contains(dir) { parts.append(dir) }
        return parts.joined(separator: ":")
    }

    /// Bridges the vendored view's surface-lifecycle delegate back to the backend. The
    /// child-exited delegate is intentionally inert: the real exit signal is HostPTY's
    /// waitpid (handleHostExit), so routing the surface's process_exit here too would
    /// double-fire onEnd with a display code that overwrites the real code.
    private final class ExitRelay: TerminalSurfaceChildExitedDelegate,
                                   TerminalSurfaceLifecycleDelegate {
        weak var owner: GhosttyViewBackend?
        func terminalChildDidExit(exitCode: UInt32, runtimeMs: UInt64) { /* HostPTY owns exit */ }
        func terminalDidAttachSurface(_ surface: TerminalSurface) {
            owner?.handleSurfaceAttach(surface)
        }
        func terminalDidDetachSurface() {}
    }
}
#endif
