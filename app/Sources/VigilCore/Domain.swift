import Foundation

// MARK: - Identity, roles, kinds (DOCTRINE §2.1 · §0 terminology)

public struct NodeID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

/// Capability slot, not a tree position (§3).
public enum Role: String, Codable, Sendable { case leaf, manager }

/// `cell` = Vigil-spawned, own PTY, injectable/takeover-able.
/// `observed` = harness-native sub-agent: no PTY, read-only, depth-1 (DOCTRINE §2.8).
/// The kind exists so we don't weld "node == cell"; observed wiring is not yet implemented.
public enum NodeKind: String, Codable, Sendable { case cell, observed }

/// NodeStatus state machine (DOCTRINE §2.6). `running` =
/// a turn is in flight (UserPromptSubmit→Stop); `idle` = turn closed, nothing pending
/// (a DISPLAY state, not terminal — the process lives); `waiting` = an unresolved
/// notice needs the human; done/failed/killed only on process exit.
public enum NodeStatus: String, Codable, Sendable {
    case starting, running, idle, waiting, done, failed, killed
    /// cell_launch fired but the agent never connected inside the liveness
    /// window — the process may never have been born (dark-screen renderer refusal).
    /// Distinct from `waiting` on purpose: waiting = a human is needed at a
    /// permission prompt; a possibly-unborn spawn must not claim that. Non-terminal —
    /// a child's birth is decoupled from any surface, so a real spawn does not stall on
    /// a renderer refusal; this state is reported and cleared purely off the watchdog
    /// truth chain (Orchestrator spawnWatchdog → .spawnStalled, agent_connected →
    /// .spawnRecovered), and any later real signal (connect/turn/exit) simply overwrites it.
    case stalled
    /// A routed task message is HELD behind the human's own typing (the hold loop)
    /// and outlived the grace. The process is ALIVE and healthy — distinct from `waiting`
    /// (no permission box, so never "awaiting authorization") and from `stalled` (the cell
    /// definitely spawned). Non-terminal; clears the moment the hold releases (delivery /
    /// fail-open / cell death). Priority (SessionStore.attentionStatus): waiting > stalled > queued.
    case queued
    /// The node's turn ended ABNORMALLY — claude hit an API error mid-response
    /// (e.g. `API Error: Connection closed mid-response`) and fired NO Stop
    /// hook, so the parent would otherwise wait forever for a report that never comes.
    /// Independent attention tier, same shape as `.stalled`: distinct from
    /// `waiting` (no permission box — a possibly-dead turn must never claim "awaiting authorization")
    /// and from `stalled` (the cell spawned fine, it was the turn that died). Non-terminal
    /// — the process is alive and idle at its prompt; a new turn / re-engagement clears it.
    /// Priority (SessionStore.attentionStatus): waiting > stalled > errored > queued.
    case errored

    /// Terminal = the node's process is gone; the node stays in the tree as a dead
    /// record (self-death and kill share this rule, first terminal status wins).
    public var isTerminal: Bool { self == .done || self == .failed || self == .killed }
}

/// A tree vertex = an agent instance + a role slot, living in one cell.
public struct Node: Identifiable, Sendable, Equatable {
    public let id: NodeID
    public var kind: NodeKind
    public var role: Role
    public var parent: NodeID?          // nil iff root (single-root invariant)
    public var children: [NodeID]
    public var status: NodeStatus
    public var title: String            // short label / the task it was given
    public var lastRollup: String?      // latest summary it reported up
    /// Per-cell model alias from spawn; nil = inherit the session default.
    public var model: String?
    /// Runtime clock stamps — set by SessionStore's injected clock, never by views:
    /// startedAt = task creation (spawn / session bootstrap); endedAt = the terminal
    /// moment (process exit). The tree panel purely renders these.
    public var startedAt: Date?
    public var endedAt: Date?

    public init(id: NodeID, kind: NodeKind = .cell, role: Role, parent: NodeID? = nil,
                children: [NodeID] = [], status: NodeStatus = .starting,
                title: String = "", lastRollup: String? = nil, model: String? = nil,
                startedAt: Date? = nil, endedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.role = role; self.parent = parent
        self.children = children; self.status = status
        self.title = title; self.lastRollup = lastRollup; self.model = model
        self.startedAt = startedAt; self.endedAt = endedAt
    }
}

