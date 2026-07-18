import XCTest
import VigilCore
@testable import VigilRuntime

/// codex sid/transcript capture surface. The rollout jsonl shape is captured from a real
/// codex 0.144.1 machine: filename `rollout-<ISO-ts>-<uuid>.jsonl`, line 0 = session_meta
/// (payload.session_id = the uuid tail of the filename).
final class CodexRolloutTests: XCTestCase {

    private let uuid = "019f4b24-1b04-7ce0-9059-7da727c56bf3"

    /// Build an isolated codex-home, drop a rollout file into it (matching the real shape), return (home, rolloutPath).
    private func makeRollout(ts: String, uuid: String, cwd: String = "/proj",
                             extraLines: [String] = []) -> (home: String, path: String) {
        let home = NSTemporaryDirectory() + "codexhome_\(getpid())_\(UUID().uuidString)"
        let dir = home + "/sessions/2026/07/10"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/rollout-\(ts)-\(uuid).jsonl"
        let meta = #"{"timestamp":"2026-07-10T08:28:34.164Z","type":"session_meta","payload":{"session_id":"\#(uuid)","id":"\#(uuid)","cwd":"\#(cwd)","cli_version":"0.144.1"}}"#
        let body = ([meta] + extraLines).joined(separator: "\n") + "\n"
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: home) }
        return (home, path)
    }

    func testSidFromNameDerivesUuidTail() {
        // The timestamp segment also contains hyphens, so the uuid is taken from the last 5 segments.
        XCTAssertEqual(
            CodexRollout.sidFromName("/x/rollout-2026-07-10T16-28-05-\(uuid).jsonl"), uuid)
    }

    func testSidFromNameRejectsNonUuidTail() {
        XCTAssertNil(CodexRollout.sidFromName("/x/rollout-2026-07-10-not-a-uuid-here.jsonl"))
        XCTAssertNil(CodexRollout.sidFromName("/x/somethingelse.jsonl"))
    }

    func testSessionMetaParsesSessionIdAndCwd() {
        let (_, path) = makeRollout(ts: "2026-07-10T16-28-05", uuid: uuid, cwd: "/my/proj")
        let meta = CodexRollout.sessionMeta(rolloutPath: path)
        XCTAssertEqual(meta?.sessionId, uuid)
        XCTAssertEqual(meta?.cwd, "/my/proj")
    }

    func testSessionMetaHandlesHugeFirstLine() {
        // Line 0 can embed a full system prompt reaching several KB — sessionMeta only reads up to the first newline, and must still parse out the sid.
        let big = String(repeating: "x", count: 300_000)
        let home = NSTemporaryDirectory() + "codexhome_big_\(getpid())_\(UUID().uuidString)"
        let dir = home + "/sessions/2026/07/10"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/rollout-2026-07-10T16-28-05-\(uuid).jsonl"
        let meta = #"{"type":"session_meta","payload":{"session_id":"\#(uuid)","base_instructions":"\#(big)"}}"#
        try? (meta + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: home) }
        XCTAssertEqual(CodexRollout.sessionMeta(rolloutPath: path, maxBytes: 512 * 1024)?.sessionId, uuid)
    }

    func testCaptureReturnsSidAndPath() {
        let (home, path) = makeRollout(ts: "2026-07-10T16-28-05", uuid: uuid)
        let cap = CodexRollout.capture(codexHome: home)
        XCTAssertEqual(cap?.sessionId, uuid)
        XCTAssertEqual(cap?.path, path)
    }

    func testNewestRolloutWinsLexically() {
        // Two rollouts in the same home (different timestamps); filename lexical order = chronological order, so the newest wins.
        let home = NSTemporaryDirectory() + "codexhome_two_\(getpid())_\(UUID().uuidString)"
        let dir = home + "/sessions/2026/07/10"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let older = "019f4b24-1b04-7ce0-9059-7da727c56bf3"
        let newer = "019f4b99-1b04-7ce0-9059-7da727c56bf3"
        for (ts, u) in [("2026-07-10T10-00-00", older), ("2026-07-10T20-00-00", newer)] {
            let p = dir + "/rollout-\(ts)-\(u).jsonl"
            try? #"{"type":"session_meta","payload":{"session_id":"\#(u)"}}\#n"#
                .write(toFile: p, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(CodexRollout.capture(codexHome: home)?.sessionId, newer)
    }

    func testCaptureNilWhenNoRollout() {
        // Honest degradation: no sessions directory / no rollout → nil (never fabricate credentials).
        let empty = NSTemporaryDirectory() + "codexhome_empty_\(getpid())_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: empty) }
        XCTAssertNil(CodexRollout.capture(codexHome: empty))
        XCTAssertNil(CodexRollout.capture(codexHome: empty + "/does-not-exist"))
    }

    /// CodexHarness.codexHome and Orchestrator capture share the same path derivation (change one place without breaking the other).
    func testCodexHomePathMatchesHarness() {
        let home = CodexHarness.codexHome(configRoot: "/s/config", node: NodeID("n1"))
        XCTAssertEqual(home, "/s/config/n1/codex-home")
    }

    // MARK: sub-agent rollout pollution

    /// Build a codex-home holding an arbitrary set of rollout files (name → line-0 payload JSON).
    private func makeHome(_ files: [(name: String, metaPayload: String)]) -> String {
        let home = NSTemporaryDirectory() + "codexhome_multi_\(getpid())_\(UUID().uuidString)"
        let dir = home + "/sessions/2026/07/13"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for f in files {
            let line = #"{"type":"session_meta","payload":\#(f.metaPayload)}"# + "\n"
            try? line.write(toFile: dir + "/" + f.name, atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: home) }
        return home
    }

    /// The core Case A bug: codex 0.144+ multi-agent has a task-spawned sub-agent write its OWN
    /// (newer) rollout into the SAME codex-home. A naive "newest wins" binds to the sub-agent; we
    /// must skip it and return the MAIN session — whose sid is the user session, not a sub-thread.
    func testNewestRolloutSkipsSubagentAndBindsMain() {
        let mainId = "019f5aa1-4da4-7563-812e-32b450862ead"   // thread_source=user, earlier
        let subId  = "019f5aa2-854e-7102-b574-044c5528d122"   // thread_source=subagent, LATER
        let home = makeHome([
            (name: "rollout-2026-07-13T16-39-08-\(mainId).jsonl",
             metaPayload: #"{"session_id":"\#(mainId)","id":"\#(mainId)","thread_source":"user","cwd":"/proj"}"#),
            // the sub-agent's meta.session_id is the PARENT's id, its filename uuid is its own thread id
            (name: "rollout-2026-07-13T16-40-28-\(subId).jsonl",
             metaPayload: #"{"session_id":"\#(mainId)","id":"\#(subId)","thread_source":"subagent","agent_role":"worker","parent_thread_id":"\#(mainId)","source":{"subagent":{"thread_spawn":{"depth":1}}}}"#),
        ])
        let cap = CodexRollout.capture(codexHome: home)
        XCTAssertNotNil(cap)
        XCTAssertTrue(cap!.path.hasSuffix("\(mainId).jsonl"), "must bind the MAIN rollout, not the newer sub-agent")
        XCTAssertEqual(cap!.sessionId, mainId, "sid must be the main session, not the sub-thread's own id")
    }

    /// Honest degradation: a codex-home with ONLY sub-agent rollouts yields no credential
    /// (never hand back a sub-thread id as if it were the session).
    func testNewestRolloutNilWhenOnlySubagents() {
        let subId = "019f5aa2-854e-7102-b574-044c5528d122"
        let home = makeHome([
            (name: "rollout-2026-07-13T16-40-28-\(subId).jsonl",
             metaPayload: #"{"session_id":"019f5aa1-4da4-7563-812e-32b450862ead","id":"\#(subId)","thread_source":"subagent","agent_role":"worker"}"#),
        ])
        XCTAssertNil(CodexRollout.capture(codexHome: home))
    }

    /// Positive-only classification: a rollout without any sub-agent marker is treated as MAIN
    /// (so a future codex that changes the main marker never accidentally drops the real session).
    func testIsSubagentRolloutClassification() {
        let base = makeHome([
            (name: "rollout-a-\(uuid).jsonl", metaPayload: #"{"session_id":"\#(uuid)","thread_source":"user"}"#),
            (name: "rollout-b-\(uuid).jsonl", metaPayload: #"{"session_id":"\#(uuid)"}"#),                       // no marker at all
            (name: "rollout-c-\(uuid).jsonl", metaPayload: #"{"session_id":"\#(uuid)","thread_source":"subagent"}"#),
            (name: "rollout-d-\(uuid).jsonl", metaPayload: #"{"session_id":"\#(uuid)","source":{"subagent":{}}}"#),
            (name: "rollout-e-\(uuid).jsonl", metaPayload: #"{"session_id":"\#(uuid)","agent_role":"worker"}"#),
        ])
        let dir = base + "/sessions/2026/07/13/"
        XCTAssertFalse(CodexRollout.isSubagentRollout(rolloutPath: dir + "rollout-a-\(uuid).jsonl"))
        XCTAssertFalse(CodexRollout.isSubagentRollout(rolloutPath: dir + "rollout-b-\(uuid).jsonl"))
        XCTAssertTrue(CodexRollout.isSubagentRollout(rolloutPath: dir + "rollout-c-\(uuid).jsonl"))
        XCTAssertTrue(CodexRollout.isSubagentRollout(rolloutPath: dir + "rollout-d-\(uuid).jsonl"))
        XCTAssertTrue(CodexRollout.isSubagentRollout(rolloutPath: dir + "rollout-e-\(uuid).jsonl"))
    }

    /// Regression against REAL codex 0.144.1 rollouts (dogfood capture, base_instructions redacted):
    /// a main + a newer sub-agent from the SAME codex-home. capture() must pick the main and read its
    /// first user_message; the sub-agent fixture must classify as a sub-agent.
    func testRealFixtureMainVsSubagent() throws {
        let mainURL = try XCTUnwrap(Bundle.module.url(
            forResource: "rollout-codex-0.144.1-main-sample", withExtension: "jsonl"))
        let subURL = try XCTUnwrap(Bundle.module.url(
            forResource: "rollout-codex-0.144.1-subagent-sample", withExtension: "jsonl"))
        // classification on the real shapes
        XCTAssertFalse(CodexRollout.isSubagentRollout(rolloutPath: mainURL.path))
        XCTAssertTrue(CodexRollout.isSubagentRollout(rolloutPath: subURL.path))
        // stage both into one codex-home with their real (sub-agent-newer) filenames
        let home = makeHome([])
        let dir = home + "/sessions/2026/07/13/"
        try FileManager.default.copyItem(atPath: mainURL.path,
            toPath: dir + "rollout-2026-07-13T16-39-08-019f5aa1-4da4-7563-812e-32b450862ead.jsonl")
        try FileManager.default.copyItem(atPath: subURL.path,
            toPath: dir + "rollout-2026-07-13T16-40-28-019f5aa2-854e-7102-b574-044c5528d122.jsonl")
        let cap = try XCTUnwrap(CodexRollout.capture(codexHome: home))
        XCTAssertEqual(cap.sessionId, "019f5aa1-4da4-7563-812e-32b450862ead")
        XCTAssertTrue(cap.path.hasSuffix("019f5aa1-4da4-7563-812e-32b450862ead.jsonl"))
        // the honest fallback name reads the MAIN's first prompt, not the sub-agent's sub-task
        let firstUser = try XCTUnwrap(CodexRollout.firstUserMessage(rolloutPath: cap.path))
        XCTAssertTrue(firstUser.hasPrefix("Spin up 10 codex"), "got: \(firstUser)")
        // the sub-agent's first prompt is the delegated sub-task ("Read-only stress-test worker N/10…") — must NOT be read
        XCTAssertFalse(firstUser.hasPrefix("Read-only stress-test"), "must bind the main session's prompt, not a sub-agent's sub-task")
    }

    /// codex naming source: firstUserMessage returns the pure first user prompt, nil before any turn.
    func testFirstUserMessage() {
        let (_, path) = makeRollout(ts: "2026-07-10T16-28-05", uuid: uuid, extraLines: [
            #"{"type":"event_msg","payload":{"type":"user_message","message":"  build the thing\nwith care  "}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"ok"}}"#,
        ])
        XCTAssertEqual(CodexRollout.firstUserMessage(rolloutPath: path), "build the thing\nwith care")
        let (_, none) = makeRollout(ts: "2026-07-10T16-29-05", uuid: uuid)   // meta only, no turn yet
        XCTAssertNil(CodexRollout.firstUserMessage(rolloutPath: none))
    }
}
