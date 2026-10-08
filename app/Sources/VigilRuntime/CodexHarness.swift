import Foundation
import VigilCore

/// The codex harness. Mirrors ClaudeCodeHarness for the codex CLI (codex-cli 0.142.4,
/// version pinned to a known-good release): a product cell is an INTERACTIVE TUI (not
/// `codex exec`), so the first-turn prompt carries the identity skill and the three
/// channels are wired through a per-node `$CODEX_HOME`:
///   - MCP  → `config.toml [mcp_servers.vigil]` (the SAME vigil-mcp stdio binary as claude);
///   - hooks → `$CODEX_HOME/hooks.json` (UserPromptSubmit/PermissionRequest/PostToolUse/Stop
///     → vigil-hook, identical command-line contract as claude — HookConfig mirror law);
///   - auth → a symlink to the user's real auth.json (token refresh writes through), so we
///     never touch the user's `~/.codex` (clean injection, add-don't-subtract).
/// The per-node home is a VIEW of the user's real codex home, not a from-zero shell:
/// config.toml inherits the user's config with only the Vigil-owned parts replaced
/// (CodexConfigInherit), and AGENTS.md / prompts are passthrough symlinks like auth.json.
/// Permission is agent-native: PermissionMode maps to codex's approval_policy +
/// sandbox_mode tier (bypass → never / danger-full-access, the all-open default).
///
/// Tool-surface trimming needs NO codex-side config: MCPToolServer advertises only the
/// tools a node's role holds (allowedFor) and rejects the rest server-side by BARE name — the
/// wire `tools/call.name` is the server's advertised name regardless of how codex namespaces
/// it for the model. The claude `--allowedTools` flag is only a client-side belt.
public struct CodexHarness: Harness {
    public let id = "codex"

    let codexBin: String
    let hookBin: String
    let mcpBin: String
    let configRoot: String        // per-node CODEX_HOME lives at <configRoot>/<node>/codex-home
    let printMode: Bool           // true = `codex exec` (headless, tests/smoke) · false = TUI
    let permissionMode: PermissionMode
    let model: String?
    let userConfigDir: String?
    let agentKey: String?
    let userHome: String?         // override of the user's real codex home (tests; nil = probe)

    public init(codexBin: String, hookBin: String, mcpBin: String, configRoot: String,
                printMode: Bool = false,
                permissionMode: PermissionMode = .standard,
                model: String? = nil,
                userConfigDir: String? = nil,
                agentKey: String? = nil,
                userCodexHome: String? = nil) {
        self.codexBin = codexBin; self.hookBin = hookBin; self.mcpBin = mcpBin
        self.configRoot = configRoot; self.printMode = printMode
        self.permissionMode = permissionMode; self.model = model
        self.userConfigDir = userConfigDir; self.agentKey = agentKey
        self.userHome = userCodexHome
    }

    /// PermissionMode → (approval_policy, sandbox_mode). bypass = the all-open default;
    /// everything else = a sane guarded tier (codex has no exact claude-mode parallel, so we
    /// keep it simple and testable).
    static func codexPermission(_ mode: PermissionMode) -> (approval: String, sandbox: String) {
        switch mode {
        case .bypass: return ("never", "danger-full-access")
        default:      return ("on-request", "workspace-write")
        }
    }