// MARK: - Structural changes (DOCTRINE §2.2 · applied immediately, no human gate)

public enum StructRequest: Sendable, Equatable {
    /// `model` = optional per-cell model alias (the manager's choice, never
    /// Vigil's); nil = inherit the session default.
    /// `name` = optional short display name for the child in the node tree (the
    /// manager's label at dispatch time); nil/blank = the task text is shown instead.
    case spawn(parent: NodeID, role: Role, task: String, model: String?, name: String?)
    case kill(NodeID)                                       // cascade-delete subtree

    /// Enum cases can't take default arguments — these overloads provide 3-arg and
    /// 4-arg construction shapes (model = inherit, name = task text).
    public static func spawn(parent: NodeID, role: Role, task: String) -> StructRequest {
        .spawn(parent: parent, role: role, task: task, model: nil, name: nil)
    }
    public static func spawn(parent: NodeID, role: Role, task: String,
                             model: String?) -> StructRequest {
        .spawn(parent: parent, role: role, task: task, model: model, name: nil)
    }
}

// MARK: - Observation notices (a notice is an observation signal, not a gate)

/// Card kinds (PLAN §2 card master table). Each kind has its own slot semantics
/// in SessionStore and its own disappearance rule — click ≠ clear for all: a card
/// lives until its cause actually resolves (PostToolUse pairing / scrape / prompt /
/// node death / hold release).
///   • permission   — a native approval box APPEARED.
///   • injectQueued — a routed task message is HELD behind the human's own typing;
///     rare, actionable (clear your input line) and self-clearing (dies on
///     delivery/fail-open/cell death).
public enum NoticeKind: String, Sendable, Codable {
    case permission
    case injectQueued = "inject-queued"
}

/// How a permission card got resolved — dogfood telemetry vocabulary.
public enum NoticeResolvedVia: String, Sendable {
    case postTool = "post-tool"   // PostToolUse paired by tool_use_id (approval side)
    case scrape                   // box text vanished from the screen (deny blind spot)
    case prompt                   // UserPromptSubmit — user is talking there again
    case nodeDeath = "node-death" // kill / self-death cascade
}

/// The appearance-side payload of a permission box (PermissionRequest hook).
/// PermissionRequest carries NO tool_use_id — the pairing tuple with PostToolUse is
/// (node, promptID, toolName, toolInput verbatim). promptID is a TURN-scoped scope key
/// (same-turn requests share it), not a per-call unique id; identical same-turn tuples
/// resolve FIFO.
public struct PermNoticeInfo: Sendable, Equatable {
    public let promptID: String?
    public let toolName: String?
    public let toolInput: String?     // canonicalized tool_input JSON — pairing component
    public let inputSummary: String?  // short human-readable tool_input digest (display)
    public let text: String           // card subtitle

    public init(promptID: String?, toolName: String?, toolInput: String?,
                inputSummary: String?, text: String) {
        self.promptID = promptID; self.toolName = toolName; self.toolInput = toolInput
        self.inputSummary = inputSummary; self.text = text
    }
}

/// The resolution-side pairing tuple (PostToolUse). toolUseID exists ONLY here:
/// it is kept for log correlation and must never be used as a pairing key.
public struct PermResolveMatch: Sendable, Equatable {
    public let promptID: String?
    public let toolName: String?
    public let toolInput: String?     // canonicalized the same way as the appearance side
    public let toolUseID: String?

    public init(promptID: String?, toolName: String?, toolInput: String?, toolUseID: String?) {
        self.promptID = promptID; self.toolName = toolName
        self.toolInput = toolInput; self.toolUseID = toolUseID
    }
}

