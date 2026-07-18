import XCTest
import VigilCore
import VigilRuntime
@testable import VigilApp

/// App-layer coverage: the root-only MCP tool fires `Orchestrator.onSessionRename`,
/// which must apply the name to the session label, pin it as user-chosen so automatic naming
/// yields, and persist the pin across resume. These scenarios use a codex root because it also
/// has a deterministic first-message fallback to suppress; the MCP surface for all root kinds
/// is pinned by GatewayTests.
@MainActor
final class CodexRenameTests: XCTestCase {

    /// A user config dir whose registry resolves `agentKey: "codex"` to a codex-kind root.
    private func codexConfigDir() -> String {
        let dir = NSTemporaryDirectory() + "vigil-codex-rename-cfg-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? #"{ "agents": { "codex": { "bin": "/usr/bin/true", "kind": "codex" } } }"#
            .write(toFile: dir + "/agents.json", atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    private func makeCodexVM(name: String) -> SessionVM {
        let arch = NSTemporaryDirectory() + "vigil-codex-rename-arch-\(UUID().uuidString.prefix(8))"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: arch) }
        let vm = SessionVM(id: "cr-\(UUID().uuidString.prefix(6))", name: name,
                           rootCwd: NSTemporaryDirectory(), initialTask: "task",
                           agentKey: "codex", userConfigDir: codexConfigDir(),
                           archiveDir: arch)
        XCTAssertEqual(vm.rootKind, .codex, "registry codex entry → root is the codex family")
        return vm
    }

    /// A minimal codex rollout whose first user_message would auto-name the session, so a
    /// suppression test can prove the pin actually blocks it (not that codex naming is broken).
    private func writeRollout(firstMessage: String) -> String {
        let path = NSTemporaryDirectory() + "vigil-codex-rename-rollout-\(UUID().uuidString).jsonl"
        let meta = #"{"type":"session_meta","payload":{"session_id":"019f-x","thread_source":"user"}}"#
        let msg = #"{"type":"event_msg","payload":{"type":"user_message","message":"\#(firstMessage)"}}"#
        try? ([meta, msg].joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testRenameToolAppliesNamePinsCustomAndPersists() throws {
        let vm = makeCodexVM(name: "ugly name truncated on first-line input")
        defer { vm.shutdown() }
        XCTAssertFalse(vm.userNamed)

        // Simulate the MCP rename tool firing onRename for the root (trim + clamp on apply).
        vm.orch.onSessionRename?(vm.store.tree.rootID, "  refactor auth module  ")
        XCTAssertEqual(vm.name, "refactor auth module", "session name becomes the agent-chosen name (trimmed)")
        XCTAssertTrue(vm.userNamed, "rename pins custom (AutoNamer yields)")

        // Persisted to meta.json so a resume restores both name and the custom pin.
        let meta = try XCTUnwrap(SessionArchive.readMeta(dir: vm.archiveDir))
        XCTAssertEqual(meta.name, "refactor auth module")
        XCTAssertEqual(meta.nameIsCustom, true)
    }

    func testRenameClampsLongName() throws {
        let vm = makeCodexVM(name: "old name")
        defer { vm.shutdown() }
        vm.orch.onSessionRename?(vm.store.tree.rootID, String(repeating: "字", count: 80))
        XCTAssertEqual(vm.name, String(repeating: "字", count: 50), "consistent with the existing naming clamp (50)")
    }

    func testRenameOnNonRootNodeIsIgnored() throws {
        let vm = makeCodexVM(name: "root name")
        defer { vm.shutdown() }
        // Defensive: the tool is root-scoped, but the app guard must also ignore a non-root id.
        vm.orch.onSessionRename?(NodeID("not-root"), "another name")
        XCTAssertEqual(vm.name, "root name")
        XCTAssertFalse(vm.userNamed)
    }

    func testCodexAutoNameYieldsToCustomRename() async throws {
        RuntimeTuning.current = RuntimeTuning()          // autoName defaults true — pin must still win
        let vm = makeCodexVM(name: "launch prefix")
        defer { vm.shutdown() }
        let root = vm.store.tree.rootID

        // Pin a custom name first, THEN a codex capture arrives whose first message differs.
        vm.orch.onSessionRename?(root, "my custom name")
        XCTAssertTrue(vm.userNamed)
        vm.orch.onCodexRollout?(root, writeRollout(firstMessage: "this is the first user message that would be used as the name"))

        // considerCodex runs off-main; give it well past a real apply window, then assert no change.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(vm.name, "my custom name", "after the custom pin, considerCodex silently skips and does not revert")
    }

    func testCodexAutoNameAppliesWithoutRename_positiveControl() async throws {
        RuntimeTuning.current = RuntimeTuning()
        let vm = makeCodexVM(name: "launch prefix")
        defer { vm.shutdown() }
        let root = vm.store.tree.rootID

        // No rename → the same capture DOES auto-name (proves the suppression above is real).
        vm.orch.onCodexRollout?(root, writeRollout(firstMessage: "review bugs codex collected"))
        for _ in 0..<100 where vm.name != "review bugs codex collected" {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(vm.name, "review bugs codex collected", "with no rename, the first-message fallback names it as usual")
        XCTAssertFalse(vm.userNamed)
    }

    func testResumeRestoresCustomPin() throws {
        // A resumed incarnation seeds userNamed from meta.nameIsCustom so the codex fallback
        // keeps yielding — without this the next capture would clobber the chosen name.
        let vm = SessionVM(id: "cr-resume", name: "custom name", rootCwd: NSTemporaryDirectory(),
                           initialTask: "", agentKey: "codex", userConfigDir: codexConfigDir(),
                           archiveDir: NSTemporaryDirectory() + "vigil-codex-resume-\(UUID().uuidString.prefix(6))",
                           resumeSessionId: "sid-1", createdAt: Date(), nameIsCustom: true)
        defer { vm.shutdown() }
        XCTAssertTrue(vm.userNamed, "resume restores the custom pin from meta.nameIsCustom")
    }
}
