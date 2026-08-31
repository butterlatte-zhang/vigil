import Foundation
import XCTest
import VigilCore
@testable import VigilRuntime

/// A no-op harness: a trivial LaunchSpec, no real claude. Lets us drive the
/// store→Effect→cell wiring deterministically (the core-loop path without an LLM).
/// `seenModels` records the per-cell model each launchSpec was asked for.
final class ModelBox: @unchecked Sendable {          // MainActor-driven in tests; no races
    var byNode: [NodeID: String?] = [:]
}
struct FakeHarness: Harness {
    let id = "fake"
    var models: ModelBox? = nil
    var kind: AgentCLIKind = .claude          // drives per-node nodeKinds in tests
    func launchSpec(task: String, cwd: String, nodeID: NodeID,
                    role: Role, isRoot: Bool, model: String?,
                    resumeSessionId: String?,
                    mcpEndpoint: String?, hookEndpoint: String?,
                    idCred: String?) -> LaunchSpec {
        models?.byNode[nodeID] = model
        return LaunchSpec(executable: "/usr/bin/true", args: [], env: [:])
    }
    func launchKind(role: Role, isRoot: Bool, cwd: String) -> AgentCLIKind { kind }
}

@MainActor
final class OrchestratorTests: XCTestCase {

    private func makeOrchestrator(rootCwd: String? = nil,
                                  harnessKind: AgentCLIKind = .claude) -> (Orchestrator, String) {
        let dir = NSTemporaryDirectory() + "vigil_orch_\(getpid())_\(UUID().uuidString)"
        let root = Node(id: NodeID("root"), role: .manager, status: .running, title: "mgr")
        let orch = Orchestrator(rootNode: root, harness: FakeHarness(kind: harnessKind),
                                sessionDir: dir, rootCwd: rootCwd) { _ in FakeBackend() }
        return (orch, dir)
    }

    private func spawnChild(_ orch: Orchestrator) -> NodeID {
        orch.store.send(.requestStruct(.spawn(parent: NodeID("root"), role: .leaf, task: "x"),
                                       from: NodeID("root"), replyID: UUID()))
        return orch.store.tree.nodes.keys.first { $0 != NodeID("root") }!
    }

    // MARK: cwd policy — no forced isolation

    func testEveryNodeRunsInTheProjectDir() async throws {
        // Vigil does not pick an isolation strategy — root AND workers run where
        // the project lives; worktrees/branches are the agent's own shell decision.
        let project = NSTemporaryDirectory() + "vigil_proj_\(getpid())_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: project) }
        let (orch, dir) = makeOrchestrator(rootCwd: project)
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")

        let child = spawnChild(orch)
        XCTAssertEqual((orch.registry.cell(NodeID("root")) as? RealCell)?.cwd, project)
        XCTAssertEqual((orch.registry.cell(child) as? RealCell)?.cwd, project)
        // No hidden side effects in the project dir: no .git, no vigil branches, nothing.
        XCTAssertFalse(FileManager.default.fileExists(atPath: project + "/.git"))

        // kill is plain cell teardown — the project dir is untouched.
        orch.store.send(.requestStruct(.kill(child), from: NodeID("root"), replyID: UUID()))
        XCTAssertNil(orch.registry.cell(child))
        XCTAssertTrue(FileManager.default.fileExists(atPath: project))
    }

