import Foundation

/// Thread-safe live source for the terminal's resolved appearance.
///
/// The responder runs on the PTY read queue while appearance/config updates originate on the
/// main actor. Keeping the launch theme and two wire-ready values behind this tiny lock lets an
/// existing session launch a later Claude child with the current light/dark policy, while agents
/// that still query OSC 10/11 receive the matching colors without crossing actor boundaries.
public final class TerminalColorSource: @unchecked Sendable {
    /// Opaque handle returned by `addObserver`, needed to unregister later. A plain counter
    /// (not the closure itself) so removal doesn't require the closure to be `Equatable`.
    public struct ObserverToken: Hashable {
        fileprivate let id: UInt64
    }

    private let lock = NSLock()
    private var terminalTheme: String?
    private var foreground: String?
    private var background: String?
    /// mode-2031 dark-cell notification observers, keyed by token for O(1) removal. Fired
    /// from `update(terminalTheme:foreground:background:)` OUTSIDE `lock` (never call an
    /// observer while holding it — a cell's observer body reads/writes other locks of its
    /// own, e.g. HostScreenParser's queue and HostPTY's lock, and holding two unrelated
    /// locks across a callback is how you build a deadlock).
    private var observers: [UInt64: (String) -> Void] = [:]
    private var nextObserverID: UInt64 = 0

    public init(terminalTheme: String? = nil,
                foreground: String? = nil, background: String? = nil) {
        self.terminalTheme = terminalTheme
        self.foreground = foreground
        self.background = background
    }

    public func update(foreground: String?, background: String?) {
        lock.lock()
        defer { lock.unlock() }
        self.foreground = foreground
        self.background = background
    }

    /// Publish one resolved appearance transaction. Claude reads `terminalTheme` at process
    /// launch; OSC responders snapshot the colors when a query completes. mode-2031 dark-cell
    /// notification: observers are notified only when `terminalTheme` actually CHANGES value
    /// (an accent-only republish with the same theme string must not re-fire a 997 report).
    public func update(terminalTheme: String?, foreground: String?, background: String?) {
        lock.lock()
        let themeChanged = terminalTheme != self.terminalTheme
        self.terminalTheme = terminalTheme
        self.foreground = foreground
        self.background = background
        let toNotify = themeChanged ? Array(observers.values) : []
        lock.unlock()
        guard themeChanged, let terminalTheme else { return }
        for observer in toNotify { observer(terminalTheme) }
    }

    public func terminalThemeSnapshot() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return terminalTheme
    }

    public func snapshot() -> (fg: String?, bg: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (fg: foreground, bg: background)
    }

    // MARK: - mode-2031 dark-cell notification observers

    /// Register to be told whenever `terminalTheme` changes (resolved "dark"/"light", never
    /// "auto" — see `synchronizeTerminalAppearance`). Thread-safe; safe to call from any
    /// thread. Callers MUST balance this with `removeObserver` when the cell dies, or the
    /// closure (and whatever it weakly captures) lingers for the app's lifetime.
    @discardableResult
    public func addObserver(_ observer: @escaping (String) -> Void) -> ObserverToken {
        lock.lock()
        defer { lock.unlock() }
        nextObserverID += 1
        let token = ObserverToken(id: nextObserverID)
        observers[token.id] = observer
        return token
    }

    /// Unregister an observer. Safe to call more than once with the same
    /// token (idempotent no-op after the first removal).
    public func removeObserver(_ token: ObserverToken) {
        lock.lock()
        defer { lock.unlock() }
        observers.removeValue(forKey: token.id)
    }
}

/// The `COLORFGBG` env-var convention (`"fg;bg"`, legacy xterm). Confirmed by a controlled
/// PTY A/B against real claude binaries (2.1.212/2.1.215/2.1.216) to be the signal claude's
/// `theme:"auto"` reads to pick its echoed-user-message bubble's fixed 256-color chrome
/// palette (`48;5;237`/`38;5;231` dark vs. `48;5;255` light) — proven INDEPENDENT of the
/// OSC 10/11 handshake `OscColorQueryResponder` answers (identical dark result whether that
/// handshake was answered instantly, answered late, or never answered at all). Do not delete
/// this as unused just because nothing else in the app reads `COLORFGBG` — it exists purely
/// to be written into a launched agent's environment.
enum TerminalColorFgBg {
    /// `theme` is `TerminalColorSource.terminalThemeSnapshot()`'s resolved value
    /// ("dark"/"light", `VGTheme.rawValue` — never the unresolved "auto" preference).
    /// Unrecognized/nil input returns nil rather than guessing a direction.
    static func value(forTheme theme: String?) -> String? {
        switch theme {
        case "dark": return "15;0"
        case "light": return "0;15"
        default: return nil
        }
    }
}

