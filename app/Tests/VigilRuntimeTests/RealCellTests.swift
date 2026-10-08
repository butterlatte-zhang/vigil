import XCTest
import VigilCore
@testable import VigilRuntime

/// A scripted TerminalBackend — no real process. Lets us test RealCell's lifecycle
/// + ack-bearing inject + exit reporting deterministically (the same
/// FakeCell seam philosophy as VigilCore).
final class FakeBackend: TerminalBackend, @unchecked Sendable {
    // Queued-inject tests mutate `screen` while the cell polls from another task —
    // lock-protect the scripted state so the fake itself is race-free.
    private let lock = NSLock()
    private var _sent: [String] = []
    // An ordered call log capturing begin/end/send so a test can assert
    // performInject opens the window before the body and closes it after the CR.
    private var _log: [String] = []
    var callLog: [String] { lock.lock(); defer { lock.unlock() }; return _log }
    private var _screen = "(scripted screen)"
    var sent: [String] { lock.lock(); defer { lock.unlock() }; return _sent }
    var screen: String {
        get { lock.lock(); defer { lock.unlock() }; return _screen }
        set { lock.lock(); defer { lock.unlock() }; _screen = newValue }
    }
    // Scriptable attributed screen. nil → derive from `screen` with an all-false
    // dim mask (probe tests set this to script dim placeholder vs typed content).
    private var _attributed: AttributedScreen?
    var attributed: AttributedScreen? {
        get { lock.lock(); defer { lock.unlock() }; return _attributed }
        set { lock.lock(); defer { lock.unlock() }; _attributed = newValue }
    }
    var started = false
    var terminated = false
    private var onEnd: ((Int32?) -> Void)?

    func start(executable: String, args: [String], env: [String: String], cwd: String,
               onEnd: @escaping (Int32?) -> Void) {
        started = true; self.onEnd = onEnd
    }
    /// Scripted reaction to each send (e.g. "the CR clears the box"). Runs outside the lock.
    var onSend: (@Sendable (String) -> Void)?
    func send(_ text: String) {
        lock.lock(); _sent.append(text); _log.append("send:\(text)"); let h = onSend; lock.unlock()
        h?(text)
    }
    func beginInject() { lock.lock(); _log.append("begin"); lock.unlock() }
    func endInject() { lock.lock(); _log.append("end"); lock.unlock() }
    func renderScreen() -> String { screen }
    func renderAttributed() -> AttributedScreen {
        if let a = attributed { return a }
        // Default: mirror `screen` text with an all-false dim mask (no dim source scripted).
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map { row -> AttributedLine in
            let t = String(row)
            return AttributedLine(text: t, dim: Array(repeating: false, count: t.count))
        }
        return AttributedScreen(lines: lines)
    }
    func terminate() { terminated = true }

    /// Scriptable child pid so RealCell's reportChildPid poll settles at once (a nil
    /// would make it poll the full 10s). Non-nil default keeps every existing test fast.
    var scriptedPid: pid_t? = 424242
    func childProcessID() -> pid_t? { lock.lock(); defer { lock.unlock() }; return scriptedPid }

    /// Test hook: simulate the child process exiting.
    func simulateExit(_ code: Int32?) { onEnd?(code) }
}

/// Scraped claude-TUI shapes for the input-line probe (box anchor, real-machine capture).
private let screenUserTyping = """
some earlier output
╭──────────────────────────────────────────╮
│ > half typed by the human                │
╰──────────────────────────────────────────╯
  ? for shortcuts
"""
private let screenInputEmpty = """
some earlier output
╭──────────────────────────────────────────╮
│ >                                        │
╰──────────────────────────────────────────╯
  ? for shortcuts
"""

final class RealCellTests: XCTestCase {

    /// CI slow-machine timing gate: a single GH runner scheduling stall can exceed 0.2s, so a
    /// fixed sleep would be gambling and losing — poll until the condition holds or times out;
    /// assertions are still made by the caller, this only absorbs "hitting the scheduling window".
    private func waitUntil(_ deadline: TimeInterval = 5,
                           _ cond: @escaping () -> Bool) async {
        let t0 = Date()
        while !cond() && Date().timeIntervalSince(t0) < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makeCell(_ backend: FakeBackend,
                          initialPrompt: String? = nil,
                          pollInterval: TimeInterval = 0.02,
                          maxQueueWait: TimeInterval = 5,
                          holdNoticeDelay: TimeInterval = 0.05,
                          readyTimeout: TimeInterval = 5,
                          landTimeout: TimeInterval = 0.1,
                          confirmWindow: TimeInterval = 0.1,
                          retryTimeout: TimeInterval = 0.5,
                          retryInterval: TimeInterval = 0.05,
                          onInjectHold: @escaping @Sendable (NodeID, Int, Bool, UInt64) -> Void = { _, _, _, _ in },
                          onExit: @escaping @Sendable (NodeID, Int32?) -> Void) -> RealCell {
        RealCell(nodeID: NodeID("n1"),
                 launch: LaunchSpec(executable: "/bin/echo", args: ["hi"], env: [:]),
                 cwd: "/tmp", backend: backend,
                 initialPrompt: initialPrompt,
                 injectPollInterval: pollInterval, injectMaxQueueWait: maxQueueWait,
                 injectHoldNoticeDelay: holdNoticeDelay,
                 initialPromptReadyTimeout: readyTimeout,
                 injectLandTimeout: landTimeout, injectConfirmWindow: confirmWindow,
                 injectRetryTimeout: retryTimeout, injectRetryInterval: retryInterval,
                 onExit: onExit, onInjectHold: onInjectHold)
    }

    func testStartLaunchesBackend() async {
        let b = FakeBackend()
        let cell = makeCell(b) { _, _ in }
        await cell.start()
        XCTAssertTrue(b.started)
    }

    // start() surfaces the backend's child pid exactly once, so the
    // orchestrator can persist a cell_pid record. The pid RealCell reports is the one the
    // backend forked (here scripted) — verbatim, no transform.
    func testStartReportsChildPid() async {
        let b = FakeBackend(); b.scriptedPid = 90210
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var pids: [(String, pid_t)] = []
            func add(_ n: NodeID, _ p: pid_t) { lock.lock(); pids.append((n.raw, p)); lock.unlock() }
            var all: [(String, pid_t)] { lock.lock(); defer { lock.unlock() }; return pids }
        }
        let box = Box()
        let cell = RealCell(nodeID: NodeID("n1"),
                            launch: LaunchSpec(executable: "/bin/echo", args: ["hi"], env: [:]),
                            cwd: "/tmp", backend: b,
                            injectPollInterval: 0.02,
                            onExit: { _, _ in },
                            onChildPid: { id, pid in box.add(id, pid) })
        await cell.start()
        await waitUntil { !box.all.isEmpty }
        XCTAssertEqual(box.all.count, 1, "child pid must be reported exactly once")
        XCTAssertEqual(box.all.first?.0, "n1")
        XCTAssertEqual(box.all.first?.1, 90210)
    }

