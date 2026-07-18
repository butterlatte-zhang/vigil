import Foundation

// Dependency-inversion seams so VigilCore stays pure (DOCTRINE §2.4). The store
// never imports these to mutate state — it emits Effects; the runtime owns cells.
// They live here so the brain + a FakeCell can be tested without a real agent.

public struct InjectAck: Sendable, Equatable {
    public let delivered: Bool
    public let note: String?
    public init(delivered: Bool, note: String? = nil) { self.delivered = delivered; self.note = note }
}

/// A cell = one node's runtime container. Core talks to cells ONLY through this.
/// For `observed` nodes (§2.8) it degrades to snapshot-only.
public protocol CellHandle: AnyObject, Sendable {
    var nodeID: NodeID { get }
    func start() async
    func inject(_ text: String) async throws -> InjectAck   // ack-bearing (§6.3)
    func snapshot() async -> String                         // rendered screen (read-only)
    func terminate() async
}

public struct LaunchSpec: Sendable, Equatable {
    public let executable: String
    public let args: [String]
    public let env: [String: String]
    /// The first-turn task, delivered by PTY injection after the cell is up rather than
    /// riding argv. Task text in argv is globally readable (`ps`) and a broad
    /// `pkill -f`/`killall` inside one worker could match any sibling/manager whose
    /// argv-carried task shares a word. The interactive product path sets this and leaves
    /// argv flag-only; nil = nothing to inject (headless printMode keeps the prompt in
    /// argv — ephemeral tests/smoke; resume carries no task).
    public let initialPrompt: String?
    public init(executable: String, args: [String], env: [String: String],
                initialPrompt: String? = nil) {
        self.executable = executable; self.args = args; self.env = env
        self.initialPrompt = initialPrompt
    }
}

/// Per-harness strategy (DOCTRINE §2.4, §5.1). Phase 1 only ClaudeCodeHarness.
/// `idCred` = Phase-1 plaintext nodeID / final-design inherited fd (§5.4).
/// Black-box scrape fallback is intentionally NOT in this protocol (§2.4).
public protocol Harness: Sendable {
    var id: String { get }
    /// `role` + `isRoot` select the node's identity prompt and tool surface: root
    /// manager / sub-manager / worker get told who they are and what tools they
    /// hold — behavior is the agent's own. `model` = per-cell model override from
    /// spawn; nil = the harness's session default. `resumeSessionId` non-nil = this
    /// launch CONTINUES an earlier CLI conversation (`--resume <sid>` for claude) —
    /// task must be empty; per-launch, root and workers alike.
    func launchSpec(task: String, cwd: String, nodeID: NodeID,
                    role: Role, isRoot: Bool, model: String?,
                    resumeSessionId: String?,
                    mcpEndpoint: String?, hookEndpoint: String?,
                    idCred: String?) -> LaunchSpec

    /// Which CLI family this node resolves to at launch. The observability layer
    /// (opencode naming via `opencode export`, send-delivery confirmation) branches on it
    /// because opencode has no external transcript_path to tail-read (its store = SQLite).
    /// Default = `.claude` — single-family / fake harnesses never need to override.
    func launchKind(role: Role, isRoot: Bool, cwd: String) -> AgentCLIKind

    /// Does a spawn-time `model` param PROVABLY name the wrong kind of thing — an agent
    /// instead of a model? `role`/`cwd` mirror `launchSpec`'s own resolution inputs (a spawned
    /// child is never root). nil = pass; non-nil = the isError text the spawn is rejected
    /// with, node never created. Default = never rejects (fake/test harnesses have no
    /// registry to check a claim against — same permissive stance as an unrecognized model).
    func spawnModelGuardError(model: String, role: Role, cwd: String) -> String?
}

public extension Harness {
    func launchKind(role: Role, isRoot: Bool, cwd: String) -> AgentCLIKind { .claude }
    func spawnModelGuardError(model: String, role: Role, cwd: String) -> String? { nil }
}