/// A non-blocking observation notice from an agent — a permission box appeared in its
/// OWN terminal (PermissionRequest hook). Vigil does not answer it; the UI surfaces it
/// so the human goes to that terminal.
/// No replyID: nothing blocks on this.
/// Session identity is NOT here: Core is per-session; the cross-session aggregation
/// tags each notice with its owning SessionVM above the store.
public struct AgentNotice: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let seq: UInt64            // monotonic arrival order (deterministic; FIFO order)
    public let nodeID: NodeID         // origin node
    public let kind: NoticeKind
    public let text: String           // claude's notification message / card subtitle
    public let promptID: String?      // turn-scoped pairing component
    public let toolName: String?
    public let toolInput: String?     // canonicalized tool_input — pairing component
    public let inputSummary: String?
    /// Real arrival clock (honesty red line: never fabricated).
    public let arrivedAt: Date

    /// Vigil-side grace: a permission card only becomes visible this long after
    /// arrival, so instant approvals (resolved by PostToolUse within the window)
    /// never flash a card. The notice itself exists immediately — resolution must be
    /// able to find it. `var` is a test seam (WiringTests zero it to get an instantly
    /// visible card); product code never writes it.
    public static var permissionGrace: TimeInterval = 2.5
    public var displayAfter: Date {
        kind == .permission ? arrivedAt.addingTimeInterval(Self.permissionGrace) : arrivedAt
    }

    public init(id: UUID = UUID(), seq: UInt64, nodeID: NodeID, kind: NoticeKind,
                text: String, promptID: String? = nil, toolName: String? = nil,
                toolInput: String? = nil, inputSummary: String? = nil,
                arrivedAt: Date = Date()) {
        self.id = id; self.seq = seq; self.nodeID = nodeID; self.kind = kind
        self.text = text; self.promptID = promptID; self.toolName = toolName
        self.toolInput = toolInput; self.inputSummary = inputSummary
        self.arrivedAt = arrivedAt
    }
}

/// One dogfood telemetry record (approval-box frequency data logged unconditionally). Emitted as an Effect —
/// the world side (Orchestrator) appends it to the session dir's jsonl and stamps the
/// wall-clock there; Core stays deterministic.
public struct PermLogEntry: Sendable, Equatable {
    public let event: String          // "perm_request" | "perm_resolve"
    public let nodeID: NodeID
    public let kind: NoticeKind
    public let promptID: String?
    public let toolName: String?
    public let toolUseID: String?     // resolve side only (PostToolUse correlation)
    public let via: String?           // resolve only: NoticeResolvedVia.rawValue

    public init(event: String, nodeID: NodeID, kind: NoticeKind, promptID: String?,
                toolName: String?, toolUseID: String? = nil, via: String?) {
        self.event = event; self.nodeID = nodeID; self.kind = kind
        self.promptID = promptID; self.toolName = toolName
        self.toolUseID = toolUseID; self.via = via
    }
}

/// Agent-tool-native permission level (claude `--permission-mode`). The permission level is
/// each agent tool's native mechanism; Vigil merely passes this value to the harness and does
/// not intercept approvals itself. rawValue IS the flag argument (bypass also goes through
/// --permission-mode, not --dangerously-skip-permissions).
public enum PermissionMode: String, CaseIterable, Sendable {
    case standard = "default"
    case acceptEdits = "acceptEdits"
    case plan = "plan"
    case bypass = "bypassPermissions"

    /// Lenient parse for the settings files (roles.json `access`) — accepts the
    /// raw flag values plus friendly aliases so a hand-edited config isn't brittle. nil =
    /// unrecognized (caller keeps its default = wide-open fallback).
    public init?(configString: String) {
        switch configString.trimmingCharacters(in: .whitespaces).lowercased() {
        case "bypass", "bypasspermissions", "full", "all", "yolo": self = .bypass
        case "default", "standard", "ask": self = .standard
        case "acceptedits", "accept-edits", "edits": self = .acceptEdits
        case "plan", "readonly", "read-only": self = .plan
        default: return nil
        }
    }
}

// MARK: - Command / Effect / Resolution (unidirectional, DOCTRINE §2.3)