    // MARK: - first-turn task via PTY injection (not argv)

    /// The initial prompt is injected only AFTER the TUI input line renders (.clear); a blind
    /// inject at launch would race the startup redraw. While the screen is
    /// still `.unknown`/not-ready, nothing is sent; once it clears, the prompt rides the normal
    /// inject path (text then a separate CR).
    func testInitialPromptInjectedAfterInputLineReady() async throws {
        let b = FakeBackend()
        b.screen = "starting up…"                        // no input box yet → .unknown, hold
        let cell = makeCell(b, initialPrompt: "run the job") { _, _ in }
        await cell.start()
        try? await Task.sleep(nanoseconds: 80_000_000)   // give the readiness gate a few polls
        XCTAssertTrue(b.sent.isEmpty, "the initial prompt is not injected before the TUI is ready")
        b.screen = screenInputEmpty                      // input box now rendered & empty (.clear)
        await waitUntil { b.sent.count >= 2 }            // text, then a SEPARATE CR (injection contract)
        XCTAssertEqual(b.sent, ["run the job", "\r"], "once ready, it is delivered via the normal inject path")
    }

    /// Input line already clear at launch → the prompt injects promptly with no hold.
    func testInitialPromptInjectedWhenReadyImmediately() async throws {
        let b = FakeBackend()
        b.screen = screenInputEmpty
        let cell = makeCell(b, initialPrompt: "hello") { _, _ in }
        await cell.start()
        await waitUntil { b.sent.count >= 2 }
        XCTAssertEqual(b.sent, ["hello", "\r"])
    }

    /// No initial prompt → nothing is ever injected on start (resume / headless printMode path).
    func testNoInitialPromptInjectsNothing() async {
        let b = FakeBackend()
        b.screen = screenInputEmpty
        let cell = makeCell(b, initialPrompt: nil) { _, _ in }
        await cell.start()
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(b.sent.isEmpty)
    }

    /// The cell dies before its TUI ever comes up → the initial prompt is dropped cleanly
    /// (never injected into a dead cell, no spin to the readiness timeout).
    func testInitialPromptDroppedIfCellExitsBeforeReady() async {
        let b = FakeBackend()
        b.screen = "loading…"                            // never clears
        let cell = makeCell(b, initialPrompt: "task", readyTimeout: 5) { _, _ in }
        await cell.start()
        b.simulateExit(0)                                // exited before ready
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(b.sent.isEmpty, "a dead cell is never injected into")
    }

    func testInjectSendsTextThenSeparateCR() async throws {
        let b = FakeBackend()
        let cell = makeCell(b) { _, _ in }
        await cell.start()
        let ack = try await cell.inject("do the thing")
        XCTAssertTrue(ack.delivered)
        XCTAssertEqual(b.sent, ["do the thing", "\r"])   // CR is its own keystroke (injection contract)
    }

    // MARK: - injection window (beginInject/endInject) wraps the sequence

    func testInjectWrapsSendSequenceInInjectionWindow() async throws {
        // begin must open the window BEFORE the body, end must close it AFTER the CR — so the
        // backend gate buffers only the true ~200ms window and replays user keystrokes after.
        let b = FakeBackend()
        let cell = makeCell(b) { _, _ in }
        await cell.start()
        let ack = try await cell.inject("payload")
        XCTAssertTrue(ack.delivered)
        XCTAssertEqual(b.callLog, ["begin", "send:payload", "send:\r", "end"],
                       "window: begin before the body, end after the CR")
    }

    func testInjectWindowClosesAfterHoldClears() async throws {
        // The hold runs with the window closed: begin appears only AFTER the
        // input line clears, never during the poll — so the human types straight through while held.
        let b = FakeBackend(); b.screen = screenUserTyping
        let cell = makeCell(b) { _, _ in }
        await cell.start()
        let pending = Task { try await cell.inject("held then sent") }
        try await Task.sleep(nanoseconds: 120_000_000)   // several poll ticks, still typing
        XCTAssertTrue(b.callLog.isEmpty, "the gate stays closed while polling on hold (no begin)")
        b.screen = screenInputEmpty
        _ = try await pending.value
        XCTAssertEqual(b.callLog, ["begin", "send:held then sent", "send:\r", "end"],
                       "the window opens only after the line clears; begin appears only in the commit sequence")
    }

    func testNoInjectionWindowWhenCellNotRunning() async throws {
        // Early return (cell not started) happens BEFORE beginInject, so no window ever opens
        // — the defer can't fire an unmatched end (begin/end never appear).
        let b = FakeBackend()
        let cell = makeCell(b) { _, _ in }
        let ack = try await cell.inject("x")
        XCTAssertFalse(ack.delivered)
        XCTAssertTrue(b.callLog.isEmpty, "a cell that never ran opens no window; defer emits no unpaired end")
    }