    public func launchSpec(task: String, cwd: String, nodeID: NodeID,
                           role: Role, isRoot: Bool, model: String? = nil,
                           resumeSessionId: String? = nil,
                           mcpEndpoint: String?, hookEndpoint: String?,
                           idCred: String?) -> LaunchSpec {
        // Launch-scoped resolution — kind:.codex so a role/session agent of another family
        // does not smuggle a foreign bin into this harness (dispatch already routed us here).
        let resolved = HarnessResolve.resolve(
            userConfigDir: userConfigDir, claudeBin: codexBin, cwd: cwd,
            role: role, isRoot: isRoot, sessionKey: agentKey, kind: .codex)
        let entry = resolved.entry
        let roleCfg = resolved.roleCfg

        // Per-role roles.json `access` overrides the session default (all-open fallback).
        let perm = Self.codexPermission(roleCfg?.access ?? permissionMode)
        // Per-node CODEX_HOME = <configRoot>/<node>/codex-home — its own subdir so it never
        // collides with the claude harness's <configRoot>/<node>/{settings,mcp}.json.
        let home = Self.writeCodexHome(
            dir: Self.codexHome(configRoot: configRoot, node: nodeID),
            node: nodeID, hookBin: hookBin, mcpBin: mcpBin,
            hookSock: hookEndpoint, mcpSock: mcpEndpoint,
            approval: perm.approval, sandbox: perm.sandbox, projectCwd: cwd,
            userCodexHome: userHome ?? Self.userCodexHome())

        let resolvedModel = HarnessResolve.resolveModel(
            param: model, sessionModel: self.model, kind: .codex, resolved: resolved,
            isRoot: isRoot)

        var args: [String] = []
        var initialPrompt: String?
        if let sid = resumeSessionId {
            // Continue an earlier codex session; config rides $CODEX_HOME so no extra flags
            // beyond the hook-trust bypass are needed.
            args += ["resume", ClaudeCodeHarness.neutralizeLeadingDash(sid),
                     "--dangerously-bypass-hook-trust"]
        } else {
            if printMode { args.append("exec") }             // headless (tests/smoke) vs TUI cell
            args.append("--dangerously-bypass-hook-trust")   // trust our per-node hooks headlessly
            if let m = resolvedModel { args += ["-m", m] }
            if let extra = entry?.extraArgs, !extra.isEmpty { args += extra }
            // First-turn prompt = the identity skill folded ahead of the task (codex has
            // no --append-system-prompt; the skill is the node's identity + tool guidance).
            let skill = ClaudeCodeHarness.skill(
                role: role, isRoot: isRoot, kind: .codex,
                promptBase: resolved.promptBase,
                promptOverride: roleCfg?.promptOverride, promptAppend: roleCfg?.promptAppend,
                promptExtras: resolved.promptExtras)
            let prompt = task.isEmpty ? skill : skill + "\n\n---\n\n" + task
            // The interactive TUI cell takes this first prompt via PTY injection
            // (RealCell.deliverInitialPrompt), keeping the task (and even the identity skill)
            // out of argv where `ps`/`pkill -f` could read/match it. Headless `codex exec`
            // (tests/smoke, ephemeral) keeps the argv positional — no PTY to inject into.
            if printMode { args.append(ClaudeCodeHarness.neutralizeLeadingDash(prompt)) }
            else { initialPrompt = prompt }
        }

        // Config hygiene: inherit the user env, overlay the entry's env (integration point:
        // base URLs / keys / proxies), then point CODEX_HOME at the per-node dir. Codex has
        // no known nested-session marker to strip.
        var env = ProcessInfo.processInfo.environment
        if let e = entry { for (k, v) in e.env { env[k] = v } }
        env["CODEX_HOME"] = home
        env["TERM"] = vigilFallbackTERM

        let bin = entry.map { VigilConfigDir.expandTilde($0.bin) } ?? codexBin
        return LaunchSpec(executable: bin, args: args, env: env, initialPrompt: initialPrompt)
    }

    // MARK: per-node CODEX_HOME (config.toml + hooks.json + auth.json)

    /// The per-node CODEX_HOME path = `<configRoot>/<node>/codex-home`. One source of truth,
    /// shared by launchSpec (writes it) and the Orchestrator (scans its `sessions/` for the
    /// rollout jsonl to recover session_id + transcript pointer). Deterministic in node id, so a
    /// resume re-incarnation resolves the SAME home where last life's rollout still lives.
    public static func codexHome(configRoot: String, node: NodeID) -> String {
        let nodeDir = (configRoot as NSString).appendingPathComponent(node.raw)
        return (nodeDir as NSString).appendingPathComponent("codex-home")
    }

