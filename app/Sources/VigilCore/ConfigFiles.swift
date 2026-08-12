import Foundation

// The launch-scoped half of settings-as-files. These are
// the config files BOTH VigilApp (launcher UI, install/watch) and VigilRuntime (the
// harness point-reads them at every cell launch) need — so they live in VigilCore.
//
// effective timing = read timing: everything here is read fresh per cell launch —
// edits apply to the NEXT spawn, live cells are untouched (the only honest semantics:
// a running process's flags cannot change). The render-scoped files (appearance.json,
// runtime.json) stay on the VigilApp watcher.
//
// Tolerance contract (mirrors ConfigStore): missing file → that file's defaults;
// unparseable file → same as missing; bad field → that field's default. A config file
// must never be able to take the app down.

// MARK: - config dir resolution

public enum VigilConfigDir {
    /// ~/.config/vigil (the audience lives in the terminal); VIGIL_CONFIG_DIR overrides (tests).
    public static var `default`: String {
        if let d = ProcessInfo.processInfo.environment["VIGIL_CONFIG_DIR"], !d.isEmpty {
            return d
        }
        return NSHomeDirectory() + "/.config/vigil"
    }

    /// "~" / "~/x" → the real home. Registry bins are user-written paths.
    public static func expandTilde(_ p: String) -> String {
        (p as NSString).expandingTildeInPath
    }
}

// MARK: - agents.json (the registry: bins, models, endpoints)

/// Which CLI family an entry drives — picks the harness adaptation, so the CASES are
/// core; the ENTRIES are the user's. claude, codex, and opencode are all wired, each
/// with its own Harness.
public enum AgentCLIKind: String, Codable, Sendable { case claude, codex, opencode, custom }

public extension AgentCLIKind {
    /// The real resume invocation each family uses — shown verbatim in the dead-node /
    /// history resume hint so a heterogeneous worker never claims the wrong syntax. claude
    /// resumes with `--resume <sid>` (ClaudeCodeHarness), codex with `resume <sid>`
    /// (CodexHarness), opencode with `--session <sid>` (OpenCodeHarness; it silently
    /// continues, no picker). `custom` is unknown → claude-shaped fallback.
    var resumeSyntax: String {
        switch self {
        case .claude, .custom: return "claude --resume"
        case .codex:           return "codex resume"
        case .opencode:        return "opencode --session"
        }
    }
}

public struct AgentEntry: Equatable, Sendable {
    public var key: String              // registry key = launcher dropdown item
    public var bin: String              // absolute or tilde-expandable executable path
    public var kind: AgentCLIKind
    // Optional model catalog. The launcher has no model dropdown, so this is not a
    // picker source or an allow-list; it is consumed only to reject a spawn model
    // that is provably listed under a different registered agent. Fresh config does not
    // seed provider catalogs because their model ids change independently of Vigil.
    public var models: [String]
    public var defaultModel: String?
    public var extraArgs: [String]      // appended verbatim (except Codex resume; see README)
    public var env: [String: String]    // endpoint: ANTHROPIC_BASE_URL / keys / proxies

    public init(key: String, bin: String, kind: AgentCLIKind = .claude,
                models: [String] = [], defaultModel: String? = nil,
                extraArgs: [String] = [], env: [String: String] = [:]) {
        self.key = key; self.bin = bin; self.kind = kind
        self.models = models; self.defaultModel = defaultModel
        self.extraArgs = extraArgs; self.env = env
    }

    /// Honesty red line (the launcher only lights up agents proven usable): a kind is usable
    /// once its Harness is wired and verified end to end. claude, codex, and opencode are
    /// all in (each verified: MCP handshake + a real model calling report + the status
    /// channel firing). `custom` stays disabled.
    public var usable: Bool { kind == .claude || kind == .codex || kind == .opencode }
}

public struct AgentRegistry: Equatable, Sendable {
    public var entries: [AgentEntry]

    public init(entries: [AgentEntry]) { self.entries = entries }

    public subscript(key: String) -> AgentEntry? {
        entries.first { $0.key == key }
    }