    func testNoInjectionWindowWhenCellExitsWhileQueued() async throws {
        // The queued-then-exit return also sits inside the hold loop, BEFORE beginInject — so
        // begin/end never fire even though the inject was undelivered.
        let b = FakeBackend(); b.screen = screenUserTyping
        let cell = makeCell(b) { _, _ in }
        await cell.start()
        let pending = Task { try await cell.inject("late") }
        try await Task.sleep(nanoseconds: 60_000_000)
        b.simulateExit(1)
        let ack = try await pending.value
        XCTAssertFalse(ack.delivered)
        XCTAssertTrue(b.callLog.isEmpty, "a cell that dies while queued: no window opens, no begin/end")
    }

    func testConcurrentInjectsDoNotInterleave() async throws {
        // N routes to the SAME cell (e.g. workers reporting up to one
        // manager) must not splice into `A B \r \r` — each message's text is
        // immediately followed by its OWN carriage return (send→settle→CR runs
        // atomically per inject).
        // 8 concurrent injects × 20 rounds turns a probabilistic race detector into a
        // reliable regression gate. The path is deterministic (tail read+swap in ONE lock
        // section), so this must stay green every run, never flaky.
        @Sendable func runRound(_ round: Int) async throws {
            let b = FakeBackend()
            let cell = RealCell(nodeID: NodeID("n1"),
                                launch: LaunchSpec(executable: "/bin/echo", args: ["hi"], env: [:]),
                                cwd: "/tmp", backend: b,
                                injectPollInterval: 0.02, injectMaxQueueWait: 5) { _, _ in }
            await cell.start()
            let messages = (0..<8).map { "msg\(round)-\($0)" }
            try await withThrowingTaskGroup(of: Void.self) { g in
                for m in messages { g.addTask { _ = try await cell.inject(m) } }
                try await g.waitForAll()
            }
            let sent = b.sent
            XCTAssertEqual(sent.count, 16, "round \(round): 8 messages each text+CR, 16 sends total")
            // Every text token is directly followed by a CR (no A,B,\r,\r splicing).
            for (i, tok) in sent.enumerated() where tok != "\r" {
                XCTAssertEqual(i + 1 < sent.count ? sent[i + 1] : nil, "\r",
                               "round \(round): \(tok) must be immediately followed by its own carriage return")
            }
            XCTAssertEqual(Set(sent.filter { $0 != "\r" }), Set(messages),
                           "round \(round): all 8 delivered, each as its own segment")
        }
        // Rounds are independent cells, so they run concurrently: 20 rounds cost one
        // round's wall-clock (each inject pays a fixed 0.15s settle inside the chain).
        try await withThrowingTaskGroup(of: Void.self) { rounds in
            for r in 0..<20 { rounds.addTask { try await runRound(r) } }
            try await rounds.waitForAll()
        }
    }

    func testInjectBeforeStartFails() async throws {
        let b = FakeBackend()
        let cell = makeCell(b) { _, _ in }
        let ack = try await cell.inject("x")
        XCTAssertFalse(ack.delivered)
        XCTAssertTrue(b.sent.isEmpty)
    }

    func testSnapshotReadsScreen() async {
        let b = FakeBackend(); b.screen = "VIGIL_PROOF_123"
        let cell = makeCell(b) { _, _ in }
        await cell.start()
        let snap = await cell.snapshot()
        XCTAssertEqual(snap, "VIGIL_PROOF_123")
    }

    func testExitReportsOnceWithCode() async {
        let b = FakeBackend()
        let box = ExitBox()
        let cell = makeCell(b) { id, code in box.record(id, code) }
        await cell.start()
        b.simulateExit(0)
        b.simulateExit(0)              // second exit must be ignored (reported once)
        XCTAssertEqual(box.calls.count, 1)
        XCTAssertEqual(box.calls.first?.0, NodeID("n1"))
        XCTAssertEqual(box.calls.first?.1, 0)
    }

    func testInjectAfterExitFails() async throws {
        let b = FakeBackend()
        let cell = makeCell(b) { _, _ in }
        await cell.start()
        b.simulateExit(1)
        let ack = try await cell.inject("late")
        XCTAssertFalse(ack.delivered)
    }

    // MARK: - input-line probe (inject shares the input surface with the human)

    func testProbeInputLineEmpty() {
        XCTAssertEqual(RealCell.probeInputLine(screenInputEmpty), .clear)
    }

    func testProbeInputLineUserTyping() {
        XCTAssertEqual(RealCell.probeInputLine(screenUserTyping),
                       .userTyping("half typed by the human"))
    }

    func testProbeInputLineNoBoxIsUnknown() {
        XCTAssertEqual(RealCell.probeInputLine("(scripted screen)"), .unknown)
        XCTAssertEqual(RealCell.probeInputLine(""), .unknown)
    }

    func testProbeInputLineMultilineBoxFindsPromptLine() {
        // A grown multi-line input box: the current (bottom) line is empty but the
        // prompt line above still holds text — that's still "the human is typing".
        let s = """
        ╭──────────────────╮
        │ > first line     │
        │   second line    │
        ╰──────────────────╯
        """
        XCTAssertEqual(RealCell.probeInputLine(s), .userTyping("first line"))
    }

    // MARK: - dim main layer (claude ≥2.1.205 full-width U+2500 double-rule bracket + dim verdict)

