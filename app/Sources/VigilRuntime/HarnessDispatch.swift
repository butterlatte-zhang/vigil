import Foundation
import VigilCore

// The per-launch dispatch layer for heterogeneous workers. A
// heterogeneous tree needs the KIND chosen per launchSpec (root = one kind, a child whose
// roles.json worker.agent="codex" = another), so the registry read + entry resolution is
// lifted to HarnessResolve (shared) and DispatchHarness routes each launch to the matching
// kind-harness. The claude path stays byte-identical (ClaudeCodeHarness re-resolves with
// kind:.claude internally); the double read is a few launch-scoped file reads, negligible.

/// The launch-scoped resolution result: which registry entry + role config this node
/// resolved to, and — derived from the entry — which CLI family to dispatch to.
struct ResolvedAgent {
    let entry: AgentEntry?
    let roleCfg: RoleSetting?
    /// Family of the SESSION's launcher-chosen entry (unfiltered registry lookup;
    /// nil = no registry / key missed). Used by resolveModel's session guard.
    let sessionKind: AgentCLIKind?
    /// The family the role's legacy bare model is BOUND to (defaults to claude) — the
    /// entry-kind of `modelAnchorAgent`, i.e. the agent in effect in the roles.json LAYER
    /// that declared the model (NOT the merged agent: a project overlay swapping `agent`
    /// must not re-anchor a global bare model).
    let roleAgentKind: AgentCLIKind?
    /// prompts.json's base identity text for this role (nil = file/key absent/blank →
    /// the harness's own builtin default). Sits below roleCfg.promptOverride in
    /// ClaudeCodeHarness.skill's assembly order — a promptOverride still wins.
    let promptBase: String?
    /// prompts.json's `extras` block (nil only when userConfigDir itself is nil — the
    /// whole prompts.json feature is inert). Threaded into ClaudeCodeHarness.skill's
    /// mechanical-line assembly.
    let promptExtras: PromptTable.PromptExtras?
    /// No entry (fallback path / no registry) = claude, the built-in default family.
    var kind: AgentCLIKind { entry?.kind ?? .claude }
}

/// The shared, pure agent/role resolution — one truth for the dispatch layer AND every
/// kind-harness (effective-time = read-time: read fresh per launch).
enum HarnessResolve {
    /// Full resolution. `kind` filters which family the role/session key may select:
    /// a kind-harness passes its OWN kind (so a foreign role agent falls back rather than
    /// launching the wrong CLI in isolation); the dispatch layer passes nil to see the
    /// true kind and route on it.
    static func resolve(userConfigDir: String?, claudeBin: String, cwd: String,
                        role: Role, isRoot: Bool, sessionKey: String?,
                        kind: AgentCLIKind? = nil) -> ResolvedAgent {
        let registry: AgentRegistry? = userConfigDir.map {
            AgentRegistry.load(dir: $0) ?? .builtinFallback(claudeBin: claudeBin)
        }
        let roles = userConfigDir.map { RoleTable.load(configDir: $0, projectCwd: cwd) }
        let roleCfg = roles?.setting(role: role, isRoot: isRoot)
        let entry = resolveEntry(registry: registry, sessionKey: sessionKey,
                                 roleKey: isRoot ? nil : roleCfg?.agent, kind: kind)
        let promptTable = userConfigDir.map { PromptTable.load(dir: $0) }
        return ResolvedAgent(entry: entry, roleCfg: roleCfg,
                             sessionKind: sessionKey.flatMap { registry?[$0]?.kind },
                             roleAgentKind: roleCfg?.modelAnchorAgent.flatMap { registry?[$0]?.kind },
                             promptBase: promptTable?.base(role: role, isRoot: isRoot),
                             promptExtras: promptTable?.extras)
    }

    /// Children: role's own agent first, session entry second; root: session entry only
    /// (root's agent is chosen in the launcher). `kind` non-nil restricts role/session matches to that
    /// family. The final fallback is the built-in claude entry — meaningful only for the
    /// agnostic (dispatch) and claude paths; a non-claude kind that matched nothing gets nil
    /// (its harness owns its own bin fallback).
    static func resolveEntry(registry: AgentRegistry?, sessionKey: String?,
                             roleKey: String?, kind: AgentCLIKind? = nil) -> AgentEntry? {
        guard let registry else { return nil }
        func ok(_ e: AgentEntry) -> Bool { e.usable && (kind == nil || e.kind == kind) }
        if let k = roleKey, let e = registry[k], ok(e) { return e }
        if let k = sessionKey, let e = registry[k], ok(e) { return e }
        if kind == nil || kind == .claude {
            return registry["claude"]?.usable == true ? registry["claude"] : nil
        }
        return nil
    }