    /// The compiled-in fallback: agents.json ABSENT (or unreadable — per-file tolerance)
    /// must keep every machine without a config file, and every test, working exactly
    /// as before. An EXISTING file with an empty {} map is a genuinely empty registry,
    /// not this.
    public static func builtinFallback(claudeBin: String) -> AgentRegistry {
        // No models list: Vigil never names models itself (an empty list is also inert —
        // the guard's cross-agent check needs a SECOND entry to ever fire).
        AgentRegistry(entries: [AgentEntry(
            key: "claude", bin: claudeBin, kind: .claude)])
    }

    /// nil = file missing or unparseable (caller falls back to builtinFallback).
    /// JSON objects don't order keys, so the dropdown order is normalized: usable
    /// (claude-kind) entries first, then alphabetical by key.
    public static func load(dir: String) -> AgentRegistry? {
        let path = (dir as NSString).appendingPathComponent("agents.json")
        guard let data = FileManager.default.contents(atPath: path),
              let dto = try? JSONDecoder().decode(FileDTO.self, from: data)
        else { return nil }
        let entries = (dto.agents ?? [:]).compactMap { key, e -> AgentEntry? in
            guard let bin = e.bin, !bin.isEmpty else { return nil }   // bin is the only required field
            let kind = e.kind.flatMap(AgentCLIKind.init(rawValue:))
                ?? AgentCLIKind(rawValue: key) ?? .custom
            return AgentEntry(key: key, bin: bin, kind: kind,
                              models: e.models ?? [],
                              defaultModel: e.defaultModel,
                              extraArgs: e.extraArgs ?? [],
                              env: e.env ?? [:])
        }
        .sorted { a, b in
            if a.usable != b.usable { return a.usable }
            return a.key < b.key
        }
        return AgentRegistry(entries: entries)
    }

    private struct EntryDTO: Decodable {
        var bin: String?; var kind: String?; var models: [String]?
        var defaultModel: String?; var extraArgs: [String]?; var env: [String: String]?
    }
    private struct FileDTO: Decodable { var agents: [String: EntryDTO]? }
}

// MARK: - roles.json (the role matrix)

public struct RoleSetting: Equatable, Sendable {
    /// Registry key for THIS role's agent. Root executable selection ignores this field
    /// (the launcher wins), but merge records it as the family anchor when the same layer
    /// declares a legacy bare-string root model. A child layer pointing at an unusable entry
    /// falls back to the session entry (an honesty red line).
    public var agent: String?
    /// Bare-string model (a legacy-compatible form): bound to the FAMILY of the agent in
    /// effect in the LAYER that declared it (`modelAnchorAgent`, defaults to claude) — it
    /// never crosses into another CLI family's argv.
    public var model: String?
    /// The `agent` value in effect (same layer or below) when the current bare `model` was
    /// declared. A HIGHER layer swapping `agent` (e.g. project .vigil sets
    /// worker.agent="codex" over a global claude entry with a bare claude-family model)
    /// must NOT re-anchor a model it never wrote — otherwise the merged result silently
    /// hands one family's model name to another CLI's argv, which that CLI rejects.
    /// nil = model declared with no agent in sight → the default family (claude).
    /// Maintained by `merge`, consumed by HarnessResolve (map-form models need no anchor).
    public var modelAnchorAgent: String?
    /// Model family namespace: kind rawValue ("claude"/"codex"/"opencode") → model. A family
    /// with no key = user didn't configure it = no model flag at all (Vigil doesn't pick the
    /// model for the user). Mutually exclusive with `model` — whichever form a roles.json
    /// layer writes replaces both.
    public var modelByKind: [String: String]?
    /// Per-role permission tier (launch-scoped, symmetric with `model`). nil = inherit
    /// the session default (wide-open fallback); this field is the surface for
    /// tightening permissions per role. Resolved per launchSpec (roleCfg?.access ?? default).
    public var access: PermissionMode?
    /// Free text appended AFTER the Vigil-owned identity+tools skill.
    public var promptAppend: String?
    /// Advanced escape hatch: REPLACES the built-in role skill entirely — the user owns the
    /// tool-surface mirror law then.
    public var promptOverride: String?