    /// A full-width rule line (all U+2500), the input-box border. 60 cells ≥ K(20).
    private func ruleLine(_ n: Int = 60) -> AttributedLine {
        let t = String(repeating: "\u{2500}", count: n)
        return AttributedLine(text: t, dim: Array(repeating: false, count: n))
    }
    /// A plain (non-dim) line — transcript / menu / status rows.
    private func plainLine(_ s: String) -> AttributedLine {
        AttributedLine(text: s, dim: Array(repeating: false, count: s.count))
    }
    /// One prompt line: mode prefix + a whitespace pad (space or NBSP) + content. The prefix and
    /// pad are never dim; `contentDim` sets the content's dim (true = claude placeholder). Mirrors
    /// the real bytes `❯\u{a0}\x1b[2mTry "…"` (placeholder) vs `❯ fix the parse` (typing).
    private func promptLine(_ prefix: Character, _ ws: Character,
                            _ content: String, contentDim: Bool) -> AttributedLine {
        let text = String(prefix) + String(ws) + content
        var dim = [false, false]
        dim += Array(repeating: contentDim, count: content.count)
        return AttributedLine(text: text, dim: dim)
    }

    func testProbeDimEmptyPlaceholderIsClear() {
        // Empty box: claude renders the dim placeholder `❯<NBSP>Try "…"` → .clear (safe to inject).
        let screen = AttributedScreen(lines: [
            plainLine("some transcript output"),
            ruleLine(),
            promptLine("\u{276F}", "\u{a0}", "Try \"how do I log an error?\"", contentDim: true),
            ruleLine(),
            plainLine("  ⏸ manual mode on · ? for shortcuts"),
        ])
        XCTAssertEqual(RealCell.probeInputLine(screen), .clear)
    }

    func testProbeDimUserTypingIsUserTyping() {
        // Non-dim content after the prefix = the human is mid-typing → hold.
        let screen = AttributedScreen(lines: [
            ruleLine(),
            promptLine("\u{276F}", " ", "fix the parse", contentDim: false),
            ruleLine(),
        ])
        XCTAssertEqual(RealCell.probeInputLine(screen), .userTyping("fix the parse"))
    }

    func testProbeDimBashPlaceholderIsClear() {
        // bash mode: the prefix is `!`; the placeholder is still dim → .clear.
        let screen = AttributedScreen(lines: [
            ruleLine(),
            promptLine("!", "\u{a0}", "Try \"run the tests\"", contentDim: true),
            ruleLine(),
        ])
        XCTAssertEqual(RealCell.probeInputLine(screen), .clear)
    }

    func testProbeDimBashUserTypingIsUserTyping() {
        let screen = AttributedScreen(lines: [
            ruleLine(),
            promptLine("!", " ", "ls", contentDim: false),
            ruleLine(),
        ])
        XCTAssertEqual(RealCell.probeInputLine(screen), .userTyping("ls"))
    }

    func testProbeDimMultilineFoldedUserTypingIsUserTyping() {
        // A folded multi-line input: only the first bracketed line carries the prefix; the
        // continuation line has none and is skipped. Verdict = userTyping (its first line).
        let screen = AttributedScreen(lines: [
            ruleLine(),
            promptLine("\u{276F}", " ", "first folded line", contentDim: false),
            plainLine("  second folded line"),
            ruleLine(),
        ])
        XCTAssertEqual(RealCell.probeInputLine(screen), .userTyping("first folded line"))
    }

    func testProbeDimSlashMenuNotMisreadAsMenuLine() {
        // `/` command menu renders ABOVE the top rule (not in the bracket); the bracket holds
        // `❯ /`. Verdict must be userTyping("/"), never a menu row.
        let screen = AttributedScreen(lines: [
            plainLine("/help    Show help"),
            plainLine("/clear   Clear conversation"),
            plainLine("/agents  Manage agents"),
            ruleLine(),
            promptLine("\u{276F}", " ", "/", contentDim: false),
            ruleLine(),
            plainLine("  ? for shortcuts"),
        ])
        XCTAssertEqual(RealCell.probeInputLine(screen), .userTyping("/"))
    }

    func testProbeDimPermissionScreenIsNotUserTyping() {
        // Permission-screen sample = captured from a real machine (claude 2.1.205,
        // `claude`, pyte, mktemp cwd + empty --settings bypassing the
        // allowlist, prompt `mkfifo` triggers the dialog, never approved). REAL structure: a SINGLE
        // full-width U+2500 rule sits ABOVE the "Bash command" panel and there is NO bottom rule —
        // the `❯ 1. Yes` options are bare indented lines, NOT rule-bracketed and NOT `│…│` boxed.
        // So the dim layer's bottomRulePair finds only one rule (needs a PAIR) → nil → box fallback →
        // no `│…>` prompt line → .unknown. The invariant under test: a permission screen is NEVER
        // read as .userTyping (a blind inject here would spuriously pick "1. Yes").
        let rule = String(repeating: "\u{2500}", count: 120)
        let screen = AttributedScreen(lines: [
            plainLine("⏺ Running 1 shell command…"),
            plainLine("  ⎿  $ mkfifo /tmp/vigil-perm-probe-fifo"),
            plainLine(""),
            plainLine(rule),                                        // the ONLY full-width U+2500 rule
            plainLine(" Bash command"),
            plainLine(""),
            plainLine("   mkfifo /tmp/vigil-perm-probe-fifo"),
            plainLine("   Create named pipe at /tmp/vigil-perm-probe-fifo"),
            plainLine(""),
            plainLine(" This command requires approval"),
            plainLine(""),
            plainLine(" Do you want to proceed?"),
            plainLine(" \u{276F} 1. Yes"),                          // ❯ = U+276F, but not rule-bracketed
            plainLine("   2. Yes, and don't ask again for: mkfifo *"),
            plainLine("   3. No"),
            plainLine(""),
            plainLine(" Esc to cancel · Tab to amend · ctrl+e to explain"),
        ])
        if case .userTyping = RealCell.probeInputLine(screen) {
            XCTFail("permission screen must not read as userTyping")
        }
        XCTAssertEqual(RealCell.probeInputLine(screen), .unknown)
    }

