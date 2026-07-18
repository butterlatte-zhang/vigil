import XCTest
import VigilCore
@testable import VigilRuntime
#if canImport(Darwin)
import Darwin
#endif

final class HarnessTests: XCTestCase {

    func testLaunchSpecWiresChannelsCleanEnvAndConfigs() throws {
        // Inherited session-identity vars that MUST be stripped for config hygiene.
        setenv("CLAUDECODE", "1", 1)
        setenv("CLAUDE_CODE_ENTRYPOINT", "cli", 1)

        let cfgRoot = NSTemporaryDirectory() + "vigil_harness_test_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }

        let h = ClaudeCodeHarness(claudeBin: "/usr/bin/claude",
                                  hookBin: "/opt/vigil-hook", mcpBin: "/opt/vigil-mcp",
                                  configRoot: cfgRoot, printMode: true)
        let spec = h.launchSpec(task: "do the thing", cwd: "/tmp/work",
                                nodeID: NodeID("n1"), role: .leaf, isRoot: false,
                                mcpEndpoint: "/s/mcp.sock", hookEndpoint: "/s/hook.sock",
                                idCred: "n1")

        // executable + wiring flags
        XCTAssertEqual(spec.executable, "/usr/bin/claude")
        XCTAssertTrue(spec.args.contains("-p"))
        XCTAssertTrue(spec.args.contains("do the thing"))
        XCTAssertTrue(spec.args.contains("--append-system-prompt"))
        XCTAssertTrue(spec.args.contains("--mcp-config"))
        // Product default = overlay on the user's MCP config, never strict
        // (full pinning in HarnessMcpOverlayTests).
        XCTAssertFalse(spec.args.contains("--strict-mcp-config"))
        XCTAssertTrue(spec.args.contains("--allowedTools"))
        // send replaces ask_human in the tool set
        XCTAssertTrue(spec.args.contains { $0.contains("mcp__vigil__spawn") })
        XCTAssertTrue(spec.args.contains { $0.contains("mcp__vigil__send") })
        XCTAssertFalse(spec.args.contains { $0.contains("ask_human") })
        // permission level = claude-native mechanism, default mode
        XCTAssertTrue(spec.args.contains("--permission-mode"))
        XCTAssertEqual(spec.args.last, "default")
        XCTAssertFalse(spec.args.contains("--dangerously-skip-permissions"))

        // clean env
        XCTAssertNil(spec.env["CLAUDECODE"])
        XCTAssertNil(spec.env["CLAUDE_CODE_ENTRYPOINT"])
        XCTAssertEqual(spec.env["TERM"], "xterm-256color")

        // settings.json observation hooks: no PreToolUse; no Notification (it would
        // double-card permission boxes now that the waiting-for-input card is gone);
        // UserPromptSubmit points at vigil-hook with node + sock.
        let settingsPath = cfgRoot + "/n1/settings.json"
        let settings = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: settingsPath))) as? [String: Any]
        let hooks = settings?["hooks"] as? [String: Any]
        XCTAssertNil(hooks?["PreToolUse"])                              // permission gate is not installed
        XCTAssertNil(hooks?["Notification"])                            // idle feed hook is not installed

        func hookCommand(_ event: String) -> String {
            let entry = (hooks?[event] as? [[String: Any]])?.first
            return ((entry?["hooks"] as? [[String: Any]])?.first)?["command"] as? String ?? ""
        }
        let promptCmd = hookCommand("UserPromptSubmit")
        XCTAssertTrue(promptCmd.contains("/opt/vigil-hook"))
        XCTAssertTrue(promptCmd.contains("--node n1"))
        // bin/sock paths are POSIX single-quoted (safe for $/`/space/…).
        XCTAssertTrue(promptCmd.contains("--sock '/s/hook.sock'"))
        XCTAssertTrue(promptCmd.contains("--event prompt"))
        // PermissionRequest + PostToolUse are observation-only — same fire-and-forget
        // vigil-hook, new --event channels.
        let permCmd = hookCommand("PermissionRequest")
        XCTAssertTrue(permCmd.contains("/opt/vigil-hook"))
        XCTAssertTrue(permCmd.contains("--node n1"))
        XCTAssertTrue(permCmd.contains("--event perm-request"))
        let postCmd = hookCommand("PostToolUse")
        XCTAssertTrue(postCmd.contains("/opt/vigil-hook"))
        XCTAssertTrue(postCmd.contains("--node n1"))
        XCTAssertTrue(postCmd.contains("--event post-tool"))
        // Stop → turn-ended observation (the running/idle divider).
        let stopCmd = hookCommand("Stop")
        XCTAssertTrue(stopCmd.contains("/opt/vigil-hook"))
        XCTAssertTrue(stopCmd.contains("--node n1"))
        XCTAssertTrue(stopCmd.contains("--event stop"))

        // mcp.json: stdio server = vigil-mcp shim with node + sock
        let mcpPath = cfgRoot + "/n1/mcp.json"
        let mcp = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: mcpPath))) as? [String: Any]
        let vigil = ((mcp?["mcpServers"] as? [String: Any])?["vigil"]) as? [String: Any]
        XCTAssertEqual(vigil?["command"] as? String, "/opt/vigil-mcp")
        let mcpArgs = vigil?["args"] as? [String] ?? []
        XCTAssertEqual(mcpArgs, ["--node", "n1", "--sock", "/s/mcp.sock"])
    }

    func testTaskLeadingDashIsNeutralizedAgainstFlagInjection() {
        // neutralizeLeadingDash still guards the paths that DO pass a positional
        // (printMode `-p`, resume sid, codex/opencode headless) — a `-`-leading string there
        // would parse as a flag.
        XCTAssertEqual(
            ClaudeCodeHarness.neutralizeLeadingDash("--dangerously-skip-permissions"),
            " --dangerously-skip-permissions")
        XCTAssertEqual(ClaudeCodeHarness.neutralizeLeadingDash("normal task"), "normal task",
                       "a task not starting with - is left untouched")

        // An interactive product cell never puts the task in argv — it rides initialPrompt
        // (PTY injection), where it is typed text and can never be parsed as a flag. The
        // argv-flag-injection surface is closed by construction, and the raw task
        // (un-neutralized) is what gets injected.
        let cfgRoot = NSTemporaryDirectory() + "vigil_harness_test_dash_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let h = ClaudeCodeHarness(claudeBin: "/usr/bin/claude", hookBin: "/h", mcpBin: "/m",
                                  configRoot: cfgRoot, printMode: false)
        let spec = h.launchSpec(task: "-p /etc/passwd", cwd: "/w", nodeID: NodeID("n1"),
                                role: .leaf, isRoot: false,
                                mcpEndpoint: "/s/m.sock", hookEndpoint: "/s/h.sock", idCred: "n1")
        XCTAssertFalse(spec.args.contains("-p /etc/passwd"), "the task does not enter argv")
        XCTAssertFalse(spec.args.contains(" -p /etc/passwd"), "not even the neutralized form enters argv")
        XCTAssertEqual(spec.initialPrompt, "-p /etc/passwd", "the task is injected verbatim via the PTY")
    }

    func testHookCommandPosixQuotesPathsWithMetacharacters() throws {
        // The hook command goes into settings.json and is executed by the shell. A user
        // directory containing shell metacharacters ($/`/(/space) would break parsing if
        // quoting were naive, and since the hook is fire-and-forget, it would die silently.
        // POSIX single quotes must be safe for every byte.
        let cfgRoot = NSTemporaryDirectory() + "vigil_harness_test_q_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let nastyHook = "/Users/z z/Dev(work)/$X/vigil-hook"
        let h = ClaudeCodeHarness(claudeBin: "/usr/bin/claude",
                                  hookBin: nastyHook, mcpBin: "/m",
                                  configRoot: cfgRoot, printMode: false)
        _ = h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n1"), role: .leaf, isRoot: false,
                         mcpEndpoint: "/s/m.sock", hookEndpoint: "/s/h.sock", idCred: "n1")
        let settings = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: cfgRoot + "/n1/settings.json")))
            as? [String: Any]
        let hooks = settings?["hooks"] as? [String: Any]
        let cmd = (((hooks?["UserPromptSubmit"] as? [[String: Any]])?.first?["hooks"]
                    as? [[String: Any]])?.first)?["command"] as? String ?? ""
        XCTAssertTrue(cmd.contains("'\(nastyHook)'"),
                      "the whole path is single-quoted — $/(/space are all literal, so the command never fails to parse in the shell")
    }

    func testPermissionModeFlagFollowsHarnessProperty() {
        // bypass also goes through --permission-mode, never --dangerously-skip-permissions.
        let cfgRoot = NSTemporaryDirectory() + "vigil_harness_test_pm_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        for (mode, flag) in [(PermissionMode.standard, "default"),
                             (.acceptEdits, "acceptEdits"),
                             (.plan, "plan"),
                             (.bypass, "bypassPermissions")] {
            let h = ClaudeCodeHarness(claudeBin: "/c", hookBin: "/h", mcpBin: "/m",
                                      configRoot: cfgRoot, printMode: true, permissionMode: mode)
            let spec = h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n1"),
                                    role: .leaf, isRoot: false,
                                    mcpEndpoint: nil, hookEndpoint: nil,
                                    idCred: "n1")
            let i = spec.args.firstIndex(of: "--permission-mode")
            XCTAssertNotNil(i)
            XCTAssertEqual(spec.args[i! + 1], flag)
            XCTAssertFalse(spec.args.contains("--dangerously-skip-permissions"))
        }
    }

    func testSkillsAreIdentityScoped() {
        // Identity + tool list only — each role sees exactly its own tool surface,
        // and the texts mirror MCPToolServer.allowedTools (prompt and hard trim agree).
        let root = ClaudeCodeHarness.skill(role: .manager, isRoot: true)
        XCTAssertTrue(root.contains("root manager"))
        XCTAssertTrue(root.contains("spawn(role"))
        XCTAssertTrue(root.contains("send(node, message)"))
        XCTAssertTrue(root.contains("kill(node)"))
        XCTAssertFalse(root.contains("report(summary)"))     // root's report has nowhere to go

        let sub = ClaudeCodeHarness.skill(role: .manager, isRoot: false)
        XCTAssertTrue(sub.contains("sub-manager"))
        XCTAssertTrue(sub.contains("spawn(role"))
        XCTAssertTrue(sub.contains("report(summary)"))

        let worker = ClaudeCodeHarness.skill(role: .leaf, isRoot: false)
        XCTAssertTrue(worker.contains("worker"))
        XCTAssertTrue(worker.contains("report(summary)"))
        XCTAssertFalse(worker.contains("spawn"))              // workers hold report only
        XCTAssertFalse(worker.contains("send(node"))
        XCTAssertFalse(worker.contains("kill(node)"))

        // No behavioral prescriptions — identity only.
        for s in [root, sub, worker] {
            XCTAssertFalse(s.lowercased().contains("never"))
            XCTAssertFalse(s.contains("MUST"))
        }
    }

    func testSkillTextMirrorsMCPAllowedToolsSurface() {
        // The allowedTools set (the server-side hard-trim ground truth in MCPToolServer) and
        // the three skill texts are each hardcoded separately, so changing only one side could
        // silently drift. This test reconciles the two sides: for each identity, read the real
        // server-side allowedTools and assert, per tool, whether its call signature appears in
        // that identity's skill text. We use the "call signature" rather than the bare tool
        // name, because worker's "report(summary): send a summary…" contains the word "send",
        // and root's "children's report(...)" contains the word "report" — only the signature
        // shape (tool + parameter parens) reflects the call surface each identity actually
        // holds.
        let signature = ["spawn": "spawn(role", "send": "send(node",
                         "report": "report(summary)", "kill": "kill(node)",
                         "rename": "rename(name"]
        let universe = Set(signature.keys)
        // Every root holds rename; no non-root identity does. The kind dimension remains in
        // this matrix because codex alone also receives its lazy-tool recovery text.
        let identities: [(name: String, role: Role, isRoot: Bool, kind: AgentCLIKind)] = [
            ("root(claude)", .manager, true, .claude),
            ("root(codex)", .manager, true, .codex),
            ("root(opencode)", .manager, true, .opencode),
            ("sub-manager", .manager, false, .codex),
            ("worker", .leaf, false, .codex),
        ]
        for id in identities {
            let allowed = MCPToolServer.allowedTools(role: id.role, isRoot: id.isRoot, kind: id.kind)
            let skill = ClaudeCodeHarness.skill(role: id.role, isRoot: id.isRoot, kind: id.kind)
            for tool in universe {
                let sig = signature[tool]!
                if allowed.contains(tool) {
                    XCTAssertTrue(skill.contains(sig),
                        "\(id.name) holds \(tool) (allowedTools) → skill must contain its call signature \(sig)")
                } else {
                    XCTAssertFalse(skill.contains(sig),
                        "\(id.name) does not hold \(tool) → skill must not contain its call signature \(sig)")
                }
            }
        }
        // Positive proof of the worker surface: no spawn/send/kill call signatures appear
        // (only report is left).
        let worker = ClaudeCodeHarness.skill(role: .leaf, isRoot: false)
        XCTAssertFalse(worker.contains("spawn("))
        XCTAssertFalse(worker.contains("send(node"))
        XCTAssertFalse(worker.contains("kill(node)"))
    }

    func testToolSearchRecoveryGuidanceIsClaudeOnlyAndOverrideDrops() {
        // claude launches carry the ToolSearch recovery line so a cell that hits schema
        // deferral (tool-search may defer mcp__vigil__ schemas under a large tool surface,
        // or across resume replay / cohort shifts) can reload its schema and retry. The
        // shared skill() default — which codex/opencode reuse — stays clean, because those
        // runtimes have no ToolSearch builtin.
        // (a) present on the claude launch path, all three identities.
        for (r, root) in [(Role.manager, true), (Role.manager, false), (Role.leaf, false)] {
            let s = spec(harness(nil), cwd: "/w", role: r, isRoot: root)
            let i = s.args.firstIndex(of: "--append-system-prompt")!
            let sys = s.args[i + 1]
            XCTAssertTrue(sys.contains("ToolSearch") && sys.contains("select:mcp__vigil__"),
                          "claude \(r)/\(root): the #51 recovery guidance must be in the system prompt")
        }
        // (b) the shared skill() default stays clean — mirror-law + codex/opencode reuse unaffected.
        XCTAssertFalse(ClaudeCodeHarness.skill(role: .leaf, isRoot: false).contains("ToolSearch"),
                       "the default skill() has no recovery line (mirror law / heterogeneous-runtime reuse surface)")
        // (c) declarative register preserved (no imperatives) even with the recovery line.
        let withRecovery = ClaudeCodeHarness.skill(role: .leaf, isRoot: false, toolSearchRecovery: true)
        XCTAssertTrue(withRecovery.contains("ToolSearch"))
        XCTAssertFalse(withRecovery.lowercased().contains("never"))
        XCTAssertFalse(withRecovery.contains("MUST"))
        // (d) promptOverride replaces the whole base → recovery dropped with it.
        XCTAssertEqual(ClaudeCodeHarness.skill(role: .leaf, isRoot: false,
                                               promptOverride: "custom", toolSearchRecovery: true),
                       "custom", "override replaces the whole base; the recovery line is dropped along with it")
    }

    func testCodexLazyToolsRecoveryLineIsCodexOnlyAndOverrideDrops() {
        // Once the per-node home inherits the user's own MCP servers, codex can defer MCP
        // schemas out of the upfront tool list while its native multi-agent tools (spawn_agent
        // & co.) stay visible — risking a manager reaching for the native tool instead of the
        // Vigil tree. The line states the two recovery surfaces (codex's tool search; code
        // mode's ALL_TOOLS registry + `tools.mcp__vigil__*` call form), and the check runs
        // before the first delegation.
        // (a) present for ALL codex identities (a worker's report schema defers the same way).
        for (role, isRoot) in [(Role.manager, true), (.manager, false), (.leaf, false)] {
            let s = ClaudeCodeHarness.skill(role: role, isRoot: isRoot, kind: .codex)
            XCTAssertTrue(s.contains("ALL_TOOLS"),
                          "codex \(role)/root=\(isRoot): code-mode discovery surface must be named")
            XCTAssertTrue(s.contains("tools.mcp__vigil__"),
                          "codex \(role)/root=\(isRoot): code-mode call form must be named")
            // declarative register preserved (no never/MUST imperatives).
            XCTAssertFalse(s.lowercased().contains("never"))
            XCTAssertFalse(s.contains("MUST"))
        }
        // (b) codex-only: claude has its own recovery line; opencode loads MCP tools upfront.
        for kind in [AgentCLIKind.claude, .opencode] {
            XCTAssertFalse(ClaudeCodeHarness.skill(role: .manager, isRoot: false, kind: kind)
                .contains("ALL_TOOLS"), "\(kind) must not carry the codex lazy-tools line")
        }
        // (c) promptOverride replaces the whole Vigil-owned base → the line drops with it.
        XCTAssertEqual(ClaudeCodeHarness.skill(role: .leaf, isRoot: false, kind: .codex,
                                               promptOverride: "custom"), "custom")
        // (d) mirror law untouched: the line adds no vigil call signature, so the codex
        // WORKER text still carries report(summary) only (reconciled by the mirror test).
        let worker = ClaudeCodeHarness.skill(role: .leaf, isRoot: false, kind: .codex)
        XCTAssertFalse(worker.contains("spawn(role"))
        XCTAssertFalse(worker.contains("send(node"))
        XCTAssertFalse(worker.contains("kill(node)"))
    }

    func testProcessHygieneRedLineForbidsByNameOperations() {
        // The red line covers all by-name process/UI operations, not just `pkill -f`/
        // `killall` — a worker using osascript to click a by-name menu item (e.g. Quit) can
        // cascade-kill the whole tree just as easily. The red line names osascript/AppleScript
        // by-name explicitly.
        let line = ClaudeCodeHarness.processHygieneRedLine
        XCTAssertTrue(line.contains("pkill"), "the old wording is preserved")
        XCTAssertTrue(line.contains("killall"), "the old wording is preserved")
        XCTAssertTrue(line.contains("osascript"), "extended to osascript by-name")
        XCTAssertTrue(line.contains("exact PID"), "cleanup uses only the exact recorded PID")

        // Appears in all three identity skills (the three share the same constant).
        for s in [ClaudeCodeHarness.rootSkill,
                  ClaudeCodeHarness.subManagerSkill,
                  ClaudeCodeHarness.workerSkill] {
            XCTAssertTrue(s.contains("osascript"), "all three skills carry the extended red line")
            // The declarative register doesn't break the identity-only invariant: no
            // never/MUST imperatives.
            XCTAssertFalse(s.lowercased().contains("never"))
            XCTAssertFalse(s.contains("MUST"))
        }
    }

    // MARK: per-cell model override (a spawn-specified model beats the session default)

    func testModelFlagPerCellOverridesSessionDefault() {
        let cfgRoot = NSTemporaryDirectory() + "vigil_harness_test_model_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        func modelArg(_ spec: LaunchSpec) -> String? {
            spec.args.firstIndex(of: "--model").map { spec.args[$0 + 1] }
        }

        let h = ClaudeCodeHarness(claudeBin: "/c", hookBin: "/h", mcpBin: "/m",
                                  configRoot: cfgRoot, printMode: true, model: "opus")
        // no per-cell override → the session default flows through (semantics unchanged)
        let inherited = h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n1"),
                                     role: .leaf, isRoot: false, model: nil,
                                     mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        XCTAssertEqual(modelArg(inherited), "opus")
        // spawn-specified model WINS over the session default
        let overridden = h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n2"),
                                      role: .leaf, isRoot: false, model: "haiku",
                                      mcpEndpoint: nil, hookEndpoint: nil, idCred: "n2")
        XCTAssertEqual(modelArg(overridden), "haiku")
        XCTAssertFalse(overridden.args.contains("opus"))
        // no session default + no override → no --model at all (claude's own default)
        let bare = ClaudeCodeHarness(claudeBin: "/c", hookBin: "/h", mcpBin: "/m",
                                     configRoot: cfgRoot, printMode: true)
        let plain = bare.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n3"),
                                    role: .leaf, isRoot: false, model: nil,
                                    mcpEndpoint: nil, hookEndpoint: nil, idCred: "n3")
        XCTAssertNil(modelArg(plain))
    }

    func testSpawnSkillLineMentionsOptionalModel() {
        // spawn's optional model param shows up in the skill texts of exactly the
        // identities whose MCP surface holds spawn — never the worker's.
        XCTAssertTrue(ClaudeCodeHarness.rootSkill.contains("model"))
        XCTAssertTrue(ClaudeCodeHarness.subManagerSkill.contains("model"))
        XCTAssertFalse(ClaudeCodeHarness.workerSkill.contains("model"))
    }

    func testManagerToolDescriptionsAreSharedConciseAndComplete() {
        for skill in [ClaudeCodeHarness.rootSkill, ClaudeCodeHarness.subManagerSkill] {
            XCTAssertTrue(skill.contains(ClaudeCodeHarness.spawnToolLine))
            XCTAssertTrue(skill.contains(ClaudeCodeHarness.sendToolLine))
            XCTAssertTrue(skill.contains(ClaudeCodeHarness.killToolLine))
        }

        let spawn = ClaudeCodeHarness.spawnToolLine
        XCTAssertTrue(spawn.contains("return its node id"))
        XCTAssertTrue(spawn.contains("leaf for a bounded one-worker task"))
        XCTAssertTrue(spawn.contains("manager only when the child must delegate"))
        XCTAssertTrue(spawn.contains("selected by roles.json, not an agent name"))
        XCTAssertTrue(spawn.contains("omit it for the configured default"))
        XCTAssertTrue(spawn.contains("short label shown in Vigil's node tree"))
        XCTAssertFalse(spawn.contains("e.g."), "model examples add noise and go stale")

        XCTAssertTrue(ClaudeCodeHarness.sendToolLine.contains("follow-up context"))
        XCTAssertTrue(ClaudeCodeHarness.sendToolLine.contains("status request"))
        XCTAssertTrue(ClaudeCodeHarness.killToolLine.contains("immediately terminate"))
        XCTAssertTrue(ClaudeCodeHarness.killToolLine.contains("use send first"))

        for kind in [AgentCLIKind.claude, .codex, .opencode] {
            let root = ClaudeCodeHarness.skill(role: .manager, isRoot: true, kind: kind)
            XCTAssertTrue(root.contains("rename(name)"))
            XCTAssertTrue(root.contains("sidebar and title bar"))
            XCTAssertTrue(root.contains("name it early"))
        }
    }

    func testRenameSkillLineIsRootOnlyAcrossAgentKinds() {
        // Every root carries rename; sub-managers and workers do not. A promptOverride
        // replaces the whole base, so rename drops with it.
        for kind in [AgentCLIKind.claude, .codex, .opencode] {
            XCTAssertTrue(ClaudeCodeHarness.skill(role: .manager, isRoot: true, kind: kind)
                .contains("rename(name"), "\(kind) root must carry the rename(name) line")
        }
        for (role, isRoot, kind) in [(Role.manager, false, AgentCLIKind.claude),
                                     (.manager, false, .codex),
                                     (.manager, false, .opencode),
                                     (.leaf, false, .codex)] {
            XCTAssertFalse(ClaudeCodeHarness.skill(role: role, isRoot: isRoot, kind: kind)
                .contains("rename(name"), "\(role)/root=\(isRoot)/\(kind) must not contain rename")
        }
        // override escape hatch drops the Vigil-owned base (incl. rename), same as toolSearch.
        XCTAssertEqual(ClaudeCodeHarness.skill(role: .manager, isRoot: true, kind: .codex,
                                               promptOverride: "custom"), "custom")
        // declarative register preserved (no never/MUST imperatives).
        let codexRoot = ClaudeCodeHarness.skill(role: .manager, isRoot: true, kind: .codex)
        XCTAssertFalse(codexRoot.lowercased().contains("never"))
        XCTAssertFalse(codexRoot.contains("MUST"))
        XCTAssertTrue(ClaudeCodeHarness.allowedTools.contains("mcp__vigil__rename"),
                      "Claude's client-side allowlist must not block the root-only server tool")
    }

    func testInteractiveModeOmitsPrintFlag() {
        let cfgRoot = NSTemporaryDirectory() + "vigil_harness_test2_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let h = ClaudeCodeHarness(claudeBin: "/c", hookBin: "/h", mcpBin: "/m",
                                  configRoot: cfgRoot, printMode: false)
        let spec = h.launchSpec(task: "task", cwd: "/w", nodeID: NodeID("root"),
                                role: .manager, isRoot: true,
                                mcpEndpoint: "/s/m", hookEndpoint: "/s/h",
                                idCred: "root")
        XCTAssertFalse(spec.args.contains("-p"))
        // Interactive cell — task is NOT an argv positional; it rides initialPrompt.
        XCTAssertFalse(spec.args.contains("task"), "the task no longer enters argv (the ps/pkill blast radius)")
        XCTAssertEqual(spec.initialPrompt, "task", "the task is injected via the PTY")
    }

    // MARK: resume re-hatching (a per-launch parameter; root and a dead worker take the same path)

    func testResumeSessionIdReplacesTaskPositional() {
        // Interactive `--resume <sid>` combines fine with --append-system-prompt/--settings/
        // --mcp-config/--allowedTools/--permission-mode. Resume is a per-launch parameter
        // (whichever cell gets revived carries the flag), and the harness itself stays
        // stateless across cells.
        let cfgRoot = NSTemporaryDirectory() + "vigil_harness_resume_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let h = ClaudeCodeHarness(claudeBin: "/c", hookBin: "/h", mcpBin: "/m",
                                  configRoot: cfgRoot, printMode: false)
        let root = h.launchSpec(task: "", cwd: "/w", nodeID: NodeID("root"),
                                role: .manager, isRoot: true, resumeSessionId: "sid-42",
                                mcpEndpoint: "/s/m", hookEndpoint: "/s/h", idCred: "root")
        XCTAssertEqual(Array(root.args.prefix(2)), ["--resume", "sid-42"])
        // Context lives CLI-side — no task positional is stuffed in (resume semantics: pick
        // up from where it left off).
        XCTAssertFalse(root.args.contains(""))

        // Reviving a dead worker takes the same parameter — a non-root node carries --resume
        // just the same, whichever node is revived.
        let worker = h.launchSpec(task: "", cwd: "/w", nodeID: NodeID("n1"),
                                  role: .leaf, isRoot: false, resumeSessionId: "sid-w1",
                                  mcpEndpoint: "/s/m", hookEndpoint: "/s/h", idCred: "n1")
        XCTAssertEqual(Array(worker.args.prefix(2)), ["--resume", "sid-w1"])

        // A fresh spawn (no resume parameter) is unaffected.
        let fresh = h.launchSpec(task: "sub task", cwd: "/w", nodeID: NodeID("n2"),
                                 role: .leaf, isRoot: false,
                                 mcpEndpoint: "/s/m", hookEndpoint: "/s/h", idCred: "n2")
        XCTAssertFalse(fresh.args.contains("--resume"))
        // Fresh interactive spawn — task rides initialPrompt, never argv.
        XCTAssertFalse(fresh.args.contains("sub task"))
        XCTAssertEqual(fresh.initialPrompt, "sub task")
    }

    func testNoResumeKeepsLaunchSurfaceUnchanged() {
        let cfgRoot = NSTemporaryDirectory() + "vigil_harness_resume2_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let h = ClaudeCodeHarness(claudeBin: "/c", hookBin: "/h", mcpBin: "/m",
                                  configRoot: cfgRoot, printMode: false)
        let spec = h.launchSpec(task: "task", cwd: "/w", nodeID: NodeID("root"),
                                role: .manager, isRoot: true,
                                mcpEndpoint: "/s/m", hookEndpoint: "/s/h", idCred: "root")
        XCTAssertFalse(spec.args.contains("--resume"))
    }

    // MARK: launch-scoped point-read (agents.json / roles.json)

    /// Throwaway dir tree for user-config tests; returns (configDir, cwd).
    private func makeUserConfig(_ tag: String,
                                agents: String? = nil, roles: String? = nil,
                                projectRoles: String? = nil,
                                prompts: String? = nil,
                                files: [String: String] = [:]) -> (dir: String, cwd: String) {
        let base = NSTemporaryDirectory() + "vigil_ucfg_\(tag)_\(getpid())"
        let cfg = base + "/config", cwd = base + "/proj"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: cwd + "/.vigil", withIntermediateDirectories: true)
        if let a = agents { try? a.write(toFile: cfg + "/agents.json", atomically: true, encoding: .utf8) }
        if let r = roles { try? r.write(toFile: cfg + "/roles.json", atomically: true, encoding: .utf8) }
        if let p = projectRoles {
            try? p.write(toFile: cwd + "/.vigil/roles.json", atomically: true, encoding: .utf8)
        }
        if let pr = prompts { try? pr.write(toFile: cfg + "/prompts.json", atomically: true, encoding: .utf8) }
        for (rel, content) in files {
            let path = cfg + "/" + rel
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? fm.removeItem(atPath: base) }
        return (cfg, cwd)
    }

    private func harness(_ configDir: String?, agentKey: String? = "claude",
                         model: String? = nil) -> ClaudeCodeHarness {
        let root = NSTemporaryDirectory() + "vigil_ucfg_cfgroot_\(UUID().uuidString.prefix(8))"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        return ClaudeCodeHarness(claudeBin: "/fallback/claude", hookBin: "/h", mcpBin: "/m",
                                 configRoot: root, printMode: true, model: model,
                                 userConfigDir: configDir, agentKey: agentKey)
    }

    private func modelArg(_ spec: LaunchSpec) -> String? {
        spec.args.firstIndex(of: "--model").map { spec.args[$0 + 1] }
    }

    private func spec(_ h: ClaudeCodeHarness, cwd: String, role: Role, isRoot: Bool,
                      model: String? = nil, node: String = "n1") -> LaunchSpec {
        h.launchSpec(task: "t", cwd: cwd, nodeID: NodeID(node), role: role, isRoot: isRoot,
                     model: model, mcpEndpoint: nil, hookEndpoint: nil, idCred: node)
    }

    func testRegistryEntryDrivesBinEnvExtraArgsAndDefaultModel() {
        let (cfg, cwd) = makeUserConfig("entry", agents: """
        { "agents": { "claude": {
            "bin": "~/mybin/claude", "models": ["sonnet", "opus"],
            "defaultModel": "sonnet", "extraArgs": ["--verbose"],
            "env": { "ANTHROPIC_BASE_URL": "https://relay.example" } } } }
        """)
        let s = spec(harness(cfg), cwd: cwd, role: .leaf, isRoot: false)
        XCTAssertEqual(s.executable, NSHomeDirectory() + "/mybin/claude", "bin must have ~ expanded")
        XCTAssertEqual(s.env["ANTHROPIC_BASE_URL"], "https://relay.example", "endpoint env injected")
        XCTAssertEqual(s.args.last, "--verbose", "extraArgs is appended at the end")
        XCTAssertEqual(modelArg(s), "sonnet", "with no stronger source, entry.defaultModel is the fallback")
    }

    func testAgentKeySelectsEndpointEntry() {
        let agents = """
        { "agents": {
            "claude": { "bin": "/real/claude" },
            "relay":  { "bin": "/real/claude2", "kind": "claude",
                        "env": { "ANTHROPIC_BASE_URL": "https://cn.example" } } } }
        """
        let (cfg, cwd) = makeUserConfig("key", agents: agents)
        let s = spec(harness(cfg, agentKey: "relay"), cwd: cwd, role: .manager, isRoot: true)
        XCTAssertEqual(s.executable, "/real/claude2")
        XCTAssertEqual(s.env["ANTHROPIC_BASE_URL"], "https://cn.example")
    }

    func testRoleAgentBeatsSessionForChildrenOnly() {
        // Heterogeneous workers: the worker goes through the relay entry; root ignores
        // roles.root.agent — root's agent is hand-picked at the launcher.
        let agents = """
        { "agents": {
            "claude": { "bin": "/real/claude" },
            "relay":  { "bin": "/relay/claude", "kind": "claude" } } }
        """
        let roles = """
        { "root": { "agent": "relay" }, "worker": { "agent": "relay" } }
        """
        let (cfg, cwd) = makeUserConfig("roleagent", agents: agents, roles: roles)
        let h = harness(cfg)
        XCTAssertEqual(spec(h, cwd: cwd, role: .leaf, isRoot: false).executable, "/relay/claude")
        XCTAssertEqual(spec(h, cwd: cwd, role: .manager, isRoot: true).executable, "/real/claude",
                       "root's agent honors only the launcher choice")
    }

    func testNonClaudeRoleAgentFallsBackToSessionEntry() {
        // This harness only drives claude — a codex-kind role agent must
        // fall back, never silently break the launch.
        let agents = """
        { "agents": {
            "claude": { "bin": "/real/claude" },
            "codex":  { "bin": "/real/codex", "kind": "codex" } } }
        """
        let (cfg, cwd) = makeUserConfig("kindfb", agents: agents,
                                        roles: #"{ "worker": { "agent": "codex" } }"#)
        XCTAssertEqual(spec(harness(cfg), cwd: cwd, role: .leaf, isRoot: false).executable,
                       "/real/claude")
    }

    func testMissingAgentsFileFallsBackToClaudeBin() {
        let (cfg, cwd) = makeUserConfig("nofile")   // neither roles nor agents exists
        let s = spec(harness(cfg), cwd: cwd, role: .leaf, isRoot: false)
        XCTAssertEqual(s.executable, "/fallback/claude",
                       "a missing agents.json = upgrading-user / test path behavior unchanged")
    }

    /// DispatchHarness.launchKind resolves the node's CLI family from the registry —
    /// the seam the Orchestrator uses to route opencode-specific observability.
    func testDispatchLaunchKindResolvesRegistryFamily() {
        let agents = """
        { "agents": {
            "claude": { "bin": "/real/claude" },
            "oc":     { "bin": "/real/opencode", "kind": "opencode" } } }
        """
        let (cfg, cwd) = makeUserConfig("kind", agents: agents)
        let root = NSTemporaryDirectory() + "vigil_dispatch_\(UUID().uuidString.prefix(8))"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        func dispatch(_ key: String) -> DispatchHarness {
            DispatchHarness(claudeBin: "/fallback/claude", codexBin: "/c", opencodeBin: "/o",
                            hookBin: "/h", mcpBin: "/m", configRoot: root,
                            userConfigDir: cfg, agentKey: key)
        }
        XCTAssertEqual(dispatch("oc").launchKind(role: .manager, isRoot: true, cwd: cwd), .opencode)
        XCTAssertEqual(dispatch("claude").launchKind(role: .manager, isRoot: true, cwd: cwd), .claude)
        // no registry entry / no config → built-in claude default
        XCTAssertEqual(dispatch("missing").launchKind(role: .leaf, isRoot: false, cwd: cwd), .claude)
    }

    func testModelChainRoleBeatsSessionForChildrenChipWinsForRoot() {
        let roles = #"{ "root": { "model": "haiku" }, "worker": { "model": "haiku" } }"#
        let (cfg, cwd) = makeUserConfig("modelchain", roles: roles)
        let h = harness(cfg, model: "opus")          // launcher chip / session default
        // child: role.model > session default; spawn param strongest
        XCTAssertEqual(modelArg(spec(h, cwd: cwd, role: .leaf, isRoot: false)), "haiku")
        XCTAssertEqual(modelArg(spec(h, cwd: cwd, role: .leaf, isRoot: false, model: "sonnet")),
                       "sonnet")
        // root: explicit chip beats roles.root.model
        XCTAssertEqual(modelArg(spec(h, cwd: cwd, role: .manager, isRoot: true)), "opus")
        // chip not chosen (session model nil) → roles.root.model takes effect
        XCTAssertEqual(modelArg(spec(harness(cfg), cwd: cwd, role: .manager, isRoot: true)),
                       "haiku")
    }

    // MARK: model is namespaced by agent family (roles.json model = map keyed by claude/codex/opencode)

    func testModelMapKeyedByFamilyForClaude() {
        // Map form: each family gets its own config; the claude side only reads the "claude"
        // key (verified for both the root and child chains).
        let roles = """
        { "root":   { "model": { "claude": "fable", "codex": "gpt-5.1-codex-max" } },
          "worker": { "model": { "claude": "haiku", "codex": "gpt-5.1-codex" } } }
        """
        let (cfg, cwd) = makeUserConfig("modelmap", roles: roles)
        let h = harness(cfg)
        XCTAssertEqual(modelArg(spec(h, cwd: cwd, role: .manager, isRoot: true)), "fable")
        XCTAssertEqual(modelArg(spec(h, cwd: cwd, role: .leaf, isRoot: false)), "haiku")
    }

    func testModelMapMissingFamilyKeyMeansUnset() {
        // The user configured no model for this family = don't pass --model at all (Vigil
        // never picks a model on the user's behalf; the CLI's own default takes over).
        let roles = #"{ "worker": { "model": { "codex": "gpt-5.1-codex" } } }"#
        let (cfg, cwd) = makeUserConfig("modelmapmiss", roles: roles)
        XCTAssertNil(modelArg(spec(harness(cfg), cwd: cwd, role: .leaf, isRoot: false)),
                     "the map only configured codex → the claude family has no config, must not borrow across families")
    }

    func testSessionModelGuardedBySessionFamily() {
        // A codex root session (agentKey=codex) spawns a claude worker: the session model was
        // recorded for the codex root and must not leak backward into the claude argv.
        let agents = """
        { "agents": {
            "claude": { "bin": "/real/claude" },
            "codex":  { "bin": "/real/codex", "kind": "codex" } } }
        """
        let (cfg, cwd) = makeUserConfig("sessguard", agents: agents)
        let h = harness(cfg, agentKey: "codex", model: "gpt-5.1-codex")
        XCTAssertNil(modelArg(spec(h, cwd: cwd, role: .leaf, isRoot: false)),
                     "session-model family != this node's family → discarded, falls to entry.defaultModel/nil")
    }

    func testLegacyBareModelBindsToRoleAgentFamily() {
        // Backward compat: a bare string binds to "the family of the agent that role
        // declares" (defaulting to claude). When worker.agent=codex, the bare string is meant
        // for codex — the claude side (the non-claude-agent fallback path) must not pick it up.
        let agents = """
        { "agents": {
            "claude": { "bin": "/real/claude" },
            "codex":  { "bin": "/real/codex", "kind": "codex" } } }
        """
        let roles = #"{ "worker": { "agent": "codex", "model": "gpt-5.1-codex" } }"#
        let (cfg, cwd) = makeUserConfig("barebind", agents: agents, roles: roles)
        XCTAssertNil(modelArg(spec(harness(cfg), cwd: cwd, role: .leaf, isRoot: false)),
                     "a bare string follows the role.agent family, no longer matched indiscriminately")
    }

    // MARK: spawn(model) misuse guard (`spawn(model: "codex")` mistakes an agent name for
    // a model name; the roles.json/session model chain guards don't cover the spawn param
    // itself). Only provably wrong values reject; any unverifiable string still passes —
    // Vigil never picks a model for the user.

    /// Builds a DispatchHarness the same way testDispatchLaunchKindResolvesRegistryFamily does
    /// — the guard must go through the exact resolution launchSpec/launchKind use.
    private func dispatchHarness(_ configDir: String?, agentKey: String? = nil) -> DispatchHarness {
        let root = NSTemporaryDirectory() + "vigil_dispatch_guard_\(UUID().uuidString.prefix(8))"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        return DispatchHarness(claudeBin: "/fallback/claude", codexBin: "/c", opencodeBin: "/o",
                               hookBin: "/h", mcpBin: "/m", configRoot: root,
                               userConfigDir: configDir, agentKey: agentKey)
    }

    func testSpawnModelGuardRejectsRegisteredAgentKeyName() {
        // model:"codex" is a registered agent key, not a model — reject, no node created,
        // and the reply names BOTH the mistake and the agent this spawn actually resolves to
        // (here: claude, the only registered entry).
        let agents = """
        { "agents": {
            "claude": { "bin": "/real/claude", "models": ["sonnet", "opus"] },
            "codex":  { "bin": "/real/codex", "kind": "codex" } } }
        """
        let (cfg, cwd) = makeUserConfig("guardkey", agents: agents)
        let err = dispatchHarness(cfg).spawnModelGuardError(model: "codex", role: .leaf, cwd: cwd)
        XCTAssertNotNil(err)
        XCTAssertTrue(err!.contains("agent name"), "must say this is an agent name, not a model name: \(err!)")
        XCTAssertTrue(err!.contains("claude"), "must name the resolved agent: \(err!)")
    }

    func testSpawnModelGuardRejectsKindNameCaseInsensitiveEvenUnregistered() {
        // "opencode" is a CLI-family name even when no agents.json entry happens to use that
        // exact key — the family-name check is independent of the registry key set. Case
        // variants must trip it too (a human mistyping "Codex"/"CODEX").
        let (cfg, cwd) = makeUserConfig("guardkind")   // no agents.json → builtin claude only
        let h = dispatchHarness(cfg)
        for variant in ["CODEX", "Codex", "opencode", "OPENCODE"] {
            XCTAssertNotNil(h.spawnModelGuardError(model: variant, role: .leaf, cwd: cwd),
                            "\(variant) must be rejected as an agent/kind name")
        }
    }

    func testSpawnModelGuardRejectsCrossFamilyModelsListHit() {
        // model is not in the RESOLVED agent's own models list, but it IS a listed model of a
        // DIFFERENT registered agent — a copy-paste from the wrong agent's list.
        let agents = """
        { "agents": {
            "claude": { "bin": "/real/claude", "models": ["sonnet", "opus", "haiku"] },
            "codex":  { "bin": "/real/codex", "kind": "codex",
                        "models": ["gpt-5.1-codex", "gpt-5.1-codex-max"] } } }
        """
        let (cfg, cwd) = makeUserConfig("guardcross", agents: agents)
        // this spawn resolves to claude (no role override) — "gpt-5.1-codex" is codex's model.
        let err = dispatchHarness(cfg).spawnModelGuardError(model: "gpt-5.1-codex", role: .leaf, cwd: cwd)
        XCTAssertNotNil(err)
        XCTAssertTrue(err!.contains("codex"), "must name the agent this model actually belongs to: \(err!)")
    }

    func testSpawnModelGuardAllowsUnknownModelString() {
        // A genuinely unrecognized model string is never provably wrong — Vigil trusts it,
        // never second-guessing a model choice it cannot disprove.
        let agents = """
        { "agents": {
            "claude": { "bin": "/real/claude", "models": ["sonnet", "opus", "haiku"] },
            "codex":  { "bin": "/real/codex", "kind": "codex", "models": ["gpt-5.1-codex"] } } }
        """
        let (cfg, cwd) = makeUserConfig("guardunknown", agents: agents)
        XCTAssertNil(dispatchHarness(cfg).spawnModelGuardError(
            model: "gpt-9-experimental", role: .leaf, cwd: cwd))
    }

    func testSpawnModelGuardAllowsOmittedModelAndEmptyModelsLists() {
        // No agents.json at all → builtin claude fallback has an empty models list on both
        // sides of every check — nothing to disprove against, always passes.
        let (cfg, cwd) = makeUserConfig("guardempty")
        XCTAssertNil(dispatchHarness(cfg).spawnModelGuardError(
            model: "anything-goes", role: .leaf, cwd: cwd))
    }

    func testSpawnModelGuardFollowsProjectRolesOverlayToNewResolvedAgent() {
        // The guard must resolve through the full merge chain (global roles.json → project
        // .vigil/roles.json field-level overlay), not a cached/global-only view — otherwise a
        // project override that changes the child's agent would leave the guard checking
        // against the wrong resolved agent.
        let agents = """
        { "agents": {
            "claude": { "bin": "/real/claude", "models": ["sonnet", "opus"] },
            "codex":  { "bin": "/real/codex", "kind": "codex", "models": ["gpt-5.1-codex"] } } }
        """
        let (cfg, cwd) = makeUserConfig("guardoverlay", agents: agents,
                                        roles: #"{ "worker": { "agent": "claude" } }"#,
                                        projectRoles: #"{ "worker": { "agent": "codex" } }"#)
        let h = dispatchHarness(cfg)
        // "opus" is claude's model — fine against the global resolution...
        XCTAssertNil(h.spawnModelGuardError(model: "gpt-5.1-codex", role: .leaf, cwd: cwd),
                     "the project overlay resolves this worker to codex, so codex's own model passes")
        // ...but "opus" is now a cross-family hit once the project overlay resolves to codex.
        let err = h.spawnModelGuardError(model: "opus", role: .leaf, cwd: cwd)
        XCTAssertNotNil(err, "the project overlay changed the resolved agent to codex — opus is claude's model")
        XCTAssertTrue(err!.contains("claude"))
    }

    func testPromptAppendKeepsVigilSectionAndAddsUserText() {
        let roles = #"{ "worker": { "promptAppend": "Reply in English only." } }"#
        let (cfg, cwd) = makeUserConfig("append", roles: roles)
        let s = spec(harness(cfg), cwd: cwd, role: .leaf, isRoot: false)
        let i = s.args.firstIndex(of: "--append-system-prompt")!
        let skill = s.args[i + 1]
        XCTAssertTrue(skill.contains("report(summary)"), "the Vigil tool-semantics section must still be present (D17 mirror law)")
        XCTAssertTrue(skill.hasSuffix("Reply in English only."), "the user injection is appended after the Vigil section")
    }

    func testPromptOverrideReplacesBase() {
        let roles = #"{ "subManager": { "promptOverride": "You are my custom division sub-manager." } }"#
        let (cfg, cwd) = makeUserConfig("override", roles: roles)
        let plain = spec(harness(cfg), cwd: cwd, role: .manager, isRoot: false)
        let i = plain.args.firstIndex(of: "--append-system-prompt")!
        XCTAssertEqual(plain.args[i + 1], "You are my custom division sub-manager.",
                       "override = whole replacement, the user owns the mirror law")
    }

    func testPromptAppendFileReference() {
        let roles = #"{ "worker": { "promptAppend": "@prompts/worker.md" } }"#
        let (cfg, cwd) = makeUserConfig("atfile", roles: roles,
                                        files: ["prompts/worker.md": "Long injected document content.\n"])
        let s = spec(harness(cfg), cwd: cwd, role: .leaf, isRoot: false)
        let i = s.args.firstIndex(of: "--append-system-prompt")!
        XCTAssertTrue(s.args[i + 1].hasSuffix("Long injected document content."), "@ref reads the file and trims surrounding whitespace")
    }

    // MARK: prompts.json — user-owned base identity text (effect: next dispatch)

    func testPromptsJSONReplacesBuiltinBaseForEachRole() {
        let prompts = """
        { "root": "Custom root identity.",
          "subManager": "Custom sub-manager identity.",
          "worker": "Custom worker identity." }
        """
        let (cfg, cwd) = makeUserConfig("prompts-base", prompts: prompts)
        func sysPrompt(_ role: Role, _ isRoot: Bool) -> String {
            let s = spec(harness(cfg), cwd: cwd, role: role, isRoot: isRoot)
            let i = s.args.firstIndex(of: "--append-system-prompt")!
            return s.args[i + 1]
        }
        XCTAssertTrue(sysPrompt(.manager, true).hasPrefix("Custom root identity."))
        XCTAssertTrue(sysPrompt(.manager, false).hasPrefix("Custom sub-manager identity."))
        XCTAssertTrue(sysPrompt(.leaf, false).hasPrefix("Custom worker identity."))
        // The compiled-in text is gone.
        XCTAssertFalse(sysPrompt(.leaf, false).contains(ClaudeCodeHarness.workerSkill))
    }

    func testPromptsJSONMissingFileOrBlankKeyFallsBackToBuiltin() {
        // No file at all → builtin.
        let (noFile, cwd1) = makeUserConfig("prompts-nofile")
        let s1 = spec(harness(noFile), cwd: cwd1, role: .leaf, isRoot: false)
        XCTAssertTrue(s1.args[s1.args.firstIndex(of: "--append-system-prompt")! + 1]
            .hasPrefix(ClaudeCodeHarness.workerSkill))

        // File present but this role's key is blank/whitespace-only → same fallback.
        let (blank, cwd2) = makeUserConfig("prompts-blank",
                                           prompts: #"{ "worker": "   \n  " }"#)
        let s2 = spec(harness(blank), cwd: cwd2, role: .leaf, isRoot: false)
        XCTAssertTrue(s2.args[s2.args.firstIndex(of: "--append-system-prompt")! + 1]
            .hasPrefix(ClaudeCodeHarness.workerSkill))

        // File present with the literal sentinel "default" → same fallback.
        let (sentinel, cwd3) = makeUserConfig("prompts-default-sentinel",
                                              prompts: #"{ "worker": "default" }"#)
        let s3 = spec(harness(sentinel), cwd: cwd3, role: .leaf, isRoot: false)
        XCTAssertTrue(s3.args[s3.args.firstIndex(of: "--append-system-prompt")! + 1]
            .hasPrefix(ClaudeCodeHarness.workerSkill))

        // File present with an explicit JSON null → same fallback.
        let (nullKey, cwd4) = makeUserConfig("prompts-null-key",
                                             prompts: #"{ "worker": null }"#)
        let s4 = spec(harness(nullKey), cwd: cwd4, role: .leaf, isRoot: false)
        XCTAssertTrue(s4.args[s4.args.firstIndex(of: "--append-system-prompt")! + 1]
            .hasPrefix(ClaudeCodeHarness.workerSkill))
    }

    func testPromptsJSONBaseStillGetsMechanicalLinesAndAppend() {
        // The dynamically-appended lines (rename for root, process hygiene, toolSearch
        // recovery) are code-owned, not identity text — they must still land on top of a
        // prompts.json base, and roles.json promptAppend still appends after it.
        let prompts = #"{ "root": "Custom root identity." }"#
        let roles = #"{ "root": { "promptAppend": "Extra root instructions." } }"#
        let (cfg, cwd) = makeUserConfig("prompts-mechanical", roles: roles, prompts: prompts)
        let s = spec(harness(cfg), cwd: cwd, role: .manager, isRoot: true)
        let text = s.args[s.args.firstIndex(of: "--append-system-prompt")! + 1]
        XCTAssertTrue(text.hasPrefix("Custom root identity."))
        XCTAssertTrue(text.contains("rename(name)"), "the code-owned rename line still appends over a prompts.json base")
        XCTAssertTrue(text.contains("ToolSearch"), "the code-owned tool-search recovery line still appends")
        XCTAssertTrue(text.hasSuffix("Extra root instructions."), "roles.json promptAppend still appends after the prompts.json base")
    }

    func testRolesPromptOverrideBeatsPromptsJSONBase() {
        // promptOverride replaces the base WHOLESALE, regardless of whether that base came
        // from prompts.json or the compiled-in default — same responsibility model as today.
        let prompts = #"{ "worker": "Custom worker identity." }"#
        let roles = #"{ "worker": { "promptOverride": "Totally different text." } }"#
        let (cfg, cwd) = makeUserConfig("prompts-override", roles: roles, prompts: prompts)
        let s = spec(harness(cfg), cwd: cwd, role: .leaf, isRoot: false)
        XCTAssertEqual(s.args[s.args.firstIndex(of: "--append-system-prompt")! + 1],
                       "Totally different text.")
    }

    func testPromptsJSONFlowsIntoCodexAndOpenCodeHarnesses() {
        // Codex/OpenCode take the first-turn prompt through ClaudeCodeHarness.skill too
        // (via their own HarnessResolve.resolve), so prompts.json must reach them the same
        // way it reaches claude.
        let prompts = #"{ "worker": "Custom worker identity." }"#
        let (cfg, cwd) = makeUserConfig("prompts-hetero", prompts: prompts)

        let codexRoot = NSTemporaryDirectory() + "vigil_prompts_codex_\(UUID().uuidString.prefix(8))"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: codexRoot) }
        let codex = CodexHarness(codexBin: "/c", hookBin: "/h", mcpBin: "/m",
                                 configRoot: codexRoot, printMode: true,
                                 userConfigDir: cfg, userCodexHome: codexRoot + "/user-home")
        let codexSpec = codex.launchSpec(task: "", cwd: cwd, nodeID: NodeID("n1"),
                                         role: .leaf, isRoot: false,
                                         mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        XCTAssertTrue(codexSpec.args.last?.hasPrefix("Custom worker identity.") == true)

        let ocRoot = NSTemporaryDirectory() + "vigil_prompts_oc_\(UUID().uuidString.prefix(8))"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: ocRoot) }
        let opencode = OpenCodeHarness(opencodeBin: "/o", hookBin: "/h", mcpBin: "/m",
                                       configRoot: ocRoot, printMode: true, userConfigDir: cfg)
        let ocSpec = opencode.launchSpec(task: "", cwd: cwd, nodeID: NodeID("n1"),
                                         role: .leaf, isRoot: false,
                                         mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        XCTAssertTrue(ocSpec.env["OPENCODE_CONFIG_CONTENT"]?.contains("Custom worker identity.") == true)
    }

    // MARK: prompts.json `extras` — per-line customization of the mechanically-appended
    // text (tool-search/lazy-tools recovery, opencode's line, root's rename hint). Same
    // unified sentinel rule as the base root/subManager/worker keys: nil/"default"/blank
    // (resolved once in PromptTable.load, see the JSON-pipeline test below) keeps the
    // builtin line, any other text replaces it. There is no more "delete this line"
    // capability — a nil field at the skill() layer always means "use the builtin," full
    // stop, since the sentinel resolution already happened upstream.

    func testPromptsExtrasClaudeLineReplacesOrKeepsBuiltin() {
        let base = ClaudeCodeHarness.skill(role: .leaf, isRoot: false, toolSearchRecovery: true)
        XCTAssertTrue(base.contains("ToolSearch"), "nil extras.claude must keep the builtin recovery line")

        let replaced = ClaudeCodeHarness.skill(role: .leaf, isRoot: false,
                                               promptExtras: .init(claude: "Custom claude recovery text."),
                                               toolSearchRecovery: true)
        XCTAssertTrue(replaced.hasSuffix("Custom claude recovery text."))
        XCTAssertFalse(replaced.contains("ToolSearch"), "a non-nil value replaces the builtin verbatim")
    }

    func testPromptsExtrasCodexLineReplacesOrKeepsBuiltin() {
        let base = ClaudeCodeHarness.skill(role: .leaf, isRoot: false, kind: .codex)
        XCTAssertTrue(base.contains("ALL_TOOLS"), "nil extras.codex must keep the builtin lazy-tools line")

        let replaced = ClaudeCodeHarness.skill(role: .leaf, isRoot: false, kind: .codex,
                                               promptExtras: .init(codex: "Custom codex recovery text."))
        XCTAssertTrue(replaced.hasSuffix("Custom codex recovery text."))
        XCTAssertFalse(replaced.contains("ALL_TOOLS"))
    }

    func testPromptsExtrasRenameLineReplacesOrKeepsBuiltin() {
        let base = ClaudeCodeHarness.skill(role: .manager, isRoot: true)
        XCTAssertTrue(base.contains("rename(name)"), "nil extras.rename must keep the builtin hint")

        let replaced = ClaudeCodeHarness.skill(role: .manager, isRoot: true,
                                               promptExtras: .init(rename: "Custom rename hint."))
        XCTAssertTrue(replaced.contains("Custom rename hint."))
        XCTAssertFalse(replaced.contains("rename(name)"))
    }

    func testPromptsExtrasOpencodeLineIsANewCapabilityWithNoBuiltinDefault() {
        // Unlike the other three keys, opencode has no compiled-in mechanical line today —
        // this is new user-reachable capability, not a customization of existing text.
        let base = ClaudeCodeHarness.skill(role: .leaf, isRoot: false, kind: .opencode)
        XCTAssertEqual(base, ClaudeCodeHarness.workerSkill,
                       "nil extras.opencode → nothing appended (no builtin default to fall back to)")

        let replaced = ClaudeCodeHarness.skill(role: .leaf, isRoot: false, kind: .opencode,
                                               promptExtras: .init(opencode: "Custom opencode line."))
        XCTAssertTrue(replaced.hasSuffix("Custom opencode line."))
    }

    func testPromptsExtrasAbsentKeyFallsBackEvenWhenSiblingKeysSet() {
        // extras present with only `rename` configured proves the fallback is evaluated
        // PER KEY — the claude/codex keys staying absent must not be treated as "the whole
        // extras block opted out of the builtin lines".
        let partial = PromptTable.PromptExtras(rename: "Custom rename.")
        let claudeText = ClaudeCodeHarness.skill(role: .leaf, isRoot: false,
                                                 promptExtras: partial, toolSearchRecovery: true)
        XCTAssertTrue(claudeText.contains("ToolSearch"), "the claude key, left unset, must keep its builtin line")
        let codexText = ClaudeCodeHarness.skill(role: .leaf, isRoot: false, kind: .codex, promptExtras: partial)
        XCTAssertTrue(codexText.contains("ALL_TOOLS"), "the codex key, left unset, must keep its builtin line")
        let rootText = ClaudeCodeHarness.skill(role: .manager, isRoot: true, promptExtras: partial)
        XCTAssertTrue(rootText.contains("Custom rename."))
        XCTAssertFalse(rootText.contains("rename(name)"))
    }

    func testPromptsExtrasOverrideStillDropsAllMechanicalLines() {
        // promptOverride replaces the whole base — extras never get a chance to run, same
        // as the existing rename/toolSearch/codex override-drop tests.
        XCTAssertEqual(ClaudeCodeHarness.skill(role: .manager, isRoot: true, kind: .codex,
                                               promptOverride: "custom",
                                               promptExtras: .init(claude: "x", codex: "y",
                                                                   opencode: "z", rename: "w")),
                       "custom")
    }

    func testPromptsJSONSentinelDefaultBlankMissingAndNullAllFallBackThroughFullPipeline() {
        // JSON-level contract, exercised through the real prompts.json → HarnessResolve →
        // each kind-harness pipeline (not just the in-memory PromptTable/PromptExtras
        // structs): the literal string "default", whitespace-only, JSON `null`, and a
        // missing key are all indistinguishable from "unset" — every one of them keeps
        // the builtin text — while any other string replaces it verbatim. Covers a base
        // role key plus all four extras keys in one file.
        let prompts = """
        { "worker": "default",
          "extras": { "claude": "   ", "codex": null, "opencode": "Custom opencode via JSON.",
                       "rename": "Custom rename via JSON." } }
        """
        let (cfg, cwd) = makeUserConfig("prompts-extras-json", prompts: prompts)

        // worker: "default" → falls back to the compiled-in base text.
        let workerSpec = spec(harness(cfg), cwd: cwd, role: .leaf, isRoot: false)
        let workerText = workerSpec.args[workerSpec.args.firstIndex(of: "--append-system-prompt")! + 1]
        XCTAssertTrue(workerText.hasPrefix(ClaudeCodeHarness.workerSkill),
                      "the literal sentinel \"default\" must behave like an absent key")
        // claude: whitespace-only → also falls back (the same trimmed-empty rule as the
        // base fields), so the builtin ToolSearch recovery line is still present.
        XCTAssertTrue(workerText.contains("ToolSearch"), "whitespace-only must behave like an absent key")

        // rename: literal text → replaces the builtin rename line on root.
        let rootSpec = spec(harness(cfg), cwd: cwd, role: .manager, isRoot: true)
        let rootText = rootSpec.args[rootSpec.args.firstIndex(of: "--append-system-prompt")! + 1]
        XCTAssertTrue(rootText.contains("Custom rename via JSON."))
        XCTAssertFalse(rootText.contains("rename(name)"))

        // codex: null → falls back to the builtin lazy-tools line (through CodexHarness
        // directly, since ClaudeCodeHarness never reaches the codex branch).
        let codexRoot = NSTemporaryDirectory() + "vigil_prompts_extras_codex_\(UUID().uuidString.prefix(8))"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: codexRoot) }
        let codex = CodexHarness(codexBin: "/c", hookBin: "/h", mcpBin: "/m",
                                 configRoot: codexRoot, printMode: true,
                                 userConfigDir: cfg, userCodexHome: codexRoot + "/user-home")
        let codexSpec = codex.launchSpec(task: "", cwd: cwd, nodeID: NodeID("n1"),
                                         role: .leaf, isRoot: false,
                                         mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        XCTAssertTrue(codexSpec.args.last?.contains("ALL_TOOLS") == true, "JSON null must behave like an absent key")

        // opencode: literal text → appears in the config-content prompt (through
        // OpenCodeHarness directly).
        let ocRoot = NSTemporaryDirectory() + "vigil_prompts_extras_oc_\(UUID().uuidString.prefix(8))"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: ocRoot) }
        let opencode = OpenCodeHarness(opencodeBin: "/o", hookBin: "/h", mcpBin: "/m",
                                       configRoot: ocRoot, printMode: true, userConfigDir: cfg)
        let ocSpec = opencode.launchSpec(task: "", cwd: cwd, nodeID: NodeID("n1"),
                                         role: .leaf, isRoot: false,
                                         mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        XCTAssertTrue(ocSpec.env["OPENCODE_CONFIG_CONTENT"]?.contains("Custom opencode via JSON.") == true)
    }

    func testProjectVigilRolesOverlayBeatsGlobal() {
        // Three-tier merge: the project's .vigil/roles.json overrides the global config
        // field-by-field (workspace injection).
        let (cfg, cwd) = makeUserConfig(
            "overlay",
            roles: #"{ "worker": { "model": "sonnet", "promptAppend": "global-injected" } }"#,
            projectRoles: #"{ "worker": { "model": "haiku" } }"#)
        let s = spec(harness(cfg), cwd: cwd, role: .leaf, isRoot: false)
        XCTAssertEqual(modelArg(s), "haiku", "the project-level field overrides the global one")
        let i = s.args.firstIndex(of: "--append-system-prompt")!
        XCTAssertTrue(s.args[i + 1].hasSuffix("global-injected"),
                      "a field the project level does not override keeps the global value (field-level merge, not file-level)")
    }

    // MARK: per-role roles.json `access` overrides the session default (wide-open by default)

    private func permHarness(_ configDir: String?, mode: PermissionMode) -> ClaudeCodeHarness {
        let root = NSTemporaryDirectory() + "vigil_ucfg_perm_\(UUID().uuidString.prefix(8))"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        return ClaudeCodeHarness(claudeBin: "/fallback/claude", hookBin: "/h", mcpBin: "/m",
                                 configRoot: root, printMode: true, permissionMode: mode,
                                 userConfigDir: configDir, agentKey: "claude")
    }

    private func permArg(_ s: LaunchSpec) -> String? {
        s.args.firstIndex(of: "--permission-mode").map { s.args[$0 + 1] }
    }

    func testRolesAccessOverridesSessionDefaultPerRole() {
        // Session default = wide open (bypass); roles.json tightens the worker only. The root
        // keeps the session default (no access set), the worker drops to acceptEdits.
        let (cfg, cwd) = makeUserConfig(
            "access", roles: #"{ "worker": { "access": "acceptEdits" } }"#)
        let h = permHarness(cfg, mode: .bypass)
        XCTAssertEqual(permArg(spec(h, cwd: cwd, role: .leaf, isRoot: false)), "acceptEdits",
                       "worker.access overrides the session's wide-open default")
        XCTAssertEqual(permArg(spec(h, cwd: cwd, role: .manager, isRoot: true)),
                       "bypassPermissions", "root sets no access → keeps the session default (wide open)")
    }

    // MARK: claude-theme — seed the resolved terminal theme so claude never queries OSC 11

    func testTerminalThemeSeededIntoSettingsJson() throws {
        // With no `theme` key, claude inherits the user's global `theme: auto` and emits an
        // OSC 11 background query at boot. A Vigil worker spawns off-screen (no ghostty
        // surface), and the HostScreenParser is deliberately inert to queries (to avoid
        // double-reply corruption) — so no answer arrives and claude falls back to a dark
        // palette, producing black prompt-echo/code/diff blocks in a light OS theme. Setting
        // `theme: light|dark` suppresses the OSC 11 query entirely — claude commits the
        // palette from settings, terminal-reply-independent. So it is seeded here.
        let cfgRoot = NSTemporaryDirectory() + "vigil_harness_theme_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let h = ClaudeCodeHarness(claudeBin: "/c", hookBin: "/h", mcpBin: "/m",
                                  configRoot: cfgRoot, printMode: false, terminalTheme: "light")
        let spec = h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n1"),
                                role: .leaf, isRoot: false,
                                mcpEndpoint: "/s/m.sock", hookEndpoint: "/s/h.sock", idCred: "n1")
        let settings = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: cfgRoot + "/n1/settings.json")))
            as? [String: Any]
        XCTAssertEqual(settings?["theme"] as? String, "light", "the resolved theme is seeded into settings.json")
        XCTAssertNotNil(settings?["hooks"], "theme coexists with the observation hooks")
        XCTAssertTrue(spec.args.contains("--settings"))

        // resume takes the same writeAgentConfigs path → theme is seeded identically, and
        // does not depend on the selected-cell surface answering OSC 11.
        _ = h.launchSpec(task: "", cwd: "/w", nodeID: NodeID("n2"),
                         role: .leaf, isRoot: false, resumeSessionId: "sid-1",
                         mcpEndpoint: "/s/m.sock", hookEndpoint: "/s/h.sock", idCred: "n2")
        let rs = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: cfgRoot + "/n2/settings.json")))
            as? [String: Any]
        XCTAssertEqual(rs?["theme"] as? String, "light", "resume and fresh write the same settings")
    }

    func testNoTerminalThemeLeavesSettingsThemeUnset() throws {
        // Backward compat (smoke/parity/tests construct without a theme): no terminalTheme →
        // no `theme` key at all, so claude's own default/user-global rules apply. Vigil never
        // picks a theme when it has none to give — mirrors the model chain's "whole chain empty
        // = no --model flag" honesty.
        let cfgRoot = NSTemporaryDirectory() + "vigil_harness_notheme_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfgRoot) }
        let h = ClaudeCodeHarness(claudeBin: "/c", hookBin: "/h", mcpBin: "/m",
                                  configRoot: cfgRoot, printMode: false)
        _ = h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n1"), role: .leaf, isRoot: false,
                         mcpEndpoint: "/s/m.sock", hookEndpoint: "/s/h.sock", idCred: "n1")
        let settings = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: cfgRoot + "/n1/settings.json")))
            as? [String: Any]
        XCTAssertNil(settings?["theme"], "no terminalTheme → the theme key is not written")
        XCTAssertNotNil(settings?["hooks"], "hooks are written as usual")
    }

    func testDispatchForwardsTerminalThemeToClaudeOnly() throws {
        // The dispatch layer must thread the resolved theme down to the claude sub-harness —
        // the only family with this OSC 11 fresh-spawn bug; codex/opencode are unaffected.
        let root = NSTemporaryDirectory() + "vigil_dispatch_theme_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let d = DispatchHarness(claudeBin: "/c", codexBin: "/cx", opencodeBin: "/o",
                                hookBin: "/h", mcpBin: "/m", configRoot: root,
                                terminalTheme: "dark")
        _ = d.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n1"), role: .leaf, isRoot: false,
                         mcpEndpoint: "/s/m.sock", hookEndpoint: "/s/h.sock", idCred: "n1")
        let settings = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: root + "/n1/settings.json")))
            as? [String: Any]
        XCTAssertEqual(settings?["theme"] as? String, "dark",
                       "DispatchHarness passes terminalTheme through to the claude sub-harness")
    }

    func testRolesAccessAcceptsFriendlyAliases() {
        // PermissionMode(configString:) parses loosely: aliases like "full"/"read-only" work.
        let (cfg, cwd) = makeUserConfig(
            "alias", roles: #"{ "worker": { "access": "read-only" }, "subManager": { "access": "full" } }"#)
        let h = permHarness(cfg, mode: .standard)
        XCTAssertEqual(permArg(spec(h, cwd: cwd, role: .leaf, isRoot: false)), "plan")
        XCTAssertEqual(permArg(spec(h, cwd: cwd, role: .manager, isRoot: false)),
                       "bypassPermissions")
    }
}
