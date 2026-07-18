import XCTest
import VigilCore
@testable import VigilRuntime
#if canImport(Darwin)
import Darwin
#endif

/// The per-node CODEX_HOME must be a VIEW of the user's real codex home (model default +
/// reasoning effort, their profiles, their own [mcp_servers.*], AGENTS.md / prompts) with
/// Vigil replacing ONLY what it owns — not an amnesiac from-zero config. If the user's
/// model default never makes it into the per-node home, a node silently falls back to the
/// codex builtin default model instead.
final class CodexConfigInheritTests: XCTestCase {

    // MARK: merge unit surface

    private let vigilTop = "approval_policy = \"never\"\nsandbox_mode = \"danger-full-access\"\n"
    private let vigilTables = """

    [projects."/w"]
    trust_level = "trusted"

    [mcp_servers.vigil]
    command = "/m"

    """

    private func merge(_ user: String?, cwd: String? = "/w") -> String {
        CodexConfigInherit.merged(user: user, vigilTopLevel: vigilTop,
                                  vigilTables: vigilTables, projectCwd: cwd)
    }

    /// One occurrence per assertion helper — "the vigil value won" claims need exactly-once.
    private func count(of needle: String, in s: String) -> Int {
        s.components(separatedBy: needle).count - 1
    }

    func testNoUserConfigYieldsPureVigilConfig() {
        XCTAssertEqual(merge(nil), vigilTop + vigilTables,
                       "no user config = the pre-inheritance from-zero config, byte-identical")
    }

    func testUserModelAndEffortInheritedAheadOfAnyTable() {
        let merged = merge("model = \"gpt-5.6-sol\"\nmodel_reasoning_effort = \"ultra\"\n")
        XCTAssertTrue(merged.contains("model = \"gpt-5.6-sol\""), "the 0716 incident key")
        XCTAssertTrue(merged.contains("model_reasoning_effort = \"ultra\""))
        // A top-level user key appearing AFTER a table header would silently join that table.
        let firstHeader = try! XCTUnwrap(merged.range(of: "\n[")).lowerBound
        let modelPos = try! XCTUnwrap(merged.range(of: "model = ")).lowerBound
        XCTAssertLessThan(modelPos, firstHeader,
                          "inherited top-level keys must stay ahead of the first table header")
    }

    func testOwnedKeysStrippedWhereverTheyAppear() {
        let merged = merge("""
        approval_policy = "on-request"
        model = "gpt-5.6-sol"

        [profiles.safe]
        approval_policy = "untrusted"
        model = "gpt-5-mini"
        """)
        XCTAssertEqual(count(of: "approval_policy", in: merged), 1,
                       "user tiers stripped everywhere (a [profiles.*] tier would outrank Vigil's top-level one); only Vigil's survives")
        XCTAssertTrue(merged.contains("approval_policy = \"never\""), "and it is Vigil's value")
        XCTAssertTrue(merged.contains("[profiles.safe]"), "the profile section itself survives")
        XCTAssertTrue(merged.contains("model = \"gpt-5-mini\""), "non-owned profile keys survive")
    }

    func testUserTrustEntryForSameCwdDroppedOthersKept() {
        let merged = merge("""
        [projects."/w"]
        trust_level = "untrusted"

        [projects."/elsewhere"]
        trust_level = "trusted"
        """)
        XCTAssertEqual(count(of: "[projects.\"/w\"]", in: merged), 1,
                       "exactly one entry for the node cwd — Vigil's")
        XCTAssertFalse(merged.contains("untrusted"),
                       "the user's (possibly untrusted) entry for the SAME cwd is dropped, or the trust box pops at turn zero")
        XCTAssertTrue(merged.contains("[projects.\"/elsewhere\"]"),
                      "the user's other project entries survive")
    }

    func testLiteralQuotedTrustHeaderStillMatched() {
        let merged = merge("[projects.'/w']\ntrust_level = \"untrusted\"\n")
        XCTAssertFalse(merged.contains("untrusted"),
                       "header matching is by decoded key, not by quoting style")
    }

    func testStaleVigilMcpDroppedUserServersSurvive() {
        let merged = merge("""
        [mcp_servers.vigil]
        command = "/stale/vigil-mcp"

        [mcp_servers.unity]
        command = "/u/unity-bridge"
        """)
        XCTAssertFalse(merged.contains("/stale/vigil-mcp"),
                       "a stale vigil wiring in the user config must not fight the per-node one")
        XCTAssertEqual(count(of: "[mcp_servers.vigil]", in: merged), 1)
        XCTAssertTrue(merged.contains("command = \"/m\""), "Vigil's wiring wins")
        XCTAssertTrue(merged.contains("[mcp_servers.unity]"),
                      "native-codex parity: the user's own MCP servers reach the node")
    }