    func testProbeDimGenuinelyEmptyBracketIsClear() {
        // A rule pair with nothing but blanks between → .clear (nothing to merge into).
        let screen = AttributedScreen(lines: [
            ruleLine(),
            plainLine("     "),
            ruleLine(),
        ])
        XCTAssertEqual(RealCell.probeInputLine(screen), .clear)
    }


    // MARK: - closed-loop submit (land → CR → confirm → bounded re-CR)

    private func boxScreen(_ content: String) -> String {
        """
        some earlier output
        ╭──────────────────────────────────────────╮
        │ > \(content)
        ╰──────────────────────────────────────────╯
          ? for shortcuts
        """
    }

    /// Script a TUI: pasted text lands `landDelay` after send; each CR clears the box iff
    /// `swallow` CRs have already been eaten (codex startup window).
    private func scriptTUI(_ b: FakeBackend, landDelay: TimeInterval = 0, swallow: Int = 0,
                           crScreens: CRLog = CRLog()) {
        let eaten = Counter()
        b.screen = screenInputEmpty
        b.onSend = { [unowned b] tok in
            if tok == "\r" {
                crScreens.add(b.screen)
                if eaten.value < swallow { eaten.bump(); return }
                b.screen = screenInputEmpty
            } else {
                if landDelay == 0 { b.screen = self.boxScreen(tok) }
                else {
                    Task { try? await Task.sleep(seconds: landDelay); b.screen = self.boxScreen(tok) }
                }
            }
        }
    }

    func testClosedLoopConfirmedNoExtraCR() async throws {
        let b = FakeBackend(); scriptTUI(b)
        let cell = makeCell(b) { _, _ in }
        await cell.start()
        let ack = try await cell.inject("hello")
        XCTAssertTrue(ack.delivered); XCTAssertNil(ack.note)
        XCTAssertEqual(b.sent, ["hello", "\r"])
    }

    func testCRSwallowedOnceIsRetriedAndWindowClosedBetween() async throws {
        let b = FakeBackend(); scriptTUI(b, swallow: 1)
        let cell = makeCell(b) { _, _ in }
        await cell.start()
        let ack = try await cell.inject("hello")
        XCTAssertTrue(ack.delivered)
        XCTAssertEqual(b.sent, ["hello", "\r", "\r"])
        XCTAssertTrue(ack.note?.contains("submit confirmed after 1 extra CR") ?? false, "\(ack.note ?? "nil")")
        XCTAssertEqual(b.callLog, ["begin", "send:hello", "send:\r", "end",
                                   "begin", "send:\r", "end"],
                       "window closes before the retry wait; each re-CR gets its own window")
    }

    func testDelayedLandingCRComesAfterLanding() async throws {
        let b = FakeBackend(); let crs = CRLog(); scriptTUI(b, landDelay: 0.15, crScreens: crs)
        let cell = makeCell(b, landTimeout: 2) { _, _ in }
        await cell.start()
        let ack = try await cell.inject("with image")
        XCTAssertTrue(ack.delivered)
        XCTAssertEqual(b.sent, ["with image", "\r"], "exactly one CR")
        XCTAssertEqual(crs.all.count, 1)
        XCTAssertEqual(RealCell.probeInputLine(crs.all[0]), .userTyping("with image"),
                       "the CR must be sent only after the text landed in the box")
    }

    func testPartialRenderIsNotMistakenForLanded() async throws {
        // A busy TUI paints the paste over several frames. Snapshotting the first frame as
        // `landed` would make the next frame look like "the box changed → submitted" and
        // silently skip the re-CR. The CR must wait until the box content stops changing.
        let b = FakeBackend(); let crs = CRLog()
        b.screen = screenInputEmpty
        b.onSend = { [unowned b] tok in
            if tok == "\r" { crs.add(b.screen); b.screen = screenInputEmpty; return }
            Task { [weak b] in
                try? await Task.sleep(seconds: 0.1); b?.screen = self.boxScreen("hel")
                try? await Task.sleep(seconds: 0.1); b?.screen = self.boxScreen("hello world")
            }
        }
        let cell = makeCell(b, landTimeout: 2) { _, _ in }
        await cell.start()
        let ack = try await cell.inject("hello world")
        XCTAssertTrue(ack.delivered); XCTAssertNil(ack.note)
        XCTAssertEqual(b.sent, ["hello world", "\r"])
        XCTAssertEqual(RealCell.probeInputLine(crs.all[0]), .userTyping("hello world"),
                       "the CR must wait for the box content to settle, not fire on a partial frame")
    }

    func testNeverLandedKeepsOpenLoopSingleCR() async throws {
        let b = FakeBackend(); b.screen = screenInputEmpty       // box stays empty after send
        let cell = makeCell(b, landTimeout: 0.1, retryTimeout: 0.5) { _, _ in }
        await cell.start()
        let ack = try await cell.inject("x")
        XCTAssertTrue(ack.delivered)
        XCTAssertEqual(b.sent, ["x", "\r"], "never observed landing → old behaviour, no retry")
    }

    func testFailOpenInjectDoesNotRetry() async throws {
        let b = FakeBackend(); b.screen = screenUserTyping       // human content that never clears
        let cell = makeCell(b, maxQueueWait: 0.1, retryTimeout: 0.5) { _, _ in }
        await cell.start()
        let ack = try await cell.inject("x")
        XCTAssertTrue(ack.delivered)
        XCTAssertEqual(b.sent, ["x", "\r"])
    }