    public init(agent: String? = nil, model: String? = nil,
                modelByKind: [String: String]? = nil, access: PermissionMode? = nil,
                promptAppend: String? = nil, promptOverride: String? = nil,
                modelAnchorAgent: String? = nil) {
        self.agent = agent; self.model = model; self.modelByKind = modelByKind
        self.access = access
        self.promptAppend = promptAppend; self.promptOverride = promptOverride
        self.modelAnchorAgent = modelAnchorAgent
    }
}

public struct RoleTable: Equatable, Sendable {
    public var root = RoleSetting()
    public var subManager = RoleSetting()
    public var worker = RoleSetting()

    public init() {}

    public func setting(role: Role, isRoot: Bool) -> RoleSetting {
        if isRoot { return root }
        return role == .manager ? subManager : worker
    }

    /// Three-layer merge: builtin defaults ← <configDir>/roles.json ←
    /// <projectCwd>/.vigil/roles.json — FIELD-level override, empty strings count as
    /// unset. promptAppend/promptOverride support "@relative/path.md" file references,
    /// resolved against the directory of the file that DECLARED them (global → config
    /// dir, project → <cwd>/.vigil) at load time — launch-scoped, so still hot.
    public static func load(configDir: String?, projectCwd: String?) -> RoleTable {
        var t = RoleTable()
        if let d = configDir {
            t.overlay(file: (d as NSString).appendingPathComponent("roles.json"), baseDir: d)
        }
        if let cwd = projectCwd {
            let vigilDir = (cwd as NSString).appendingPathComponent(".vigil")
            t.overlay(file: (vigilDir as NSString).appendingPathComponent("roles.json"),
                      baseDir: vigilDir)
        }
        return t
    }

    private mutating func overlay(file: String, baseDir: String) {
        guard let data = FileManager.default.contents(atPath: file),
              let dto = try? JSONDecoder().decode(FileDTO.self, from: data) else { return }
        Self.merge(&root, dto.root, baseDir: baseDir)
        Self.merge(&subManager, dto.subManager, baseDir: baseDir)
        Self.merge(&worker, dto.worker, baseDir: baseDir)
    }

    private struct RoleDTO: Decodable {
        var agent: String?; var model: ModelField?; var access: String?
        var promptAppend: String?; var promptOverride: String?

        /// "model" has two forms — bare string (legacy, bound to role.agent's family) or map (family namespace).
        enum ModelField: Decodable {
            case bare(String)
            case byKind([String: String])
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { self = .bare(s) }
                else { self = .byKind(try c.decode([String: String].self)) }
            }
        }
    }
    private struct FileDTO: Decodable {
        var root: RoleDTO?; var subManager: RoleDTO?; var worker: RoleDTO?
    }

    private static func merge(_ s: inout RoleSetting, _ dto: RoleDTO?, baseDir: String) {
        guard let dto else { return }
        if let a = dto.agent, !a.isEmpty { s.agent = a }
        // "model" is one logical field in two forms: a NON-EMPTY value in this layer
        // replaces both wholesale (field-level override leaves no cross-form residue).
        // Empty string/map/null is unset and therefore does not clear a lower layer.
        switch dto.model {
        case .bare(let m) where !m.isEmpty:
            // Anchor the bare model to the agent in effect AS OF THIS LAYER (agent
            // merged just above) — a later layer swapping `agent` keeps this anchor, so
            // the model's family binding never migrates with an agent it wasn't written for.
            s.model = m; s.modelByKind = nil; s.modelAnchorAgent = s.agent
        case .byKind(let map):
            let clean = map.filter { !$0.value.isEmpty }
            if !clean.isEmpty { s.modelByKind = clean; s.model = nil; s.modelAnchorAgent = nil }
        default: break
        }
        if let a = dto.access, let mode = PermissionMode(configString: a) { s.access = mode }
        if let p = resolvePrompt(dto.promptAppend, baseDir: baseDir) { s.promptAppend = p }
        if let p = resolvePrompt(dto.promptOverride, baseDir: baseDir) { s.promptOverride = p }
    }

    private static func resolvePrompt(_ raw: String?, baseDir: String) -> String? {
        guard var s = raw, !s.isEmpty else { return nil }
        if s.hasPrefix("@") {
            let rel = String(s.dropFirst())
            let path = rel.hasPrefix("/") ? rel
                : (baseDir as NSString).appendingPathComponent(rel)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  !text.isEmpty else { return nil }   // dangling ref = unset, never "@x" verbatim
            s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.isEmpty ? nil : s
    }
}

