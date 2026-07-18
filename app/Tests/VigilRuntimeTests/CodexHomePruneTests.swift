import Foundation
import XCTest
import VigilCore
@testable import VigilRuntime

/// Per-node CODEX_HOME isolation is a config + rollout-attribution boundary, but codex
/// 0.144+ also treats its home as a CACHE root: every cold start re-downloads ~38MB of
/// node-agnostic bytes (curated plugin templates + catalog caches + logs sqlite) that the
/// isolation then multiplies per worker. The prune deletes exactly those re-downloadable
/// caches from DEAD sessions; everything resume/afterlife reads survives: sessions/
/// (rollout = resume credential + transcript pointer), config.toml, hooks.json, the
/// auth.json symlink, state/history.
final class CodexHomePruneTests: XCTestCase {

    private var dir = ""

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "vigil_prune_\(getpid())_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// A realistic per-node codex-home under `<session>/config/<node>/codex-home`, shaped
    /// like a real codex 0.144 one (cache dirs + logs sqlite triplet + keepers).
    @discardableResult
    private func makeCodexHome(session: String, node: String) throws -> String {
        let home = "\(session)/config/\(node)/codex-home"
        let fm = FileManager.default
        for d in ["plugins/cache/openai-curated-remote", "cache/remote_plugin_catalog",
                  "sessions/2026/07/13", "shell_snapshots"] {
            try fm.createDirectory(atPath: "\(home)/\(d)", withIntermediateDirectories: true)
        }
        try "pptx".write(toFile: "\(home)/plugins/cache/openai-curated-remote/reference.pptx",
                         atomically: true, encoding: .utf8)
        try "catalog".write(toFile: "\(home)/cache/remote_plugin_catalog/e35.json",
                            atomically: true, encoding: .utf8)
        for f in ["logs_2.sqlite", "logs_2.sqlite-wal", "logs_2.sqlite-shm"] {
            try "log".write(toFile: "\(home)/\(f)", atomically: true, encoding: .utf8)
        }
        try "rollout".write(toFile: "\(home)/sessions/2026/07/13/rollout-x.jsonl",
                            atomically: true, encoding: .utf8)
        for f in ["config.toml", "hooks.json", "state_5.sqlite", "memories_1.sqlite",
                  "history.jsonl", "version.json"] {
            try "keep".write(toFile: "\(home)/\(f)", atomically: true, encoding: .utf8)
        }
        return home
    }

    private func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

    // MARK: pruneNodeHome — the delete set is EXACTLY {plugins/, cache/, logs_*.sqlite*}

    func testPruneNodeHomeDeletesOnlyRedownloadableCaches() throws {
        let home = try makeCodexHome(session: dir, node: "n1")
        let freed = CodexHomePrune.pruneNodeHome(home)

        XCTAssertGreaterThan(freed, 0, "deleted bytes must be reported")
        XCTAssertFalse(exists("\(home)/plugins"))
        XCTAssertFalse(exists("\(home)/cache"))
        XCTAssertFalse(exists("\(home)/logs_2.sqlite"))
        XCTAssertFalse(exists("\(home)/logs_2.sqlite-wal"))
        XCTAssertFalse(exists("\(home)/logs_2.sqlite-shm"))

        // Resume credential + injected config + codex's own state all survive.
        XCTAssertTrue(exists("\(home)/sessions/2026/07/13/rollout-x.jsonl"))
        for f in ["config.toml", "hooks.json", "state_5.sqlite", "memories_1.sqlite",
                  "history.jsonl", "version.json", "shell_snapshots"] {
            XCTAssertTrue(exists("\(home)/\(f)"), "\(f) must be kept")
        }
    }

    func testAuthSymlinkSurvivesAndTargetIsUntouched() throws {
        let home = try makeCodexHome(session: dir, node: "n1")
        let realAuth = dir + "/real-auth.json"
        try "secret".write(toFile: realAuth, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: "\(home)/auth.json",
                                                   withDestinationPath: realAuth)

        CodexHomePrune.pruneNodeHome(home)

        // The link stays a link, the user's real credential file is never touched.
        let attrs = try FileManager.default.attributesOfItem(atPath: "\(home)/auth.json")
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(try String(contentsOfFile: realAuth, encoding: .utf8), "secret")
    }