    func testRetryStopsWhenInputChangedUnderUs() async throws {
        let b = FakeBackend(); scriptTUI(b, swallow: 100)
        let cell = makeCell(b, confirmWindow: 0.1, retryTimeout: 5, retryInterval: 0.4) { _, _ in }
        await cell.start()
        let t = Task { try await cell.inject("hello") }
        try await Task.sleep(nanoseconds: 350_000_000)           // CR#1 swallowed, waiting to retry
        b.screen = boxScreen("human is typing now")
        let ack = try await t.value
        XCTAssertEqual(b.sent, ["hello", "\r"], "content changed → no further CR, ever")
        XCTAssertTrue(ack.note?.contains("confirmed after 0 extra") ?? false, "\(ack.note ?? "nil")")
    }

    func testRetryBudgetExhaustedReportsUnconfirmed() async throws {
        let b = FakeBackend(); scriptTUI(b, swallow: 1000)
        let cell = makeCell(b, confirmWindow: 0.03, retryTimeout: 0.3, retryInterval: 0.05) { _, _ in }
        await cell.start()
        let ack = try await cell.inject("stuck")
        XCTAssertTrue(ack.delivered)
        XCTAssertTrue(ack.note?.contains("submit unconfirmed after") ?? false, "\(ack.note ?? "nil")")
        XCTAssertGreaterThan(b.sent.filter { $0 == "\r" }.count, 2)
        XCTAssertLessThan(b.sent.filter { $0 == "\r" }.count, 20, "bounded")
        XCTAssertEqual(b.callLog.filter { $0 == "begin" }.count, b.callLog.filter { $0 == "end" }.count)
    }

    func testRetryLoopExitsPromptlyOnCancelAndOnCellExit() async throws {
        let b = FakeBackend(); scriptTUI(b, swallow: 1000)
        let cell = makeCell(b, confirmWindow: 0.03, retryTimeout: 60, retryInterval: 0.05) { _, _ in }
        await cell.start()
        let t = Task { try await cell.inject("stuck") }
        try await Task.sleep(nanoseconds: 200_000_000)
        let t0 = Date(); t.cancel()
        _ = try? await t.value
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2, "cancel must end the retry loop")

