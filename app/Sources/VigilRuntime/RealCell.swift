import Foundation
import VigilCore

/// L1 takeover (DOCTRINE §4): one node's runtime container. Wraps a TerminalBackend
/// (HostPTY + libghostty: GhosttyViewBackend surface / HeadlessBackend vt) and conforms to
/// Core's `CellHandle`, so the
/// brain talks to it only through start / inject(→ack) / snapshot / terminate.
/// Monitors process exit and reports it up via `onExit` → the coordinator maps it to a
/// `nodeExited`/`nodeFailed` Command (DOCTRINE §2.6 symmetric node death).
public final class RealCell: CellHandle, @unchecked Sendable {
    public let nodeID: NodeID
    private let backend: TerminalBackend
    private let launch: LaunchSpec
    public let cwd: String   // where the child runs (the project dir)
    private let onExit: @Sendable (NodeID, Int32?) -> Void
    private let injectPollInterval: TimeInterval
    private let injectMaxQueueWait: TimeInterval
    private let injectHoldNoticeDelay: TimeInterval
    /// The first-turn task, delivered by PTY injection after the cell is up (argv would be
    /// a ps/pkill mass-kill surface). nil = nothing to inject (resume, headless printMode).
    /// See `deliverInitialPrompt`.
    private let initialPrompt: String?
    /// How long to wait for the child's TUI input line to render before injecting the
    /// initial prompt — then fail-open (a first task is never dropped). Injectable so tests
    /// drive it in ms; the poll cadence reuses `injectPollInterval`.
    private let initialPromptReadyTimeout: TimeInterval
    /// The inject hold made user-visible — (node, pending, held, epoch). held=true fires
    /// once a hold outlives the grace (and again on count refreshes); held=false fires when
    /// that hold releases, however it ends. A hold that clears inside the grace never fires.
    /// epoch = a per-cell monotonic stamp allocated UNDER `lock` at the emission's decision
    /// moment, so the store can order signals that reorder across its MainActor hop (a
    /// count-refresh emitted before a settle but applied after it → dropped as stale).
    private let onInjectHold: @Sendable (NodeID, Int, Bool, UInt64) -> Void
    /// Fires once with the child's OS pid after the backend forks it, so the
    /// orchestrator can persist a `cell_pid` record for startup reaping. Never fires for a
    /// backend with no real process (FakeCell → childProcessID() nil) or a cell that dies
    /// before the fork publishes a pid.
    private let onChildPid: @Sendable (NodeID, pid_t) -> Void

    private let lock = NSLock()
    private var started = false
    private var exited = false
    /// Hold-notice state: injects in flight (entered `inject`, not yet returned — the
    /// held one plus the FIFO tail behind it), whether the current hold has fired its
    /// notice (FIFO guarantees at most ONE inject sits in the hold loop), and the
    /// monotonic epoch counter stamped on every onInjectHold emission (all mutated under
    /// `lock`, so epoch order == lock-acquisition order == logical decision order).
    private var pendingInjects = 0
    private var holdNoticed = false
    private var holdSeq: UInt64 = 0
    /// FIFO chain for injects: the send→settle→CR sequence must run to
    /// completion before the next inject starts, or two concurrent routes to this cell
    /// interleave into `send(A) send(B) \r \r` (a spliced line + one blank submit). Each
    /// call links behind the previous under `lock`, so ordering = lock-acquisition order.
    private var injectTail: Task<Void, Never> = Task {}

    // Synchronous lock wrapper so the lock/unlock calls don't sit directly in an
    // async body (avoids the "NSLock unavailable from async" v6 warning).
    private func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    public init(nodeID: NodeID, launch: LaunchSpec, cwd: String,
                backend: TerminalBackend,
                initialPrompt: String? = nil,
                injectPollInterval: TimeInterval = 0.5,
                injectMaxQueueWait: TimeInterval = 120,
                injectHoldNoticeDelay: TimeInterval = 2.0,
                initialPromptReadyTimeout: TimeInterval = 30,
                onExit: @escaping @Sendable (NodeID, Int32?) -> Void,
                onInjectHold: @escaping @Sendable (NodeID, Int, Bool, UInt64) -> Void = { _, _, _, _ in },
                onChildPid: @escaping @Sendable (NodeID, pid_t) -> Void = { _, _ in }) {
        self.nodeID = nodeID; self.launch = launch; self.cwd = cwd
        self.backend = backend; self.onExit = onExit
        self.initialPrompt = initialPrompt
        self.injectPollInterval = injectPollInterval
        self.injectMaxQueueWait = injectMaxQueueWait
        self.injectHoldNoticeDelay = injectHoldNoticeDelay
        self.initialPromptReadyTimeout = initialPromptReadyTimeout
        self.onInjectHold = onInjectHold
        self.onChildPid = onChildPid
    }

