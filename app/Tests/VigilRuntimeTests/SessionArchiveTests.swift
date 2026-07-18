import Foundation
import XCTest
import VigilCore
@testable import VigilRuntime

// SessionArchive is the READ-BACK layer over what the Orchestrator already writes:
// orchestration.jsonl (spawn/exit/kill/agent_prompt, world-side timestamps) + meta.json
// (session identity, written by the app layer). Vigil stores POINTERS to the CLIs'
// transcripts, never copies — a vanished transcript degrades gracefully, the skeleton
// (Vigil's own data) always survives.

final class SessionArchiveTests: XCTestCase {

    private var tmpDirs: [String] = []

    override func tearDown() {
        for d in tmpDirs { try? FileManager.default.removeItem(atPath: d) }
        tmpDirs.removeAll()
        super.tearDown()
    }

    private func makeDir() throws -> String {
        let d = NSTemporaryDirectory() + "vigil_archive_test_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        tmpDirs.append(d)
        return d
    }

    private func jsonl(_ objs: [[String: Any]]) -> [String] {
        objs.map {
            String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)!
        }
    }

    /// The exact line shapes Orchestrator.orchLog writes today.
    private func sampleLines() -> [String] {
        jsonl([
            ["ts": "2026-07-07T10:00:00Z", "event": "cell_launch", "node": "root",
             "role": "manager", "root": true, "task": "main task"],
            ["ts": "2026-07-07T10:00:05Z", "event": "agent_connected", "node": "root"],
            ["ts": "2026-07-07T10:00:10Z", "event": "agent_prompt", "node": "root",
             "transcript": "/tmp/claude/root-old.jsonl", "session_id": "sid-root-1"],
            ["ts": "2026-07-07T10:01:00Z", "event": "cell_launch", "node": "n1",
             "role": "leaf", "root": false, "task": "worker A", "parent": "root",
             "model": "opus"],
            ["ts": "2026-07-07T10:01:02Z", "event": "agent_prompt", "node": "n1",
             "transcript": "/tmp/claude/n1.jsonl", "session_id": "sid-n1"],
            ["ts": "2026-07-07T10:01:30Z", "event": "cell_launch", "node": "n2",
             "role": "leaf", "root": false, "task": "worker B", "parent": "root"],
            ["ts": "2026-07-07T10:02:00Z", "event": "agent_prompt", "node": "root",
             "transcript": "/tmp/claude/root-new.jsonl", "session_id": "sid-root-2"],
            ["ts": "2026-07-07T10:05:00Z", "event": "route", "to": "root",
             "kind": "rollup", "text": "CHILD_ROLLUP:done"],
            ["ts": "2026-07-07T10:05:01Z", "event": "exit", "node": "n1", "code": 0],
            ["ts": "2026-07-07T10:06:00Z", "event": "kill", "node": "n2"],
            ["ts": "2026-07-07T10:06:01Z", "event": "exit", "node": "n2", "code": 9],
        ])
    }

    // MARK: history tree shows the dispatch-time name

    func testReplayPrefersTitleOverTask() throws {
        let s = SessionArchive.replay(lines: jsonl([
            ["ts": "2026-07-10T10:00:00Z", "event": "cell_launch",
             "node": "root", "role": "manager", "root": true, "task": "main task"],
            ["ts": "2026-07-10T10:01:00Z", "event": "cell_launch",
             "node": "n1", "role": "leaf", "root": false, "parent": "root",
             "task": "handle all fixes for issue #49…", "title": "issue-49 fix"],
        ]))
        let tree = try XCTUnwrap(s.tree)
        XCTAssertEqual(tree[NodeID("n1")]?.title, "issue-49 fix",
                       "the history tree prefers title (#54); an old record with no title falls back to task")
        XCTAssertEqual(tree.root.title, "main task", "with no title field, task is used as before")
    }

    // MARK: replay — tree skeleton (node/role/status/timeline)

    func testReplayRebuildsTreeSkeleton() throws {
        let s = SessionArchive.replay(lines: sampleLines())
        let tree = try XCTUnwrap(s.tree)
        XCTAssertEqual(tree.rootID, NodeID("root"))
        XCTAssertEqual(tree.count, 3)
        XCTAssertEqual(tree.root.role, .manager)
        XCTAssertEqual(tree.root.title, "main task")
        XCTAssertEqual(Set(tree.root.children), Set([NodeID("n1"), NodeID("n2")]))

        let n1 = try XCTUnwrap(tree[NodeID("n1")])
        XCTAssertEqual(n1.parent, NodeID("root"))
        XCTAssertEqual(n1.role, .leaf)
        XCTAssertEqual(n1.title, "worker A")
        XCTAssertEqual(n1.model, "opus")
        XCTAssertEqual(n1.status, .done)                       // exit code 0
        XCTAssertNotNil(n1.startedAt)
        XCTAssertNotNil(n1.endedAt)

        let n2 = try XCTUnwrap(tree[NodeID("n2")])
        XCTAssertEqual(n2.status, .killed)                     // kill precedes the exit echo
    }

    func testReplayTimelineStampsComeFromEventTimestamps() throws {
        let s = SessionArchive.replay(lines: sampleLines())
        let tree = try XCTUnwrap(s.tree)
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(tree[NodeID("n1")]?.startedAt, iso.date(from: "2026-07-07T10:01:00Z"))
        XCTAssertEqual(tree[NodeID("n1")]?.endedAt, iso.date(from: "2026-07-07T10:05:01Z"))
        XCTAssertEqual(s.firstEventAt, iso.date(from: "2026-07-07T10:00:00Z"))
        XCTAssertEqual(s.lastEventAt, iso.date(from: "2026-07-07T10:06:01Z"))
    }

    func testReplayNodeWithoutTerminalEventShowsKilled() throws {
        // App quit / crash mid-run: no exit line ever lands. The PTY died with the app —
        // "Killed" is the honest display; endedAt stays nil (we never saw the moment).
        let s = SessionArchive.replay(lines: jsonl([
            ["ts": "2026-07-07T10:00:00Z", "event": "cell_launch", "node": "root",
             "role": "manager", "root": true, "task": "t"],
        ]))
        let root = try XCTUnwrap(s.tree?.root)
        XCTAssertEqual(root.status, .killed)
        XCTAssertNil(root.endedAt)
    }

    func testReplayFirstTerminalEventWins() throws {
        // Mirrors SessionStore's sticky-terminal rule: the teardown SIGTERM echo after a
        // clean exit must not rewrite done → killed/failed.
        let s = SessionArchive.replay(lines: jsonl([
            ["ts": "2026-07-07T10:00:00Z", "event": "cell_launch", "node": "root",
             "role": "manager", "root": true, "task": "t"],
            ["ts": "2026-07-07T10:01:00Z", "event": "cell_launch", "node": "n1",
             "role": "leaf", "root": false, "task": "w", "parent": "root"],
            ["ts": "2026-07-07T10:02:00Z", "event": "exit", "node": "n1", "code": 0],
            ["ts": "2026-07-07T10:02:01Z", "event": "kill", "node": "n1"],
        ]))
        XCTAssertEqual(s.tree?[NodeID("n1")]?.status, .done)
        XCTAssertEqual(s.tree?[NodeID("n1")]?.endedAt,
                       ISO8601DateFormatter().date(from: "2026-07-07T10:02:00Z"))
    }

    func testReplayParentlessChildAttachesUnderRoot() throws {
        // Logs with no parent field degrade to a flat tree under root rather
        // than dropping the node (the skeleton must survive old logs).
        let s = SessionArchive.replay(lines: jsonl([
            ["ts": "2026-07-07T10:00:00Z", "event": "cell_launch", "node": "root",
             "role": "manager", "root": true, "task": "t"],
            ["ts": "2026-07-07T10:01:00Z", "event": "cell_launch", "node": "n1",
             "role": "leaf", "root": false, "task": "w"],
        ]))
        XCTAssertEqual(s.tree?[NodeID("n1")]?.parent, NodeID("root"))
    }

    func testReplayIgnoresMalformedAndUnknownLines() throws {
        var lines = sampleLines()
        lines.insert("not json at all {", at: 2)
        lines.insert(jsonl([["ts": "2026-07-07T10:03:00Z", "event": "future_event",
                             "node": "n1"]])[0], at: 5)
        let s = SessionArchive.replay(lines: lines)
        XCTAssertEqual(s.tree?.count, 3)                       // unaffected
    }

    func testReplayEmptyLogHasNoTree() {
        let s = SessionArchive.replay(lines: [])
        XCTAssertNil(s.tree)
    }

    // MARK: replay — transcript pointer join (node → CLI transcript)

    func testReplayJoinsTranscriptPointersLastWins() throws {
        let s = SessionArchive.replay(lines: sampleLines())
        // claude rotates transcript files across turns; the newest pointer is the session.
        XCTAssertEqual(s.transcripts[NodeID("root")], "/tmp/claude/root-new.jsonl")
        XCTAssertEqual(s.transcripts[NodeID("n1")], "/tmp/claude/n1.jsonl")
        XCTAssertNil(s.transcripts[NodeID("n2")])              // never prompted
    }

    // MARK: replay — session id join (resume's key, collected from agent_prompt lines)

    func testReplayCollectsSessionIdsLastWins() throws {
        // After resume, claude forks a new session id — the hook collection follows a
        // "last one wins" rule, riding the same agent_prompt line as the transcript pointer.
        let s = SessionArchive.replay(lines: sampleLines())
        XCTAssertEqual(s.sessionIds[NodeID("root")], "sid-root-2")
        XCTAssertEqual(s.sessionIds[NodeID("n1")], "sid-n1")
        XCTAssertNil(s.sessionIds[NodeID("n2")])               // never prompted
    }

    // MARK: replay — re-incarnation (resume reuses the same session dir, a second cell_launch)

    func testReplayReincarnationResetsTerminalState() throws {
        // A second cell_launch for the same node = a new incarnation from resume: terminal-state
        // stickiness must be cleared (status reverts to "no terminal event", endedAt is cleared,
        // startedAt is renewed) — otherwise a resumed session's history playback would be frozen
        // at the first exit forever.
        let iso = ISO8601DateFormatter()
        let base: [[String: Any]] = [
            ["ts": "2026-07-07T10:00:00Z", "event": "cell_launch", "node": "root",
             "role": "manager", "root": true, "task": "t"],
            ["ts": "2026-07-07T10:01:00Z", "event": "exit", "node": "root", "code": 0],
            ["ts": "2026-07-07T11:00:00Z", "event": "cell_launch", "node": "root",
             "role": "manager", "root": true, "task": "t"],
        ]
        let mid = SessionArchive.replay(lines: jsonl(base))
        let root = try XCTUnwrap(mid.tree?.root)
        XCTAssertEqual(root.status, .killed)                   // the new incarnation has no terminal event yet
        XCTAssertNil(root.endedAt)
        XCTAssertEqual(root.startedAt, iso.date(from: "2026-07-07T11:00:00Z"))

        // The new incarnation's exit lands its terminal state normally (the sticky rule takes
        // effect again within the new incarnation).
        let done = SessionArchive.replay(lines: jsonl(base + [
            ["ts": "2026-07-07T11:30:00Z", "event": "exit", "node": "root", "code": 0],
            ["ts": "2026-07-07T11:30:01Z", "event": "kill", "node": "root"],
        ]))
        XCTAssertEqual(done.tree?.root.status, .done)
        XCTAssertEqual(done.tree?.root.endedAt, iso.date(from: "2026-07-07T11:30:00Z"))
    }

    // MARK: meta.json round-trip

    func testMetaRoundTrip() throws {
        let dir = try makeDir()
        let meta = SessionArchiveMeta(id: "20260707-100000-abcd1234", name: "fix bug",
                                      projectName: "vigil", projectCwd: "/tmp/proj",
                                      agent: "claude", model: "opus",
                                      createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        SessionArchive.writeMeta(meta, dir: dir)
        XCTAssertEqual(SessionArchive.readMeta(dir: dir), meta)
    }

    func testReadMetaMissingReturnsNil() throws {
        XCTAssertNil(SessionArchive.readMeta(dir: try makeDir()))
    }

    func testMetaRootSessionIdRoundTripAndBackwardCompat() throws {
        // resume only reads meta.rootSessionId (no need for a full replay). Old
        // meta.json files lack this key → it decodes to nil (backward compatible; the UI
        // falls back to the read-only HistoryPane).
        let dir = try makeDir()
        let meta = SessionArchiveMeta(id: "x", name: "n", projectName: nil, projectCwd: nil,
                                      agent: "claude", model: nil,
                                      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                                      rootSessionId: "0f3a-uuid")
        SessionArchive.writeMeta(meta, dir: dir)
        XCTAssertEqual(SessionArchive.readMeta(dir: dir)?.rootSessionId, "0f3a-uuid")

        let legacy = """
        {"id":"y","name":"old","agent":"claude","createdAt":"2026-07-01T00:00:00Z"}
        """
        let legacyDir = try makeDir()
        try legacy.write(toFile: legacyDir + "/meta.json", atomically: true, encoding: .utf8)
        let read = try XCTUnwrap(SessionArchive.readMeta(dir: legacyDir))
        XCTAssertNil(read.rootSessionId)
    }

    // MARK: archived flag (sidebar Archived section)

    func testSetArchivedFlipsFlagInPlaceAndOldMetaDecodesUnarchived() throws {
        let dir = try makeDir()
        SessionArchive.writeMeta(
            SessionArchiveMeta(id: "a", name: "n", projectName: "p", projectCwd: "/tmp/p",
                               agent: "codex", model: nil,
                               createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                               rootSessionId: "sid-1"),
            dir: dir)
        // Meta with no key decodes un-archived.
        XCTAssertNil(SessionArchive.readMeta(dir: dir)?.archived)

        SessionArchive.setArchived(dir: dir, true)
        let flagged = try XCTUnwrap(SessionArchive.readMeta(dir: dir))
        XCTAssertEqual(flagged.archived, true)
        // The flip must not lose the rest of the identity card.
        XCTAssertEqual(flagged.rootSessionId, "sid-1")
        XCTAssertEqual(flagged.agent, "codex")

        // Un-archive encodes as key-absent (clean meta).
        SessionArchive.setArchived(dir: dir, false)
        XCTAssertNil(SessionArchive.readMeta(dir: dir)?.archived)
    }

    func testSetArchivedSynthesizesMinimalMetaWhenMissing() throws {
        let dir = try makeDir()
        SessionArchive.setArchived(dir: dir, true)
        let meta = try XCTUnwrap(SessionArchive.readMeta(dir: dir))
        XCTAssertEqual(meta.archived, true)
        XCTAssertEqual(meta.id, (dir as NSString).lastPathComponent)
        XCTAssertEqual(meta.name, meta.id)
    }

    // MARK: load + list (list and rebuild from the stable dir after restart)

    func testLoadReadsOrchestrationJsonl() throws {
        let dir = try makeDir()
        try sampleLines().joined(separator: "\n")
            .write(toFile: dir + "/orchestration.jsonl", atomically: true, encoding: .utf8)
        let s = try XCTUnwrap(SessionArchive.load(dir: dir))
        XCTAssertEqual(s.tree?.count, 3)
    }

    func testLoadMissingDirReturnsNil() {
        XCTAssertNil(SessionArchive.load(dir: NSTemporaryDirectory() + "vigil_no_such_\(UUID())"))
    }

    func testListFindsSessionsNewestFirstAndSkipsNonSessions() throws {
        let root = try makeDir()
        for (name, ts) in [("a-old", 1_800_000_000.0), ("b-new", 1_800_100_000.0)] {
            let d = root + "/" + name
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            try sampleLines().joined(separator: "\n")
                .write(toFile: d + "/orchestration.jsonl", atomically: true, encoding: .utf8)
            SessionArchive.writeMeta(
                SessionArchiveMeta(id: name, name: "task \(name)", projectName: "p",
                                   projectCwd: "/tmp/p", agent: "claude", model: nil,
                                   createdAt: Date(timeIntervalSince1970: ts)),
                dir: d)
        }
        // A dir with no orchestration.jsonl is not a session — never listed.
        try FileManager.default.createDirectory(atPath: root + "/junk",
                                                withIntermediateDirectories: true)

        let list = SessionArchive.list(root: root)
        XCTAssertEqual(list.map(\.id), ["b-new", "a-old"])
        XCTAssertEqual(list.first?.name, "task b-new")
        XCTAssertEqual(list.first?.dir, root + "/b-new")
    }

    func testListMissingRootIsEmpty() {
        XCTAssertEqual(SessionArchive.list(root: "/tmp/vigil_no_such_root_\(UUID())").count, 0)
    }

    // MARK: dir naming (session dir names under the stable dir — unique + human-readable)

    func testNewSessionDirNameIsUniqueAndSortable() {
        let a = SessionArchive.newSessionDirName()
        let b = SessionArchive.newSessionDirName()
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.contains("/"))
    }
}
