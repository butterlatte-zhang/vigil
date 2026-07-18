import Foundation

// The minimal terminal-process surface RealCell needs (DOCTRINE §0/§8).
//   • HeadlessBackend (HostPTY + libghostty-vt VtScreen) → tests / vigil-smoke (no window)
//   • GhosttyViewBackend (HostPTY + libghostty surface)  → VigilApp (the visible terminal)
// RealCell is backend-agnostic so the load-bearing PTY mechanism (spike step2) can be
// smoke-tested headless AND drive the real on-screen terminal, without welding "node == view".
// Both stacks parse via libghostty (VtScreen headless / GhosttyKit surface).

/// The one TERM value every backend/harness falls back to. Forced while xterm-ghostty
/// terminfo ships nowhere (absent from the system db, not bundled in
/// GhosttyKit.xcframework) — cell subprocesses (tput/vim/…) would hit "unknown
/// terminal". Revisit when the .app bundles terminfo.
let vigilFallbackTERM = "xterm-256color"

/// Stage A — one screen row read WITH per-cell attributes. `text` is byte-identical to
/// the matching `renderScreen()` row (same §12.3 normalization: unwritten/control cells →
/// space, trimRight); `dim[i]` is the SGR-2 "faint" bit (libghostty `GhosttyStyle.faint`)
/// of the cell that produced the i-th **Character**
/// of `text`. `text.count == dim.count` always (index-aligned). The stage-B input-line probe
/// strips the mode prefix (`❯`/`!`/`#`/`>` + whitespace) and reads the remaining dim to tell
/// claude's dim placeholder (`.clear`) from real user typing (`.userTyping`).
public struct AttributedLine: Sendable, Equatable {
    public let text: String
    public let dim: [Bool]
    public init(text: String, dim: [Bool]) { self.text = text; self.dim = dim }
}

/// The visible grid as text + per-Character dim, the attributed sibling of `renderScreen()`.
/// `lines.map(\.text).joined(separator: "\n")` equals `renderScreen()` exactly.
public struct AttributedScreen: Sendable, Equatable {
    public let lines: [AttributedLine]
    public init(lines: [AttributedLine]) { self.lines = lines }
}

public protocol TerminalBackend: AnyObject {
    /// Start the child process. `onEnd` fires exactly once with the exit code
    /// (nil = abnormal / no code — DOCTRINE §2.6 startup EOF → failed).
    func start(executable: String, args: [String], env: [String: String], cwd: String,
               onEnd: @escaping (Int32?) -> Void)
    /// Inject raw bytes (keystrokes) into the PTY.
    func send(_ text: String)
    /// Render the visible screen grid to text (NUL/control cells → spaces so word
    /// boundaries are real spaces — the §12.3 scrape fix: unwritten cells render as real spaces.
    func renderScreen() -> String
    /// Stage A: the attributed sibling of `renderScreen()` — same §12.3 text plus a
    /// per-Character dim mask (SGR 2). `renderScreen()` is UNCHANGED (zero migration for
    /// TurnWatcher/PermWatcher). Backends with no attribute source return the same text with
    /// an all-false mask.
    func renderAttributed() -> AttributedScreen
    /// Stage B (part 2): open/close the injection window. Between `beginInject()` and
    /// `endInject()` a backend may buffer user/protocol keystrokes arriving at its write
    /// choke point and replay them AFTER the injected bytes, so a human typing during the
    /// ~200ms inject sequence never splices into the injected line. Only the host-managed
    /// ghostty backend has a choke point to gate; every other backend is a no-op.
    func beginInject()
    func endInject()
    /// Terminate the child process.
    func terminate()
    /// The backend's child OS pid once forked, else nil. Backends with no
    /// real OS process (FakeCell) return nil and are simply never recorded for reaping.
    func childProcessID() -> pid_t?
}

public extension TerminalBackend {
    /// Default: no injection window (backends with no host-side write choke point — Headless,
    /// View, Fake — inject straight through, so there is nothing to gate).
    func beginInject() {}
    func endInject() {}
    /// Default: no reapable OS process (FakeCell and any pure-in-memory backend).
    func childProcessID() -> pid_t? { nil }
}

