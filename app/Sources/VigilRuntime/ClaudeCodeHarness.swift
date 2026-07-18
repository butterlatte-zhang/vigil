import Foundation
import VigilCore

/// The claude harness. Owns the Vigil skill artifact and how to inject it into claude, and
/// produces the LaunchSpec that wires the cell to two channels: observation hooks →
/// `vigil-hook` (UserPromptSubmit / PermissionRequest / PostToolUse / Stop) and an MCP
/// server → `vigil-mcp` (spawn/send/report/kill). Permission level is claude's native
/// mechanism (`--permission-mode`) — Vigil passes the mode through and never intercepts
/// approvals. Per-node settings/mcp files overlay the user's own config, and the env strips
/// only the parent session's identity markers — cell env = user env + vigil channels, add
/// don't subtract.
public struct ClaudeCodeHarness: Harness {
    public let id = "claude-code"

    /// VigilApp's Claude policy: stay in native auto mode. `auto` lets claude itself query OSC
    /// 10/11 for the live foreground/background (the host answers even off-screen) and
    /// subscribe to DEC mode 2031, so a later `CSI ?997;n` push from the host makes claude
    /// re-query and redraw on a live theme flip. Pinning to the light/dark value resolved at
    /// launch time is silent and correct at birth but starves that self-heal chain. Accepted
    /// edge: the very first frame, before the OSC round trip lands, may render in a
    /// transitional color.
    public static let terminalTheme = "auto"

    let claudeBin: String
    let hookBin: String
    let mcpBin: String
    let configRoot: String        // where per-node settings.json / mcp.json are written
    let printMode: Bool           // true = `-p` (smoke, headless) · false = interactive (app)
    /// Agent-native permission level. Workers share the harness instance, so a
    /// session's mode is inherited by every cell it launches — the intended semantics.
    let permissionMode: PermissionMode
    /// Model alias passed straight to `claude --model` (nil = claude's own default).
    /// Same inheritance as permissionMode: one harness per session, workers inherit.
    let model: String?
    /// Default (product) = overlay — the vigil server is added to the user's own MCP
    /// config (no-strict is a pure overlay: user + project + injected all connect; a name
    /// collision resolves silently in --mcp-config's favor, so the vigil channel can't be
    /// hijacked). A cell must never be weaker than a bare terminal. true = vigil-smoke/Tier-2
    /// determinism opt-in.
    let strictMCP: Bool
    /// The user config dir (~/.config/vigil) — non-nil turns on the launch-scoped point-read
    /// of agents.json/roles.json at every launchSpec (effective time = read time: edits hit
    /// the next spawn, live cells untouched). nil (default, smoke/parity/tests) disables this
    /// path entirely.
    let userConfigDir: String?
    /// The launcher-selected registry entry — the root's agent, and the fallback for
    /// children whose role declares no agent of its own.
    let agentKey: String?

    /// Claude render-theme setting written into every node's settings.json. VigilApp supplies the
    /// single static value `auto`: Claude may issue OSC 10/11, and the host-managed terminal answers
    /// from its live shared TerminalColorSource even before a surface attaches. The generic fixed
    /// parameter remains for smoke/parity/tests and explicit harness consumers; nil means write no
    /// theme key.
    let fixedTerminalTheme: String?

    public init(claudeBin: String, hookBin: String, mcpBin: String, configRoot: String,
                printMode: Bool = false,
                permissionMode: PermissionMode = .standard,
                model: String? = nil,
                strictMCP: Bool = false,
                userConfigDir: String? = nil,
                agentKey: String? = nil,
                terminalTheme: String? = nil) {
        self.claudeBin = claudeBin; self.hookBin = hookBin; self.mcpBin = mcpBin
        self.configRoot = configRoot; self.printMode = printMode
        self.permissionMode = permissionMode
        self.model = model
        self.strictMCP = strictMCP
        self.userConfigDir = userConfigDir
        self.agentKey = agentKey
        self.fixedTerminalTheme = terminalTheme
    }