/// Agents query the parent terminal's foreground/background color at
/// boot — `ESC]10;?…` / `ESC]11;?…` — to pick a light/dark render palette. codex (≥0.144)
/// and opencode contain the literal probes (measured with `strings`); Claude queries too
/// whenever it launches with `theme: auto` — VigilApp seeds `auto` rather than a frozen
/// light/dark, so this handshake is Claude's NORMAL boot path, not just a
/// standalone-harness edge case. A LIVE ghostty surface answers the
/// probes itself once attached. But a background-spawned worker is born in the dark-screen
/// stage (no surface exists yet — off-screen cells build their surface lazily, only
/// when selected) — nobody answers, the query times out, and the agent silently falls back
/// to the wrong palette. The fix (and this type) is
/// agent-agnostic BY DESIGN: it sits on the raw PTY byte stream shared by every cell
/// regardless of which binary is on the other end, and contains no branch on agent kind.
/// Extending it to another agent needs no changes here.
///
/// This is a host-managed-terminal-protocol shim, not a Vigil input-interception feature:
/// it answers a query the CHILD PROCESS ITSELF addressed to "the terminal" — exactly what
/// ghostty's own surface would do if one existed yet. Vigil does not intercept human⇄agent
/// interaction; this never touches an agent's actual input/output
/// content, only a terminal-protocol handshake byte a live surface would answer anyway.
///
/// Deliberately does NOT touch the byte stream it scans: callers feed it the SAME bytes
/// they hand to the scrape parser / surface, unmodified, and it never signals "consume
/// this" — it is a passive bystander that ALSO reacts by writing a reply, never a filter.
/// Never touches `HostScreenParser`/`VtScreen` parsing semantics (vigil-parity stays green
/// because this type is entirely orthogonal to the scrape source) and never touches
/// `InjectGate` (its reply bypasses the injection window like any other host-direct write —
/// there is no user keystroke in flight here to buffer against).
///
/// mode-2031 dark-cell notification (`ColorSchemeReport`, wired in `GhosttyViewBackend`):
/// same shape of problem, one level up the protocol. An agent that subscribes to DEC mode
/// 2031 expects an UNSOLICITED `ESC[?997;1n`/`;2n` the moment the terminal's scheme flips —
/// it never asks, the terminal is expected to push. A live surface pushes this itself; a
/// surfaceless cell has nobody to push it, so the host does — gated on the agent's own mode
/// subscription (`HostScreenParser.colorSchemeReportMode`) via `TerminalColorSource`'s
/// observer mechanism above, firing only while no surface is attached (an attached surface's
/// own broadcast owns the report; a host-sent duplicate would be a double notification, not
/// a missing one). Same non-interception argument as OSC 10/11 applies: this only fulfills a
/// terminal-protocol obligation the child itself opted into.
final class OscColorQueryResponder {

    /// The terminator the query used — mirrored back on the reply (xterm semantics: a
    /// BEL-terminated query gets a BEL-terminated reply, an ST-terminated query gets ST).
    private enum Terminator {
        case bel
        case st
    }

    /// A tiny prefix automaton over `ESC ] 1 (0|1) ; ? <terminator>`. Persisted across
    /// `feed()` calls so a query split at an arbitrary byte boundary (real `read()` chunks
    /// cut wherever the kernel felt like it) is still recognized.
    private enum State {
        case idle
        case sawEsc
        case sawBracket
        case sawOne
        /// `code` is "10" or "11" — fixed once the second digit lands.
        case sawCode(code: String)
        case sawSemicolon(code: String)
        case sawQuestion(code: String)
        /// Saw ESC after `?` — awaiting the `\` that completes an ST terminator.
        case sawQuestionEsc(code: String)
    }

    private var state: State = .idle
    /// The one surface generation that has received every byte in the current candidate.
    /// nil means at least one byte was held/dropped or different chunks reached different
    /// surfaces, so ghostty cannot own the complete query.
    private var candidateSurfaceGeneration: UInt64?
    private let colorSource: TerminalColorSource
    /// Compatibility seam for the original API. Production uses the explicit
    /// `surfaceDidReceive` result from `InMemoryTerminalSession.receive` instead.
    private let legacyIsAttached: (() -> Bool)?
    private let respond: (Data) -> Void

    init(colorSource: TerminalColorSource, respond: @escaping (Data) -> Void) {
        self.colorSource = colorSource
        self.legacyIsAttached = nil
        self.respond = respond
    }

    /// - Parameters:
    ///   - foregroundColor: the OSC 10 reply body (e.g. `"rgb:eded/eded/eded"`), or nil to
    ///     never answer OSC 10 (no theme seeded — test/smoke/parity paths, current
    ///     behavior preserved).
    ///   - backgroundColor: same shape, for OSC 11.
    ///   - isAttached: legacy compatibility seam, sampled once for each `feed(_:)` chunk.
    ///     Production passes the actual surface-delivery result to
    ///     `feed(_:surfaceDidReceive:)` instead.
    ///   - respond: called with the exact bytes to write back to the PTY master.
    init(foregroundColor: String?, backgroundColor: String?,
         isAttached: @escaping () -> Bool, respond: @escaping (Data) -> Void) {
        self.colorSource = TerminalColorSource(foreground: foregroundColor,
                                               background: backgroundColor)
        self.legacyIsAttached = isAttached
        self.respond = respond
    }

