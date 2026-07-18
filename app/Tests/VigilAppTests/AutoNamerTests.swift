import XCTest
import VigilCore
import VigilRuntime
@testable import VigilApp

/// T1a: AutoNamer reads the title claude itself appends to the session transcript JSONL
/// (no subprocess spawn). Parsing contract
/// (`AutoNamer.extractTitle`):
///   - `{"type":"ai-title","aiTitle":"..."}` lines repeat per turn → take the LAST one;
///   - `{"type":"custom-title",...}` (user `/rename`) beats ai-title regardless of order —
///     a manual name is never overwritten by the auto title;
///   - best-effort: no title lines / garbage lines → nil (format is claude-internal and
///     may change between versions; nil keeps the current name).
final class AutoNamerTests: XCTestCase {

    func testTakesLastAITitle() {
        let jsonl = """
        {"type":"ai-title","aiTitle":"old title","sessionId":"s1"}
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"ai-title","aiTitle":"new title","sessionId":"s1"}
        """
        XCTAssertEqual(AutoNamer.extractTitle(from: jsonl), "new title")
    }

    func testCustomTitleWinsOverAITitle() {
        // custom-title before a newer ai-title: manual name still wins.
        let customFirst = """
        {"type":"custom-title","customTitle":"manual name","sessionId":"s1"}
        {"type":"ai-title","aiTitle":"auto name","sessionId":"s1"}
        """
        XCTAssertEqual(AutoNamer.extractTitle(from: customFirst), "manual name")

        // custom-title after the ai-title: same outcome.
        let customLast = """
        {"type":"ai-title","aiTitle":"auto name","sessionId":"s1"}
        {"type":"custom-title","customTitle":"manual name","sessionId":"s1"}
        """
        XCTAssertEqual(AutoNamer.extractTitle(from: customLast), "manual name")
    }

    func testCustomTitleTolerantFieldName() {
        // No local sample of a custom-title line exists, so the field name is unverified — accept "title" as well.
        let jsonl = """
        {"type":"ai-title","aiTitle":"auto name","sessionId":"s1"}
        {"type":"custom-title","title":"manual name","sessionId":"s1"}
        """
        XCTAssertEqual(AutoNamer.extractTitle(from: jsonl), "manual name")
    }