    func testPruneIsIdempotent() throws {
        let home = try makeCodexHome(session: dir, node: "n1")
        XCTAssertGreaterThan(CodexHomePrune.pruneNodeHome(home), 0)
        XCTAssertEqual(CodexHomePrune.pruneNodeHome(home), 0, "second run finds nothing")
        // A home that never existed is a no-op, not an error.
        XCTAssertEqual(CodexHomePrune.pruneNodeHome(dir + "/nope/codex-home"), 0)
    }

    // MARK: pruneSession — walks config/*/codex-home, other families' node dirs untouched

    func testPruneSessionTouchesOnlyCodexHomes() throws {
        let codexHome = try makeCodexHome(session: dir, node: "n2")
        // Sibling node dirs of the other families (claude settings / opencode plugin).
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir + "/config/n1", withIntermediateDirectories: true)
        try "cfg".write(toFile: dir + "/config/n1/settings.json", atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: dir + "/config/n3", withIntermediateDirectories: true)
        try "js".write(toFile: dir + "/config/n3/oc-plugin.js", atomically: true, encoding: .utf8)

        let freed = CodexHomePrune.pruneSession(dir: dir)

        XCTAssertGreaterThan(freed, 0)
        XCTAssertFalse(exists("\(codexHome)/plugins"))
        XCTAssertTrue(exists("\(codexHome)/sessions"))
        XCTAssertTrue(exists(dir + "/config/n1/settings.json"))
        XCTAssertTrue(exists(dir + "/config/n3/oc-plugin.js"))
    }

    // MARK: pruneAllDead — the startup sweep never touches a session held live

    func testPruneAllDeadSparesLiveSessionsAndSweepsDeadOnes() throws {
        let fm = FileManager.default
        let dead = dir + "/s-dead", live = dir + "/s-live"
        for s in [dead, live] {
            try fm.createDirectory(atPath: s, withIntermediateDirectories: true)
            try "{}".write(toFile: s + "/orchestration.jsonl", atomically: true, encoding: .utf8)
        }
        let deadHome = try makeCodexHome(session: dead, node: "n1")
        let liveHome = try makeCodexHome(session: live, node: "n1")
        // A stray dir without orchestration.jsonl is not a session — never entered.
        let stray = dir + "/not-a-session"
        _ = try makeCodexHome(session: stray, node: "n1")

        let freed = CodexHomePrune.pruneAllDead(root: dir, isLive: { $0 == live })

        XCTAssertGreaterThan(freed, 0)
        XCTAssertFalse(exists("\(deadHome)/plugins"), "dead session is swept")
        XCTAssertTrue(exists("\(liveHome)/plugins"), "live session is never touched")
        XCTAssertTrue(exists("\(stray)/config/n1/codex-home/plugins"),
                      "non-session dirs are not entered")
    }

    // MARK: session death — Orchestrator.stop() prunes after the cells are down

    @MainActor
    func testOrchestratorStopPrunesCodexCaches() async throws {
        let sess = dir + "/sess"
        let root = Node(id: NodeID("root"), role: .manager, status: .running, title: "mgr")
        let orch = Orchestrator(rootNode: root, harness: FakeHarness(),
                                sessionDir: sess) { _ in FakeBackend() }
        try orch.start(rootTask: "")
        let home = try makeCodexHome(session: sess, node: "n1")

        orch.stop()

        // stop() prunes after the async cell terminations — poll briefly.
        for _ in 0..<200 where exists("\(home)/plugins") {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(exists("\(home)/plugins"))
        XCTAssertFalse(exists("\(home)/cache"))
        XCTAssertTrue(exists("\(home)/sessions/2026/07/13/rollout-x.jsonl"),
                      "resume credential survives session death")
        XCTAssertTrue(exists("\(home)/config.toml"))
    }
}