    func testNilRootCwdFallsBackToSessionScratchDir() async throws {
        // No project dir (tests / vigil-smoke): per-node scratch dir under the session.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")

        let child = spawnChild(orch)
        let scratch = dir + "/work/" + child.raw
        XCTAssertEqual((orch.registry.cell(child) as? RealCell)?.cwd, scratch)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch))
    }


    func testSpawnModelReachesHarnessLaunchSpec() async throws {
        // spawn(model:) threads Command → Node → launchCell → launchSpec;
        // omitting model stays nil (inherit-session semantics unchanged).
        let dir = NSTemporaryDirectory() + "vigil_orch_\(getpid())_\(UUID().uuidString)"
        let box = ModelBox()
        let root = Node(id: NodeID("root"), role: .manager, status: .running, title: "mgr")
        let orch = Orchestrator(rootNode: root, harness: FakeHarness(models: box),
                                sessionDir: dir) { _ in FakeBackend() }
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")

        orch.store.send(.requestStruct(
            .spawn(parent: NodeID("root"), role: .leaf, task: "probe", model: "haiku"),
            from: NodeID("root"), replyID: UUID()))
        let withModel = orch.store.tree.nodes.keys.first { $0 != NodeID("root") }!
        XCTAssertEqual(box.byNode[withModel], "haiku")

        orch.store.send(.requestStruct(
            .spawn(parent: NodeID("root"), role: .leaf, task: "plain"),
            from: NodeID("root"), replyID: UUID()))
        let plain = orch.store.tree.nodes.keys.first {
            $0 != NodeID("root") && $0 != withModel
        }!
        XCTAssertEqual(box.byNode[plain] ?? nil, nil)
    }

    func testSpawnLaunchesAndRegistersChildImmediately() async throws {
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")

        // root cell launched by bootstrap
        XCTAssertNotNil(orch.registry.cell(NodeID("root")))

        // a manager spawn request arrives (as the MCP server would emit it), applied
        // immediately, no decide step; the tree grows and the cell launches.
        let replyID = UUID()
        orch.store.send(.requestStruct(.spawn(parent: NodeID("root"), role: .leaf, task: "do x"),
                                       from: NodeID("root"), replyID: replyID))

        XCTAssertEqual(orch.store.tree.count, 2)
        let child = orch.store.tree.nodes.keys.first { $0 != NodeID("root") }
        XCTAssertNotNil(child)
        XCTAssertNotNil(orch.registry.cell(child!))               // child cell registered (sync)
        XCTAssertNotNil(orch.registry.backend(child!))

        // cell.start() runs in a scheduled Task; yield until the backend launches.
        let fb = orch.registry.backend(child!) as? FakeBackend
        for _ in 0..<50 where !(fb?.started ?? false) { await Task.yield() }
        XCTAssertEqual(fb?.started, true)                         // backend actually launched
    }

    // MARK: pre-spawn disk-write failure = explicit failure + forensic trail, no silent degrade

    func testLaunchAbortsLoudlyWhenWorkDirCannotBeCreated() throws {
        // Proxy for a full disk / permission error: put a plain file where work/ should be,
        // so the later createDirectory(work/<node>) is guaranteed to fail. A disk-write
        // failure must fail loudly: explicit nodeFailed + a forensic orchestration.jsonl
        // line + store.note — the cell must never launch half-built with no hook/no MCP
        // and zero logging.
        let (orch, dir) = makeOrchestrator()     // rootCwd nil → root uses workRoot/<node>
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/work", contents: Data("block".utf8))

        try orch.start(rootTask: "hello")        // root's launchCell runs here

        XCTAssertNil(orch.registry.cell(NodeID("root")),
                     "a disk-write failure must abort the launch, leaving no half-built cell")
        XCTAssertEqual(orch.store.tree[NodeID("root")]?.status, .failed,
                       "the node is explicitly failed, not pretending to be launching")
        let raw = (try? String(contentsOfFile: dir + "/orchestration.jsonl", encoding: .utf8)) ?? ""
        XCTAssertTrue(raw.contains("cell_launch_aborted"), "the abort event must leave a trace (no more zero logging)")
        XCTAssertTrue(raw.contains("io_error"), "the underlying IO failure must leave a trace too")
        XCTAssertTrue(orch.store.log.contains { $0.contains("spawn aborted") },
                      "store.note must record a visible abort explanation")
    }

    func testKillTearsDownChildCellImmediately() async throws {
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")

        // spawn a child (immediate)
        orch.store.send(.requestStruct(.spawn(parent: NodeID("root"), role: .leaf, task: "x"),
                                       from: NodeID("root"), replyID: UUID()))
        let child = orch.store.tree.nodes.keys.first { $0 != NodeID("root") }!

        // kill it (immediate) → cell removed from registry; the node itself
        // stays in the tree as a dead record (.killed), mirroring self-death.
        orch.store.send(.requestStruct(.kill(child), from: NodeID("root"), replyID: UUID()))

        XCTAssertEqual(orch.store.tree.count, 2)
        XCTAssertEqual(orch.store.tree[child]?.status, .killed)
        XCTAssertNil(orch.registry.cell(child))
    }

    // MARK: dead-node afterlife — transcript pointer + frozen last frame

    func testKillFreezesLastFrameAndKeepsTranscriptPointer() async throws {
        // The dead-node pane's two data sources: the node → transcript join key must
        // survive the kill, and the last rendered frame is captured at teardown
        // (before the backend leaves the registry) as the dangling-pointer fallback.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        orch.recordAgentPrompt(child, payload: ["transcript_path": "/tmp/t/child.jsonl"])
        (orch.registry.backend(child) as? FakeBackend)?.screen = "final frame ✓"

        orch.store.send(.requestStruct(.kill(child), from: NodeID("root"), replyID: UUID()))

        XCTAssertEqual(orch.transcripts[child], "/tmp/t/child.jsonl")
        XCTAssertEqual(orch.frozenScreens[child], "final frame ✓")
        XCTAssertNil(orch.registry.backend(child))          // the live backend is gone
    }

    /// Natural death (user exits claude) must not terminate the cell or pull it
    /// out of the registry — the backend is frozen on its final screen, and the
    /// dead-node pane's lastFrame must stay reachable. Only kill is a teardown.
    func testNaturalExitFreezesLastFrameAndSparesTheCell() async throws {
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        for _ in 0..<50 where !fb.started { await Task.yield() }
        fb.screen = "❯ exit — final frame"

        fb.simulateExit(0)                                  // the child process ends itself
        for _ in 0..<200 where orch.store.tree[child]?.status.isTerminal != true {
            await Task.yield()
        }

        XCTAssertEqual(orch.store.tree[child]?.status, .done)
        XCTAssertEqual(orch.frozenScreens[child], "❯ exit — final frame")  // lastFrame reachable
        XCTAssertFalse(fb.terminated)                       // no coup de grâce on the dead cell
        XCTAssertNotNil(orch.registry.backend(child))       // backend stays: frozen final screen
    }

    // MARK: queued injects must surface — route → hold → queued card + .queued → settle, full chain wiring

    func testQueuedInjectRaisesAndSettlesNoticeCard() async throws {
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.injectTuning = (poll: 0.02, maxWait: 5, noticeDelay: 0.05)
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        for _ in 0..<50 where !fb.started { await Task.yield() }
        fb.screen = """
        ╭──────────────────────────╮
        │ > human mid-typing       │
        ╰──────────────────────────╯
        """

        orch.store.send(.message(from: NodeID("root"), to: child, text: "hello", replyID: nil))

        // grace elapses while the line stays busy → the queued card appears + .queued
        try await waitUntil("queued card appears") {
            orch.store.notices.contains { $0.kind == .injectQueued && $0.nodeID == child }
        }
        XCTAssertEqual(orch.store.tree[child]?.status, .queued)   // independent state, not .waiting

        // the human clears the line → delivery → the card dies by itself
        fb.screen = """
        ╭──────────────────────────╮
        │ >                        │
        ╰──────────────────────────╯
        """
        try await waitUntil("card settles") { orch.store.notices.isEmpty }
        try await waitUntil("message delivered") { fb.sent.contains("hello") }
    }

    // MARK: opencode send-delivery honest degrade

    /// launchKind flows through to nodeKinds so kind-specific observability can branch.
    func testLaunchKindCapturedPerNode() async throws {
        let (orch, dir) = makeOrchestrator(harnessKind: .opencode)
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        XCTAssertEqual(orch.nodeKinds[NodeID("root")], .opencode)
        XCTAssertEqual(orch.nodeKinds[child], .opencode)
    }

    /// opencode has no external JSONL to tail-read, so a tracked send to an opencode
    /// node must not enter the transcript-confirmation loop (which would never confirm →
    /// reinject → false-fail). It degrades honestly: one `delivery_unconfirmed` forensic
    /// line, nothing left pending, and never a false `delivery_confirmed`/`delivery_failed`.
    func testOpenCodeSendDegradesToUnconfirmedNotFalseFail() async throws {
        let (orch, dir) = makeOrchestrator(harnessKind: .opencode)
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.deliveryTuning = (maxAttempts: 3, grace: 0.05)   // would false-fail fast if tracked
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        for _ in 0..<50 where !fb.started { await Task.yield() }
        fb.screen = "> \n"                                     // clear input line → inject delivers

        orch.store.send(.message(from: NodeID("root"), to: child,
                                 text: "MESSAGE FROM root: go", replyID: UUID()))

        try await waitUntil("delivery_unconfirmed logged") {
            (try? String(contentsOfFile: dir + "/orchestration.jsonl", encoding: .utf8))?
                .contains("delivery_unconfirmed") ?? false
        }
        XCTAssertEqual(orch.deliveryTracker?.pendingCount, 0, "an opencode target does not enter the confirmation loop")

        // Let the tracker tick a few times — an opencode send must never surface a false
        // confirmed/failed verdict.
        try await Task.sleep(nanoseconds: 300_000_000)
        let raw = try String(contentsOfFile: dir + "/orchestration.jsonl", encoding: .utf8)
        XCTAssertFalse(raw.contains("delivery_confirmed"), "must not falsely report delivery")
        XCTAssertFalse(raw.contains("delivery_failed"), "must not falsely report failure")
    }

    // MARK: codex sid/transcript capture

    /// Write a fake rollout jsonl into a node's per-node CODEX_HOME (the exact path the
    /// harness would use), so captureCodexSession has something real to scan.
    private func seedCodexRollout(_ dir: String, node: String, sid: String) -> String {
        let home = dir + "/config/\(node)/codex-home/sessions/2026/07/10"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let path = home + "/rollout-2026-07-10T16-28-05-\(sid).jsonl"
        try? #"{"type":"session_meta","payload":{"session_id":"\#(sid)","cwd":"/proj"}}\#n"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// codex cannot emit a prompt/stop hook — capture instead scans the CODEX_HOME
    /// rollout. Once the sid + pointer are recovered, they're fed into the same agent_prompt
    /// event claude uses (replay/resumeKey pick it up with zero changes), and it's idempotent
    /// (sid/pointer unchanged → no duplicate event).
    func testCodexCaptureEmitsAgentPromptAndSetsSessionId() async throws {
        let (orch, dir) = makeOrchestrator(harnessKind: .codex)
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        XCTAssertEqual(orch.nodeKinds[NodeID("root")], .codex)

        let sid = "019f4b24-1b04-7ce0-9059-7da727c56bf3"
        let path = seedCodexRollout(dir, node: "root", sid: sid)

        orch.captureCodexSession(NodeID("root"))
        XCTAssertEqual(orch.sessionIds[NodeID("root")], sid, "resume credential captured")
        XCTAssertEqual(orch.transcripts[NodeID("root")], path, "transcript pointer captured")

        // End-to-end: once agent_prompt is persisted, SessionArchive.replay can rebuild
        // sid/pointer/resumeKey (codex filenames aren't a bare uuid, so this depends on the
        // explicitly captured session_id — otherwise resumeKey would derive as nil).
        let archived = try XCTUnwrap(SessionArchive.load(dir: dir))
        XCTAssertEqual(archived.sessionIds[NodeID("root")], sid)
        XCTAssertEqual(archived.transcripts[NodeID("root")], path)
        XCTAssertEqual(archived.resumeKey(for: NodeID("root")), sid, "resume credential end-to-end")

        // Idempotent: sid/pointer unchanged → the second call doesn't emit another agent_prompt.
        let raw1 = try String(contentsOfFile: dir + "/orchestration.jsonl", encoding: .utf8)
        let before = raw1.components(separatedBy: "agent_prompt").count
        orch.captureCodexSession(NodeID("root"))
        let raw2 = try String(contentsOfFile: dir + "/orchestration.jsonl", encoding: .utf8)
        XCTAssertEqual(raw2.components(separatedBy: "agent_prompt").count, before, "idempotent — no duplicate")
    }

    /// Non-codex nodes are never captured (family gate) — a claude node that can't find a codex rollout still never emits a spurious event.
    func testCaptureCodexSkipsNonCodexNode() async throws {
        let (orch, dir) = makeOrchestrator(harnessKind: .claude)
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        _ = seedCodexRollout(dir, node: "root", sid: "019f4b24-1b04-7ce0-9059-7da727c56bf3")
        orch.captureCodexSession(NodeID("root"))
        XCTAssertNil(orch.sessionIds[NodeID("root")], "the claude family does not go through codex capture")
    }

    /// codex rollout is shaped as event_msg, so the claude-shaped TranscriptScan never
    /// matches — a tracked send to a codex node must degrade to delivery_unconfirmed (same as
    /// opencode), and must never falsely report confirmed/failed.
    func testCodexSendDegradesToUnconfirmedNotFalseFail() async throws {
        let (orch, dir) = makeOrchestrator(harnessKind: .codex)
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.deliveryTuning = (maxAttempts: 3, grace: 0.05)
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        for _ in 0..<50 where !fb.started { await Task.yield() }
        fb.screen = "> \n"

        orch.store.send(.message(from: NodeID("root"), to: child,
                                 text: "MESSAGE FROM root: go", replyID: UUID()))
        try await waitUntil("delivery_unconfirmed logged") {
            (try? String(contentsOfFile: dir + "/orchestration.jsonl", encoding: .utf8))?
                .contains("delivery_unconfirmed") ?? false
        }
        XCTAssertEqual(orch.deliveryTracker?.pendingCount, 0, "a codex target does not enter the confirmation loop")
        try await Task.sleep(nanoseconds: 300_000_000)
        let raw = try String(contentsOfFile: dir + "/orchestration.jsonl", encoding: .utf8)
        XCTAssertFalse(raw.contains("delivery_confirmed"), "must not falsely report delivery")
        XCTAssertFalse(raw.contains("delivery_failed"), "must not falsely report failure")
    }

    // MARK: opencode transcript capture + per-node kind in archive

    /// opencode transcript lands in SQLite, with no external JSONL — capture relies on the
    /// app layer calling `opencode export` for a snapshot. recordOpenCodeCapture (the sync,
    /// testable core) writes `opencode-<node>.json` + feeds agent_prompt (sid is already
    /// captured by the plugin hook); replay rebuilds the pointer + sid, and it's idempotent
    /// (pointer unchanged → no duplicate event). Honest degrade: an empty raw is never persisted.
    func testOpenCodeCaptureMaterializesPointerAndReplays() async throws {
        let (orch, dir) = makeOrchestrator(harnessKind: .opencode)
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        XCTAssertEqual(orch.nodeKinds[NodeID("root")], .opencode)
        let root = NodeID("root")
        let sid = "ses_0b46fc18cffeSopROVmNUAK1RB"
        // sid arrives via the plugin prompt hook (session_id, no transcript_path).
        orch.recordAgentPrompt(root, payload: ["session_id": sid])

        let json = #"{"info":{"id":"\#(sid)","title":"T"},"messages":[{"info":{"role":"user"},"parts":[{"type":"text","text":"hi"}]}]}"#
        orch.recordOpenCodeCapture(root, sid: sid, raw: json)

        let path = (dir as NSString).appendingPathComponent("opencode-root.json")
        XCTAssertEqual(orch.transcripts[root], path, "the pointer points at the snapshot file")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), json, "the snapshot on disk = the raw export")

        // End-to-end: once agent_prompt is persisted, replay rebuilds the pointer + sid + resumeKey.
        let archived = try XCTUnwrap(SessionArchive.load(dir: dir))
        XCTAssertEqual(archived.transcripts[root], path)
        XCTAssertEqual(archived.sessionIds[root], sid)
        XCTAssertEqual(archived.resumeKey(for: root), sid)

        // Idempotent: pointer unchanged → the second call doesn't emit another agent_prompt.
        let before = try String(contentsOfFile: dir + "/orchestration.jsonl", encoding: .utf8)
            .components(separatedBy: "\"transcript\"").count
        orch.recordOpenCodeCapture(root, sid: sid, raw: json)
        let after = try String(contentsOfFile: dir + "/orchestration.jsonl", encoding: .utf8)
            .components(separatedBy: "\"transcript\"").count
        XCTAssertEqual(after, before, "idempotent: pointer unchanged → no duplicate transcript event")
    }

    /// Honest degrade: an empty/nil export → no file written, no event emitted (never a hollow shell); family-gated so non-opencode nodes never trigger it.
    func testOpenCodeCaptureHonestDegradation() async throws {
        let (orch, dir) = makeOrchestrator(harnessKind: .opencode)
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let root = NodeID("root")
        orch.recordOpenCodeCapture(root, sid: "s", raw: nil)
        XCTAssertNil(orch.transcripts[root], "a nil export writes no pointer")
        orch.recordOpenCodeCapture(root, sid: "s", raw: "")
        XCTAssertNil(orch.transcripts[root], "an empty export writes no pointer")
        // Family gate: captureOpenCodeSession is a no-op for non-opencode nodes (doesn't crash even with no exporter).
        let (claudeOrch, cdir) = makeOrchestrator(harnessKind: .claude)
        defer { claudeOrch.stop(); try? FileManager.default.removeItem(atPath: cdir) }
        try claudeOrch.start(rootTask: "")
        claudeOrch.recordAgentPrompt(NodeID("root"), payload: ["session_id": "s"])
        claudeOrch.captureOpenCodeSession(NodeID("root"))   // no-op, no crash
        XCTAssertNil(claudeOrch.transcripts[NodeID("root")])
    }

    /// cell_launch records each node's own kind → SessionArchive.replay rebuilds
    /// nodeKinds node-by-node (the history view uses this to give each dead node its own
    /// resume syntax, so heterogeneous workers never inherit the root's family).
    func testCellLaunchRecordsPerNodeKindInArchive() async throws {
        let (orch, dir) = makeOrchestrator(harnessKind: .opencode)
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let archived = try XCTUnwrap(SessionArchive.load(dir: dir))
        XCTAssertEqual(archived.nodeKinds[NodeID("root")], .opencode,
                       "cell_launch recorded root's kind, replay rebuilds it")
    }

    /// Poll a MainActor condition with a hard timeout — the async analogue of the
    /// yield-loops above (the hold loop sleeps on a real clock, yielding isn't enough).
    private func waitUntil(_ what: String, timeout: TimeInterval = 3,
                           _ cond: () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { return XCTFail("timeout: \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: dogfood telemetry — unconditional jsonl in the session dir

    func testPermLifecycleAppendsDogfoodJsonl() async throws {
        // Request/resolve land as jsonl lines via the .permLog Effect (Command in → Effect out;
        // the world-side timestamp is stamped here at write time, honest clock).
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let child = spawnChild(orch)

        let input = #"{"command":"git push"}"#
        orch.store.send(.permRequested(from: child, info: PermNoticeInfo(
            promptID: "p9", toolName: "Bash", toolInput: input,
            inputSummary: "git push", text: "perm")))
        orch.store.send(.resolveNotice(from: child, match: PermResolveMatch(
            promptID: "p9", toolName: "Bash", toolInput: input, toolUseID: "toolu_9"),
            via: .postTool))

        let path = dir + "/perm_dogfood.jsonl"
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let lines = raw.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        let req = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(req["event"] as? String, "perm_request")
        XCTAssertEqual(req["node"] as? String, child.raw)
        XCTAssertEqual(req["prompt_id"] as? String, "p9")
        XCTAssertEqual(req["tool"] as? String, "Bash")
        XCTAssertNotNil(req["ts"] as? String)
        let res = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(res["event"] as? String, "perm_resolve")
        XCTAssertEqual(res["via"] as? String, "post-tool")
        XCTAssertEqual(res["tool_use_id"] as? String, "toolu_9")   // correlation tag
    }

    func testPermWatcherIsMountedAfterStart() async throws {
        // The scrape fallback lives on the Orchestrator (world reads → Command ingress).
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        XCTAssertNotNil(orch.permWatcher)
    }

    // MARK: orchestration event log — per-session jsonl, world-side timestamps

    func testOrchestrationEventsAppendJsonl() async throws {
        // Every Effect-egress orchestration event lands as one jsonl line: a forensic
        // trail sufficient to reconstruct what happened without hunting through transcripts.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "root task")
        let child = spawnChild(orch)
        orch.store.send(.message(from: NodeID("root"), to: child, text: "MESSAGE FROM root: go",
                                 replyID: nil))
        orch.store.send(.rollup(from: child, summary: "done"))     // routes CHILD_ROLLUP → root
        orch.store.send(.requestStruct(.kill(child), from: NodeID("root"), replyID: UUID()))

        let raw = try String(contentsOfFile: dir + "/orchestration.jsonl", encoding: .utf8)
        let events = try raw.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let kinds = events.compactMap { $0["event"] as? String }
        XCTAssertEqual(kinds.filter { $0 == "cell_launch" }.count, 2)   // root + child
        XCTAssertEqual(kinds.filter { $0 == "kill" }.count, 1)
        XCTAssertTrue(events.allSatisfy { $0["ts"] is String })

        let launches = events.filter { $0["event"] as? String == "cell_launch" }
        XCTAssertEqual(launches.first?["node"] as? String, "root")
        XCTAssertEqual(launches.first?["root"] as? Bool, true)
        XCTAssertEqual(launches.first?["task"] as? String, "root task")
        XCTAssertEqual(launches.last?["node"] as? String, child.raw)
        XCTAssertEqual(launches.last?["root"] as? Bool, false)
        // parent is the tree edge — without it the history replay cannot rebuild
        // the skeleton. Root has none; every child records its spawner.
        XCTAssertNil(launches.first?["parent"])
        XCTAssertEqual(launches.last?["parent"] as? String, "root")
        XCTAssertEqual(launches.last?["role"] as? String, "leaf")

        let routes = events.filter { $0["event"] as? String == "route" }
        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(routes.first?["kind"] as? String, "message")
        XCTAssertEqual(routes.first?["to"] as? String, child.raw)
        XCTAssertEqual(routes.last?["kind"] as? String, "rollup")
        XCTAssertEqual(routes.last?["to"] as? String, "root")
        // text is a bounded prefix — forensics, not a transcript mirror.
        XCTAssertEqual(routes.first?["text"] as? String, "MESSAGE FROM root: go")
        // provenance: viaPath[0] is the sender (§6.3) — a message from root carries "from":
        // root, a rollup from the child carries "from": the child.
        XCTAssertEqual(routes.first?["from"] as? String, "root")
        XCTAssertEqual(routes.last?["from"] as? String, child.raw)
    }

    func testRollupRouteEventKeepsTextBeyond80Chars() async throws {
        // A rollup IS the report itself — worth more than the 80-char forensic snippet every
        // other route kind gets (message/system/perm_review), so a dogfood run can be read
        // straight off orchestration.jsonl.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let longSummary = String(repeating: "x", count: 300)

        orch.store.send(.rollup(from: child, summary: longSummary))

        let route = try XCTUnwrap(orchEvents(dir).first { $0["event"] as? String == "route" && $0["kind"] as? String == "rollup" })
        XCTAssertEqual(route["from"] as? String, child.raw)
        XCTAssertEqual(route["to"] as? String, "root")
        let text = try XCTUnwrap(route["text"] as? String)
        XCTAssertEqual(text, String(("CHILD_ROLLUP:" + longSummary).prefix(400)))
        XCTAssertGreaterThan(text.count, 80)
    }

    // MARK: API-error turn-death visibility (Fix B) + honest send-delivery wiring (Fix A)

    private func writeTranscript(_ path: String, _ lines: [String]) {
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testApiErrorTurnDeathMarksErroredAndNotifiesParent() async throws {
        // Fix B: a turn killed by an API error, with no Stop hook → the node goes .errored + the parent is auto-notified.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let rootBackend = try XCTUnwrap(orch.registry.backend(NodeID("root")) as? FakeBackend)

        let tpath = dir + "/child.jsonl"
        writeTranscript(tpath, [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}"#,
            #"{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"API Error: Connection closed mid-response"}]}}"#,
        ])
        orch.recordAgentPrompt(child, payload: ["transcript_path": tpath, "session_id": "sid"])

        orch.receive(.turnEnded(child, gen: nil))    // turn wraps up → triggers API-error detection

        XCTAssertEqual(orch.store.tree[child]?.status, .errored, "an API-killed turn = its own .errored state")
        let events = orchEvents(dir)
        let errored = try XCTUnwrap(events.first { $0["event"] as? String == "turn_errored" && $0["node"] as? String == child.raw })
        XCTAssertEqual(errored["reason"] as? String, "API Error: Connection closed mid-response",
                       "turn_errored carries the matched error text — jsonl-only diagnosis, no transcript hunt")
        try await waitUntil("the parent received a system notification") {
            rootBackend.sent.contains { $0.contains("API error") && $0.contains(child.raw) }
        }
        // Idempotent: calling turnEnded again (no new error line) does not report a second time.
        orch.receive(.turnEnded(child, gen: nil))
        XCTAssertEqual(orchEvents(dir).filter { $0["event"] as? String == "turn_errored" }.count, 1)
    }

    // MARK: the API-error turn-death notice must not lie about the report

    func testApiErrorAfterReportSaysReportReceivedNotReRun() async throws {
        // If the worker already reported up this turn and the turn's wrap-up then hits an
        // API error, the notice must say the report was received — never the generic
        // "no report, may need re-run" wording, which would risk re-running finished work.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let rootBackend = try XCTUnwrap(orch.registry.backend(NodeID("root")) as? FakeBackend)

        let tpath = dir + "/child.jsonl"
        orch.recordAgentPrompt(child, payload: ["transcript_path": tpath])
        // Turn opens → the worker reports up → the wrap-up hits an API error (this exact order).
        orch.receive(.turnStarted(child))
        orch.receive(.rollup(from: child, summary: "done"))
        writeTranscript(tpath, [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"summary"}]}}"#,
            #"{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"API Error: Connection closed mid-response"}]}}"#,
        ])
        orch.receive(.turnEnded(child, gen: nil))

        XCTAssertEqual(orch.store.tree[child]?.status, .errored)
        try await waitUntil("the parent received report-received wording") {
            rootBackend.sent.contains { $0.contains("report was received") && $0.contains(child.raw) }
        }
        XCTAssertFalse(rootBackend.sent.contains { $0.contains("sent no report") },
                       "the report was delivered — must not falsely claim no report was received")
    }

    func testApiErrorWithNoReportKeepsReRunAdvice() async throws {
        // The genuine no-report case: turn died on an API error before any report →
        // the manager is honestly told it may need to re-run the worker.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let rootBackend = try XCTUnwrap(orch.registry.backend(NodeID("root")) as? FakeBackend)

        let tpath = dir + "/child.jsonl"
        orch.recordAgentPrompt(child, payload: ["transcript_path": tpath])
        orch.receive(.turnStarted(child))
        writeTranscript(tpath, [
            #"{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"API Error: Connection closed mid-response"}]}}"#,
        ])
        orch.receive(.turnEnded(child, gen: nil))

        try await waitUntil("the parent received no-report / re-run wording") {
            rootBackend.sent.contains { $0.contains("sent no report") && $0.contains(child.raw) }
        }
        XCTAssertFalse(rootBackend.sent.contains { $0.contains("report was received") },
                       "with no report, must not falsely claim one was received")
    }

    // MARK: a send whose target is killed must not advise a resend

    func testKilledTargetReceiptIsSilentWhenCallerIsTheKiller() async throws {
        // The manager killed n1, so a still-in-flight send to n1 must NOT come back as
        // "may need to resend" (resend to a node the manager itself just killed is nonsense) —
        // when the caller is the killer, the receipt is pure noise → stay silent.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.deliveryTuning = (maxAttempts: 3, grace: 0)
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let rootBackend = try XCTUnwrap(orch.registry.backend(NodeID("root")) as? FakeBackend)
        let tpath = dir + "/child.jsonl"
        writeTranscript(tpath, [])
        orch.recordAgentPrompt(child, payload: ["transcript_path": tpath])

        orch.store.send(.message(from: NodeID("root"), to: child,
                                 text: "MESSAGE FROM root: go", replyID: UUID()))
        try await waitUntil("delivery registered") { orch.deliveryTracker?.pendingCount == 1 }

        // root kills its own child while the send is unconfirmed.
        orch.receive(.requestStruct(.kill(child), from: NodeID("root"), replyID: UUID()))
        XCTAssertEqual(orch.store.tree[child]?.status, .killed)

        orch.deliveryTracker?.tick()
        XCTAssertEqual(orch.deliveryTracker?.pendingCount, 0)
        // Forensic line still lands; the caller-facing receipt does not.
        XCTAssertTrue(orchEvents(dir).contains { $0["event"] as? String == "delivery_failed" })
        XCTAssertFalse(rootBackend.sent.contains { $0.contains("resend") || $0.contains("voided") },
                       "a target the caller itself killed must not get a resend receipt")
    }

    func testDeadTargetReceiptSaysVoidedNotResend() async throws {
        // A send whose target died on its own (self-death, not by the caller) gets an honest
        // terminal receipt: the message is voided, do not resend — never the "may need to resend"
        // advice that only makes sense for a still-alive, genuine-loss path.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.deliveryTuning = (maxAttempts: 3, grace: 0)
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let rootBackend = try XCTUnwrap(orch.registry.backend(NodeID("root")) as? FakeBackend)
        let tpath = dir + "/child.jsonl"
        writeTranscript(tpath, [])
        orch.recordAgentPrompt(child, payload: ["transcript_path": tpath])

        orch.store.send(.message(from: NodeID("root"), to: child,
                                 text: "MESSAGE FROM root: go", replyID: UUID()))
        try await waitUntil("delivery registered") { orch.deliveryTracker?.pendingCount == 1 }

        orch.receive(.nodeExited(child, code: 1))   // the worker's process died on its own
        XCTAssertTrue(orch.store.tree[child]?.status.isTerminal == true)

        orch.deliveryTracker?.tick()
        XCTAssertEqual(orch.deliveryTracker?.pendingCount, 0)
        try await waitUntil("the caller received a voided terminal receipt") {
            rootBackend.sent.contains { $0.contains("voided") && $0.contains("do not resend")
                                        && $0.contains(child.raw) }
        }
        XCTAssertFalse(rootBackend.sent.contains { $0.contains("unconfirmed after") },
                       "a dead target gets a terminal receipt, never the in-flight unconfirmed wording")
    }

    func testTrackedSendRegistersAndConfirmsViaTranscript() async throws {
        // Fix A happy path: send registers as pending; a real user message appearing in the target's transcript = delivery confirmed.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let tpath = dir + "/child.jsonl"                             // not yet written to disk → baseline 0
        orch.recordAgentPrompt(child, payload: ["transcript_path": tpath])

        let rid = UUID()
        orch.store.send(.message(from: NodeID("root"), to: child,
                                 text: "MESSAGE FROM root: use postgres", replyID: rid))
        try await waitUntil("delivery registered") { orch.deliveryTracker?.pendingCount == 1 }

        // The target actually absorbs the message into its context (a real user line appears in the transcript append).
        writeTranscript(tpath, [
            #"{"type":"user","message":{"role":"user","content":"MESSAGE FROM root: use postgres"}}"#,
        ])
        orch.deliveryTracker?.tick()
        XCTAssertEqual(orch.deliveryTracker?.pendingCount, 0, "removed after confirmation")
        XCTAssertTrue(orchEvents(dir).contains { $0["event"] as? String == "delivery_confirmed" })
    }

    func testTrackedSendFinalFailureRoutesReceiptToCaller() async throws {
        // Fix A failure path: the turn dies, the message never shows up in the transcript → retries are exhausted → a SYSTEM receipt routes back to the caller.
        let dir = NSTemporaryDirectory() + "vigil_orch_\(getpid())_\(UUID().uuidString)"
        let root = Node(id: NodeID("root"), role: .manager, status: .running, title: "mgr")
        let orch = Orchestrator(rootNode: root, harness: FakeHarness(), sessionDir: dir) { _ in FakeBackend() }
        orch.deliveryTuning = (maxAttempts: 1, grace: 0)             // retry cap = 1, no grace
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let rootBackend = try XCTUnwrap(orch.registry.backend(NodeID("root")) as? FakeBackend)
        let tpath = dir + "/child.jsonl"
        writeTranscript(tpath, [])
        orch.recordAgentPrompt(child, payload: ["transcript_path": tpath])

        orch.store.send(.message(from: NodeID("root"), to: child,
                                 text: "MESSAGE FROM root: go", replyID: UUID()))
        try await waitUntil("delivery registered") { orch.deliveryTracker?.pendingCount == 1 }
        orch.receive(.turnEnded(child, gen: nil))                   // the turn dies (no API-error line) → idle

        orch.deliveryTracker?.tick()                                // attempt 1: reinject
        orch.deliveryTracker?.tick()                                // cap exhausted → fail
        XCTAssertEqual(orch.deliveryTracker?.pendingCount, 0)
        let events = orchEvents(dir)
        XCTAssertTrue(events.contains { $0["event"] as? String == "delivery_retry" })
        XCTAssertTrue(events.contains { $0["event"] as? String == "delivery_failed" })
        try await waitUntil("the caller received a failure receipt") {
            rootBackend.sent.contains { $0.contains("unconfirmed") && $0.contains(child.raw) }
        }
    }

    /// A scripted CellHandle for the ack plumbing: inject returns a fixed ack
    /// instead of driving a PTY.
    private final class ScriptedAckCell: CellHandle, @unchecked Sendable {
        let nodeID: NodeID
        let ack: InjectAck
        init(_ id: NodeID, ack: InjectAck) { self.nodeID = id; self.ack = ack }
        func start() async {}
        func inject(_ text: String) async throws -> InjectAck { ack }
        func snapshot() async -> String { "" }
        func terminate() async {}
    }

    func testInjectAckLandsInJsonlAndUndeliveredIsNotSent() async throws {
        // inject can resolve without throwing while still undelivered (cell
        // died while queued behind the user's typing) — the route must log it and must
        // not pretend "sent"; a delivered-with-note ack (queued
        // wait, fail-open) must leave its evidence in the forensic trail.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let child = spawnChild(orch)

        let dead = ScriptedAckCell(child, ack: InjectAck(delivered: false,
                                                         note: "cell exited while queued"))
        orch.registry.add(dead, backend: FakeBackend())
        orch.store.send(.message(from: NodeID("root"), to: child, text: "gone?", replyID: nil))

        let queued = ScriptedAckCell(child, ack: InjectAck(delivered: true,
                                                           note: "queued 1.2s before delivery"))
        orch.registry.add(queued, backend: FakeBackend())
        orch.store.send(.message(from: NodeID("root"), to: child, text: "late", replyID: nil))

        // The ack lands from an async Task — poll the trail until both lines appear.
        var events: [[String: Any]] = []
        for _ in 0..<200 {
            let raw = (try? String(contentsOfFile: dir + "/orchestration.jsonl",
                                   encoding: .utf8)) ?? ""
            events = raw.split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
            let kinds = events.compactMap { $0["event"] as? String }
            if kinds.contains("route_failed"),
               kinds.filter({ $0 == "inject_note" }).count == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let failed = events.filter { $0["event"] as? String == "route_failed" }
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?["reason"] as? String, "cell exited while queued")

        let notes = events.filter { $0["event"] as? String == "inject_note" }
        XCTAssertEqual(notes.count, 2)
        // The two ack Tasks race to the jsonl — match lines by content, not arrival
        // order, since which write lands first is not guaranteed.
        let undelivered = notes.first { ($0["delivered"] as? Bool) == false }
        let delivered = notes.first { ($0["delivered"] as? Bool) == true }
        XCTAssertEqual(undelivered?["note"] as? String, "cell exited while queued")
        XCTAssertEqual(delivered?["note"] as? String, "queued 1.2s before delivery")
    }

    /// A throwing inject — the third route-failure block.
    private final class ThrowingCell: CellHandle, @unchecked Sendable {
        struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
        let nodeID: NodeID
        init(_ id: NodeID) { self.nodeID = id }
        func start() async {}
        func inject(_ text: String) async throws -> InjectAck { throw Boom() }
        func snapshot() async -> String { "" }
        func terminate() async {}
    }

    func testRouteFailureTrioPinsReasonAndNoteText() async throws {
        // Pin all three route-failure shapes — jsonl reason + store.log line for
        // undelivered ack, throwing inject, and no-live-cell.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let child = spawnChild(orch)

        // ① non-throwing undelivered ack
        let dead = ScriptedAckCell(child, ack: InjectAck(delivered: false, note: "typing hold"))
        orch.registry.add(dead, backend: FakeBackend())
        orch.store.send(.message(from: NodeID("root"), to: child, text: "a", replyID: nil))
        // ② throwing inject
        orch.registry.add(ThrowingCell(child), backend: FakeBackend())
        orch.store.send(.message(from: NodeID("root"), to: child, text: "b", replyID: nil))
        // ③ node alive in the tree, no live cell
        orch.registry.remove(child)
        orch.store.send(.message(from: NodeID("root"), to: child, text: "c", replyID: nil))

        var failed: [[String: Any]] = []
        for _ in 0..<200 {
            let raw = (try? String(contentsOfFile: dir + "/orchestration.jsonl",
                                   encoding: .utf8)) ?? ""
            failed = raw.split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }.filter { $0["event"] as? String == "route_failed" }
            if failed.count == 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let reasons = Set(failed.compactMap { $0["reason"] as? String })
        XCTAssertEqual(reasons, ["typing hold", "inject failed: boom", "no live cell"])
        XCTAssertTrue(failed.allSatisfy { $0["to"] as? String == child.raw })

        XCTAssertTrue(orch.store.log.contains("route inject UNDELIVERED: \(child) typing hold"))
        XCTAssertTrue(orch.store.log.contains("route inject FAILED: \(child) boom"))
        XCTAssertTrue(orch.store.log.contains("route dropped: no cell \(child)"))
    }

    func testFailRouteAckBytesReachTheSenderPerBranch() async throws {
        // Pin the ack bytes end-to-end over the real MCP socket (what the sending manager
        // actually reads back): block-1 non-throwing undelivered = "node <id> not
        // reachable: " + the cell's note; block-2 throwing inject = "… not reachable:
        // inject failed" (fixed short wire detail — the error dump stays in jsonl).
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let child = spawnChild(orch)

        guard let fd = connectUDS(orch.mcpSock) else {
            return XCTFail("cannot connect \(orch.mcpSock)")
        }
        let ch = SocketLineChannel(fd: fd)
        await ch.write(JSONLine.dump(["node": "root"]))
        func sendAndReadAck(_ id: Int) async -> (text: String?, isError: Bool?) {
            await ch.write(JSONLine.dump([
                "jsonrpc": "2.0", "id": id, "method": "tools/call",
                "params": ["name": "send",
                           "arguments": ["node": child.raw, "message": "m\(id)"]],
            ]))
            let result = JSONLine.parse(await ch.readLine() ?? "")?["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            return (content?.first?["text"] as? String, result?["isError"] as? Bool)
        }

        // ① block-1: the cell resolves undelivered without throwing (queued death)
        orch.registry.add(ScriptedAckCell(child, ack: InjectAck(delivered: false,
                                                                note: "typing hold")),
                          backend: FakeBackend())
        let ack1 = await sendAndReadAck(1)
        XCTAssertEqual(ack1.text, "node \(child.raw) not reachable: typing hold")
        XCTAssertEqual(ack1.isError, true)

        // ② block-2: inject THROWS → the short detail, never the interpolated dump
        orch.registry.add(ThrowingCell(child), backend: FakeBackend())
        let ack2 = await sendAndReadAck(2)
        XCTAssertEqual(ack2.text, "node \(child.raw) not reachable: inject failed")
        XCTAssertEqual(ack2.isError, true)

        await ch.close()
    }

    /// Raw UDS client for the wire-level test above (mirrors VigilShimCore.connectUDS;
    /// kept local so the test target stays free of the shim dependency).
    private func connectUDS(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd); return nil
        }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard ok == 0 else { close(fd); return nil }
        return fd
    }

    func testAgentPromptRecordsTranscriptMapping() async throws {
        // node → claude transcript mapping: the join key needed to correlate a node
        // with its transcript. Recorded from the UserPromptSubmit payload, world side.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        orch.recordAgentPrompt(NodeID("root"),
                               payload: ["transcript_path": "/tmp/t/abc.jsonl", "prompt": "hi"])

        let raw = try String(contentsOfFile: dir + "/orchestration.jsonl", encoding: .utf8)
        let events = try raw.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let prompt = try XCTUnwrap(events.first { $0["event"] as? String == "agent_prompt" })
        XCTAssertEqual(prompt["node"] as? String, "root")
        XCTAssertEqual(prompt["transcript"] as? String, "/tmp/t/abc.jsonl")
    }

    // MARK: on-demand dead-node resurrection + archive pointer adoption

    func testResumeNodeRelaunchesCellWithForensicTrail() async throws {
        // A naturally-dead worker (the cell is frozen but stays in the registry) →
        // resumeNode: the old cell steps aside, a new cell is launched with resume semantics,
        // and a second cell_launch event carries the resume field (forensic trail).
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        for _ in 0..<50 where !fb.started { await Task.yield() }
        fb.simulateExit(0)
        for _ in 0..<200 where orch.store.tree[child]?.status.isTerminal != true {
            await Task.yield()
        }

        orch.store.send(.resumeNode(child, sessionID: "sid-w9"))

        // Once resurrection settles, the state = idle (a TUI waiting for input, with no
        // turn running — if it stayed .running nothing would ever flip it, and the sidebar
        // would spin forever). Along the way nodeOnline still passes through .running once;
        // the final state is decided by turnEnded.
        XCTAssertEqual(orch.store.tree[child]?.status, .idle)
        let nb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        XCTAssertFalse(nb === fb, "revival = a new cell takes over the node slot, the old frozen cell yields")

        let raw = try String(contentsOfFile: dir + "/orchestration.jsonl", encoding: .utf8)
        let launches = try raw.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }.filter { $0["event"] as? String == "cell_launch" && $0["node"] as? String == child.raw }
        XCTAssertEqual(launches.count, 2)
        XCTAssertEqual(launches.last?["resume"] as? String, "sid-w9")
    }

    func testAdoptArchiveBackfillsSessionIdsFromTranscriptBasenames() throws {
        // Archive adoption: sessionIds are taken directly; gaps are backfilled from the
        // transcript filename (a claude transcript is just <sid>.jsonl); anything already
        // captured live always takes priority; a non-UUID filename is never guessed at.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.recordAgentPrompt(NodeID("root"), payload: ["session_id": "sid-live"])

        let a = SessionArchive.replay(lines: [
            #"{"ts":"2026-07-07T10:00:00Z","event":"cell_launch","node":"root","role":"manager","root":true,"task":"t"}"#,
            #"{"ts":"2026-07-07T10:00:01Z","event":"agent_prompt","node":"root","transcript":"/tmp/x/old-root.jsonl","session_id":"sid-old-root"}"#,
            #"{"ts":"2026-07-07T10:01:00Z","event":"cell_launch","node":"n1","role":"leaf","root":false,"task":"w","parent":"root"}"#,
            #"{"ts":"2026-07-07T10:01:01Z","event":"agent_prompt","node":"n1","transcript":"/tmp/x/1c9fac26-85b7-4e4d-b19c-0084c01975e0.jsonl"}"#,
            #"{"ts":"2026-07-07T10:02:00Z","event":"cell_launch","node":"n2","role":"leaf","root":false,"task":"w2","parent":"root"}"#,
            #"{"ts":"2026-07-07T10:02:01Z","event":"agent_prompt","node":"n2","transcript":"/tmp/x/not-a-uuid.jsonl"}"#,
        ])
        orch.adoptArchive(a)

        XCTAssertEqual(orch.sessionIds[NodeID("root")], "sid-live", "live capture takes priority, not overwritten by the archive")
        XCTAssertEqual(orch.sessionIds[NodeID("n1")], "1c9fac26-85b7-4e4d-b19c-0084c01975e0",
                       "the gap is backfilled from the transcript filename (old data has no session_id line)")
        XCTAssertNil(orch.sessionIds[NodeID("n2")], "a non-UUID filename = not derivable, honestly left blank")
        XCTAssertEqual(orch.transcripts[NodeID("n1")], "/tmp/x/1c9fac26-85b7-4e4d-b19c-0084c01975e0.jsonl")
    }

    func testAgentPromptRecordsSessionIdLastWins() async throws {
        // claude's hook payload carries its own session_id — after a resume
        // a new id forks off, and "last one wins" tracks it; the live mapping feeds
        // meta.rootSessionId, the jsonl line feeds archive replay.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        orch.recordAgentPrompt(NodeID("root"),
                               payload: ["transcript_path": "/tmp/t/a.jsonl",
                                         "session_id": "sid-1"])
        orch.recordAgentPrompt(NodeID("root"),
                               payload: ["transcript_path": "/tmp/t/b.jsonl",
                                         "session_id": "sid-2"])
        XCTAssertEqual(orch.sessionIds[NodeID("root")], "sid-2")

        let raw = try String(contentsOfFile: dir + "/orchestration.jsonl", encoding: .utf8)
        let events = try raw.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let prompts = events.filter { $0["event"] as? String == "agent_prompt" }
        XCTAssertEqual(prompts.compactMap { $0["session_id"] as? String }, ["sid-1", "sid-2"])
    }

    // MARK: honest reporting of a spawn that's only fake-alive (cell_launch → agent_connected timing window)

    private func makeStallOrchestrator(stall: TimeInterval,
                                       resumeRootSessionId: String? = nil)
    -> (Orchestrator, String) {
        let dir = NSTemporaryDirectory() + "vigil_orch_\(getpid())_\(UUID().uuidString)"
        let root = Node(id: NodeID("root"), role: .manager, status: .running, title: "mgr")
        let orch = Orchestrator(rootNode: root, harness: FakeHarness(), sessionDir: dir,
                                resumeRootSessionId: resumeRootSessionId,
                                spawnStallSeconds: stall) { _ in FakeBackend() }
        return (orch, dir)
    }

    private func orchEvents(_ dir: String) -> [[String: Any]] {
        let raw = (try? String(contentsOfFile: dir + "/orchestration.jsonl",
                               encoding: .utf8)) ?? ""
        return raw.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    /// The stall window's product default comes from runtime.json
    /// (read at watchdog arm — immediate-effect); an explicit test override still wins.
    func testSpawnStallWindowReadsRuntimeTuningWhenNotInjected() {
        RuntimeTuning.current.spawnStallSeconds = 99
        addTeardownBlock { RuntimeTuning.current = .defaults }
        let dir = NSTemporaryDirectory() + "vigil_orch_\(getpid())_\(UUID().uuidString)"
        let root = Node(id: NodeID("root"), role: .manager, status: .running, title: "mgr")
        let orch = Orchestrator(rootNode: root, harness: FakeHarness(),
                                sessionDir: dir) { _ in FakeBackend() }
        XCTAssertEqual(orch.spawnStallSeconds, 99)

        let (injected, dir2) = makeStallOrchestrator(stall: 0.05)
        defer { try? FileManager.default.removeItem(atPath: dir2) }
        XCTAssertEqual(injected.spawnStallSeconds, 0.05, "an explicit override wins")
    }

    func testSpawnStallReportsThenRecovers() async throws {
        // The event chain launch → stalled → recovered stays in sync with the indicator: no
        // agent_connected within the window → spawn_stalled is persisted + the node goes
        // .stalled (an independent state — same sidebar-attention tier, but the copy reads
        // "spawn never connected," never posing as waiting for authorization); once it connects
        // → spawn_recovered is persisted + the indicator clears.
        let (orch, dir) = makeStallOrchestrator(stall: 0.05)
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        XCTAssertNotNil(orch.spawnWatchdogs[child], "a genuine new spawn must arm a watchdog")
        XCTAssertNotNil(orch.spawnWatchdogs[NodeID("root")], "root and worker follow the same rule")

        for _ in 0..<400 where orch.store.tree[child]?.status != .stalled {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(orch.store.tree[child]?.status, .stalled,
                       "stalled = its own state (a node in the tree != the process is alive, same-family honesty as #19)")
        let stalled = orchEvents(dir).filter { $0["event"] as? String == "spawn_stalled" }
        XCTAssertTrue(stalled.contains { $0["node"] as? String == child.raw },
                      "spawn_stalled must land in orchestration.jsonl with its node")

        orch.noteAgentConnected(child)
        XCTAssertEqual(orch.store.tree[child]?.status, .idle, "recovered = the indicator is cleared")
        let recovered = orchEvents(dir).filter { $0["event"] as? String == "spawn_recovered" }
        XCTAssertEqual(recovered.compactMap { $0["node"] as? String }, [child.raw])
        XCTAssertNil(orch.spawnWatchdogs[child])
    }

    func testConnectInsideWindowNeverStalls() async throws {
        // Zero behavior change on the normal lit-screen path: agent_connected within the window → never stalled, no extra events.
        let (orch, dir) = makeStallOrchestrator(stall: 0.08)
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        orch.noteAgentConnected(child)                    // normal path: connects instantly
        orch.noteAgentConnected(NodeID("root"))
        XCTAssertNil(orch.spawnWatchdogs[child])

        try await Task.sleep(nanoseconds: 200_000_000)    // let the entire window elapse
        let events = orchEvents(dir)
        XCTAssertFalse(events.contains { $0["event"] as? String == "spawn_stalled" })
        XCTAssertFalse(events.contains { $0["event"] as? String == "spawn_recovered" },
                       "no stall means no recovered (never fabricate events)")
        XCTAssertEqual(orch.store.tree[child]?.status, .running)
    }

    func testResumeAndDeathPathsSkipOrCancelWatchdog() async throws {
        // Exclusion cases: resume (both root --resume and worker resurrection) is not a
        // genuinely new spawn, so it must not start the timer; node death must cancel any
        // in-flight watchdog. stall=10s → never fires within the test's lifetime — the
        // watchdog dictionary itself is the assertion target (no sleep race).
        let (orch, dir) = makeStallOrchestrator(stall: 10, resumeRootSessionId: "sid-root")
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        XCTAssertNil(orch.spawnWatchdogs[NodeID("root")], "root --resume is not timed")

        let child = spawnChild(orch)                      // a genuinely new spawn: starts the timer
        XCTAssertNotNil(orch.spawnWatchdogs[child])
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        for _ in 0..<50 where !fb.started { await Task.yield() }
        fb.simulateExit(0)
        for _ in 0..<200 where orch.store.tree[child]?.status.isTerminal != true {
            await Task.yield()
        }
        XCTAssertNil(orch.spawnWatchdogs[child], "node death must cancel the watchdog")

        orch.store.send(.resumeNode(child, sessionID: "sid-w"))
        XCTAssertNil(orch.spawnWatchdogs[child], "a revived worker (--resume) is not timed")
    }

    func testKillCancelsSpawnWatchdog() async throws {
        let (orch, dir) = makeStallOrchestrator(stall: 10)
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        XCTAssertNotNil(orch.spawnWatchdogs[child])
        orch.store.send(.requestStruct(.kill(child), from: NodeID("root"), replyID: UUID()))
        XCTAssertNil(orch.spawnWatchdogs[child], "tearing down a cell on kill also tears down its watchdog")
    }

    func testMessageRoutesIntoChildTerminal() async throws {
        // The manager→worker downlink end-to-end below Core: .message → Effect.route →
        // registry cell inject (the runtime half of the MCP `send` tool).
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")

        orch.store.send(.requestStruct(.spawn(parent: NodeID("root"), role: .leaf, task: "x"),
                                       from: NodeID("root"), replyID: UUID()))
        let child = orch.store.tree.nodes.keys.first { $0 != NodeID("root") }!
        let fb = orch.registry.backend(child) as? FakeBackend
        for _ in 0..<50 where !(fb?.started ?? false) { await Task.yield() }

        orch.store.send(.message(from: NodeID("root"), to: child,
                                 text: "MESSAGE FROM root: proceed", replyID: nil))
        // Effect.route → cell.inject runs in a scheduled Task; yield until delivered.
        for _ in 0..<50 where !(fb?.sent.contains("MESSAGE FROM root: proceed") ?? false) {
            await Task.yield()
        }
        XCTAssertTrue(fb?.sent.contains("MESSAGE FROM root: proceed") ?? false)
    }

    func testSendRouteFailuresLandInOrchestrationJsonl() async throws {
        // Both drop spots — Core-side (no such node) and world-side (node alive in
        // the tree but its cell is gone) — must each leave a route_failed jsonl line.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try orch.start(rootTask: "")

        orch.store.send(.message(from: NodeID("root"), to: NodeID("ghost"), text: "hi",
                                 replyID: nil))
        let child = spawnChild(orch)
        orch.registry.remove(child)                        // the starting/ghost window
        orch.store.send(.message(from: NodeID("root"), to: child, text: "hi", replyID: nil))

        let raw = try String(contentsOfFile: dir + "/orchestration.jsonl", encoding: .utf8)
        let events = try raw.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let failed = events.filter { $0["event"] as? String == "route_failed" }
        XCTAssertEqual(failed.count, 2)
        XCTAssertEqual(failed.first?["to"] as? String, "ghost")
        XCTAssertEqual(failed.first?["reason"] as? String, "no such node")
        XCTAssertEqual(failed.last?["to"] as? String, child.raw)
        XCTAssertEqual(failed.last?["reason"] as? String, "no live cell")
    }

    // MARK: report watchdog — silent-worker nudge (turnEnded × zero report × delivered)

    func testSilentTurnTriggersExactlyOneReminder() async throws {
        // Core behavior: a non-root worker was actually given a task, its turn ends
        // with no report() call reaching the parent → the harness nudges it once via the
        // ordinary inject path, and the nudge is forensically logged.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.watchdogGraceSeconds = 0.05   // deterministic: real grace is only about the turn_duration race
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        orch.recordAgentPrompt(child, payload: ["transcript_path": dir + "/child.jsonl"])  // (a) delivered
        orch.receive(.turnStarted(child))

        orch.receive(.turnEnded(child, gen: nil))    // silent turn end

        try await waitUntil("the watchdog reminder lands in the child's terminal") {
            fb.sent.contains(Orchestrator.reportWatchdogText)
        }
        let events = orchEvents(dir).filter { $0["event"] as? String == "report_watchdog" }
        XCTAssertEqual(events.map { $0["node"] as? String }, [child.raw])
    }

    func testReportWithinTurnSuppressesReminder() async throws {
        // Condition (b): a report DID arrive this turn → no nudge, no forensic line.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.watchdogGraceSeconds = 0.05
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        orch.recordAgentPrompt(child, payload: ["transcript_path": dir + "/child.jsonl"])
        orch.receive(.turnStarted(child))
        orch.receive(.rollup(from: child, summary: "done"))

        orch.receive(.turnEnded(child, gen: nil))

        XCTAssertTrue(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog" }.isEmpty)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(fb.sent.contains(Orchestrator.reportWatchdogText))
    }

    func testReminderThenSilentTurnDoesNotDoubleNudge() async throws {
        // The core bounding invariant: the reminder itself opens a new turn — if THAT
        // turn also ends silently, reminderOutstanding must still gate a second nudge
        // (no ping-pong).
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.watchdogGraceSeconds = 0.05
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        orch.recordAgentPrompt(child, payload: ["transcript_path": dir + "/child.jsonl"])
        orch.receive(.turnStarted(child))
        orch.receive(.turnEnded(child, gen: nil))    // silent → reminder #1
        try await waitUntil("the first reminder lands") {
            fb.sent.contains(Orchestrator.reportWatchdogText)
        }
        XCTAssertEqual(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog" }.count, 1)

        orch.receive(.turnStarted(child))            // the reminder's own turn
        orch.receive(.turnEnded(child, gen: nil))     // also silent

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fb.sent.filter { $0 == Orchestrator.reportWatchdogText }.count, 1,
                       "reminderOutstanding gates a second nudge until a report arrives")
        XCTAssertEqual(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog" }.count, 1)
    }

    func testReportClearsReminderGateAllowingAnotherLater() async throws {
        // A report() clears reminderOutstanding — further silence CAN be nudged again.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.watchdogGraceSeconds = 0.05
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        orch.recordAgentPrompt(child, payload: ["transcript_path": dir + "/child.jsonl"])
        orch.receive(.turnStarted(child))
        orch.receive(.turnEnded(child, gen: nil))    // silent → reminder #1
        try await waitUntil("the first reminder lands") {
            fb.sent.contains(Orchestrator.reportWatchdogText)
        }

        orch.receive(.turnStarted(child))
        orch.receive(.rollup(from: child, summary: "done"))   // report clears the gate
        orch.receive(.turnEnded(child, gen: nil))              // reported this turn → no nudge

        // A report clears watchdogDelivered too (A2, per-delivery not lifetime) — a genuine
        // new manager delivery re-arms it, mirroring a real `send` reaching the worker.
        orch.recordAgentPrompt(child, payload: ["transcript_path": dir + "/child.jsonl",
                                                "prompt": "MESSAGE FROM root: keep going"])
        orch.receive(.turnStarted(child))
        orch.receive(.turnEnded(child, gen: nil))              // silent again → reminder #2 allowed

        try await waitUntil("a second reminder lands after the report cleared the gate") {
            fb.sent.filter { $0 == Orchestrator.reportWatchdogText }.count == 2
        }
        XCTAssertEqual(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog" }.count, 2)
    }

    func testRootNeverGetsReportWatchdogReminder() async throws {
        // Root has no parent to report to — immune by construction, regardless of delivery.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.watchdogGraceSeconds = 0.05
        try orch.start(rootTask: "")
        let rootBackend = try XCTUnwrap(orch.registry.backend(NodeID("root")) as? FakeBackend)
        orch.recordAgentPrompt(NodeID("root"), payload: ["transcript_path": dir + "/root.jsonl"])
        orch.receive(.turnStarted(NodeID("root")))

        orch.receive(.turnEnded(NodeID("root"), gen: nil))

        XCTAssertTrue(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog" }.isEmpty)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(rootBackend.sent.contains(Orchestrator.reportWatchdogText))
    }

    func testResumeWithNoDeliveryNeverTriggers() async throws {
        // Condition (a): a resume settles idle with nothing ever delivered this lifecycle
        // (no recordAgentPrompt call) — a later turnEnded must not nudge a node Vigil
        // never actually asked anything of.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.watchdogGraceSeconds = 0.05
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        for _ in 0..<50 where !fb.started { await Task.yield() }
        fb.simulateExit(0)
        for _ in 0..<200 where orch.store.tree[child]?.status.isTerminal != true {
            await Task.yield()
        }

        orch.store.send(.resumeNode(child, sessionID: "sid-resume"))
        XCTAssertEqual(orch.store.tree[child]?.status, .idle)
        let nb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)

        orch.receive(.turnEnded(child, gen: nil))    // no recordAgentPrompt ever called this lifecycle

        XCTAssertTrue(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog" }.isEmpty)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(nb.sent.contains(Orchestrator.reportWatchdogText))
    }

    func testReportWatchdogDisabledSwitchNoActions() async throws {
        // runtime.json `reportWatchdog: false` — the check is skipped entirely.
        RuntimeTuning.current.reportWatchdog = false
        addTeardownBlock { RuntimeTuning.current = .defaults }
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.watchdogGraceSeconds = 0.05
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        orch.recordAgentPrompt(child, payload: ["transcript_path": dir + "/child.jsonl"])
        orch.receive(.turnStarted(child))

        orch.receive(.turnEnded(child, gen: nil))

        XCTAssertTrue(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog" }.isEmpty)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(fb.sent.contains(Orchestrator.reportWatchdogText))
    }

    func testDeadCellNeverGetsReportWatchdogReminder() async throws {
        // Red line: a dead node gets no injection — same honesty rule as every other
        // inject path.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.watchdogGraceSeconds = 0.05
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        orch.recordAgentPrompt(child, payload: ["transcript_path": dir + "/child.jsonl"])
        orch.receive(.turnStarted(child))
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        for _ in 0..<50 where !fb.started { await Task.yield() }
        fb.simulateExit(0)
        for _ in 0..<200 where orch.store.tree[child]?.status.isTerminal != true {
            await Task.yield()
        }

        orch.receive(.turnEnded(child, gen: nil))

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog" }.isEmpty,
                      "a dead node is never nudged")
    }

    // MARK: report watchdog — background-agent exemption (A1)

    func testBackgroundAgentsPendingSuppressesWatchdog() async throws {
        // The evidence-grounded fix: a turn that ended while claude's own turn_duration line
        // says background subagents are still running is not a silent worker — never nudge it.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.watchdogGraceSeconds = 0.05
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        let tpath = dir + "/child.jsonl"
        orch.recordAgentPrompt(child, payload: ["transcript_path": tpath])
        orch.receive(.turnStarted(child))
        writeTranscript(tpath, [
            #"{"type":"system","subtype":"turn_duration","pendingBackgroundAgentCount":2}"#,
        ])

        orch.receive(.turnEnded(child, gen: nil))

        try await Task.sleep(nanoseconds: 150_000_000)   // past the grace
        XCTAssertTrue(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog" }.isEmpty)
        XCTAssertFalse(fb.sent.contains(Orchestrator.reportWatchdogText))
        let skipped = orchEvents(dir).filter { $0["event"] as? String == "report_watchdog_skipped" }
        XCTAssertEqual(skipped.count, 1)
        XCTAssertEqual(skipped.first?["reason"] as? String, "background_agents_pending")
        XCTAssertEqual(skipped.first?["count"] as? Int, 2)
    }

    func testBackgroundAgentsZeroStillTriggersWatchdog() async throws {
        // Regression guard: a turn_duration line reporting zero pending background agents
        // must not be mistaken for the exemption — the silent-worker nudge still fires.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.watchdogGraceSeconds = 0.05
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        let tpath = dir + "/child.jsonl"
        orch.recordAgentPrompt(child, payload: ["transcript_path": tpath])
        orch.receive(.turnStarted(child))
        writeTranscript(tpath, [
            #"{"type":"system","subtype":"turn_duration","pendingBackgroundAgentCount":0}"#,
        ])

        orch.receive(.turnEnded(child, gen: nil))

        try await waitUntil("count 0 is not an exemption") {
            fb.sent.contains(Orchestrator.reportWatchdogText)
        }
        XCTAssertEqual(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog" }.count, 1)
        XCTAssertTrue(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog_skipped" }.isEmpty)
    }

    func testTranscriptWithoutTurnDurationLineStillTriggersWatchdog() async throws {
        // codex / opencode / an older claude never write a turn_duration line — its absence
        // must never be treated as an exemption.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.watchdogGraceSeconds = 0.05
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        let tpath = dir + "/child.jsonl"
        orch.recordAgentPrompt(child, payload: ["transcript_path": tpath])
        orch.receive(.turnStarted(child))
        writeTranscript(tpath, [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done thinking"}]}}"#,
        ])

        orch.receive(.turnEnded(child, gen: nil))

        try await waitUntil("no turn_duration line never blocks the nudge") {
            fb.sent.contains(Orchestrator.reportWatchdogText)
        }
        XCTAssertTrue(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog_skipped" }.isEmpty)
    }

    func testTurnDurationLineWrittenDuringGraceStillSuppresses() async throws {
        // The race guard: claude's Stop hook (→ .turnEnded) fires BEFORE it appends the
        // turn_duration line (same-second on real transcripts) — the line lands a beat later,
        // still well inside the grace window. The deferred check must catch it.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.watchdogGraceSeconds = 0.25
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        let tpath = dir + "/child.jsonl"
        orch.recordAgentPrompt(child, payload: ["transcript_path": tpath])
        orch.receive(.turnStarted(child))
        writeTranscript(tpath, [])   // the transcript exists, empty, when the Stop hook fires

        orch.receive(.turnEnded(child, gen: nil))   // Stop hook lands — no turn_duration line yet
        try await Task.sleep(nanoseconds: 40_000_000)   // still well inside the 0.25s grace
        writeTranscript(tpath, [
            #"{"type":"system","subtype":"turn_duration","pendingBackgroundAgentCount":1}"#,
        ])

        try await Task.sleep(nanoseconds: 350_000_000)   // past the grace
        XCTAssertTrue(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog" }.isEmpty,
                      "the deferred check re-reads the transcript, catching the line written mid-grace")
        XCTAssertFalse(fb.sent.contains(Orchestrator.reportWatchdogText))
        XCTAssertEqual(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog_skipped" }.count, 1)
    }

    // MARK: report watchdog — per-delivery arming, not lifetime (A2)

    func testNoNagWithoutNewDeliveryAfterReport() async throws {
        // watchdogDelivered is per-delivery, not lifetime: after a report answers the
        // delivery it was asked for, a LATER silent turn with no new manager send/task in
        // between must not nag — reportedSinceTurnStart only guards the turn the report
        // itself landed in, so without this the worker's own idle continuation turns would
        // keep getting nagged forever (the lifetime-set over-nagging bug this replaced).
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.watchdogGraceSeconds = 0.05
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        orch.recordAgentPrompt(child, payload: ["transcript_path": dir + "/child.jsonl"])
        orch.receive(.turnStarted(child))
        orch.receive(.rollup(from: child, summary: "done"))
        orch.receive(.turnEnded(child, gen: nil))   // reported this turn → no nudge (existing guard)

        orch.receive(.turnStarted(child))           // a new turn, but nobody delivered anything
        orch.receive(.turnEnded(child, gen: nil))   // silent — yet there is no outstanding delivery

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog" }.isEmpty,
                      "no new manager delivery since the report — this silence is legitimate")
        XCTAssertFalse(fb.sent.contains(Orchestrator.reportWatchdogText))

        // A genuine new delivery (a routed send) re-arms it.
        orch.recordAgentPrompt(child, payload: ["transcript_path": dir + "/child.jsonl",
                                                "prompt": "MESSAGE FROM root: keep going"])
        orch.receive(.turnStarted(child))
        orch.receive(.turnEnded(child, gen: nil))   // silent again → now this IS a dummy report

        try await waitUntil("a new delivery re-arms the watchdog") {
            fb.sent.contains(Orchestrator.reportWatchdogText)
        }
        XCTAssertEqual(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog" }.count, 1)
    }

    func testRecordAgentPromptDoesNotArmForOwnReminderOrTaskNotification() async throws {
        // The watchdog's own reminder and a `<task-notification>` are system-originated, not a
        // genuine manager ask — arming on them would recreate the ping-pong the lifetime set
        // caused.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.watchdogGraceSeconds = 0.05
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)

        orch.recordAgentPrompt(child, payload: ["transcript_path": dir + "/child.jsonl",
                                                "prompt": Orchestrator.reportWatchdogText])
        orch.receive(.turnStarted(child))
        orch.receive(.turnEnded(child, gen: nil))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog" }.isEmpty,
                      "the watchdog's own reminder must not re-arm itself")

        orch.recordAgentPrompt(child, payload: ["transcript_path": dir + "/child.jsonl",
            "prompt": "<task-notification>agent finished elsewhere</task-notification>"])
        orch.receive(.turnStarted(child))
        orch.receive(.turnEnded(child, gen: nil))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog" }.isEmpty,
                      "a system task-notification is not a manager delivery")
        XCTAssertFalse(fb.sent.contains(Orchestrator.reportWatchdogText))
    }

    func testRouteDeliveredMessageRearmsWatchdogKindAgnostic() async throws {
        // R1: codex/opencode's capture sites only insert watchdogDelivered on a sid/pointer
        // change (in practice once per lifecycle), so recordAgentPrompt's prompt-text
        // introspection (claude-hook-only) can't re-arm them after a `.rollup` cleared it. The
        // `.route` effect handler's delivered-message branch is the kind-agnostic re-arm path:
        // any harness, once a real manager message actually reaches the PTY.
        let (orch, dir) = makeOrchestrator()
        defer { orch.stop(); try? FileManager.default.removeItem(atPath: dir) }
        orch.watchdogGraceSeconds = 0.05
        try orch.start(rootTask: "")
        let child = spawnChild(orch)
        let fb = try XCTUnwrap(orch.registry.backend(child) as? FakeBackend)
        for _ in 0..<50 where !fb.started { await Task.yield() }

        orch.recordAgentPrompt(child, payload: ["transcript_path": dir + "/child.jsonl"])
        orch.receive(.turnStarted(child))
        orch.receive(.rollup(from: child, summary: "done"))   // clears watchdogDelivered
        orch.receive(.turnEnded(child, gen: nil))             // reported this turn → no nudge

        // A rollup-shaped or SYSTEM-shaped route delivered to the child must NOT arm it —
        // only a genuine manager message counts.
        orch.store.send(.message(from: NodeID("root"), to: child,
                                 text: "SYSTEM: your message was voided", replyID: nil))
        try await waitUntil("the SYSTEM receipt is delivered") {
            fb.sent.contains("SYSTEM: your message was voided")
        }
        orch.store.send(.message(from: NodeID("root"), to: child,
                                 text: "CHILD_ROLLUP:not a real rollup", replyID: nil))
        try await waitUntil("the rollup-shaped text is delivered") {
            fb.sent.contains("CHILD_ROLLUP:not a real rollup")
        }
        orch.receive(.turnStarted(child))
        orch.receive(.turnEnded(child, gen: nil))    // silent — but nothing armed it
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog" }.isEmpty,
                      "SYSTEM-shaped and rollup-shaped routes must not arm the watchdog")

        // A genuine manager message DOES (re-)arm it. The arm lands AFTER the inject ack
        // resolves (RealCell.performInject sends the text, settles ~150ms, sends "\r", and
        // only then returns; the orchestrator inserts into watchdogDelivered after that) —
        // so waiting on the PTY bytes (text or even the trailing CR) races the arm and flaked
        // ~50% under load. Wait on the arm itself via the read-only test seam.
        XCTAssertFalse(orch.isWatchdogArmed(child), "precondition: nothing armed before the follow-up")
        orch.store.send(.message(from: NodeID("root"), to: child,
                                 text: "MESSAGE FROM root: follow-up", replyID: nil))
        try await waitUntil("the follow-up delivery armed the watchdog", timeout: 5) {
            orch.isWatchdogArmed(child)
        }
        orch.receive(.turnStarted(child))
        orch.receive(.turnEnded(child, gen: nil))    // silent finish after the follow-up

        try await waitUntil("the follow-up delivery re-armed the watchdog") {
            fb.sent.contains(Orchestrator.reportWatchdogText)
        }
        XCTAssertEqual(orchEvents(dir).filter { $0["event"] as? String == "report_watchdog" }.count, 1)
    }
}