    /// Build the per-node CODEX_HOME and return its path. config.toml = the USER's real
    /// config.toml with only the Vigil-owned parts replaced (inherit-then-override, see
    /// CodexConfigInherit — model default / profiles / their own MCP servers all carry over);
    /// hooks.json carries the four observation hooks; auth.json / AGENTS.md / prompts are
    /// symlinked from the user's real codex home so they never go stale behind a copy.
    @discardableResult
    static func writeCodexHome(dir: String, node: NodeID, hookBin: String, mcpBin: String,
                               hookSock: String?, mcpSock: String?,
                               approval: String, sandbox: String,
                               projectCwd: String? = nil,
                               userCodexHome: String = CodexHarness.userCodexHome()) -> String {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Vigil-owned overlay: permission tier (top-level keys) + trust + vigil MCP (tables).
        var top = "approval_policy = \(tomlString(approval))\n"
        top += "sandbox_mode = \(tomlString(sandbox))\n"
        // A per-node CODEX_HOME gets a version.json after first run, and codex then pops an
        // "Update available — Update now (npm install -g …)" box on resume: any injected CR
        // would trigger a global npm install. Pin the check off (overrides the user's value).
        top += "check_for_update_on_startup = false\n"
        var tables = ""
        // Under a fresh per-node CODEX_HOME, codex 0.144+ pops a directory-trust box before the
        // composer ("Do you trust the contents of this directory?"), and initialPrompt queues
        // until a human presses Enter. Pre-seeding project trust avoids the box at turn zero,
        // matching the all-open default. The path key must be TOML basic-string escaped
        // (tomlString escapes \ and " char by char), so a cwd with spaces/quotes won't break
        // the table.
        if let cwd = projectCwd, !cwd.isEmpty {
            tables += "\n[projects.\(tomlString(cwd))]\n"
            tables += "trust_level = \"trusted\"\n"
        }
        // Vigil raises the priority of its own tools via skill text and MCP tool descriptions
        // rather than disabling other tools or CLI features.
        if let mcpSock = mcpSock {
            tables += "\n[mcp_servers.vigil]\n"
            tables += "command = \(tomlString(mcpBin))\n"
            let argv = ["--node", node.raw, "--sock", mcpSock].map(tomlString).joined(separator: ", ")
            tables += "args = [\(argv)]\n"
        }
        let userToml = try? String(
            contentsOfFile: (userCodexHome as NSString).appendingPathComponent("config.toml"),
            encoding: .utf8)
        let toml = CodexConfigInherit.merged(
            user: userToml, vigilTopLevel: top, vigilTables: tables,
            projectCwd: (projectCwd?.isEmpty == false) ? projectCwd : nil)
        try? toml.write(toFile: (dir as NSString).appendingPathComponent("config.toml"),
                        atomically: true, encoding: .utf8)

        // hooks.json: same nested shape + vigil-hook contract as claude (HookConfig mirror law).
        if let hookSock = hookSock {
            let hooks = HookConfig.observationHooks(hookBin: hookBin, node: node, hookSock: hookSock)
            FileIO.writeJSON(["hooks": hooks],
                             to: (dir as NSString).appendingPathComponent("hooks.json"),
                             options: [.prettyPrinted])
        }

        // User-home passthrough, read surfaces only (never copy, never touch ~/.codex):
        // auth.json (credentials — token refresh writes through), AGENTS.md (global
        // instructions), prompts/ (custom prompts). Everything STATEFUL stays per-node by
        // design: sessions/ + history + state sqlite (rollout attribution) and the
        // re-downloadable caches (CodexHomePrune's delete set).
        let fm = FileManager.default
        for name in ["auth.json", "AGENTS.md", "prompts"] {
            let src = (userCodexHome as NSString).appendingPathComponent(name)
            let dst = (dir as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: src) {
                try? fm.removeItem(atPath: dst)                    // idempotent re-launch
                try? fm.createSymbolicLink(atPath: dst, withDestinationPath: src)
            } else if (try? fm.destinationOfSymbolicLink(atPath: dst)) != nil {
                try? fm.removeItem(atPath: dst)                    // source gone → no dangling link
            }
        }
        return dir
    }

    /// The user's real codex home = $CODEX_HOME if set, else ~/.codex.
    static func userCodexHome(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let h = env["CODEX_HOME"], !h.isEmpty { return h }
        return NSHomeDirectory() + "/.codex"
    }

    /// Minimal TOML basic-string quoting: escape backslash + double-quote (paths can carry
    /// neither newlines nor control chars in practice, so the basic-string form is enough).
    static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