        let b2 = FakeBackend(); scriptTUI(b2, swallow: 1000)
        let cell2 = makeCell(b2, confirmWindow: 0.03, retryTimeout: 60, retryInterval: 0.05) { _, _ in }
        await cell2.start()
        let t2 = Task { try await cell2.inject("stuck") }
        try await Task.sleep(nanoseconds: 200_000_000)
        let t1 = Date(); b2.simulateExit(1)
        _ = try? await t2.value
        XCTAssertLessThan(Date().timeIntervalSince(t1), 2, "cell exit must end the retry loop")
    }

    func testInjectImmediateWhenInputLineEmpty() async throws {
        let b = FakeBackend(); b.screen = screenInputEmpty
        let cell = makeCell(b) { _, _ in }
        await cell.start()
        let ack = try await cell.inject("go")
        XCTAssertTrue(ack.delivered)
        XCTAssertNil(ack.note)                        // clean path: no queueing happened
        XCTAssertEqual(b.sent, ["go", "\r"])
    }

    func testInjectQueuedWhileUserTypingThenDeliveredAfterClear() async throws {
        let b = FakeBackend(); b.screen = screenUserTyping
        let cell = makeCell(b) { _, _ in }
        await cell.start()
        let pending = Task { try await cell.inject("rollup msg") }
        try await Task.sleep(nanoseconds: 150_000_000)   // several poll ticks
        XCTAssertTrue(b.sent.isEmpty, "inject must hold while the human is typing")
        b.screen = screenInputEmpty                      // human submitted / cleared
        let ack = try await pending.value
        XCTAssertTrue(ack.delivered)
        XCTAssertTrue(ack.note?.contains("queued") ?? false,
                      "ack.note should carry the queued duration, got \(ack.note ?? "nil")")
        XCTAssertEqual(b.sent, ["rollup msg", "\r"])
    }

    func testConcurrentInjectsQueuedBehindTypingThenReleasedThroughChain() async throws {
        // The queue/poll path under concurrency. While the human
        // is mid-typing ALL injects must hold — the chain head polls the input line,
        // the rest wait behind it in the FIFO chain. Once the line clears, the head
        // delivers (ack carries its queued note) and the rest flow straight through
        // (line already clear → no note), each still one atomic text+CR segment.
        let b = FakeBackend(); b.screen = screenUserTyping
        let cell = makeCell(b) { _, _ in }
        await cell.start()
        let messages = (0..<4).map { "queue\($0)" }
        let tasks = messages.map { m in Task { try await cell.inject(m) } }
        try await Task.sleep(nanoseconds: 150_000_000)   // several poll ticks
        XCTAssertTrue(b.sent.isEmpty, "when the input line is non-empty every inject must be held")
        b.screen = screenInputEmpty                      // human submitted / cleared
        var acks: [InjectAck] = []
        for t in tasks { acks.append(try await t.value) }

        XCTAssertTrue(acks.allSatisfy(\.delivered), "after clearing, released in order, all delivered")
        XCTAssertEqual(acks.filter { $0.note?.contains("queued") ?? false }.count, 1,
                       "only the chain head actually polled; the rest wait behind it and the line is already clear by their turn")
        let sent = b.sent
        XCTAssertEqual(sent.count, 8, "4 messages each text+CR, 8 sends total")
        for (i, tok) in sent.enumerated() where tok != "\r" {
            XCTAssertEqual(i + 1 < sent.count ? sent[i + 1] : nil, "\r",
                           "\(tok) must be immediately followed by its own carriage return")
        }
        XCTAssertEqual(Set(sent.filter { $0 != "\r" }), Set(messages), "all 4 delivered, each as its own segment")
    }

    func testInjectFailOpenWhenProbeUnknown() async throws {
        let b = FakeBackend(); b.screen = "no input box on this screen"
        let cell = makeCell(b) { _, _ in }
        await cell.start()
        let ack = try await cell.inject("go anyway")
        XCTAssertTrue(ack.delivered)                  // fail-open: never hold on a bad scrape
        XCTAssertEqual(b.sent, ["go anyway", "\r"])
    }

    func testInjectFailOpenAfterMaxQueueWait() async throws {
        let b = FakeBackend(); b.screen = screenUserTyping
        let cell = makeCell(b, pollInterval: 0.02, maxQueueWait: 0.1) { _, _ in }
        await cell.start()
        let ack = try await cell.inject("must not be held forever")
        XCTAssertTrue(ack.delivered)                  // cap reached → inject anyway
        XCTAssertTrue(ack.note?.contains("fail-open") ?? false,
                      "ack.note should say fail-open, got \(ack.note ?? "nil")")
        XCTAssertEqual(b.sent, ["must not be held forever", "\r"])
    }

    func testInjectPollLoopExitsPromptlyOnCancellation() async throws {
        // The hold loop must check Task.isCancelled and propagate cancellation, not swallow
        // it — a cancelled inject must not hot-spin until injectMaxQueueWait (120s prod).
        // Cancelling the inject task must return an undelivered ack fast, running the
        // hold-settle defer on the way out (cf. PermWatcher's implementation).
        let b = FakeBackend(); b.screen = screenUserTyping   // holds & polls indefinitely
        // A large cap: the loop must not spin the full duration once cancelled, or the deadline below trips.
        let cell = makeCell(b, pollInterval: 0.02, maxQueueWait: 30) { _, _ in }
        await cell.start()
        let done = DoneBox()
        let t = Task { done.finish(try? await cell.inject("x")) }
        try await Task.sleep(nanoseconds: 100_000_000)       // in the hold loop, still typing
        XCTAssertTrue(b.sent.isEmpty, "still holding while the human types")
        t.cancel()
        await waitUntil(3) { done.isDone }                   // must return well under maxWait
        XCTAssertTrue(done.isDone, "after cancellation inject must return promptly, never hot-spin up to maxQueueWait")
        XCTAssertEqual(done.ack?.delivered, false, "cancelled = not delivered")
        XCTAssertTrue(b.sent.isEmpty, "never inject after cancellation")
    }

    func testHoldNoticeSettlesOnCancellation() async throws {
        // The cancellation exit path must still run the hold-settle defer — a fired card that
        // never settles outlives the queue it reports (orphan card, same invariant as
        // fail-open / cell-death exits).
        let b = FakeBackend(); b.screen = screenUserTyping
        let box = HoldBox()
        let cell = makeCell(b, maxQueueWait: 30, holdNoticeDelay: 0.04,
                            onInjectHold: { _, p, h, e in box.record(p, h, e) }) { _, _ in }
        await cell.start()
        let done = DoneBox()
        let t = Task { done.finish(try? await cell.inject("x")) }
        await waitUntil { !box.events.isEmpty }              // held notice fired
        t.cancel()
        await waitUntil(3) { done.isDone }
        XCTAssertEqual(box.events.map(\.held), [true, false], "cancellation must settle too — no orphaned card left behind")
    }

    func testInjectQueuedThenCellExitsReportsUndelivered() async throws {
        let b = FakeBackend(); b.screen = screenUserTyping
        let cell = makeCell(b) { _, _ in }
        await cell.start()
        let pending = Task { try await cell.inject("late") }
        try await Task.sleep(nanoseconds: 60_000_000)
        b.simulateExit(1)
        let ack = try await pending.value
        XCTAssertFalse(ack.delivered)                 // never silently pretend delivery
        XCTAssertTrue(b.sent.isEmpty)
    }

    // MARK: - hold notice (a queued state must speak up — the hold becomes a user-visible signal)

    func testHoldNoticeFiresAfterGraceAndSettlesOnDelivery() async throws {
        let b = FakeBackend(); b.screen = screenUserTyping
        let box = HoldBox()
        let cell = makeCell(b, onInjectHold: { _, p, h, e in box.record(p, h, e) }) { _, _ in }
        await cell.start()
        let pending = Task { try await cell.inject("msg") }
        await waitUntil { !box.events.isEmpty }              // past the grace, still typing
        try await Task.sleep(nanoseconds: 150_000_000)       // margin: a duplicate would land here
        XCTAssertEqual(box.events.map(\.held), [true], "exactly one held notice after the grace, never repeated")
        XCTAssertEqual(box.events.first?.pending, 1)
        b.screen = screenInputEmpty                          // human cleared the line
        let ack = try await pending.value
        XCTAssertTrue(ack.delivered)
        XCTAssertEqual(box.events.map(\.held), [true, false], "must settle after delivery")
    }

    func testQuickClearNeverFiresHoldNotice() async throws {
        // Same technique as the quick-clear case: a line that clears inside the grace window never flashes a card.
        let b = FakeBackend(); b.screen = screenUserTyping
        let box = HoldBox()
        let cell = makeCell(b, holdNoticeDelay: 1.0,
                            onInjectHold: { _, p, h, e in box.record(p, h, e) }) { _, _ in }
        await cell.start()
        let pending = Task { try await cell.inject("msg") }
        try await Task.sleep(nanoseconds: 60_000_000)        // a few polls, inside the grace
        b.screen = screenInputEmpty
        let ack = try await pending.value
        XCTAssertTrue(ack.delivered)
        XCTAssertTrue(box.events.isEmpty, "release within the grace window emits no notice")
    }

    func testHoldNoticeSettlesOnFailOpen() async throws {
        let b = FakeBackend(); b.screen = screenUserTyping
        let box = HoldBox()
        // A short fail-open window can expire on a slow runner before the first poll tick
        // (fail-open happens before the notice gets a chance to fire, giving an event sequence
        // of [] instead of [true, false]). Use a 2s window and wait for the notice to actually
        // appear first; the invariant under test is unchanged: a fired notice must settle.
        let cell = makeCell(b, maxQueueWait: 2.0, holdNoticeDelay: 0.04,
                            onInjectHold: { _, p, h, e in box.record(p, h, e) }) { _, _ in }
        await cell.start()
        let pending = Task { try await cell.inject("cap") }
        await waitUntil { !box.events.isEmpty }              // held notice has already fired
        let ack = try await pending.value                    // hits the 2s mark, fail-open
        XCTAssertTrue(ack.delivered)                         // fail-open delivered anyway
        XCTAssertEqual(box.events.map(\.held), [true, false], "fail-open must settle too")
    }

    func testHoldNoticeSettlesWhenCellExits() async throws {
        let b = FakeBackend(); b.screen = screenUserTyping
        let box = HoldBox()
        let cell = makeCell(b, onInjectHold: { _, p, h, e in box.record(p, h, e) }) { _, _ in }
        await cell.start()
        let pending = Task { try await cell.inject("late") }
        await waitUntil { !box.events.isEmpty }              // held notice fired
        b.simulateExit(1)
        let ack = try await pending.value
        XCTAssertFalse(ack.delivered)
        await waitUntil { box.events.count == 2 }            // settle callback drains
        XCTAssertEqual(box.events.map(\.held), [true, false], "a dead cell must settle too — no orphaned card left behind")
    }

    func testSecondInjectRefreshesHeldPendingCount() async throws {
        let b = FakeBackend(); b.screen = screenUserTyping
        let box = HoldBox()
        let cell = makeCell(b, onInjectHold: { _, p, h, e in box.record(p, h, e) }) { _, _ in }
        await cell.start()
        let first = Task { try await cell.inject("A") }
        try await Task.sleep(nanoseconds: 200_000_000)       // A's held notice has already fired
        let second = Task { try await cell.inject("B") }     // B queues at the tail of the FIFO
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(box.events.filter(\.held).map(\.pending), [1, 2],
                       "a second one queuing up must refresh the count")
        b.screen = screenInputEmpty
        let (a, c) = try await (first.value, second.value)
        XCTAssertTrue(a.delivered && c.delivered)
        XCTAssertEqual(box.events.last?.held, false)
    }

    func testHoldNoticeEpochsAreStrictlyMonotonic() async throws {
        // RealCell stamps every emission with a strictly increasing, unique epoch under its
        // lock (decision order), so the store can order signals that reorder across its
        // MainActor hop. Drive held→refresh→settle and assert the epochs are monotonic and distinct.
        let b = FakeBackend(); b.screen = screenUserTyping
        let box = HoldBox()
        let cell = makeCell(b, onInjectHold: { _, p, h, e in box.record(p, h, e) }) { _, _ in }
        await cell.start()
        let first = Task { try await cell.inject("A") }
        try await Task.sleep(nanoseconds: 200_000_000)       // A held
        let second = Task { try await cell.inject("B") }     // refresh
        try await Task.sleep(nanoseconds: 100_000_000)
        b.screen = screenInputEmpty
        _ = try await (first.value, second.value)
        let epochs = box.events.map(\.epoch)
        XCTAssertFalse(epochs.isEmpty)
        XCTAssertEqual(epochs, epochs.sorted(), "epoch must be monotonic (decision order under the lock)")
        XCTAssertEqual(Set(epochs).count, epochs.count, "epoch must be unique")
    }

    // MARK: - bracketedPasteWrap (multi-line send parity with ghostty's native paste path)

    func testBracketedPasteWrapModeOffIsRaw() {
        XCTAssertEqual(bracketedPasteWrap("a\nb\nc", modeOn: false), "a\nb\nc")
    }

    func testBracketedPasteWrapSingleLineUnchanged() {
        XCTAssertEqual(bracketedPasteWrap("1\r", modeOn: true), "1\r")
        XCTAssertEqual(bracketedPasteWrap("hello", modeOn: true), "hello")
    }

    func testBracketedPasteWrapMultilineWrapsBodyKeepsTrailingCROutside() {
        // Body newlines ride INSIDE the paste block; the submission CR stays outside —
        // the same shape ghostty's paste path produces natively.
        XCTAssertEqual(bracketedPasteWrap("a\nb\nc", modeOn: true),
                       "\u{1b}[200~a\nb\nc\u{1b}[201~")
        XCTAssertEqual(bracketedPasteWrap("a\nb\r", modeOn: true),
                       "\u{1b}[200~a\nb\u{1b}[201~\r")
    }
}