    /// Scan one chunk of raw PTY output. Safe to call with any split of the byte stream,
    /// including one byte at a time. No return value — this is an observer, not a filter.
    func feed(_ data: Data) {
        feed(data, surfaceDidReceive: legacyIsAttached?() ?? false)
    }

    /// Compatibility/test convenience for callers that only have a stable attached Bool.
    /// Production supplies the real generation returned by InMemoryTerminalSession.receive.
    func feed(_ data: Data, surfaceDidReceive: Bool) {
        feed(data, surfaceGeneration: surfaceDidReceive ? 1 : nil)
    }

    /// Scan a chunk and record whether the DISPLAY surface actually received these same bytes.
    /// Only a query whose every byte reached the same surface generation is left for ghostty to
    /// answer. If a byte was held by the attach gate, there was no surface, or a rebuild split the
    /// query across two surfaces, the host owns the reply.
    func feed(_ data: Data, surfaceGeneration: UInt64?) {
        for byte in data {
            step(byte, surfaceGeneration: surfaceGeneration)
        }
    }

    private func step(_ byte: UInt8, surfaceGeneration: UInt64?) {
        switch state {
        case .idle:
            if byte == 0x1B {
                candidateSurfaceGeneration = surfaceGeneration
                state = .sawEsc
            }
        case .sawEsc:
            mergeSurfaceGeneration(surfaceGeneration)
            state = byte == UInt8(ascii: "]")
                ? .sawBracket
                : restart(byte, surfaceGeneration: surfaceGeneration)
        case .sawBracket:
            mergeSurfaceGeneration(surfaceGeneration)
            state = byte == UInt8(ascii: "1")
                ? .sawOne
                : restart(byte, surfaceGeneration: surfaceGeneration)
        case .sawOne:
            mergeSurfaceGeneration(surfaceGeneration)
            if byte == UInt8(ascii: "0") { state = .sawCode(code: "10") }
            else if byte == UInt8(ascii: "1") { state = .sawCode(code: "11") }
            else { state = restart(byte, surfaceGeneration: surfaceGeneration) }
        case .sawCode(let code):
            mergeSurfaceGeneration(surfaceGeneration)
            state = byte == UInt8(ascii: ";")
                ? .sawSemicolon(code: code)
                : restart(byte, surfaceGeneration: surfaceGeneration)
        case .sawSemicolon(let code):
            mergeSurfaceGeneration(surfaceGeneration)
            state = byte == UInt8(ascii: "?")
                ? .sawQuestion(code: code)
                : restart(byte, surfaceGeneration: surfaceGeneration)
        case .sawQuestion(let code):
            mergeSurfaceGeneration(surfaceGeneration)
            if byte == 0x07 {
                complete(code: code, terminator: .bel)
            } else if byte == 0x1B {
                state = .sawQuestionEsc(code: code)
            } else {
                state = restart(byte, surfaceGeneration: surfaceGeneration)
            }
        case .sawQuestionEsc(let code):
            mergeSurfaceGeneration(surfaceGeneration)
            if byte == UInt8(ascii: "\\") {
                complete(code: code, terminator: .st)
            } else {
                state = restart(byte, surfaceGeneration: surfaceGeneration)
            }
        }
    }

    private func mergeSurfaceGeneration(_ generation: UInt64?) {
        guard let candidate = candidateSurfaceGeneration,
              let generation,
              candidate == generation else {
            candidateSurfaceGeneration = nil
            return
        }
    }

    /// A mismatched byte aborts the current candidate. An ESC can start a brand-new
    /// sequence immediately — it must never be swallowed by the abort, or a query that
    /// immediately follows a truncated one would be missed.
    private func restart(_ byte: UInt8, surfaceGeneration: UInt64?) -> State {
        if byte == 0x1B {
            candidateSurfaceGeneration = surfaceGeneration
            return .sawEsc
        }
        candidateSurfaceGeneration = nil
        return .idle
    }

    private func complete(code: String, terminator: Terminator) {
        let owningSurface = candidateSurfaceGeneration
        state = .idle
        candidateSurfaceGeneration = nil
        guard owningSurface == nil else { return }
        let colors = colorSource.snapshot()
        let color = code == "10" ? colors.fg : colors.bg
        guard let color else { return }
        var reply = Data([0x1B])
        reply.append(contentsOf: Array("]\(code);\(color)".utf8))
        switch terminator {
        case .bel: reply.append(0x07)
        case .st: reply.append(contentsOf: [0x1B, UInt8(ascii: "\\")])
        }
        respond(reply)
    }
}