    public func start() async {
        withLock { started = true }
        backend.start(executable: launch.executable, args: launch.args,
                      env: launch.env, cwd: cwd) { [weak self] code in
            guard let self else { return }
            let firstExit = self.withLock { let f = !self.exited; self.exited = true; return f }
            guard firstExit else { return }       // exit reported exactly once
            self.onExit(self.nodeID, code)
        }
        // Capture the child pid once forkpty publishes it. The pid is
        // known synchronously after HostPTY forks, but GhosttyViewBackend forks on a
        // main-actor hop inside start() (so it lags this call) — a brief poll bridges the
        // gap without blocking the launch path. Fire-and-forget, exits on first pid or death.
        Task { [weak self] in await self?.reportChildPid() }
        // The first-turn task rides PTY injection, not argv. Deliver it once the
        // TUI has rendered its input line, through the SAME FIFO/hold path as any send.
        // Fire-and-forget: start() returns immediately, the launch path is unblocked.
        if let prompt = initialPrompt, !prompt.isEmpty {
            Task { [weak self] in await self?.deliverInitialPrompt(prompt) }
        }
    }

    /// Poll the backend for the freshly-forked child pid and report it up exactly once.
    /// Bounded (~10s) so a backend that never forks — or a cell that dies during startup —
    /// can't leak the task. Fires on the bare pid: the recorded identity is the child's
    /// START TIME (kernel proc metadata, set at fork and stable across exec — always the
    /// child's own) plus the exec path we ASKED to launch (`launch.executable`), NOT the
    /// argv read back from the process. That read (KERN_PROCARGS2) is unsafe here: during the
    /// pre-exec window the child's memory image is still the forking parent's, so it returns
    /// VIGIL's own argv, not the agent's — capturing that would make the reaper's identity
    /// check miss the real orphan. So we never read it; recordCellPid uses the ground-truth
    /// exe the orchestrator already holds.
    private func reportChildPid() async {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if withLock({ exited }) { return }
            if let pid = backend.childProcessID(), pid > 0 {
                onChildPid(nodeID, pid)
                return
            }
            try? await Task.sleep(seconds: injectPollInterval)
        }
    }

    /// Wait for the child's TUI input line to become ready-and-empty (`.clear`),
    /// then inject the first-turn task via the ordinary `inject` FIFO. A blind inject at
    /// launch would race the TUI's startup redraw and be swallowed, and
    /// `.unknown` during the splash is "not ready yet", not "fail open" — so this readiness
    /// gate polls for `.clear` specifically, with a timeout that fail-opens (a first task is
    /// never dropped). The actual send then reuses `inject`, so InjectGate/hold/FIFO all hold.
    private func deliverInitialPrompt(_ text: String) async {
        let deadline = Date().addingTimeInterval(initialPromptReadyTimeout)
        while Date() < deadline {
            if withLock({ exited }) { return }           // died before the TUI came up
            if case .clear = Self.probeInputLine(backend.renderAttributed()) { break }
            try? await Task.sleep(seconds: injectPollInterval)
        }
        _ = try? await inject(text)
    }

    /// Ack-bearing injection (DOCTRINE §6.3). Send the text, let the
    /// TUI settle, then send the carriage return as a SEPARATE keystroke — otherwise a
    /// bundled CR gets swallowed by the redraw (§12.5-C2).
    ///
    /// The terminal is ALSO the human's only input surface — a blind inject
    /// appends to (and submits) whatever they were mid-typing. So probe the TUI input
    /// line first: user content there → hold and poll until it clears. This one rule
    /// covers busy turns too (mid-turn typing shows in the same box; claude queues our
    /// text safely once the box is clear). A failed/uncertain probe or the wait
    /// cap falls open to a direct inject — a message is never held forever.
    /// Serialized entry point: link behind the current tail, then run the actual inject
    /// only after the prior one fully finished. `injectTail` advances to
    /// a barrier that completes with THIS job so the next caller waits on us in turn.
    /// Read-tail and set-tail happen in ONE lock section: split acquisitions let two
    /// concurrent injects adopt the same tail and run side by side — the exact
    /// interleave this serialization is built to prevent.
    public func inject(_ text: String) async throws -> InjectAck {
        let (job, refresh): (Task<InjectAck, Error>, (pending: Int, epoch: UInt64)?) = withLock {
            pendingInjects += 1
            let previous = injectTail
            let j = Task { () throws -> InjectAck in
                _ = await previous.value
                defer { self.withLock { self.pendingInjects -= 1 } }
                return try await self.performInject(text)
            }
            injectTail = Task { _ = try? await j.value }
            // A new message joining the tail while a hold notice stands refreshes the
            // standing card's count. The epoch is stamped HERE under `lock` so a settle
            // that overtakes this refresh across the MainActor hop wins (store drops the
            // stale refresh).
            if holdNoticed { holdSeq += 1; return (j, (pendingInjects, holdSeq)) }
            return (j, nil)
        }
        if let r = refresh { onInjectHold(nodeID, r.pending, true, r.epoch) }
        // Propagate the caller's cancellation into `job` so performInject's hold
        // loop (which runs inside `job`) observes Task.isCancelled and bails instead of
        // hot-spinning to injectMaxQueueWait. Awaiting job.value alone would not — an
        // unstructured Task does not inherit the awaiter's cancellation.
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    private func performInject(_ text: String) async throws -> InjectAck {
        let canSend = withLock { started && !exited }
        guard canSend else { return InjectAck(delivered: false, note: "cell not running") }

        var note: String?
        if case .userTyping = Self.probeInputLine(backend.renderAttributed()) {
            let queuedAt = Date()
            var failOpen = false
            // However the hold ends — delivered, fail-open, cell death — a fired
            // notice MUST settle, or the card outlives the queue it reports. Epoch stamped
            // under `lock` in the same section that clears holdNoticed.
            defer {
                let fired: (pending: Int, epoch: UInt64)? = withLock {
                    guard holdNoticed else { return nil }
                    holdNoticed = false; holdSeq += 1
                    return (pendingInjects, holdSeq)
                }
                if let f = fired { onInjectHold(nodeID, f.pending, false, f.epoch) }
            }
            while true {
                // `try?` below swallows the sleep's CancellationError, so the loop
                // head is the only place cancellation is honored — bail here (the defer
                // above still settles the hold card) rather than spinning to the cap.
                if Task.isCancelled {
                    return InjectAck(delivered: false, note: "inject cancelled")
                }
                try? await Task.sleep(seconds: injectPollInterval)
                guard withLock({ !exited }) else {
                    return InjectAck(delivered: false, note: "cell exited while inject queued")
                }
                // .clear or .unknown both release the hold — unknown means the scrape
                // stopped being trustworthy, and fail-open beats holding the message.
                guard case .userTyping = Self.probeInputLine(backend.renderAttributed()) else { break }
                if Date().timeIntervalSince(queuedAt) >= injectMaxQueueWait { failOpen = true; break }
                // The hold becomes visible only after a grace — a line that clears
                // within moments never flashes a card (same trick as an instantly-approved permission card).
                if withLock({ !holdNoticed }),
                   Date().timeIntervalSince(queuedAt) >= injectHoldNoticeDelay {
                    let fired: (pending: Int, epoch: UInt64) = withLock {
                        holdNoticed = true; holdSeq += 1; return (pendingInjects, holdSeq)
                    }
                    onInjectHold(nodeID, fired.pending, true, fired.epoch)
                }
            }
            let waited = String(format: "%.1fs", Date().timeIntervalSince(queuedAt))
            note = failOpen
                ? "queued \(waited): input line still busy, fail-open inject"
                : "queued \(waited): waited for user input line to clear"
        }

        // Open the injection window around the send→settle→CR sequence.
        // The hold loop above ran with the window CLOSED (red line ②) — the human typed
        // straight through while we waited. Now that we commit to inject, gate keystrokes that
        // arrive during the ~200ms window and replay them after the CR (backend gate + replay;
        // no-op on non-host backends). `defer` guarantees endInject fires even on early exit —
        // a leaked-open window would buffer the user's input forever.
        backend.beginInject()
        defer { backend.endInject() }
        backend.send(text)
        try? await Task.sleep(seconds: 0.15)   // settle before CR
        backend.send("\r")
        return InjectAck(delivered: true, note: note)
    }

    /// Probe verdict for the claude-TUI input line.
    enum InputLineProbe: Equatable {
        case clear                 // input line found and empty → safe to inject now
        case userTyping(String)    // human content in the box → hold
        case unknown               // no input line recognized → fail-open
    }

    /// Read the TUI input line for pending human content, two layers:
    ///   • dim main layer (claude ≥2.1.205): the input sits between the bottom-most pair of full-width
    ///     pure-U+2500 rules; strip the mode prefix (❯/!/#/> + whitespace) and read the SGR-2 dim
    ///     bit — a dim remainder is claude's placeholder (.clear), a non-dim one is real typing
    ///     (.userTyping). Structure-anchored, so `/` menus (above the top rule) and permission
    ///     `❯ 1.Yes` (in a │…│ box, not rule-bracketed) never fool it.
    ///   • `│>` box-format fallback (codex box-format TUI): a border-anchored read,
    ///     only reached when the main layer finds no rule-bracketed input.
    /// Neither matches → .unknown (fail-open; a message is never held on an untrusted scrape).
    static func probeInputLine(_ screen: AttributedScreen) -> InputLineProbe {
        if let verdict = probeDimInputLine(screen) { return verdict }
        // codex ≥0.142 borderless `›` composer, tried BEFORE the box fallback so its
        // header banner `│ >_ OpenAI Codex … │` can never be misread as the input line.
        if let verdict = probeCodexComposerLine(screen) { return verdict }
        // opencode's `┃`-barred composer — only its empty placeholder
        // yields a verdict (`.clear`); everything else falls through to the box fallback / .unknown.
        if let verdict = probeOpenCodeComposerLine(screen) { return verdict }
        return probeBoxInputLine(screen.lines.map(\.text).joined(separator: "\n"))
    }

    /// String convenience: wraps into an all-false-dim screen. A box-format string carries no
    /// pure-U+2500 rule (rounded corners ≠ U+2500), so the dim layer defers and this routes to the
    /// box fallback. Lets the codex box-format direct tests keep calling with a String literal.
    static func probeInputLine(_ screen: String) -> InputLineProbe {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map {
            AttributedLine(text: String($0), dim: Array(repeating: false, count: $0.count))
        }
        return probeInputLine(AttributedScreen(lines: lines))
    }

    /// A rule = a line that, trimmed, is nothing but ≥`ruleMinRun` U+2500 cells (the full-width
    /// input-box border). K=20 fixed (not %-of-width): the box spans the terminal so its rules run
    /// 78–198 cells; 20 clears every real width while rejecting stray short `───` runs in output.
    private static let ruleMinRun = 20
    private static func isRuleLine(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.count >= ruleMinRun && t.allSatisfy { $0 == "\u{2500}" }
    }

    /// claude mode prefixes that open the input line: normal ❯, bash !, memory #, and > (older).
    private static let modePrefixes: Set<Character> = ["\u{276F}", "!", "#", ">"]

    /// dim main layer. nil (→ box fallback) when there is no rule-bracketed input line or the
    /// bracket holds no recognizable prompt prefix.
    private static func probeDimInputLine(_ screen: AttributedScreen) -> InputLineProbe? {
        guard let (top, bottom) = bottomRulePair(screen.lines) else { return nil }
        let content = screen.lines[(top + 1)..<bottom]
        if content.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return .clear                                    // rule-bracketed but genuinely empty
        }
        // The prompt line is the first bracketed line carrying a mode prefix; continuation lines of
        // a folded multi-line input have no prefix and are skipped for the verdict.
        for line in content {
            guard let (rest, restDim) = stripModePrefix(line) else { continue }
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return .clear }             // prefix only, nothing typed
            if restDim.first == true { return .clear }       // dim remainder = claude placeholder (SGR-2 present)
            if isPlaceholderText(trimmed) { return .clear }  // placeholder even when NOT dim
            return .userTyping(trimmed)                       // non-dim, non-placeholder = real human content
        }
        return nil                                            // bracketed but no prompt prefix
    }

    /// Claude's empty-box hint is `Try "<suggestion>"`. It is USUALLY dim (SGR-2), but
    /// claude does NOT emit the faint attribute reliably — under a Vigil forkpty (HostPTY) it
    /// can render the SAME placeholder text with ZERO styling. The dim bit alone then misreads
    /// the empty box as user typing, so `deliverInitialPrompt` never observes `.clear` and the
    /// first-turn task never injects. Recognize the placeholder by its text as a second,
    /// style-INDEPENDENT signal. The dim path stays first so a real dim read still wins; this
    /// only rescues the no-dim render.
    ///
    /// Load-bearing shape: `Try "…"`. A human literally typing `Try "…"` is the sole false-positive
    /// (accepted — vanishingly rare); a future placeholder-text drift degrades safely (→ .userTyping
    /// → hold → fail-open inject, never a spliced submit).
    private static func isPlaceholderText(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("Try \"") && trimmed.hasSuffix("\"") && trimmed.count > 5
    }

    /// codex composer prompt marker (U+203A ›), the borderless composer opened by codex ≥0.142.
    private static let codexPromptPrefix: Character = "\u{203A}"

    /// codex ≥0.142 dropped the old `│ > … │` box composer for a border-LESS line
    /// `› <placeholder|typed>` — no U+2500 rule bracket (so the claude dim layer defers) and no
    /// `│…│` border (so `probeBoxInputLine` would otherwise latch onto the header banner
    /// `│ >_ OpenAI Codex (vX.Y.Z) │` and read `.userTyping` FOREVER —
    /// `deliverInitialPrompt` would never see `.clear`, and the first-turn task would never
    /// inject). Anchor on the `›` marker instead: scan bottom-up (the composer sits at the
    /// screen bottom; the footer status line below it and any transcript `›` above it never
    /// shadow it), strip the marker, and split placeholder vs. typed by the SAME dim
    /// discriminator claude uses — codex renders the rotating placeholder text SGR-2 dim and
    /// real typing plain. The rotating placeholder set is unbounded, so there is deliberately
    /// NO text allow-list here; the dim bit is the whole signal. Returns nil (→ box fallback)
    /// when no `›` line is present.
    private static func probeCodexComposerLine(_ screen: AttributedScreen) -> InputLineProbe? {
        for line in screen.lines.reversed() {
            let chars = Array(line.text)
            var i = 0
            while i < chars.count, isProbeWhitespace(chars[i]) { i += 1 }   // tolerate leading pad
            guard i < chars.count, chars[i] == codexPromptPrefix else { continue }
            i += 1
            while i < chars.count, isProbeWhitespace(chars[i]) { i += 1 }   // marker→content gap
            let contentStart = i
            let rest = String(chars[contentStart...]).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return .clear }                                // marker only, nothing typed
            let dim = contentStart < line.dim.count ? line.dim[contentStart] : false
            if dim { return .clear }                                         // dim = codex placeholder
            return .userTyping(rest)                                          // plain = real human content
        }
        return nil                                                           // no `›` composer on screen
    }

    /// opencode composer marker (U+2503 ┃, the heavy left bar) and its placeholder text lead.
    private static let openCodePromptPrefix: Character = "\u{2503}"
    private static let openCodePlaceholderLead = "Ask anything"

    /// opencode's TUI composer is a `┃`-barred box
    /// `┃  <placeholder|typed>` with a `┃  Build · <model>` status row just below it — no U+2500
    /// rule and no `│…│` border, so both prior layers defer and without this probe the verdict
    /// would be `.unknown` (fail-open only; the first-turn task would ride the 30s readiness
    /// timeout, never a prompt `.clear`).
    /// opencode paints the placeholder a dim GRAY *truecolor* (rgb ~128,128,128), NOT SGR-2, so the
    /// dim bit is unavailable — the placeholder TEXT lead is the only stable signal (same
    /// style-independent shape as claude's `Try "…"`). Deliberately conservative: ONLY the
    /// placeholder yields a verdict (`.clear`, so the initial prompt injects promptly); anything else
    /// (typed content, drift, a bare `┃` status row) returns nil → box fallback → `.unknown` →
    /// fail-open. The typed-line HOLD is intentionally not
    /// attempted: the input row is not structurally separable from the `· model` status row, and a
    /// wrong `.userTyping` there would be worse than today's fail-open. Placeholder drift degrades
    /// safely to nil. Bottom-up so the status row (`Build ·`) and blank `┃` rows are skipped until
    /// the placeholder row is reached.
    private static func probeOpenCodeComposerLine(_ screen: AttributedScreen) -> InputLineProbe? {
        for line in screen.lines.reversed() {
            let chars = Array(line.text)
            var i = 0
            while i < chars.count, isProbeWhitespace(chars[i]) { i += 1 }
            guard i < chars.count, chars[i] == openCodePromptPrefix else { continue }
            i += 1
            while i < chars.count, isProbeWhitespace(chars[i]) { i += 1 }
            let rest = String(chars[i...]).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix(openCodePlaceholderLead) { return .clear }   // opencode empty placeholder
        }
        return nil
    }

    /// Bottom-most pair of rule lines = the input box (it sits at the screen bottom; transcript
    /// rules are always above its top rule). Returns (topRuleIndex, bottomRuleIndex).
    private static func bottomRulePair(_ lines: [AttributedLine]) -> (Int, Int)? {
        var bottom: Int?
        for i in stride(from: lines.count - 1, through: 0, by: -1) where isRuleLine(lines[i].text) {
            if let b = bottom { return (i, b) }
            bottom = i
        }
        return nil
    }

    /// Strip a leading mode prefix (`❯`/`!`/`#`/`>` + trailing whitespace, `.whitespaces` incl.
    /// NBSP U+00A0 — claude's placeholder pads the prefix with NBSP) off one attributed line,
    /// returning the remaining text and its index-aligned dim slice. nil = no mode prefix here.
    private static func stripModePrefix(_ line: AttributedLine) -> (String, [Bool])? {
        let chars = Array(line.text)
        var i = 0
        while i < chars.count, isProbeWhitespace(chars[i]) { i += 1 }   // tolerate leading pad
        guard i < chars.count, modePrefixes.contains(chars[i]) else { return nil }
        i += 1
        while i < chars.count, isProbeWhitespace(chars[i]) { i += 1 }   // prefix→content gap
        let rest = String(chars[i...])
        let dim = i <= line.dim.count ? Array(line.dim[i...]) : []
        return (rest, dim)
    }

    private static func isProbeWhitespace(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
    }

    /// codex box-format fallback — the `│ > … │` border read.
    /// Bottom-up: the input box is at the screen bottom, so the first `>`-prompt border line from
    /// below is it; quoted `>` lines higher in the transcript never shadow it.
    private static func probeBoxInputLine(_ screen: String) -> InputLineProbe {
        for raw in screen.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("│") else { continue }
            var body = line.dropFirst()                       // strip the box borders
            if body.hasSuffix("│") { body = body.dropLast() }
            let inner = body.trimmingCharacters(in: .whitespaces)
            guard inner.hasPrefix(">") else { continue }      // border line, not the prompt
            // codex ≥0.142's header banner `│ >_ OpenAI Codex (vX.Y.Z) │` is NOT an input
            // line — its `>_` splash marker (a stylized cursor) is distinct from a real `> ` prompt.
            // The `›` layer already handles the live composer; this skip is the belt-and-suspenders
            // for a transient frame with no `›` visible, so the banner can never masquerade as typing.
            if inner.hasPrefix(">_") { continue }
            let content = inner.dropFirst().trimmingCharacters(in: .whitespaces)
            return content.isEmpty ? .clear : .userTyping(String(content))
        }
        return .unknown
    }

    public func snapshot() async -> String { backend.renderScreen() }

    public func terminate() async {
        let live = withLock { started && !exited }
        if live { backend.terminate() }
    }
}