    /// Model chain, family-namespace aware. Order — root: param (launcher
    /// chip / resume meta) > session > role > entry; children: param (spawn's param is strongest) >
    /// role > session > entry (worker=cheap while the session runs big, this asymmetry is exactly the point).
    /// Guards on every source that could carry a FOREIGN family's alias:
    ///   - roles map form takes exactly this family's key;
    ///   - roles bare string (legacy) is bound to roleCfg.agent's family, default claude;
    ///   - session model applies only when the session's family == this node's family
    ///     (unknown session family — no registry, direct construction — trusts the caller).
    /// The whole chain empty = nil = NO model flag: Vigil never picks a model for the
    /// user; the CLI's own default rules. `kind` = the calling harness's own family.
    static func resolveModel(param: String?, sessionModel: String?,
                             kind: AgentCLIKind, resolved: ResolvedAgent,
                             isRoot: Bool) -> String? {
        let roleModel: String? = {
            if let map = resolved.roleCfg?.modelByKind { return map[kind.rawValue] }
            guard let bare = resolved.roleCfg?.model else { return nil }
            return (resolved.roleAgentKind ?? .claude) == kind ? bare : nil
        }()
        let session = (resolved.sessionKind ?? kind) == kind ? sessionModel : nil
        let entryDefault = resolved.entry?.defaultModel
        if isRoot { return param ?? session ?? roleModel ?? entryDefault }
        return param ?? roleModel ?? session ?? entryDefault
    }

    /// Spawn model-misuse guard: catches `spawn(role: "manager", model: "codex")`-shaped calls
    /// that mistake an agent name for a model name — roles.json alone would resolve the child
    /// to the codex agent and `codex -m codex` would 400 against the backend, leaving the
    /// parent with no idea the child never really started. The roles.json/session model chain
    /// has its own guards; this is the one param those never cover, since a spawn's model
    /// param is trusted by design.
    ///
    /// Only PROVABLE class errors are rejected, never an unverifiable model string
    /// (Vigil does not choose models for the user):
    ///   ① `model` collides with a registered agent key or a CLI family name (claude/codex/
    ///      opencode) — almost certainly an agent name typed into the wrong parameter.
    ///   ② `model` is not in the resolving agent's own `models` list but IS a listed model of
    ///      a DIFFERENT registered agent — almost certainly copied from the wrong agent's list.
    /// Any other string — known or not — passes; an empty/unconfigured `models` list on either
    /// side always passes (nothing to disprove against).
    ///
    /// `resolved` must come from the same `resolve()` call the launch itself uses (single
    /// source of truth, this file's banner comment); `registry` is the same registry read,
    /// passed separately because the guard scans EVERY entry, not just the resolved one.
    static func spawnModelGuardError(model: String, resolved: ResolvedAgent,
                                     registry: AgentRegistry?) -> String? {
        guard let registry else { return nil }
        let resolvedName = resolved.entry?.key ?? "claude"
        let lower = model.lowercased()
        let agentKeyNames = Set(registry.entries.map { $0.key.lowercased() })
        let kindNames: Set<String> = ["claude", "codex", "opencode"]
        if agentKeyNames.contains(lower) || kindNames.contains(lower) {
            return "\"\(model)\" looks like an agent name, not a model name — the child's agent "
                + "is decided by roles.json (this spawn resolves to \"\(resolvedName)\"), not by "
                + "this parameter; omit model to use \(resolvedName)'s own default, or pass an "
                + "actual model name (e.g. \"opus\", \"gpt-5.1\")."
        }
        let resolvedModels = resolved.entry?.models ?? []
        if !resolvedModels.isEmpty, !resolvedModels.contains(model),
           let owner = registry.entries.first(where: { $0.key != resolvedName && $0.models.contains(model) }) {
            return "\"\(model)\" is a model of agent \"\(owner.key)\", not \"\(resolvedName)\" "
                + "(the child's resolved agent) — check roles.json/agents.json, or omit model to "
                + "use \"\(resolvedName)\"'s own default."
        }
        return nil
    }
}

/// The `Harness` the Orchestrator actually holds: it owns one sub-harness per wired
/// CLI family and, at every launchSpec, resolves the node's entry kind-agnostically then
/// delegates to the matching family. It stays out of the fake-agent seam (ScriptHarness is
/// still injected directly by AppModel for UI tests).
public struct DispatchHarness: Harness {
    public let id = "dispatch"

    let claudeBin: String
    let userConfigDir: String?
    let agentKey: String?
    let claude: ClaudeCodeHarness
    let codex: CodexHarness
    let opencode: OpenCodeHarness
    /// The session-wide live color source (same instance every cell's OSC responder reads —
    /// see GhosttyBackend). Point-read at every launchSpec (never cached at construction) so
    /// a theme flip mid-session reaches the NEXT spawn, fresh or resume. nil = no COLORFGBG
    /// injection (vigil-smoke / headless / tests that construct with no color source at all).
    let terminalColorSource: TerminalColorSource?