// MARK: - prompts.json (user-owned base identity text, per role)

/// The user-editable base identity text for each of the three roles — an optional
/// replacement for `ClaudeCodeHarness`'s built-in `rootSkill`/`subManagerSkill`/
/// `workerSkill` constants. Sits BELOW roles.json in the prompt-assembly order: a
/// role's `promptOverride` still replaces this base wholesale (same responsibility the
/// user already takes on with promptOverride — mirroring the D17 tool-surface law is on
/// them), and `promptAppend` still appends after whichever base won.
///
/// All seven fields (the three base roles plus `extras`'s four) share ONE tolerance rule,
/// resolved once here at load time — a value counts as "unset" (falls back to the
/// built-in text) when, after trimming whitespace, it is empty OR exactly `"default"`;
/// a missing key or a JSON `null` are the same as an empty string. Any other text is used
/// verbatim. `"default"` is a literal sentinel, not a magic word inside real prose — it
/// exists so the shipped file can seed every key as `"default"` (self-documenting: the
/// file always mirrors the exact key set, and a user only has to replace the ONE key
/// they actually want to change) without special-casing an empty string, which reads as
/// "I meant to clear this" far less clearly than the word itself.
public struct PromptTable: Equatable, Sendable {
    public var root: String?
    public var subManager: String?
    public var worker: String?
    public var extras: PromptExtras

    public init(root: String? = nil, subManager: String? = nil, worker: String? = nil,
               extras: PromptExtras = PromptExtras()) {
        self.root = root; self.subManager = subManager; self.worker = worker
        self.extras = extras
    }

    public func base(role: Role, isRoot: Bool) -> String? {
        if isRoot { return root }
        return role == .manager ? subManager : worker
    }

    /// The four mechanically-appended lines ClaudeCodeHarness.skill folds on top of the
    /// base text — each one keyed by the launch it applies to (kind, or the root-only
    /// rename hint), not by role. Same "default"/blank/missing/null-means-unset rule as
    /// the base three fields (see the type doc) — resolved once in `load`, so by the time
    /// these fields reach `skill()` a nil is simply "append the builtin line" and a
    /// non-nil is simply "append this text", with no further blank-checking there.
    public struct PromptExtras: Equatable, Sendable {
        /// Appended to every claude-kind launch when toolSearchRecovery is requested.
        /// Builtin default: ClaudeCodeHarness.toolSearchRecoveryLine.
        public var claude: String?
        /// Appended to every codex-kind launch. Builtin default: codexLazyToolsRecoveryLine.
        public var codex: String?
        /// Appended to every opencode-kind launch. No builtin default (new capability —
        /// nil means no line at all, same as an unconfigured file).
        public var opencode: String?
        /// Appended to every root identity, any kind. Builtin default: sessionRenameLine.
        public var rename: String?

        public init(claude: String? = nil, codex: String? = nil,
                    opencode: String? = nil, rename: String? = nil) {
            self.claude = claude; self.codex = codex
            self.opencode = opencode; self.rename = rename
        }
    }

    /// Launch-scoped point-read, same convention as RoleTable.load: missing file /
    /// unparseable file / any field resolving to "unset" (see the type doc's sentinel
    /// rule) all fall back to nil (the caller's builtin default).
    public static func load(dir: String) -> PromptTable {
        let path = (dir as NSString).appendingPathComponent("prompts.json")
        guard let data = FileManager.default.contents(atPath: path),
              let dto = try? JSONDecoder().decode(DTO.self, from: data)
        else { return PromptTable() }
        return PromptTable(root: resolveOverride(dto.root),
                           subManager: resolveOverride(dto.subManager),
                           worker: resolveOverride(dto.worker),
                           extras: PromptExtras(claude: resolveOverride(dto.extras?.claude),
                                                codex: resolveOverride(dto.extras?.codex),
                                                opencode: resolveOverride(dto.extras?.opencode),
                                                rename: resolveOverride(dto.extras?.rename)))
    }

