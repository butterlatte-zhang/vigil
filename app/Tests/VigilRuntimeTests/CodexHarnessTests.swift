import XCTest
import VigilCore
@testable import VigilRuntime
#if canImport(Darwin)
import Darwin
#endif

/// The codex harness and the dispatch layer route each launch to the resolved entry's
/// CLI family. Mirrors HarnessTests' LaunchSpec-assertion style.
final class CodexHarnessTests: XCTestCase {

    private func codexHome(_ cfgRoot: String, _ node: String) -> String {
        cfgRoot + "/\(node)/codex-home"
    }

    private func readConfigToml(_ cfgRoot: String, _ node: String) throws -> String {
        try String(contentsOfFile: codexHome(cfgRoot, node) + "/config.toml", encoding: .utf8)
    }

    private func modelArg(_ spec: LaunchSpec) -> String? {
        spec.args.firstIndex(of: "-m").map { spec.args[$0 + 1] }
    }

    // MARK: codex launch surface

    func testCodexInteractiveLaunchSpecWiresPromptSkillHooksAndMcp() throws {
        let cfgRoot = NSTemporaryDirectory() + "vigil_codex_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        // userCodexHome pinned to a nonexistent dir: config.toml assertions must not depend
        // on the dev machine's real ~/.codex (inheritance is covered by its own tests).
        let h = CodexHarness(codexBin: "/usr/bin/codex", hookBin: "/opt/vigil-hook",
                             mcpBin: "/opt/vigil-mcp", configRoot: cfgRoot,
                             printMode: false, permissionMode: .bypass,
                             userCodexHome: cfgRoot + "/nouser")
        let spec = h.launchSpec(task: "do the thing", cwd: "/tmp/work",
                                nodeID: NodeID("n1"), role: .leaf, isRoot: false,
                                mcpEndpoint: "/s/mcp.sock", hookEndpoint: "/s/hook.sock",
                                idCred: "n1")

        // executable + interactive (no `exec`), hook trust bypass present
        XCTAssertEqual(spec.executable, "/usr/bin/codex")
        XCTAssertFalse(spec.args.contains("exec"), "product cell = interactive TUI, not exec")
        XCTAssertTrue(spec.args.contains("--dangerously-bypass-hook-trust"))
        // The first-turn prompt (skill folded ahead of the task) rides initialPrompt = PTY
        // injection, NOT argv — neither the task nor the skill leaks into `ps`/`pkill -f`.
        let prompt = try XCTUnwrap(spec.initialPrompt)
        XCTAssertFalse(spec.args.contains(prompt), "the prompt does not enter argv")
        XCTAssertFalse(spec.args.contains { $0.contains("do the thing") }, "the task does not enter argv")
        XCTAssertTrue(prompt.contains("worker"), "worker identity skill folded into prompt")
        XCTAssertTrue(prompt.contains("report(summary)"), "tool guidance present")
        XCTAssertTrue(prompt.contains("do the thing"), "task appended after the skill")
        // The ToolSearch self-heal line is claude-only (codex has no ToolSearch builtin) —
        // codex reuses ClaudeCodeHarness.skill() WITHOUT toolSearchRecovery, so it must not leak in.
        XCTAssertFalse(prompt.contains("ToolSearch"), "the recovery line is claude-only; it must not leak into the codex prompt")
        // codex gets its OWN lazy-tools recovery line instead (kind-gated in skill()) —
        // codex defers MCP schemas under a large tool surface; the line names the code-mode
        // ALL_TOOLS registry and the tool-search reload path so the cell self-heals at turn zero.
        XCTAssertTrue(prompt.contains("ALL_TOOLS"), "codex prompt carries the lazy-tools recovery line")

        // env: CODEX_HOME points at the per-node home; TERM forced
        XCTAssertEqual(spec.env["CODEX_HOME"], codexHome(cfgRoot, "n1"))
        XCTAssertEqual(spec.env["TERM"], "xterm-256color")

        // config.toml: fully-open profile + vigil MCP (same vigil-mcp binary as claude)
        let toml = try readConfigToml(cfgRoot, "n1")
        XCTAssertTrue(toml.contains("approval_policy = \"never\""))
        XCTAssertTrue(toml.contains("sandbox_mode = \"danger-full-access\""))
        XCTAssertTrue(toml.contains("[mcp_servers.vigil]"))
        XCTAssertTrue(toml.contains("command = \"/opt/vigil-mcp\""))
        XCTAssertTrue(toml.contains("args = [\"--node\", \"n1\", \"--sock\", \"/s/mcp.sock\"]"))
        // Vigil does not pin `[features] tool_search`; when the per-node home inherits the
        // user's MCP servers and the tool surface grows large, codex self-heals via the
        // skill text (codexLazyToolsRecoveryLine) instead of disabling the feature.
        XCTAssertFalse(toml.contains("tool_search"),
                       "codex config.toml must not pin tool_search")

        // hooks.json: same nested shape + vigil-hook contract as claude
        let hooksData = try Data(contentsOf: URL(fileURLWithPath:
            codexHome(cfgRoot, "n1") + "/hooks.json"))
        let hooks = try XCTUnwrap((try JSONSerialization.jsonObject(with: hooksData)
            as? [String: Any])?["hooks"] as? [String: Any])
        func hookCmd(_ event: String) -> String {
            let entry = (hooks[event] as? [[String: Any]])?.first
            return ((entry?["hooks"] as? [[String: Any]])?.first)?["command"] as? String ?? ""
        }
        XCTAssertTrue(hookCmd("UserPromptSubmit").contains("/opt/vigil-hook"))
        XCTAssertTrue(hookCmd("UserPromptSubmit").contains("--node n1"))
        XCTAssertTrue(hookCmd("UserPromptSubmit").contains("--event prompt"))
        XCTAssertTrue(hookCmd("PermissionRequest").contains("--event perm-request"))
        XCTAssertTrue(hookCmd("PostToolUse").contains("--event post-tool"))
        XCTAssertTrue(hookCmd("Stop").contains("--event stop"))
        // sock path POSIX single-quoted (metachar-safe, mirror claude)
        XCTAssertTrue(hookCmd("Stop").contains("--sock '/s/hook.sock'"))
    }