    public init(claudeBin: String, codexBin: String, opencodeBin: String,
                hookBin: String, mcpBin: String,
                configRoot: String, printMode: Bool = false,
                permissionMode: PermissionMode = .standard,
                model: String? = nil, strictMCP: Bool = false,
                userConfigDir: String? = nil, agentKey: String? = nil,
                terminalTheme: String? = nil,
                terminalColorSource: TerminalColorSource? = nil) {
        self.claudeBin = claudeBin
        self.userConfigDir = userConfigDir
        self.agentKey = agentKey
        self.terminalColorSource = terminalColorSource
        // The sub-harnesses re-resolve internally (each with its own kind filter), so they
        // get the full param set — bin/env/extraArgs/model all still apply.
        // terminalTheme is a Claude settings.json policy and therefore goes to the Claude
        // sub-harness only. The terminal-level OSC responder itself remains agent-agnostic.
        self.claude = ClaudeCodeHarness(
            claudeBin: claudeBin, hookBin: hookBin, mcpBin: mcpBin, configRoot: configRoot,
            printMode: printMode, permissionMode: permissionMode, model: model,
            strictMCP: strictMCP, userConfigDir: userConfigDir, agentKey: agentKey,
            terminalTheme: terminalTheme)
        self.codex = CodexHarness(
            codexBin: codexBin, hookBin: hookBin, mcpBin: mcpBin, configRoot: configRoot,
            printMode: printMode, permissionMode: permissionMode, model: model,
            userConfigDir: userConfigDir, agentKey: agentKey)
        self.opencode = OpenCodeHarness(
            opencodeBin: opencodeBin, hookBin: hookBin, mcpBin: mcpBin, configRoot: configRoot,
            printMode: printMode, permissionMode: permissionMode, model: model,
            userConfigDir: userConfigDir, agentKey: agentKey)
    }

    public func launchSpec(task: String, cwd: String, nodeID: NodeID,
                           role: Role, isRoot: Bool, model: String? = nil,
                           resumeSessionId: String? = nil,
                           mcpEndpoint: String?, hookEndpoint: String?,
                           idCred: String?) -> LaunchSpec {
        let resolved = HarnessResolve.resolve(
            userConfigDir: userConfigDir, claudeBin: claudeBin, cwd: cwd,
            role: role, isRoot: isRoot, sessionKey: agentKey)   // kind: nil = see the truth
        let h: Harness
        switch resolved.kind {
        case .codex:    h = codex
        case .opencode: h = opencode
        default:        h = claude
        }
        let spec = h.launchSpec(task: task, cwd: cwd, nodeID: nodeID, role: role, isRoot: isRoot,
                                model: model, resumeSessionId: resumeSessionId,
                                mcpEndpoint: mcpEndpoint, hookEndpoint: hookEndpoint,
                                idCred: idCred)
        return Self.applyTerminalColorFgBg(
            to: spec, resolvedTheme: terminalColorSource?.terminalThemeSnapshot())
    }

    /// Overlay `COLORFGBG` onto an already-built `LaunchSpec` — the single assembly point for
    /// all three kinds, so the light/dark → "fg;bg" mapping (`TerminalColorFgBg`) lives in
    /// exactly one place rather than being duplicated across ClaudeCodeHarness/CodexHarness/
    /// OpenCodeHarness. Additive only: never touches `args`/`initialPrompt`, and never touches
    /// claude's `theme` settings key or the OSC 10/11 + DEC 2031 self-heal chain those three
    /// harnesses already own. `resolvedTheme` unresolved/nil → no-op (spec unchanged), same
    /// "nothing to give, give nothing" honesty as the model chain.
    static func applyTerminalColorFgBg(to spec: LaunchSpec, resolvedTheme: String?) -> LaunchSpec {
        guard let value = TerminalColorFgBg.value(forTheme: resolvedTheme) else { return spec }
        var env = spec.env
        env["COLORFGBG"] = value
        return LaunchSpec(executable: spec.executable, args: spec.args, env: env,
                          initialPrompt: spec.initialPrompt)
    }

    /// The resolved family, kind-agnostically (same resolution launchSpec uses) — the
    /// Orchestrator captures it per node so opencode observability (naming/delivery) branches.
    public func launchKind(role: Role, isRoot: Bool, cwd: String) -> AgentCLIKind {
        HarnessResolve.resolve(userConfigDir: userConfigDir, claudeBin: claudeBin, cwd: cwd,
                               role: role, isRoot: isRoot, sessionKey: agentKey).kind
    }

    /// The spawn-param model-misuse guard, resolved through the SAME `HarnessResolve
    /// .resolve()` call (kind: nil — the true kind this child would get) that `launchSpec`
    /// itself uses; the registry is re-read separately (launch-scoped, negligible — same
    /// convention as the double read noted in this file's banner) because the guard must
    /// scan every entry, not just the one this role resolves to. A spawned child is never
    /// root, so `isRoot` is always false here.
    public func spawnModelGuardError(model: String, role: Role, cwd: String) -> String? {
        let resolved = HarnessResolve.resolve(userConfigDir: userConfigDir, claudeBin: claudeBin,
                                              cwd: cwd, role: role, isRoot: false,
                                              sessionKey: agentKey)
        let registry: AgentRegistry? = userConfigDir.map {
            AgentRegistry.load(dir: $0) ?? .builtinFallback(claudeBin: claudeBin)
        }
        return HarnessResolve.spawnModelGuardError(model: model, resolved: resolved, registry: registry)
    }
}