    /// The exact env vars a live claude session injects to mark its own session —
    /// inherited into a cell they misattribute identity (nested-session detection, the
    /// parent's session UUID / entrypoint / install dir). Strip these five and nothing
    /// else: an explicit blacklist, never a prefix sweep — CLAUDE_CODE_EXPERIMENTAL_*
    /// and other user feature flags must reach the cell (add don't subtract).
    public static let strippedSessionMarkers = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_EXECPATH",
    ]

    /// Union of Vigil MCP tools Claude may call; MCPToolServer applies the per-node hard trim.
    public static let allowedTools =
        "mcp__vigil__spawn,mcp__vigil__send,mcp__vigil__report,mcp__vigil__kill,mcp__vigil__rename"

    /// Write the per-node settings.json (observation hooks → vigil-hook) + mcp.json
    /// (vigil-mcp shim). Shared by `launchSpec` (Vigil launches the agent) and the shell
    /// pre-season (the user launches it themselves via the PATH shim). Returns the paths.
    /// Hooks are fire-and-forget (instant return) — no PreToolUse blocking, no timeout
    /// tuning. Two observation-only hooks, PermissionRequest (box appeared) and PostToolUse
    /// (approval resolved), let vigil-hook print nothing and exit 0, so the native box is
    /// untouched.
    @discardableResult
    public static func writeAgentConfigs(dir: String, node: NodeID, hookBin: String, mcpBin: String,
                                         hookSock: String?, mcpSock: String?,
                                         theme: String? = nil)
        -> (settings: String?, mcp: String?) {
        // The load-bearing dir guard is in Orchestrator.launchCell, which precreates this
        // nodeDir with a reporting FileIO.createDirectory and hard-fails the spawn if it
        // can't be made — so a config write here never lands a cell with no hooks/no MCP
        // silently. This create stays for the shell pre-season path (no orchestrator), now
        // via the same checked helper.
        FileIO.createDirectory(dir)
        // settings.json holds the observation hooks AND the launch-scoped render-theme policy.
        // Both OVERLAY the user's own settings via `--settings` (--settings MERGES over
        // the user global). VigilApp explicitly writes `auto` so claude's own OSC 10/11 query +
        // DEC 2031 subscription stay live (self-heals on a later theme flip) rather than freezing
        // a session-time snapshot. Written when EITHER is present.
        var settingsDict: [String: Any] = [:]
        if let hookSock = hookSock {
            // Event names = HookEvent: the same truth source HookGateway switches on.
            // Shared with CodexHarness via HookConfig (mirror law). The notification surface
            // is permission events only: PermissionRequest (box appeared) and PostToolUse
            // (approval resolved).
            settingsDict["hooks"] = HookConfig.observationHooks(hookBin: hookBin, node: node, hookSock: hookSock)
        }
        if let theme, !theme.isEmpty {
            // `auto` intentionally permits terminal color discovery. The host answers a
            // surfaceless worker from TerminalColorSource; explicit fixed values remain supported
            // for standalone harness consumers and tests.
            settingsDict["theme"] = theme
        }
        var settingsPath: String?
        if !settingsDict.isEmpty {
            let p = (dir as NSString).appendingPathComponent("settings.json")
            FileIO.writeJSON(settingsDict, to: p, options: [.prettyPrinted])
            settingsPath = p
        }
        var mcpPath: String?
        if let mcpSock = mcpSock {
            let p = (dir as NSString).appendingPathComponent("mcp.json")
            // alwaysLoad (claude ≥2.1.121) exempts the vigil server from tool-search
            // deferral, so the mcp__vigil__ schemas are in the initial context instead of
            // name-only stubs — a worker whose report schema is deferred could otherwise
            // answer in plain text and never report. The toolSearchRecoveryLine self-heal
            // only fires on an attempted call; this closes the never-attempted gap. Older
            // claude versions ignore the unknown key.
            FileIO.writeJSON(["mcpServers": ["vigil": [
                "command": mcpBin, "args": ["--node", node.raw, "--sock", mcpSock],
                "alwaysLoad": true,
            ]]], to: p, options: [.prettyPrinted])
            mcpPath = p
        }
        return (settingsPath, mcpPath)
    }

    public func launchSpec(task: String, cwd: String, nodeID: NodeID,
                           role: Role, isRoot: Bool, model: String? = nil,
                           resumeSessionId: String? = nil,
                           mcpEndpoint: String?, hookEndpoint: String?,
                           idCred: String?) -> LaunchSpec {
        // Launch-scoped point-read (userConfigDir nil = all of this is inert): agents.json +
        // roles.json (global ← project .vigil overlay) are read fresh for THIS launch — the
        // file-edit → next-spawn hot path. Shared with the dispatch layer + CodexHarness via
        // HarnessResolve; `kind: .claude` keeps this harness claude-only in isolation (a
        // codex role agent falls back to the session entry — the dispatch layer is what
        // routes codex to CodexHarness).
        let resolved = HarnessResolve.resolve(
            userConfigDir: userConfigDir, claudeBin: claudeBin, cwd: cwd,
            role: role, isRoot: isRoot, sessionKey: agentKey, kind: .claude)
        let entry = resolved.entry
        let roleCfg = resolved.roleCfg

        let nodeDir = (configRoot as NSString).appendingPathComponent(nodeID.raw)
        let (settingsPath, mcpPath) = ClaudeCodeHarness.writeAgentConfigs(
            dir: nodeDir, node: nodeID, hookBin: hookBin, mcpBin: mcpBin,
            hookSock: hookEndpoint, mcpSock: mcpEndpoint, theme: fixedTerminalTheme)

        var args: [String] = []
        var initialPrompt: String?
        if printMode {
            args += ["-p", Self.neutralizeLeadingDash(task)]
        } else if let sid = resumeSessionId {
            // Continue from a breakpoint; task must be empty. Per-launch (root resume and
            // dead-worker revival take the same path); interactive --resume works combined
            // with the full set of flags.
            args += ["--resume", sid]
        } else if !task.isEmpty {
            // Interactive product cell — task is NOT an argv positional (the ps/pkill
            // mass-kill surface). It rides PTY injection after the TUI is up
            // (RealCell.deliverInitialPrompt), so argv stays flag-only. Injected text needs
            // no leading-dash neutralize (it is typed into the input box, never parsed as a
            // flag).
            initialPrompt = task
        }
        args += ["--append-system-prompt",
                 Self.skill(role: role, isRoot: isRoot,
                            promptBase: resolved.promptBase,
                            promptOverride: roleCfg?.promptOverride,
                            promptAppend: roleCfg?.promptAppend,
                            promptExtras: resolved.promptExtras,
                            toolSearchRecovery: true)]
        if let settingsPath = settingsPath { args += ["--settings", settingsPath] }
        if let mcpPath = mcpPath {
            args += ["--mcp-config", mcpPath]
            if strictMCP { args += ["--strict-mcp-config"] }
        }
        args += ["--allowedTools", Self.allowedTools]
        // Permission level = claude's native mechanism; bypass also goes through this
        // flag (never --dangerously-skip-permissions). Per-role roles.json `access`
        // overrides the session default (which defaults all-open); unset = inherit.
        args += ["--permission-mode", (roleCfg?.access ?? permissionMode).rawValue]
        if let model = HarnessResolve.resolveModel(param: model, sessionModel: self.model,
                                                   kind: .claude, resolved: resolved,
                                                   isRoot: isRoot) {
            args += ["--model", model]
        }
        if let extra = entry?.extraArgs, !extra.isEmpty { args += extra }

        // Strip only the parent session's identity markers — a cell is a first-class
        // session, not a nested child. Everything else passes through (cell env = user
        // env + vigil overlay).
        var env = ProcessInfo.processInfo.environment
        for k in Self.strippedSessionMarkers { env.removeValue(forKey: k) }
        // Vigil does not pin ENABLE_TOOL_SEARCH; it only raises vigil's decision priority
        // (skill text + tool descriptions prefer mcp__vigil__ over native sub-agent tools)
        // without forcing tool-search off. If a deferral occurs, the toolSearchRecoveryLine
        // self-heals. A deliberate agents.json entry.env may still set ENABLE_TOOL_SEARCH —
        // general passthrough below.
        // The entry's env (base URLs / keys / proxies) overlays the inherited env — same
        // add-don't-subtract direction as the vigil channels.
        if let e = entry { for (k, v) in e.env { env[k] = v } }
        // Forced (not just a nil fallback) — rationale at vigilFallbackTERM.
        env["TERM"] = vigilFallbackTERM

        let bin = entry.map { VigilConfigDir.expandTilde($0.bin) } ?? claudeBin
        return LaunchSpec(executable: bin, args: args, env: env, initialPrompt: initialPrompt)
    }

    // MARK: skill artifacts (identity + tools only; behavior is the agent's own)

    /// Selects the identity prompt for a node — these are its load-bearing texts, the
    /// ones that determine whether the skill is actually obeyed. Tool lists here mirror the MCP surface the
    /// server actually exposes per role (MCPToolServer.allowedTools) — the prompt and
    /// the hard tool trim must never disagree.
    ///
    /// Injection surface (roles.json): `promptAppend` is the safe surface — free user text
    /// after the Vigil-owned identity+tools section, mirror law intact.
    /// `promptOverride` replaces the role base entirely (an advanced escape hatch; the user
    /// owns the mirror law then).
    /// `promptBase` is prompts.json's user-owned replacement for the compiled-in
    /// rootSkill/subManagerSkill/workerSkill identity text (nil = that file/key is
    /// absent/blank → the compiled-in default). It sits BELOW `promptOverride` in this
    /// assembly order — a roles.json override still wins wholesale — and the user takes
    /// on the same mirror-law responsibility `promptOverride` already carries.
    /// `toolSearchRecovery` appends the tool-search self-heal line (claude-only — it names
    /// the `ToolSearch` builtin, which codex/opencode lack, so those harnesses call skill()
    /// without it). It is Vigil-owned base content: a `promptOverride` (user replaces the
    /// whole base) drops it, and a user `promptAppend` stays the trailing suffix.
    /// Every root gets the `rename` line, matching MCPToolServer's root surface; non-root
    /// nodes never see it. A `promptOverride` (whole-base replacement) drops it.
    /// Every codex identity additionally gets the codexLazyToolsRecoveryLine (codex defers
    /// MCP schemas under a large tool surface; claude has its own self-heal line, opencode
    /// loads MCP tools upfront). Same override semantics.
    /// `promptExtras` (prompts.json's `extras` block) lets the user customize each of
    /// those four mechanically-appended lines individually. The blank/"default"/missing
    /// sentinel resolution already happened in `PromptTable.load` — by the time it
    /// reaches here, a nil field simply means "append the builtin line" and a non-nil
    /// field means "append this text instead", with no further blank-checking.
    public static func skill(role: Role, isRoot: Bool,
                             kind: AgentCLIKind = .claude,
                             promptBase: String? = nil,
                             promptOverride: String? = nil,
                             promptAppend: String? = nil,
                             promptExtras: PromptTable.PromptExtras? = nil,
                             toolSearchRecovery: Bool = false) -> String {
        var text = promptOverride
            ?? promptBase
            ?? (isRoot ? rootSkill : (role == .manager ? subManagerSkill : workerSkill))
        if promptOverride == nil, isRoot {
            text += "\n" + (promptExtras?.rename ?? sessionRenameLine)
        }
        if promptOverride == nil, kind == .codex {
            text += "\n" + (promptExtras?.codex ?? codexLazyToolsRecoveryLine)
        }
        if promptOverride == nil, kind == .opencode, let line = promptExtras?.opencode {
            // No builtin default for opencode (new capability) — nil means no line at all.
            text += "\n" + line
        }
        if promptOverride == nil, toolSearchRecovery {
            text += "\n" + (promptExtras?.claude ?? toolSearchRecoveryLine)
        }
        if let extra = promptAppend, !extra.isEmpty { text += "\n" + extra }
        return text
    }

    /// Shared manager tool descriptions. Keep these short, but preserve the choices that are
    /// easy to misuse: leaf vs. manager, model vs. agent, visible naming, and graceful vs. forced
    /// coordination. Root and sub-manager interpolate the same strings so their wording cannot
    /// drift.
    static let spawnToolLine =
    "- spawn(role, task, model?, name?): create a child and return its node id. Use leaf for a " +
    "bounded one-worker task; use manager only when the child must delegate. model is a model " +
    "valid for the agent selected by roles.json, not an agent name; omit it for the configured " +
    "default. name is a short label shown in Vigil's node tree."

    static let sendToolLine =
    "- send(node, message): deliver instructions, follow-up context, or a status request to a live child."

    static let killToolLine =
    "- kill(node): immediately terminate a child subtree; use send first when a graceful stop or final report is possible."

    public static let rootSkill = """
    You are the root manager of a Vigil agent tree; the user works with you directly \
    in this terminal.
    Vigil MCP tools:
    \(spawnToolLine)
    \(sendToolLine)
    \(killToolLine)
    Your children's report(...) summaries arrive here in your terminal.
    \(delegationPreferenceLine)
    \(processHygieneRedLine)
    """

    public static let subManagerSkill = """
    You are a sub-manager in a Vigil agent tree: you own one branch of your parent's \
    task.
    Vigil MCP tools:
    \(spawnToolLine)
    \(sendToolLine)
    - report(summary): send your result up to your parent — as an actual call of this \
    Vigil tool, not as text in your reply; only a report(...) call reaches your parent, \
    and a turn that ends without one leaves your parent waiting.
    \(killToolLine)
    \(delegationPreferenceLine)
    \(processHygieneRedLine)
    """

    public static let workerSkill = """
    You are a worker in a Vigil agent tree: You carry out the tasks assigned to you by \
    your manager
    Vigil MCP tool:
    - report(summary): send your result up to your manager — as an actual call of this \
    Vigil tool, not as the word "report" in your reply. Text printed in this terminal \
    stays local to this cell; only a report(...) tool call reaches your manager, and a \
    turn that ends without one leaves your manager waiting. The natural last step of a \
    finished task is a report call carrying a short summary. Replies from your manager \
    arrive in this terminal.
    \(processHygieneRedLine)
    """

    /// Guidance on cleaning up processes a node itself started. Phrased declaratively (states
    /// the consequence, like the tool descriptions above — no "never"/"MUST" imperatives) so
    /// it stays within the identity-scoped register the skill invariant enforces. It adds no
    /// tool name, so the MCPToolServer.allowedTools mirror law is untouched. A by-name kill
    /// (`pkill -f <pattern>`) can match the task-carrying argv of a manager or a sibling and
    /// mass-kill a whole branch — the task text itself is kept out of argv to close that
    /// match surface. A by-name UI action (`osascript`/AppleScript targeting the app process
    /// by name) is just as broad, and can hit another running instance instead of its own, so
    /// the line names both.
    /// Raises Vigil's decision priority without restricting the agent's own tooling. When
    /// there is a subtask to hand off, the agent should reach for the Vigil spawn/send/kill
    /// tools ahead of any native sub-agent/task mechanism — only Vigil children live in the
    /// node tree, roll their results up, and surface to the user; a native sub-agent is
    /// invisible to both. Phrased as a preference ("prefer"), not a restriction — declarative
    /// register, and it adds no mcp__vigil__ call signature, so the allowedTools mirror law
    /// is intact.
    /// root + sub-manager only (they hold spawn); worker (report-only) has nothing to delegate.
    static let delegationPreferenceLine =
    "Delegation: when you hand a subtask to a child, prefer the Vigil spawn/send/kill tools over the " +
    "agent's own sub-agent or task tools — only Vigil children appear in the node tree, roll their " +
    "results back up to you, and show up for the user; a native sub-agent stays invisible to Vigil and to the user."

    /// Keeps the visible session label aligned with the current task across every CLI
    /// family, for all roots. Non-root nodes are named by their parent's spawn(name).
    /// Declarative register (no never/MUST imperatives).
    static let sessionRenameLine =
    "- rename(name): set this session's short label in Vigil's sidebar and title bar; name it " +
    "early and update it when the task focus changes."

    static let processHygieneRedLine =
    "Process hygiene: clean up processes you started by the exact PID you recorded at launch. " +
    "Any by-name operation is a broad match: `pkill -f <pattern>` or `killall` scans every " +
    "process's command line, and `osascript`/AppleScript `tell (application) process \"<name>\"` " +
    "(quit/terminate/click by-name) targets any process or window sharing that name — either can " +
    "match and terminate a sibling worker, your manager, or another running instance, tearing down the tree."

    /// Self-heal for claude only. Claude's interactive tool-search is free to defer
    /// mcp__vigil__ schemas out of the initial context when the combined tool surface is
    /// large, so whenever a vigil tool call comes back unavailable (turn zero under a big
    /// tool surface, a resumed session replaying deferred-tool markers, or a cohort/default
    /// shift mid-session), the agent reloads the schema via ToolSearch and retries.
    /// Declarative register (no imperatives), and it adds no mcp__vigil__ call signature, so
    /// the MCPToolServer.allowedTools mirror law is untouched.
    static let toolSearchRecoveryLine =
    "If a Vigil tool call comes back as not available, its mcp__vigil__ schema was deferred by " +
    "claude's tool-search; running ToolSearch with select:mcp__vigil__<tool-name> reloads that " +
    "schema, and the same call then goes through on retry."

    /// Codex analog of the claude self-heal line. Once the per-node home inherits the user's
    /// own MCP servers (CodexConfigInherit), the combined tool surface can be large enough
    /// that codex defers MCP schemas out of the upfront tool list while its native
    /// multi-agent tools (spawn_agent & co.) stay visible — the manager can reach for the
    /// visible native tool and the Vigil tree misses its children, or a worker whose deferred
    /// tool is `report` finishes silently (claude is pinned via `_meta anthropic/alwaysLoad`,
    /// which codex ignores). Two recovery surfaces exist: classic mode reloads schemas via
    /// codex's tool search; code mode lists them in the ALL_TOOLS registry and calls them as
    /// `tools.mcp__vigil__<tool-name>` inside exec. Declarative register (no imperatives),
    /// and it adds no vigil call signature, so the MCPToolServer.allowedTools mirror law is
    /// untouched.
    static let codexLazyToolsRecoveryLine =
    "Vigil tools under codex may load lazily: they can be missing from the upfront tool list " +
    "(while codex's own multi-agent tools like spawn_agent are visible) yet still be available. " +
    "A tool search for \"vigil\" loads their schemas; in code mode they appear in the ALL_TOOLS " +
    "registry and are callable as `tools.mcp__vigil__<tool-name>` inside exec. Confirming the " +
    "Vigil tools are loaded early in the turn — before the first delegation or the closing " +
    "report — keeps the work visible in the Vigil tree."

    // MARK: helpers

    /// A spawn task is passed to claude as a bare positional arg. A task beginning with
    /// `-` would be parsed as a flag: a prompt-injected manager could smuggle
    /// `--dangerously-skip-permissions` into a child and defeat the inherited permission
    /// mode; a legit task starting with `-` would just fail to launch. Guard with a leading
    /// space — argv-neutralized, prompt semantics unchanged (claude trims leading whitespace
    /// from the prompt).
    static func neutralizeLeadingDash(_ task: String) -> String {
        task.first == "-" ? " " + task : task
    }
}