    func testCodexConfigPreseedsProjectTrust() throws {
        // Under a fresh per-node CODEX_HOME, codex 0.144+ pops "Do you trust the contents of
        // this directory?" before the composer appears, and the initialPrompt queues until a
        // human presses Enter. Permissions default to fully open, so Vigil pre-seeds
        // [projects."<cwd>"] trust_level="trusted" to close off the directory trust prompt at
        // spawn time. cwd is a path key, so it must be TOML-quote-escaped.
        let cfgRoot = NSTemporaryDirectory() + "vigil_codex_trust_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let h = CodexHarness(codexBin: "/usr/bin/codex", hookBin: "/h", mcpBin: "/m",
                             configRoot: cfgRoot, printMode: false, permissionMode: .bypass,
                             userCodexHome: cfgRoot + "/nouser")
        _ = h.launchSpec(task: "t", cwd: "/tmp/work", nodeID: NodeID("n1"),
                         role: .leaf, isRoot: false,
                         mcpEndpoint: "/s/m.sock", hookEndpoint: "/s/h.sock", idCred: "n1")
        let toml = try readConfigToml(cfgRoot, "n1")
        XCTAssertTrue(toml.contains("[projects.\"/tmp/work\"]"),
                      "config.toml must contain a trust entry for the current cwd")
        // trust_level belongs to that project table: trust_level = "trusted" must immediately follow the section header
        let seg = toml.components(separatedBy: "[projects.\"/tmp/work\"]").last ?? ""
        XCTAssertTrue(seg.contains("trust_level = \"trusted\""),
                      "the project section must declare trust_level = trusted")
    }

    func testCodexProjectTrustKeyIsTomlEscaped() throws {
        // Path-key TOML escaping: when cwd contains " / \, the basic-string quoting must escape every character so config.toml doesn't blow up.
        let cfgRoot = NSTemporaryDirectory() + "vigil_codex_trustesc_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let nasty = #"/Users/z z/Dev"work"\proj"#
        let h = CodexHarness(codexBin: "/usr/bin/codex", hookBin: "/h", mcpBin: "/m",
                             configRoot: cfgRoot, printMode: false, permissionMode: .bypass,
                             userCodexHome: cfgRoot + "/nouser")
        _ = h.launchSpec(task: "t", cwd: nasty, nodeID: NodeID("n1"),
                         role: .leaf, isRoot: false,
                         mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        let toml = try readConfigToml(cfgRoot, "n1")
        let expectedKey = CodexHarness.tomlString(nasty)         // "\"...\\\"...\\\\...\""
        XCTAssertTrue(toml.contains("[projects.\(expectedKey)]"),
                      "the path key must use the same TOML basic-string escaping as the value")
    }

    func testCodexPrintModeUsesExecSubcommand() {
        let cfgRoot = NSTemporaryDirectory() + "vigil_codex_exec_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let h = CodexHarness(codexBin: "/c/codex", hookBin: "/h", mcpBin: "/m",
                             configRoot: cfgRoot, printMode: true, permissionMode: .bypass)
        let spec = h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n1"),
                                role: .leaf, isRoot: false,
                                mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        XCTAssertEqual(spec.args.first, "exec", "headless = codex exec")
    }

    func testCodexResumeUsesResumeSubcommand() {
        let cfgRoot = NSTemporaryDirectory() + "vigil_codex_resume_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let h = CodexHarness(codexBin: "/c/codex", hookBin: "/h", mcpBin: "/m",
                             configRoot: cfgRoot, printMode: false)
        let spec = h.launchSpec(task: "", cwd: "/w", nodeID: NodeID("n1"),
                                role: .leaf, isRoot: false, resumeSessionId: "sid-42",
                                mcpEndpoint: "/s/m", hookEndpoint: "/s/h", idCred: "n1")
        XCTAssertEqual(Array(spec.args.prefix(2)), ["resume", "sid-42"])
        XCTAssertTrue(spec.args.contains("--dangerously-bypass-hook-trust"))
        // resume does not inject the task/skill positional (context lives on the codex side)
        XCTAssertFalse(spec.args.contains { $0.contains("worker") })
    }

    /// resume's launchSpec still calls writeCodexHome (refreshing config/hooks), but it must
    /// never wipe out the previous life's rollout — `codex resume <sid>` relies on that
    /// rollout under sessions/ in the same CODEX_HOME to recover context. And resume's
    /// CODEX_HOME must equal the codexHome used at capture time (same node id).
    func testCodexResumePreservesRolloutAndPointsSameHome() throws {
        let cfgRoot = NSTemporaryDirectory() + "vigil_codex_resume_home_\(getpid())_\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let home = CodexHarness.codexHome(configRoot: cfgRoot, node: NodeID("n1"))
        // Previous life's rollout (turn already persisted) — resume must preserve it.
        let rolloutDir = home + "/sessions/2026/07/10"
        try FileManager.default.createDirectory(atPath: rolloutDir, withIntermediateDirectories: true)
        let rollout = rolloutDir + "/rollout-2026-07-10T16-28-05-019f4b24-1b04-7ce0-9059-7da727c56bf3.jsonl"
        try #"{"type":"session_meta","payload":{"session_id":"019f4b24-1b04-7ce0-9059-7da727c56bf3"}}"#
            .write(toFile: rollout, atomically: true, encoding: .utf8)

        let h = CodexHarness(codexBin: "/c/codex", hookBin: "/h", mcpBin: "/m",
                             configRoot: cfgRoot, printMode: false)
        let spec = h.launchSpec(task: "", cwd: "/w", nodeID: NodeID("n1"),
                                role: .leaf, isRoot: false,
                                resumeSessionId: "019f4b24-1b04-7ce0-9059-7da727c56bf3",
                                mcpEndpoint: "/s/m", hookEndpoint: "/s/h", idCred: "n1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rollout),
                      "resume's writeCodexHome must never wipe the previous life's rollout")
        XCTAssertEqual(spec.env["CODEX_HOME"], home, "resume CODEX_HOME = the same home as at capture time")
    }

    func testCodexPermissionMappingGuardedByDefault() throws {
        let cfgRoot = NSTemporaryDirectory() + "vigil_codex_perm_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let h = CodexHarness(codexBin: "/c/codex", hookBin: "/h", mcpBin: "/m",
                             configRoot: cfgRoot, printMode: false, permissionMode: .standard,
                             userCodexHome: cfgRoot + "/nouser")
        _ = h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n1"), role: .leaf, isRoot: false,
                         mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        let toml = try readConfigToml(cfgRoot, "n1")
        XCTAssertTrue(toml.contains("approval_policy = \"on-request\""))
        XCTAssertTrue(toml.contains("sandbox_mode = \"workspace-write\""))
    }

    func testCodexModelFlowsThroughDashM() {
        let cfgRoot = NSTemporaryDirectory() + "vigil_codex_model_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let h = CodexHarness(codexBin: "/c/codex", hookBin: "/h", mcpBin: "/m",
                             configRoot: cfgRoot, printMode: false, model: "gpt-5-codex")
        let inherited = h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n1"),
                                     role: .leaf, isRoot: false, model: nil,
                                     mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        XCTAssertEqual(modelArg(inherited), "gpt-5-codex")
        let overridden = h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n2"),
                                      role: .leaf, isRoot: false, model: "o3",
                                      mcpEndpoint: nil, hookEndpoint: nil, idCred: "n2")
        XCTAssertEqual(modelArg(overridden), "o3")
    }

    func testCodexRegistryEntryDrivesBinEnvExtraArgs() {
        // A codex-kind registry entry: bin/env/extraArgs applied, ~ expanded.
        let base = NSTemporaryDirectory() + "vigil_codex_reg_\(getpid())"
        let cfg = base + "/config", cwd = base + "/proj"
        try? FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let agents = """
        { "agents": { "codex": {
            "bin": "~/bin/codex", "kind": "codex", "defaultModel": "gpt-5-codex",
            "extraArgs": ["--search"], "env": { "OPENAI_BASE_URL": "https://relay.example" } } } }
        """
        try? agents.write(toFile: cfg + "/agents.json", atomically: true, encoding: .utf8)
        let cfgRoot = base + "/cfgroot"
        let h = CodexHarness(codexBin: "/fallback/codex", hookBin: "/h", mcpBin: "/m",
                             configRoot: cfgRoot, printMode: false,
                             userConfigDir: cfg, agentKey: "codex")
        let spec = h.launchSpec(task: "t", cwd: cwd, nodeID: NodeID("n1"),
                                role: .leaf, isRoot: false,
                                mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        XCTAssertEqual(spec.executable, NSHomeDirectory() + "/bin/codex", "bin must have ~ expanded")
        XCTAssertEqual(spec.env["OPENAI_BASE_URL"], "https://relay.example", "endpoint env injected")
        XCTAssertTrue(spec.args.contains("--search"), "extraArgs appended")
        XCTAssertEqual(modelArg(spec), "gpt-5-codex", "entry.defaultModel fallback")
    }

    // MARK: - model family namespace (a codex root must not pick up a claude alias)

    /// Throwaway config dir: agents.json registers both families + a given roles.json.
    private func makeConfig(_ tag: String, roles: String) -> (cfg: String, cfgRoot: String) {
        let base = NSTemporaryDirectory() + "vigil_codex_47_\(tag)_\(getpid())"
        let cfg = base + "/config"
        try? FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: base) }
        let agents = """
        { "agents": {
            "claude": { "bin": "/real/claude" },
            "codex":  { "bin": "/real/codex", "kind": "codex" } } }
        """
        try? agents.write(toFile: cfg + "/agents.json", atomically: true, encoding: .utf8)
        try? roles.write(toFile: cfg + "/roles.json", atomically: true, encoding: .utf8)
        return (cfg, base + "/cfgroot")
    }

    private func rootSpec(_ cfg: String, _ cfgRoot: String) -> LaunchSpec {
        let h = CodexHarness(codexBin: "/fallback/codex", hookBin: "/h", mcpBin: "/m",
                             configRoot: cfgRoot, printMode: false,
                             userConfigDir: cfg, agentKey: "codex")
        return h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("root"),
                            role: .manager, isRoot: true,
                            mcpEndpoint: nil, hookEndpoint: nil, idCred: "root")
    }

    func testCodexIgnoresClaudeBareRoleModel() {
        // roles.root.model bare string carrying a claude alias + launcher picks codex →
        // `codex -m <claude-alias>` → backend 400 rejection. A bare string defaults to the
        // claude family; the codex side must treat it as unconfigured.
        let (cfg, cfgRoot) = makeConfig("fable", roles: #"{ "root": { "model": "fable" } }"#)
        XCTAssertNil(modelArg(rootSpec(cfg, cfgRoot)),
                     "a claude alias must not leak into codex argv; no config for this family = no -m passed")
    }

    func testCodexModelMapHitsOwnFamily() {
        let (cfg, cfgRoot) = makeConfig("map", roles:
            #"{ "root": { "model": { "claude": "fable", "codex": "gpt-5.1-codex-max" } } }"#)
        XCTAssertEqual(modelArg(rootSpec(cfg, cfgRoot)), "gpt-5.1-codex-max")
    }

    func testCodexLegacyBareModelBoundToCodexRoleAgent() {
        // Positive compatibility case: worker.agent=codex + a bare string → the bare string belongs to the codex family, so it still applies normally (old configs aren't broken)
        let (cfg, cfgRoot) = makeConfig("bare", roles:
            #"{ "worker": { "agent": "codex", "model": "gpt-5.1-codex" } }"#)
        let h = CodexHarness(codexBin: "/fallback/codex", hookBin: "/h", mcpBin: "/m",
                             configRoot: cfgRoot, printMode: false,
                             userConfigDir: cfg, agentKey: "claude")
        let spec = h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n1"),
                                role: .leaf, isRoot: false,
                                mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        XCTAssertEqual(modelArg(spec), "gpt-5.1-codex")
    }

    // MARK: - bare-string model family anchoring across field-level cross-layer merges

    /// Global worker{agent:"claude", model:<claude-alias>} + project .vigil worker{agent:"codex"}:
    /// after the field-level override swaps out the agent, the underlying bare-string model
    /// was written under the claude declaration and must not migrate into the codex family's
    /// argv — a mismatched family would hand a claude alias to `codex -m`, rejected by the
    /// backend.
    func testProjectAgentSwapDoesNotMigrateGlobalBareModel() {
        let (cfg, cfgRoot) = makeConfig("xlayer", roles:
            #"{ "worker": { "agent": "claude", "model": "opus" } }"#)
        let base = (cfg as NSString).deletingLastPathComponent
        let cwd = base + "/proj"
        try? FileManager.default.createDirectory(atPath: cwd + "/.vigil",
                                                 withIntermediateDirectories: true)
        try? #"{ "worker": { "agent": "codex" } }"#
            .write(toFile: cwd + "/.vigil/roles.json", atomically: true, encoding: .utf8)
        let h = CodexHarness(codexBin: "/fallback/codex", hookBin: "/h", mcpBin: "/m",
                             configRoot: cfgRoot, printMode: false,
                             userConfigDir: cfg, agentKey: "claude")
        let spec = h.launchSpec(task: "t", cwd: cwd, nodeID: NodeID("n1"),
                                role: .leaf, isRoot: false,
                                mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        XCTAssertNil(modelArg(spec),
                     "after switching family across layers, a lower-level bare-string model must not migrate — it is anchored to the agent family of the layer that declared it")
    }

    /// Positive anchoring case: the project layer writes a bare-string model on its own (agent
    /// is inherited from the global layer) — the anchor is the agent in effect when the model
    /// was written (global codex), so it still flows into the codex argv normally. This guard
    /// only blocks "a higher layer swapping agent re-anchors the model beneath it"; it does not
    /// touch "writing a model under an already-established lower-layer agent context."
    func testProjectBareModelBindsToInheritedAgentFamily() {
        let (cfg, cfgRoot) = makeConfig("projmodel", roles:
            #"{ "worker": { "agent": "codex" } }"#)
        let base = (cfg as NSString).deletingLastPathComponent
        let cwd = base + "/proj"
        try? FileManager.default.createDirectory(atPath: cwd + "/.vigil",
                                                 withIntermediateDirectories: true)
        try? #"{ "worker": { "model": "gpt-5.1-codex-max" } }"#
            .write(toFile: cwd + "/.vigil/roles.json", atomically: true, encoding: .utf8)
        let h = CodexHarness(codexBin: "/fallback/codex", hookBin: "/h", mcpBin: "/m",
                             configRoot: cfgRoot, printMode: false,
                             userConfigDir: cfg, agentKey: "claude")
        let spec = h.launchSpec(task: "t", cwd: cwd, nodeID: NodeID("n1"),
                                role: .leaf, isRoot: false,
                                mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        XCTAssertEqual(modelArg(spec), "gpt-5.1-codex-max",
                       "a project-level model is anchored to the global agent family in effect when it was declared")
    }

    /// Reverse guardrail: the project layer swaps to another entry within the same family
    /// (claude → claude relay), so the bare-string model's family is unchanged and must be
    /// preserved — anchoring compares by family, not by registry key.
    func testProjectAgentSwapWithinFamilyKeepsBareModel() {
        let base = NSTemporaryDirectory() + "vigil_codex_53same_\(getpid())"
        let cfg = base + "/config", cwd = base + "/proj"
        try? FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: cwd + "/.vigil",
                                                 withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: base) }
        let agents = """
        { "agents": {
            "claude":       { "bin": "/real/claude" },
            "claude-relay": { "bin": "/relay/claude", "kind": "claude" },
            "codex":        { "bin": "/real/codex", "kind": "codex" } } }
        """
        try? agents.write(toFile: cfg + "/agents.json", atomically: true, encoding: .utf8)
        try? #"{ "worker": { "agent": "claude", "model": "opus" } }"#
            .write(toFile: cfg + "/roles.json", atomically: true, encoding: .utf8)
        try? #"{ "worker": { "agent": "claude-relay" } }"#
            .write(toFile: cwd + "/.vigil/roles.json", atomically: true, encoding: .utf8)
        let h = ClaudeCodeHarness(claudeBin: "/fallback/claude", hookBin: "/h", mcpBin: "/m",
                                  configRoot: base + "/cfgroot", printMode: true,
                                  userConfigDir: cfg, agentKey: "claude")
        let spec = h.launchSpec(task: "t", cwd: cwd, nodeID: NodeID("n1"),
                                role: .leaf, isRoot: false,
                                mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        let mIdx = spec.args.firstIndex(of: "--model")
        XCTAssertEqual(mIdx.map { spec.args[$0 + 1] }, "opus",
                       "switching entries within the same family does not lose the bare-string model — compare by family, not by registry key")
    }

    func testRolesAccessOverridesSessionDefault() throws {
        // session default guarded (.standard → on-request); roles.json opens the
        // worker to bypass → codex fully-open profile (never / danger-full-access).
        let base = NSTemporaryDirectory() + "vigil_codex_access_\(getpid())"
        let cfg = base + "/config", cwd = base + "/proj"
        try? FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        try? #"{ "worker": { "access": "bypass" } }"#
            .write(toFile: cfg + "/roles.json", atomically: true, encoding: .utf8)
        let cfgRoot = base + "/cfgroot"
        let h = CodexHarness(codexBin: "/c/codex", hookBin: "/h", mcpBin: "/m",
                             configRoot: cfgRoot, printMode: false, permissionMode: .standard,
                             userConfigDir: cfg, agentKey: "codex",
                             userCodexHome: cfgRoot + "/nouser")
        _ = h.launchSpec(task: "t", cwd: cwd, nodeID: NodeID("n1"), role: .leaf, isRoot: false,
                         mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        let toml = try readConfigToml(cfgRoot, "n1")
        XCTAssertTrue(toml.contains("approval_policy = \"never\""), "worker.access=bypass → wide open")
        XCTAssertTrue(toml.contains("sandbox_mode = \"danger-full-access\""))
    }

    // MARK: dispatch layer

    /// The two-kind tree: a claude root + a codex worker, resolved per launch and routed to
    /// the matching harness.
    func testDispatchRoutesByResolvedEntryKind() throws {
        let base = NSTemporaryDirectory() + "vigil_dispatch_\(getpid())"
        let cfg = base + "/config", cwd = base + "/proj"
        try? FileManager.default.createDirectory(atPath: cfg + "/.vigil", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let agents = """
        { "agents": {
            "claude": { "bin": "/real/claude", "kind": "claude" },
            "codex":  { "bin": "/real/codex",  "kind": "codex" } } }
        """
        let roles = #"{ "worker": { "agent": "codex" } }"#
        try? agents.write(toFile: cfg + "/agents.json", atomically: true, encoding: .utf8)
        try? roles.write(toFile: cfg + "/roles.json", atomically: true, encoding: .utf8)

        let h = DispatchHarness(claudeBin: "/fallback/claude", codexBin: "/fallback/codex",
                                opencodeBin: "/fallback/opencode",
                                hookBin: "/h", mcpBin: "/m", configRoot: base + "/cfgroot",
                                printMode: false, userConfigDir: cfg, agentKey: "claude")

        // root → claude family. It preserves the inherited process environment but must not
        // synthesize/replace CODEX_HOME; only the codex worker below owns a per-node home.
        let root = h.launchSpec(task: "t", cwd: cwd, nodeID: NodeID("root"),
                                role: .manager, isRoot: true,
                                mcpEndpoint: "/s/m", hookEndpoint: "/s/h", idCred: "root")
        XCTAssertEqual(root.executable, "/real/claude")
        XCTAssertTrue(root.args.contains("--append-system-prompt"), "claude launch surface")
        XCTAssertEqual(root.env["CODEX_HOME"], ProcessInfo.processInfo.environment["CODEX_HOME"])

        // worker with role.agent="codex" → codex family
        let worker = h.launchSpec(task: "t", cwd: cwd, nodeID: NodeID("w1"),
                                  role: .leaf, isRoot: false,
                                  mcpEndpoint: "/s/m", hookEndpoint: "/s/h", idCred: "w1")
        XCTAssertEqual(worker.executable, "/real/codex")
        XCTAssertTrue(worker.args.contains("--dangerously-bypass-hook-trust"), "codex launch surface")
        XCTAssertEqual(worker.env["CODEX_HOME"], codexHome(base + "/cfgroot", "w1"),
                       "the codex route must replace any inherited value with its per-node home")
        XCTAssertFalse(worker.args.contains("--append-system-prompt"), "not a claude launch")
    }

    func testDispatchNoRegistryFallsToClaude() {
        // No userConfigDir → registry nil → kind .claude → the claude sub-harness (the
        // smoke / test path, byte-identical to a bare ClaudeCodeHarness).
        let cfgRoot = NSTemporaryDirectory() + "vigil_dispatch_fb_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let h = DispatchHarness(claudeBin: "/c/claude", codexBin: "/c/codex",
                                opencodeBin: "/c/opencode",
                                hookBin: "/h", mcpBin: "/m", configRoot: cfgRoot, printMode: true)
        let spec = h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n1"),
                                role: .leaf, isRoot: false,
                                mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        XCTAssertEqual(spec.executable, "/c/claude")
        XCTAssertTrue(spec.args.contains("-p"), "claude print mode")
        XCTAssertEqual(spec.env["CODEX_HOME"], ProcessInfo.processInfo.environment["CODEX_HOME"],
                       "the Claude fallback preserves, but does not synthesize, inherited env")
    }
}
