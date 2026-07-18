import XCTest
import VigilCore
@testable import VigilRuntime
#if canImport(Darwin)
import Darwin
#endif

/// The opencode harness (everything via OPENCODE_CONFIG_CONTENT + one plugin file)
/// and its routing through the dispatch layer.
final class OpenCodeHarnessTests: XCTestCase {

    private func config(_ spec: LaunchSpec) throws -> [String: Any] {
        let json = try XCTUnwrap(spec.env["OPENCODE_CONFIG_CONTENT"])
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testInteractiveLaunchWiresAgentAutoConfigContentAndPluginEnv() throws {
        let cfgRoot = NSTemporaryDirectory() + "vigil_oc_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let h = OpenCodeHarness(opencodeBin: "/usr/bin/opencode", hookBin: "/opt/vigil-hook",
                                mcpBin: "/opt/vigil-mcp", configRoot: cfgRoot,
                                printMode: false, permissionMode: .bypass)
        let spec = h.launchSpec(task: "do the thing", cwd: "/tmp/work",
                                nodeID: NodeID("n1"), role: .leaf, isRoot: false,
                                mcpEndpoint: "/s/mcp.sock", hookEndpoint: "/s/hook.sock",
                                idCred: "n1")

        XCTAssertEqual(spec.executable, "/usr/bin/opencode")
        XCTAssertFalse(spec.args.contains("run"), "product cell = TUI, not headless run")
        // --agent worker, --auto (bypass fully-open). The task rides initialPrompt
        // (PTY injection), NOT `--prompt` — it must not appear in argv (the ps/pkill blast radius).
        XCTAssertEqual(spec.args.firstIndex(of: "--agent").map { spec.args[$0 + 1] }, "worker")
        XCTAssertTrue(spec.args.contains("--auto"))
        XCTAssertFalse(spec.args.contains("--prompt"), "the task does not enter argv via --prompt")
        XCTAssertFalse(spec.args.contains("do the thing"), "the task does not enter argv")
        XCTAssertEqual(spec.initialPrompt, "do the thing", "the task is injected via the PTY")

        // OPENCODE_CONFIG_CONTENT: mcp.vigil (same vigil-mcp binary), plugin, this node's agent
        let cfg = try config(spec)
        let mcp = try XCTUnwrap((cfg["mcp"] as? [String: Any])?["vigil"] as? [String: Any])
        XCTAssertEqual(mcp["type"] as? String, "local")
        XCTAssertEqual(mcp["enabled"] as? Bool, true)
        // command array = mcpBin + node/sock (reuse the claude/codex vigil-mcp binary)
        XCTAssertEqual(mcp["command"] as? [String],
                       ["/opt/vigil-mcp", "--node", "n1", "--sock", "/s/mcp.sock"])
        let agent = try XCTUnwrap((cfg["agent"] as? [String: Any])?["worker"] as? [String: Any])
        XCTAssertTrue((agent["prompt"] as? String ?? "").contains("report(summary)"),
                      "D17 worker skill goes into agent.prompt")
        let plugins = try XCTUnwrap(cfg["plugin"] as? [String])
        XCTAssertEqual(plugins.first, cfgRoot + "/n1/oc-plugin.js")

        // plugin env for the reverse channel
        XCTAssertEqual(spec.env["VIGIL_HOOK_BIN"], "/opt/vigil-hook")
        XCTAssertEqual(spec.env["VIGIL_NODE"], "n1")
        XCTAssertEqual(spec.env["VIGIL_SOCK"], "/s/hook.sock")
        XCTAssertEqual(spec.env["TERM"], "xterm-256color")

        // the plugin file is on disk (vigil dir, never repo) and execs vigil-hook per HookEvent
        let js = try String(contentsOfFile: cfgRoot + "/n1/oc-plugin.js", encoding: .utf8)
        XCTAssertTrue(js.contains("session.idle"))
        XCTAssertTrue(js.contains("\"\(HookEvent.stop.rawValue)\""), "session.idle → stop")
        XCTAssertTrue(js.contains("\"\(HookEvent.postTool.rawValue)\""), "tool.execute.after → post-tool")
        XCTAssertTrue(js.contains("\"\(HookEvent.permRequest.rawValue)\""), "permission.ask → perm-request")
        XCTAssertTrue(js.contains("VIGIL_HOOK_BIN"), "reverse channel reads node/sock from env")
    }