    func testMultilineStringBodyIsOpaque() {
        let merged = merge("""
        banner = \"\"\"
        [projects."/w"]
        approval_policy = "decoy"
        \"\"\"
        note = "kept"
        """)
        XCTAssertTrue(merged.contains("approval_policy = \"decoy\""),
                      "lines inside a multi-line string are string BODY, not structure")
        XCTAssertTrue(merged.contains("[projects.\"/w\"]\napproval_policy = \"decoy\""),
                      "the decoy header inside the string survives verbatim")
        XCTAssertTrue(merged.contains("note = \"kept\""),
                      "filtering resumes after the string closes")
    }

    // MARK: harness integration — the per-node home is a view of the user's home

    func testCodexHomeInheritsUserConfigAndPassthroughAssets() throws {
        let base = NSTemporaryDirectory() + "vigil_codex_inherit_\(getpid())_\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let userHome = base + "/userhome", cfgRoot = base + "/cfgroot"
        try FileManager.default.createDirectory(atPath: userHome + "/prompts",
                                                withIntermediateDirectories: true)
        try """
        model = "gpt-5.6-sol"
        model_reasoning_effort = "ultra"
        approval_policy = "on-request"

        [mcp_servers.unity]
        command = "/u/unity-bridge"
        """.write(toFile: userHome + "/config.toml", atomically: true, encoding: .utf8)
        try "auth".write(toFile: userHome + "/auth.json", atomically: true, encoding: .utf8)
        try "global instructions".write(toFile: userHome + "/AGENTS.md", atomically: true, encoding: .utf8)

        let h = CodexHarness(codexBin: "/usr/bin/codex", hookBin: "/h", mcpBin: "/m",
                             configRoot: cfgRoot, printMode: false, permissionMode: .bypass,
                             userCodexHome: userHome)
        _ = h.launchSpec(task: "t", cwd: "/tmp/work", nodeID: NodeID("n1"),
                         role: .leaf, isRoot: false,
                         mcpEndpoint: "/s/m.sock", hookEndpoint: "/s/h.sock", idCred: "n1")

        let home = CodexHarness.codexHome(configRoot: cfgRoot, node: NodeID("n1"))
        let toml = try String(contentsOfFile: home + "/config.toml", encoding: .utf8)
        XCTAssertTrue(toml.contains("model = \"gpt-5.6-sol\""), "user model default inherited")
        XCTAssertTrue(toml.contains("model_reasoning_effort = \"ultra\""))
        XCTAssertTrue(toml.contains("[mcp_servers.unity]"), "user MCP servers inherited")
        XCTAssertTrue(toml.contains("[mcp_servers.vigil]"), "vigil wiring still present")
        XCTAssertTrue(toml.contains("approval_policy = \"never\""), "vigil tier wins")
        XCTAssertFalse(toml.contains("on-request"), "user tier stripped")

        for name in ["auth.json", "AGENTS.md", "prompts"] {
            let dst = home + "/" + name
            XCTAssertEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: dst),
                           userHome + "/" + name, "\(name) is a passthrough symlink, not a copy")
        }
    }

    func testPassthroughLinkRemovedWhenUserAssetDisappears() throws {
        let base = NSTemporaryDirectory() + "vigil_codex_dangling_\(getpid())_\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let userHome = base + "/userhome", cfgRoot = base + "/cfgroot"
        try FileManager.default.createDirectory(atPath: userHome, withIntermediateDirectories: true)
        try "global".write(toFile: userHome + "/AGENTS.md", atomically: true, encoding: .utf8)

        let h = CodexHarness(codexBin: "/usr/bin/codex", hookBin: "/h", mcpBin: "/m",
                             configRoot: cfgRoot, printMode: false, permissionMode: .bypass,
                             userCodexHome: userHome)
        let launch = { _ = h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n1"),
                                        role: .leaf, isRoot: false,
                                        mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1") }
        launch()
        let dst = CodexHarness.codexHome(configRoot: cfgRoot, node: NodeID("n1")) + "/AGENTS.md"
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: dst))

        try FileManager.default.removeItem(atPath: userHome + "/AGENTS.md")
        launch()   // re-launch (resume path re-writes the home)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: dst),
                     "a dangling passthrough link must not survive a re-launch")
    }
}