    /// nil (key absent / JSON null), whitespace-only, or the literal sentinel `"default"`
    /// (compared after trimming) → nil = unset = the caller's builtin. Any other text is
    /// returned VERBATIM (not trimmed) — a real override is used exactly as written.
    private static func resolveOverride(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "default" { return nil }
        return s
    }

    private struct DTO: Decodable {
        var root: String?; var subManager: String?; var worker: String?
        var extras: ExtrasDTO?
    }
    private struct ExtrasDTO: Decodable {
        var claude: String?; var codex: String?; var opencode: String?; var rename: String?
    }
}

// MARK: - runtime.json (policy values, render-scoped, watch hot-applies)

/// Terminal-observability switch. `off` = zero hot-path cost (TerminalDebugLog.isEnabled
/// early-exits before any allocation); `metrics` = geometry only (HostPTY winsize + surface
/// setSize↔size commit verdicts); `standard` adds surface lifecycle on top. Neither mode ever
/// records user terminal content — geometry and event metadata only — so it is safe to leave on
/// during a repro. Any unrecognized string decodes back to `off`.
public enum TerminalDebugLogMode: String, Sendable, Equatable {
    case off
    case standard
    case metrics

    public init(parsing raw: String) {
        self = TerminalDebugLogMode(rawValue: raw.lowercased()) ?? .off
    }
}

/// Tuning knobs, not state (DOCTRINE unidirectional flow doesn't apply): read at use sites, written only by
/// AppModel.applyConfig (and tests). Language mode v5 relaxed concurrency — the value
/// type is Sendable and writes happen on the main actor in practice.
public struct RuntimeTuning: Equatable, Sendable {
    /// Rest harvester: minutes to wait before silently shutting down a non-focused rest session; <=0 = harvesting off.
    public var harvestAfterMinutes: Int = 60
    /// Cap on live sessions; dispatching a new root over the cap → evict the least-recently-active rest tree; <=0 = unlimited.
    public var maxLiveSessions: Int = 10
    /// A non-focused tree stuck in attention/stalled with no running/starting node, after a timeout (hours)
    /// force-harvest it; <=0 = off (a live tree is never harvested by this — a red line).
    public var harvestStuckAfterHours: Int = 24
    /// Injection-hold safety valve: how many seconds to poll-hold while the input line is non-empty before fail-open.
    public var injectHoldTimeoutSeconds: Int = 300
    /// Cap on the transcript tail read when self-rendering history.
    public var historyTailCapMB: Int = 8
    /// Sidebar project groups with >N rows collapse by default.
    public var sidebarCollapseThreshold: Int = 5
    /// Direct-read naming switch.
    public var autoName: Bool = true
    /// Approval-box frequency dogfood logged to disk.
    public var permDogfoodLog: Bool = true
    /// Seconds a fresh spawn may go without agent_connected before it is honestly
    /// reported stalled. Read at watchdog arm.
    public var spawnStallSeconds: Int = 15
    /// Seconds RealCell waits for the composer to be ready before fail-opening the
    /// initial-prompt injection (too low can drop the first prompt).
    /// Read at cell birth — applies to the next dispatched cell.
    public var initialPromptReadyTimeoutSeconds: Int = 30
    /// Reinject budget for an unconfirmed send() after its turn died, before failure
    /// is reported back to the caller.
    public var deliveryMaxAttempts: Int = 3
    /// Seconds an unconfirmed delivery waits after its turn dies before it is
    /// re-injected.
    public var deliveryReinjectGraceSeconds: Int = 4
    /// The ephemeral bottom-right "spawned … under …" / "killed …" orchestration toast.
    /// Notification CARDS are permission events only — this structural float is opt-in
    /// noise, so it is OFF by default; flip true to watch spawn/kill events fly by.
    /// Read at the toast site.
    public var orchestrationToasts: Bool = false
    /// The executable the ⌘J scratch shell launches (always as an interactive login
    /// shell, argv `-l -i`). Empty / "auto" = follow `$SHELL` (fallback /bin/zsh) — the
    /// built-in behavior made explicit. Read at panel birth (the next ⌘J open), so
    /// edits are hot without a restart.
    public var bottomShellCommand: String = ""
    /// Terminal geometry/lifecycle debug log to `<sessionDir>/terminal-debug.log`.
    /// Default off = no telemetry, no cost.
    public var terminalDebugLog: TerminalDebugLogMode = .off
    /// Nudge a non-root node once when its turn ends with no report() call reaching
    /// its parent (the "silent dummy report" failure mode). Default on; false = the
    /// Orchestrator's turnEnded handler skips the check entirely.
    public var reportWatchdog: Bool = true