    func testAgentNameByRole() {
        XCTAssertEqual(OpenCodeHarness.agentName(role: .manager, isRoot: true), "root")
        XCTAssertEqual(OpenCodeHarness.agentName(role: .manager, isRoot: false), "sub-manager")
        XCTAssertEqual(OpenCodeHarness.agentName(role: .leaf, isRoot: false), "worker")
    }

    func testResumeUsesSessionFlagNoPrompt() {
        let cfgRoot = NSTemporaryDirectory() + "vigil_oc_resume_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let h = OpenCodeHarness(opencodeBin: "/o", hookBin: "/h", mcpBin: "/m",
                                configRoot: cfgRoot, printMode: false)
        let spec = h.launchSpec(task: "", cwd: "/w", nodeID: NodeID("n1"),
                                role: .leaf, isRoot: false, resumeSessionId: "ses_42",
                                mcpEndpoint: "/s/m", hookEndpoint: "/s/h", idCred: "n1")
        XCTAssertEqual(spec.args.firstIndex(of: "--session").map { spec.args[$0 + 1] }, "ses_42")
        XCTAssertFalse(spec.args.contains("--prompt"), "resume does not stuff in an initial prompt")
    }

    func testPrintModeUsesRunSubcommandPositionalMessage() {
        let cfgRoot = NSTemporaryDirectory() + "vigil_oc_run_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let h = OpenCodeHarness(opencodeBin: "/o", hookBin: "/h", mcpBin: "/m",
                                configRoot: cfgRoot, printMode: true, permissionMode: .bypass)
        let spec = h.launchSpec(task: "hello", cwd: "/w", nodeID: NodeID("n1"),
                                role: .leaf, isRoot: false,
                                mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        XCTAssertEqual(Array(spec.args.prefix(3)), ["run", "--format", "json"])
        XCTAssertEqual(spec.args.last, "hello", "run: the message is a positional argument")
        XCTAssertFalse(spec.args.contains("--prompt"))
    }

    func testGuardedModeOmitsAuto() {
        let cfgRoot = NSTemporaryDirectory() + "vigil_oc_perm_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let h = OpenCodeHarness(opencodeBin: "/o", hookBin: "/h", mcpBin: "/m",
                                configRoot: cfgRoot, printMode: false, permissionMode: .standard)
        let spec = h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n1"),
                                role: .leaf, isRoot: false,
                                mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        XCTAssertFalse(spec.args.contains("--auto"), "a non-bypass access level does not pass --auto")
    }

    func testRegistryEntryDrivesBinEnvModel() throws {
        let base = NSTemporaryDirectory() + "vigil_oc_reg_\(getpid())"
        let cfg = base + "/config", cwd = base + "/proj"
        try? FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let agents = """
        { "agents": { "opencode": {
            "bin": "~/.bun/bin/opencode", "kind": "opencode", "defaultModel": "opencode/deepseek-v4-flash-free",
            "env": { "OPENCODE_THEME": "x" } } } }
        """
        try? agents.write(toFile: cfg + "/agents.json", atomically: true, encoding: .utf8)
        let h = OpenCodeHarness(opencodeBin: "/fallback/opencode", hookBin: "/h", mcpBin: "/m",
                                configRoot: base + "/cfgroot", printMode: false,
                                userConfigDir: cfg, agentKey: "opencode")
        let spec = h.launchSpec(task: "t", cwd: cwd, nodeID: NodeID("n1"),
                                role: .leaf, isRoot: false,
                                mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        XCTAssertEqual(spec.executable, NSHomeDirectory() + "/.bun/bin/opencode")
        XCTAssertEqual(spec.env["OPENCODE_THEME"], "x")
        XCTAssertEqual(spec.args.firstIndex(of: "-m").map { spec.args[$0 + 1] },
                       "opencode/deepseek-v4-flash-free")
    }

    func testModelMapKeyedByFamilyForOpencode() {
        // On the opencode side, only the map's "opencode" key is taken; the claude alias (a bare string defaults to claude) must not hit
        let base = NSTemporaryDirectory() + "vigil_oc_47_\(getpid())"
        let cfg = base + "/config", cwd = base + "/proj"
        try? FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        try? #"{ "agents": { "opencode": { "bin": "/real/opencode", "kind": "opencode" } } }"#
            .write(toFile: cfg + "/agents.json", atomically: true, encoding: .utf8)
        try? """
        { "root":   { "model": { "claude": "fable", "opencode": "opencode/kimi-k3" } },
          "worker": { "model": "haiku" } }
        """.write(toFile: cfg + "/roles.json", atomically: true, encoding: .utf8)
        let h = OpenCodeHarness(opencodeBin: "/fallback/opencode", hookBin: "/h", mcpBin: "/m",
                                configRoot: base + "/cfgroot", printMode: false,
                                userConfigDir: cfg, agentKey: "opencode")
        func modelArg(_ s: LaunchSpec) -> String? {
            s.args.firstIndex(of: "-m").map { s.args[$0 + 1] }
        }
        let root = h.launchSpec(task: "t", cwd: cwd, nodeID: NodeID("root"), role: .manager,
                                isRoot: true, mcpEndpoint: nil, hookEndpoint: nil, idCred: "root")
        XCTAssertEqual(modelArg(root), "opencode/kimi-k3", "the map hits this family's key")
        let worker = h.launchSpec(task: "t", cwd: cwd, nodeID: NodeID("w"), role: .leaf,
                                  isRoot: false, mcpEndpoint: nil, hookEndpoint: nil, idCred: "w")
        XCTAssertNil(modelArg(worker), "the bare string haiku belongs to the claude family; on the opencode side = unconfigured, so no -m is passed")
    }

    func testRolesAccessOverridesSessionDefault() throws {
        // Session default is guarded (no --auto); roles.json opens the worker to
        // bypass → --auto present.
        let base = NSTemporaryDirectory() + "vigil_oc_access_\(getpid())"
        let cfg = base + "/config", cwd = base + "/proj"
        try? FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        try? #"{ "worker": { "access": "bypass" }, "subManager": { "access": "plan" } }"#
            .write(toFile: cfg + "/roles.json", atomically: true, encoding: .utf8)
        let h = OpenCodeHarness(opencodeBin: "/o", hookBin: "/h", mcpBin: "/m",
                                configRoot: base + "/cfgroot", printMode: false,
                                permissionMode: .standard, userConfigDir: cfg, agentKey: "opencode")
        let worker = h.launchSpec(task: "t", cwd: cwd, nodeID: NodeID("w"), role: .leaf,
                                  isRoot: false, mcpEndpoint: nil, hookEndpoint: nil, idCred: "w")
        XCTAssertTrue(worker.args.contains("--auto"), "worker.access=bypass → --auto")
        let sub = h.launchSpec(task: "t", cwd: cwd, nodeID: NodeID("s"), role: .manager,
                               isRoot: false, mcpEndpoint: nil, hookEndpoint: nil, idCred: "s")
        XCTAssertFalse(sub.args.contains("--auto"), "sub-manager.access=plan → not wide open")
    }

    // MARK: dispatch routing (three-kind)

    func testDispatchRoutesOpencodeByRoleAgent() throws {
        let base = NSTemporaryDirectory() + "vigil_disp3_\(getpid())"
        let cfg = base + "/config", cwd = base + "/proj"
        try? FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let agents = """
        { "agents": {
            "claude":   { "bin": "/real/claude",   "kind": "claude" },
            "opencode": { "bin": "/real/opencode", "kind": "opencode" } } }
        """
        let roles = #"{ "worker": { "agent": "opencode" } }"#
        try? agents.write(toFile: cfg + "/agents.json", atomically: true, encoding: .utf8)
        try? roles.write(toFile: cfg + "/roles.json", atomically: true, encoding: .utf8)
        let h = DispatchHarness(claudeBin: "/fb/claude", codexBin: "/fb/codex",
                                opencodeBin: "/fb/opencode", hookBin: "/h", mcpBin: "/m",
                                configRoot: base + "/cfgroot", printMode: false,
                                userConfigDir: cfg, agentKey: "claude")
        // root → claude
        let root = h.launchSpec(task: "t", cwd: cwd, nodeID: NodeID("root"),
                                role: .manager, isRoot: true,
                                mcpEndpoint: "/s/m", hookEndpoint: "/s/h", idCred: "root")
        XCTAssertEqual(root.executable, "/real/claude")
        // worker role.agent="opencode" → opencode family (config content + --auto)
        let worker = h.launchSpec(task: "t", cwd: cwd, nodeID: NodeID("w1"),
                                  role: .leaf, isRoot: false,
                                  mcpEndpoint: "/s/m", hookEndpoint: "/s/h", idCred: "w1")
        XCTAssertEqual(worker.executable, "/real/opencode")
        XCTAssertNotNil(worker.env["OPENCODE_CONFIG_CONTENT"])
        XCTAssertEqual(worker.env["VIGIL_NODE"], "w1")
    }
}