/// The single ingress.
public enum Command: Sendable {
    case nodeOnline(NodeID)
    case nodeExited(NodeID, code: Int?)
    case nodeFailed(NodeID, reason: String)
    case requestStruct(StructRequest, from: NodeID, replyID: UUID)  // applied immediately, no human gate
    case rollup(from: NodeID, summary: String)            // report — fire-and-forget
    case message(from: NodeID, to: NodeID, text: String, replyID: UUID?)
        // ↑ send — LCA-routed injection; replyID resolves with the delivery
        //   verdict (.sendAck) so the MCP send tool reports delivery truthfully
    case permRequested(from: NodeID, info: PermNoticeInfo) // a permission box appeared
    case resolveNotice(from: NodeID, match: PermResolveMatch?, via: NoticeResolvedVia)
        // ↑ the approval resolved: PostToolUse tuple pairing, FIFO on identical tuples;
        //   match nil = node-wide (scrape/robustness — a deny cancels the whole turn)
    case clearNotices(NodeID)                             // UserPromptSubmit: ALL kinds die
    case turnStarted(NodeID)                              // UserPromptSubmit: turn opens
    case turnEnded(NodeID, gen: Int?)
        // ↑ turn closes → idle/waiting. gen = WHICH turn the verdict is about:
        //   scrape sources (TurnWatcher) pass it so a stale verdict
        //   can never close a LATER turn; hook (Stop) / resume sources pass nil =
        //   unconditional close (their signal is authoritative for "now").
    case restoreSkeleton(Tree)
        // ↑ Tree afterlife: graft the previous incarnation's replayed skeleton
        //   (SessionArchive.replay of THIS session dir) under the live root — dead
        //   workers show as terminal rows, ready for per-node resume
    case resumeNode(NodeID, sessionID: String)
        // ↑ Per-node resume: re-incarnate ONE terminal node's cell with
        //   `--resume <sessionID>` (sid resolved world-side from the hook-captured map)
    case spawnStalled(NodeID)
        // ↑ cell_launch fired but no agent_connected inside the liveness window —
        //   the cell's process may never have been born. A node in the tree ≠ a live process:
        //   the node goes .stalled (attention tier, own copy — NOT waiting/awaiting authorization)
    case spawnRecovered(NodeID)
        // ↑ The stalled node's agent finally connected — indicator clears
    case injectQueued(NodeID, pending: Int, epoch: UInt64)
        // ↑ A routed message entered the hold loop and outlived the grace —
        //   pending = messages waiting on that cell (the held one + the FIFO tail).
        //   epoch = a per-cell monotonic stamp (RealCell allocates it UNDER its lock in
        //   decision order): the queued/settled callbacks each cross a MainActor hop, so
        //   a count-refresh emitted before a settle can be APPLIED after it — the store
        //   drops any signal whose epoch is not newer than the last one applied for the
        //   node, making apply order irrelevant.
    case injectSettled(NodeID, epoch: UInt64)
        // ↑ The hold released (delivered / fail-open / cell death) — the card dies.
        //   Same epoch discipline as injectQueued.
    case turnErrored(NodeID)
        // ↑ The node's turn died on an API error (no Stop hook fires for an API
        //   error's wrap-up). The world side reads the transcript's error
        //   line and emits this; the node goes .errored (attention tier, own copy —
        //   NOT waiting/awaiting authorization, same shape as spawnStalled) so the human/parent can see
        //   it needs to continue running. Cleared by the next turnStarted / clearNotices (re-engaged).
}

public enum StructResult: Sendable, Equatable {
    case spawned(NodeID)
    case killed([NodeID])
    case denied(reason: String)
    case failed(reason: String)
}

/// What a blocked MCP request gets back (DOCTRINE §2.3). Struct requests resolve
/// synchronously; `.cancelled` remains for teardown races (in-flight reply of a node
/// that died between emit and apply).
public enum Resolution: Sendable, Equatable {
    case structResult(StructResult)
    case cancelled(reason: String)
    case sendAck(delivered: Bool, note: String)        // send delivery verdict to the tool
}

/// The single egress — the only way Core touches the world.
public enum Effect: Sendable, Equatable {
    case spawnCell(node: Node, task: String)
    case resumeCell(node: Node, sessionID: String)
        // ↑ Relaunch the node's cell continuing its CLI conversation
    case killCells([NodeID])
    case route(to: NodeID, text: String, viaPath: [NodeID], replyID: UUID?)
        // ↑ LCA-relayed (§6.3); replyID = a send waiting for its delivery verdict
    case routeFailed(from: NodeID, to: NodeID, reason: String)
        // ↑ Core-side route drop → the runtime logs one orchestration.jsonl failure line
    case deliver(replyID: UUID, Resolution)
    case permLog(PermLogEntry)        // dogfood telemetry → session-dir jsonl (unconditional)
}