    public init() {}
    public static let defaults = RuntimeTuning()

    /// The live values every use site reads; AppModel.applyConfig lands file edits here.
    public nonisolated(unsafe) static var current = RuntimeTuning()

    public static func load(dir: String) -> RuntimeTuning {
        var t = RuntimeTuning()
        let path = (dir as NSString).appendingPathComponent("runtime.json")
        guard let data = FileManager.default.contents(atPath: path),
              let dto = try? JSONDecoder().decode(DTO.self, from: data) else { return t }
        if let v = dto.harvestAfterMinutes { t.harvestAfterMinutes = v }
        if let v = dto.maxLiveSessions { t.maxLiveSessions = v }             // <=0 is valid = unlimited
        if let v = dto.harvestStuckAfterHours { t.harvestStuckAfterHours = v } // <=0 is valid = off
        if let v = dto.injectHoldTimeoutSeconds, v > 0 { t.injectHoldTimeoutSeconds = v }
        if let v = dto.historyTailCapMB, v > 0 { t.historyTailCapMB = v }
        if let v = dto.sidebarCollapseThreshold, v > 0 { t.sidebarCollapseThreshold = v }
        if let v = dto.autoName { t.autoName = v }
        if let v = dto.permDogfoodLog { t.permDogfoodLog = v }
        // Same convention as the inject valve — only positive values
        // apply; 0/negative silently keeps the default (documented in the README).
        if let v = dto.spawnStallSeconds, v > 0 { t.spawnStallSeconds = v }
        if let v = dto.initialPromptReadyTimeoutSeconds, v > 0 {
            t.initialPromptReadyTimeoutSeconds = v
        }
        if let v = dto.deliveryMaxAttempts, v > 0 { t.deliveryMaxAttempts = v }
        if let v = dto.deliveryReinjectGraceSeconds, v > 0 {
            t.deliveryReinjectGraceSeconds = v
        }
        if let v = dto.orchestrationToasts { t.orchestrationToasts = v }
        // Bottom-shell command: any non-empty string is a valid override; "auto" is the
        // explicit synonym for the built-in $SHELL behavior (normalized to "" so the use
        // site has a single "follow $SHELL" sentinel).
        if let v = dto.bottomShellCommand {
            let trimmed = v.trimmingCharacters(in: .whitespaces)
            t.bottomShellCommand = trimmed.lowercased() == "auto" ? "" : trimmed
        }
        // An unrecognized string decodes to .off (TerminalDebugLogMode(parsing:)),
        // matching the "invalid value keeps the default" convention above.
        if let v = dto.terminalDebugLog { t.terminalDebugLog = TerminalDebugLogMode(parsing: v) }
        if let v = dto.reportWatchdog { t.reportWatchdog = v }
        return t
    }

    private struct DTO: Decodable {
        var harvestAfterMinutes: Int?; var injectHoldTimeoutSeconds: Int?
        var maxLiveSessions: Int?; var harvestStuckAfterHours: Int?
        var historyTailCapMB: Int?; var sidebarCollapseThreshold: Int?
        var autoName: Bool?; var permDogfoodLog: Bool?
        var spawnStallSeconds: Int?; var initialPromptReadyTimeoutSeconds: Int?
        var deliveryMaxAttempts: Int?; var deliveryReinjectGraceSeconds: Int?
        var orchestrationToasts: Bool?; var bottomShellCommand: String?
        var terminalDebugLog: String?
        var reportWatchdog: Bool?
    }
}