/// Thread-safe collector for the exit callback (it may fire off the test's task).
final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(NodeID, Int32?)] = []
    func record(_ id: NodeID, _ code: Int32?) { lock.lock(); calls.append((id, code)); lock.unlock() }
}

/// Thread-safe latch for an inject's completion + its ack (the inject runs in its own Task).
final class DoneBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _ack: InjectAck?
    private var _done = false
    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return _done }
    var ack: InjectAck? { lock.lock(); defer { lock.unlock() }; return _ack }
    func finish(_ a: InjectAck?) { lock.lock(); _ack = a; _done = true; lock.unlock() }
}

/// Thread-safe collector for hold notices (fired from the inject's polling task).
final class HoldBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [(pending: Int, held: Bool, epoch: UInt64)] = []
    var events: [(pending: Int, held: Bool, epoch: UInt64)] { lock.lock(); defer { lock.unlock() }; return _events }
    func record(_ pending: Int, _ held: Bool, _ epoch: UInt64) {
        lock.lock(); _events.append((pending, held, epoch)); lock.unlock()
    }
}

final class CRLog: @unchecked Sendable {
    private let lock = NSLock(); private var _a: [String] = []
    func add(_ s: String) { lock.lock(); _a.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return _a }
}
final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var _v = 0
    func bump() { lock.lock(); _v += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _v }
}