/// A multi-line body must arrive as ONE message, not one submission per line.
/// The ghostty backend gets this from its paste path natively (spike g6: surface_text
/// wraps the run in ESC[200~…ESC[201~ iff the child app enabled bracketed paste);
/// the host-managed backends write raw PTY bytes, so they wrap HERE under the same
/// condition — mode off (plain shell) stays raw, exactly like typing. A trailing run
/// of \r (the submission intent, RealCell.inject's separate "\r") stays OUTSIDE the
/// wrap so Enter still submits after the paste.
func bracketedPasteWrap(_ text: String, modeOn: Bool) -> String {
    guard modeOn else { return text }
    var body = text, trailing = ""
    while body.hasSuffix("\r") { trailing = "\r" + trailing; body.removeLast() }
    guard body.contains("\n") else { return text }
    return "\u{1b}[200~" + body + "\u{1b}[201~" + trailing
}

// MARK: - Headless backend (no view) — tests & smoke

/// Built on `HostPTY` + `HostScreenParser` (libghostty-vt `VtScreen`), the SAME
/// process + scrape pair `GhosttyViewBackend` uses minus the display surface. Vigil forks the
/// child itself and feeds every PTY byte into the vt parser — so the headless scrape is
/// byte-identical to the on-screen one by construction (PLAN invariant ⑦), and `swift test`'s
/// HostScrapeIntegrationTests exercise the exact same code path.
public final class HeadlessBackend: TerminalBackend, @unchecked Sendable {
    private let cols: Int
    private let rows: Int
    private let pty = HostPTY()
    private let lock = NSLock()
    private var parser: HostScreenParser?
    private var onEnd: ((Int32?) -> Void)?
    /// The OSC 10/11 color-query responder — never attached (headless has no surface,
    /// ever), so it stays active for the cell's whole lifetime whenever a color is
    /// configured. nil/nil (the default — every current call site: tests/vigil-smoke/
    /// vigil-parity) = inert, current behavior.
    private var oscResponder: OscColorQueryResponder?
    private let foregroundColorSpec: String?
    private let backgroundColorSpec: String?

    public init(cols: Int = 200, rows: Int = 50,
               foregroundColorSpec: String? = nil, backgroundColorSpec: String? = nil) {
        self.cols = cols; self.rows = rows
        self.foregroundColorSpec = foregroundColorSpec
        self.backgroundColorSpec = backgroundColorSpec
    }

    public func start(executable: String, args: [String], env: [String: String], cwd: String,
                      onEnd: @escaping (Int32?) -> Void) {
        let parser = HostScreenParser(cols: cols, rows: rows)
        let responder: OscColorQueryResponder? =
            (foregroundColorSpec != nil || backgroundColorSpec != nil)
            ? OscColorQueryResponder(foregroundColor: foregroundColorSpec,
                                     backgroundColor: backgroundColorSpec,
                                     isAttached: { false },   // headless: no surface, ever
                                     respond: { [weak pty] data in pty?.write(data) })
            : nil
        lock.lock(); self.parser = parser; self.onEnd = onEnd; self.oscResponder = responder
        lock.unlock()

        // Fork the PTY at the requested grid so the child wraps at cols/rows. A resize BEFORE
        // start() is remembered as the fork winsize (HostPTY.pendingWinsize).
        pty.resize(cols: cols, rows: rows, widthPx: 0, heightPx: 0)

        var e = env
        if e["TERM"] == nil { e["TERM"] = vigilFallbackTERM }
        pty.start(executable: executable, args: args, env: e, cwd: cwd,
                  onData: { data in
                      parser.feed(data)
                      responder?.feed(data)
                  },
                  onExit: { [weak self] code in
                      // Flush in-flight bytes into the grid before the final screen is read
                      // (HostPTY.onExit can outrun the read-queue tail — stage 1 note).
                      parser.afterPending { self?.fireEnd(code) }
                  })
    }

    public func send(_ text: String) {
        lock.lock(); let parser = self.parser; lock.unlock()
        guard let parser else { return }
        // Mode read on the parser's feed queue (never mid-mutation), same rule as before.
        let wrapped = bracketedPasteWrap(text, modeOn: parser.bracketedPasteMode)
        pty.write(Data(wrapped.utf8))
    }

    public func renderScreen() -> String {
        lock.lock(); let parser = self.parser; lock.unlock()
        return parser?.renderScreen() ?? ""
    }

    public func renderAttributed() -> AttributedScreen {
        lock.lock(); let parser = self.parser; lock.unlock()
        return parser?.renderAttributed() ?? AttributedScreen(lines: [])
    }

    public func terminate() {
        // Kill the child's process group; the reaper's waitpid → onExit(nil) delivers the
        // single onEnd (SIGKILL decodes to nil).
        pty.terminate()
    }

    public func childProcessID() -> pid_t? { pty.childProcessID() }

    private func fireEnd(_ code: Int32?) {
        lock.lock(); let cb = onEnd; onEnd = nil; lock.unlock()
        cb?(code)
    }
}