    func testNoTitleLinesReturnsNil() {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        not json at all {{{
        {"type":"ai-title"}
        """
        XCTAssertNil(AutoNamer.extractTitle(from: jsonl))
        XCTAssertNil(AutoNamer.extractTitle(from: ""))
    }

    func testTitleIsTrimmedAndClamped() {
        let long = String(repeating: "x", count: 80)
        let jsonl = "{\"type\":\"ai-title\",\"aiTitle\":\"  padded  \"}\n"
            + "{\"type\":\"ai-title\",\"aiTitle\":\"\(long)\"}"
        XCTAssertEqual(AutoNamer.extractTitle(from: jsonl), String(repeating: "x", count: 50))
        XCTAssertEqual(AutoNamer.extractTitle(from: "{\"type\":\"ai-title\",\"aiTitle\":\"  padded  \"}"),
                       "padded")
        // whitespace-only title = no title.
        XCTAssertNil(AutoNamer.extractTitle(from: "{\"type\":\"ai-title\",\"aiTitle\":\"   \"}"))
    }

    // MARK: opencode — title via `opencode export <sid>` JSON (info.title)

    func testOpenCodeExportTitleFromInfo() {
        // Real `opencode export` shape (probe-captured, opencode 1.17.16): {"info":{...,"title":…},"messages":[…]}
        let json = #"{"info":{"id":"ses_x","title":"PONG","version":"1.17.16"},"messages":[]}"#
        XCTAssertEqual(AutoNamer.extractOpenCodeTitle(fromExportJSON: json), "PONG")
    }

    func testOpenCodePlaceholderTitleSkipped() {
        // opencode seeds un-named sessions with "New session - <ISO ts>" — never surface it.
        let json = #"{"info":{"title":"New session - 2026-07-09T10:19:57.042Z"}}"#
        XCTAssertNil(AutoNamer.extractOpenCodeTitle(fromExportJSON: json))
    }

    func testOpenCodeMissingOrGarbageTitleReturnsNil() {
        XCTAssertNil(AutoNamer.extractOpenCodeTitle(fromExportJSON: #"{"info":{}}"#))
        XCTAssertNil(AutoNamer.extractOpenCodeTitle(fromExportJSON: #"{"messages":[]}"#))
        XCTAssertNil(AutoNamer.extractOpenCodeTitle(fromExportJSON: "not json {{{"))
        XCTAssertNil(AutoNamer.extractOpenCodeTitle(fromExportJSON: ""))
    }

    func testOpenCodeTitleTrimmedAndClamped() {
        let long = String(repeating: "x", count: 80)
        XCTAssertEqual(AutoNamer.extractOpenCodeTitle(fromExportJSON: "{\"info\":{\"title\":\"\(long)\"}}"),
                       String(repeating: "x", count: 50))
        XCTAssertEqual(AutoNamer.extractOpenCodeTitle(fromExportJSON: #"{"info":{"title":"  padded  "}}"#),
                       "padded")
        XCTAssertNil(AutoNamer.extractOpenCodeTitle(fromExportJSON: #"{"info":{"title":"   "}}"#))
    }

    // MARK: codex — honest fallback title from the main rollout's first user_message

    /// Write a minimal codex rollout (session_meta + optional event_msg lines) and return its path.
    private func writeRollout(_ lines: [String]) -> String {
        let path = NSTemporaryDirectory() + "vigil-codex-name-\(UUID().uuidString).jsonl"
        let meta = #"{"type":"session_meta","payload":{"session_id":"019f-x","thread_source":"user"}}"#
        try? (([meta] + lines).joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testCodexFallbackTitleTakesFirstLineOfFirstUserMessage() {
        let p = writeRollout([
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Spin up 10 codex workers for a stress test.\nFigure out what to give them; just don't modify files."}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"OK"}}"#,
        ])
        // honest: the user's literal first prompt (first line only), NOT a fabricated AI title
        XCTAssertEqual(AutoNamer.codexFallbackTitle(rolloutPath: p), "Spin up 10 codex workers for a stress test.")
    }

    func testCodexFallbackTitleClampsLongPrompt() {
        let long = String(repeating: "字", count: 80)
        let p = writeRollout([
            #"{"type":"event_msg","payload":{"type":"user_message","message":"\#(long)"}}"#,
        ])
        XCTAssertEqual(AutoNamer.codexFallbackTitle(rolloutPath: p), String(repeating: "字", count: 50))
    }

    func testCodexFallbackTitleNilWhenNoUserMessageYet() {
        // meta only (early capture before the first turn) → keep the launch name.
        XCTAssertNil(AutoNamer.codexFallbackTitle(rolloutPath: writeRollout([])))
        XCTAssertNil(AutoNamer.codexFallbackTitle(rolloutPath: "/does/not/exist.jsonl"))
    }
}

// MARK: - watch polling (aligning with cmux: a title is applied the moment it lands mid-turn)

@MainActor
final class AutoNamerWatchTests: XCTestCase {

    private func tmpPath() -> String {
        NSTemporaryDirectory() + "vigil-namer-watch-\(UUID().uuidString).jsonl"
    }

    func testWatchAppliesTitleTheMomentItLands() async throws {
        let p = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: p) }
        try #"{"type":"user","message":{"content":"hi"}}"#
            .write(toFile: p, atomically: true, encoding: .utf8)

        let namer = AutoNamer()
        var applied: String?
        namer.onName = { applied = $0 }
        namer.watch(transcriptPath: p, currentName: "launch prefix name", interval: 0.05)

        // The first few polls spin idle (no title line), then ai-title lands → the very next poll applies it.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(applied, "must not rename before the title lands")
        let fh = try XCTUnwrap(FileHandle(forWritingAtPath: p))
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(
            "\n{\"type\":\"ai-title\",\"aiTitle\":\"title generated mid-turn\"}\n".utf8))
        try fh.close()

        for _ in 0..<100 where applied == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(applied, "title generated mid-turn")
    }

    func testWatchStopsAfterFirstHitAndSkipsSameName() async throws {
        let p = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: p) }
        try #"{"type":"ai-title","aiTitle":"already the current name"}"#
            .write(toFile: p, atomically: true, encoding: .utf8)

        let namer = AutoNamer()
        var count = 0
        namer.onName = { _ in count += 1 }
        namer.watch(transcriptPath: p, currentName: "already the current name", interval: 0.05)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(count, 0, "title equals current name → no rename")
    }

    func testWatchSecondTurnSeesThroughTheStaleTitle() async throws {
        // claude rewrites ai-title every turn — from turn ≥2 onward, the transcript already
        // has the previous turn's stale title sitting in it. watch must not quit the moment
        // its first tick hits that stale title (that would make "mid-turn naming" work only
        // for the first turn) — it must treat that as the baseline and wait for the **new**
        // title of the current turn.
        let p = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: p) }
        try #"{"type":"ai-title","aiTitle":"previous turn's title"}"#
            .write(toFile: p, atomically: true, encoding: .utf8)

        let namer = AutoNamer()
        var applied: String?
        namer.onName = { applied = $0 }
        namer.watch(transcriptPath: p, currentName: "previous turn's title", interval: 0.05)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(applied, "old title = baseline, must not fire or quit early")

        let fh = try XCTUnwrap(FileHandle(forWritingAtPath: p))
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(
            "\n{\"type\":\"ai-title\",\"aiTitle\":\"second turn's new title\"}\n".utf8))
        try fh.close()
        for _ in 0..<100 where applied == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(applied, "second turn's new title", "new title lands → renamed mid-turn")
    }

    /// considerCodex reads the main rollout's first user_message off-main and applies it as
    /// the session name (the honest codex fallback — no ai-title/export title source). Skips when the
    /// derived title already equals the current name (fires every turn, must be idempotent).
    func testConsiderCodexAppliesFirstPromptAndSkipsSameName() async throws {
        let p = NSTemporaryDirectory() + "vigil-codex-consider-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: p) }
        try (#"{"type":"session_meta","payload":{"session_id":"019f-x","thread_source":"user"}}"# + "\n"
            + #"{"type":"event_msg","payload":{"type":"user_message","message":"review bugs codex collected"}}"# + "\n")
            .write(toFile: p, atomically: true, encoding: .utf8)

        let namer = AutoNamer()
        var applied: [String] = []
        namer.onName = { applied.append($0) }
        namer.considerCodex(rolloutPath: p, currentName: "launch prefix")
        for _ in 0..<100 where applied.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(applied, ["review bugs codex collected"])

        // already the current name → no spurious re-apply
        namer.considerCodex(rolloutPath: p, currentName: "review bugs codex collected")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(applied, ["review bugs codex collected"])
    }

    func testCancelWatchStopsThePolling() async throws {
        // Stop wind-down / shutdown hook: after cancellation, even a new title landing on disk must not be applied.
        let p = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: p) }
        try #"{"type":"user","message":{"content":"hi"}}"#
            .write(toFile: p, atomically: true, encoding: .utf8)

        let namer = AutoNamer()
        var applied: String?
        namer.onName = { applied = $0 }
        namer.watch(transcriptPath: p, currentName: "old name", interval: 0.05)
        namer.cancelWatch()
        let fh = try XCTUnwrap(FileHandle(forWritingAtPath: p))
        try fh.seekToEnd()
        try fh.write(contentsOf: Data("\n{\"type\":\"ai-title\",\"aiTitle\":\"late title\"}\n".utf8))
        try fh.close()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(applied, "no rename after cancelWatch")
    }
}

// MARK: - Stop-hook wiring

/// SessionVM leg: claude only writes ai-title into the transcript within a turn — reading
/// it at the prompt moment on the first turn necessarily comes up empty (the name stays
/// on the launch prefix). Stop = the turn winding down; re-reading here must carry the
/// name back to the tab/header bar (setName → synced to meta.json). T1b infrastructure is
/// shared with ResumeTests (fake agent + isolated archive).
@MainActor
final class AutoNamerStopWiringTests: XCTestCase {

    override func setUp() {
        super.setUp()
        setenv("VIGIL_UITEST", "1", 1)
        setenv("VIGIL_FAKE_AGENT_CMD", WiringTests.stubScript, 1)
    }

    private var apps: [AppModel] = []

    override func tearDown() {
        for app in apps { for s in app.allSessions { s.shutdown() } }
        apps.removeAll()
        try? FileManager.default.removeItem(atPath: VigilArchive.root)
        super.tearDown()
    }

    func testStopHookAppliesAITitleToSessionNameAndMeta() async throws {
        guard UITestSupport.fakeAgentCommand == WiringTests.stubScript else {
            return XCTFail("fake-agent seam inactive — refusing to launch a real agent")
        }
        let app = AppModel()
        apps.append(app)
        let dir = NSTemporaryDirectory() + "vigil-namer-proj-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = ProjectVM(id: UUID().uuidString, name: "Demo project", cwd: dir)
        app.projects.append(p)
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "env probe",
                                                 agent: "claude", access: .standard))
        XCTAssertEqual(vm.name, "env probe")

        let t = NSTemporaryDirectory() + "vigil-namer-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: t) }
        try #"{"type":"ai-title","aiTitle":"check current environment test","sessionId":"s1"}"#
            .write(toFile: t, atomically: true, encoding: .utf8)

        // Simulate the hook gateway's Stop delivery (the gateway leg is separately pinned by GatewayTests).
        vm.orch.onAgentStop?(NodeID("root"), ["transcript_path": t])

        for _ in 0..<200 where vm.name != "check current environment test" {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(vm.name, "check current environment test",
                       "Stop re-reads transcript → ai-title applied to session name (tab/header same source)")
        XCTAssertEqual(SessionArchive.readMeta(dir: vm.archiveDir)?.name, "check current environment test")
    }

    /// the prompt leg = watch polling — even if the title lands **mid-turn**, it
    /// must be applied to the name right away, without waiting for Stop.
    func testPromptHookWatchesAndAppliesTitleMidTurn() async throws {
        guard UITestSupport.fakeAgentCommand == WiringTests.stubScript else {
            return XCTFail("fake-agent seam inactive — refusing to launch a real agent")
        }
        let app = AppModel()
        apps.append(app)
        let dir = NSTemporaryDirectory() + "vigil-namer-proj-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = ProjectVM(id: UUID().uuidString, name: "Demo project", cwd: dir)
        app.projects.append(p)
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "env probe",
                                                 agent: "claude", access: .standard))

        let t = NSTemporaryDirectory() + "vigil-namer-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: t) }
        try #"{"type":"user","message":{"content":"env probe"}}"#
            .write(toFile: t, atomically: true, encoding: .utf8)

        // Simulate UserPromptSubmit (the title doesn't exist yet at this point) → watch starts polling.
        vm.orch.onAgentPrompt?(NodeID("root"), ["transcript_path": t])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(vm.name, "env probe", "name stays put before the title lands")

        // ai-title lands mid-turn (no Stop) → the poll that hits it renames immediately.
        let fh = try XCTUnwrap(FileHandle(forWritingAtPath: t))
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(
            "\n{\"type\":\"ai-title\",\"aiTitle\":\"check current environment test\"}\n".utf8))
        try fh.close()

        for _ in 0..<300 where vm.name != "check current environment test" {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(vm.name, "check current environment test", "hit mid-turn → renamed without waiting for Stop")
    }
}
