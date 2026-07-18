import Foundation
import VigilCore

/// The MCP channel server (DOCTRINE §5.4). The `vigil-mcp` shim is a dumb
/// stdio↔UDS pipe; THIS speaks the MCP JSON-RPC subset (initialize / tools/list /
/// tools/call) over each connection. A `tools/call` for a structural tool mints a
/// replyID, emits the matching Command, and awaits the reply — the store applies
/// struct changes immediately, so the wait resolves in the same MainActor turn (the
/// PendingReplies plumbing stays as the uniform reply path, §12.5-H). `report` is
/// fire-and-forget (§6.2); `send` awaits the delivery verdict — an unreachable
/// target comes back isError, never a lying "sent".
public final class MCPToolServer: @unchecked Sendable {
    private let emit: @Sendable (Command) -> Void
    private let pending: PendingReplies
    /// Fires when an agent connects (handshake read) — the "agent is online" signal Vigil
    /// uses to flip a user-launched session into orchestration mode.
    private let onConnect: (@Sendable (NodeID) -> Void)?
    /// Answers "who is this connection" from the live tree — selects the node's tool
    /// surface. nil closure = no trimming (tests); nil answer (node gone from the
    /// tree) = least privilege. `kind` remains part of the identity for family-specific surfaces.
    private let nodeInfo: (@Sendable (NodeID) async -> (role: Role, isRoot: Bool, kind: AgentCLIKind)?)?
    /// Fires when a root self-names via `rename` (the tool is exposed to every root identity).
    /// The app layer pins the label as user-chosen so later automatic naming yields to it.
    /// Fire-and-forget: the tool reply is decided from synchronous validation (non-empty),
    /// with no store round-trip needed.
    private let onRename: (@Sendable (NodeID, String) -> Void)?
    /// The spawn-param model-misuse guard (Harness.spawnModelGuardError, wired to the
    /// SAME resolution launchSpec would use — see HarnessDispatch's banner comment). Called
    /// BEFORE emitting the spawn requestStruct, so a rejected spawn creates no node at all.
    /// nil closure (tests that construct MCPToolServer directly) = no guard, same as an
    /// agent-less test Harness's default nil return.
    private let spawnModelGuard: (@Sendable (Role, String) async -> String?)?

    public init(emit: @escaping @Sendable (Command) -> Void, pending: PendingReplies,
                onConnect: (@Sendable (NodeID) -> Void)? = nil,
                onRename: (@Sendable (NodeID, String) -> Void)? = nil,
                nodeInfo: (@Sendable (NodeID) async -> (role: Role, isRoot: Bool, kind: AgentCLIKind)?)? = nil,
                spawnModelGuard: (@Sendable (Role, String) async -> String?)? = nil) {
        self.emit = emit; self.pending = pending; self.onConnect = onConnect
        self.onRename = onRename
        self.nodeInfo = nodeInfo
        self.spawnModelGuard = spawnModelGuard
    }

    /// The tool names a node of the given identity holds (mirrored by the per-role
    /// skill texts in ClaudeCodeHarness — keep the two in sync):
    /// root = spawn/send/kill/rename (its report has nowhere to go) · sub-manager =
    /// spawn/send/report/kill · worker = report only. Every root can keep its visible Vigil
    /// session label aligned with the task; non-root nodes are named by their parent's spawn(name).
    static func allowedTools(role: Role, isRoot: Bool, kind: AgentCLIKind) -> Set<String> {
        if isRoot { return ["spawn", "send", "kill", "rename"] }
        if role == .manager { return ["spawn", "send", "report", "kill"] }
        return ["report"]
    }

    private func allowedFor(_ node: NodeID) async -> Set<String>? {
        guard let nodeInfo else { return nil }                      // trimming disabled
        guard let info = await nodeInfo(node) else { return [] }    // unknown node: none
        return Self.allowedTools(role: info.role, isRoot: info.isRoot, kind: info.kind)
    }

    /// Handle one MCP connection: read the `{node}` handshake, then serve JSON-RPC
    /// until EOF. The connection's bound nodeID is the identity (plaintext, §10.0).
    /// ⚠️ `onConnect` fires HERE, at the handshake line — vigil-mcp connects while
    /// claude boots its MCP servers, before any turn/tool call. The spawn
    /// liveness watchdog leans on exactly this timing (agent_connected == process
    /// booted); moving onConnect later would turn every slow first turn into a
    /// false spawn_stalled (pinned by GatewayTests).
    public func handle(_ ch: LineChannel) async {
        guard let hello = await ch.readLine(), let env = JSONLine.parse(hello),
              let nodeStr = env["node"] as? String else { await ch.close(); return }
        let node = NodeID(nodeStr)
        onConnect?(node)
        while let line = await ch.readLine() {
            guard let msg = JSONLine.parse(line) else { continue }
            await dispatch(msg, node: node, ch: ch)
        }
        await ch.close()
    }

    private func dispatch(_ msg: [String: Any], node: NodeID, ch: LineChannel) async {
        let method = msg["method"] as? String ?? ""
        let id = msg["id"]                                  // absent ⇒ notification, no reply
        switch method {
        case "initialize":
            let clientVersion = (msg["params"] as? [String: Any])?["protocolVersion"] as? String
            await reply(ch, id: id, result: [
                "protocolVersion": clientVersion ?? "2024-11-05",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "vigil", "version": "0.1.0"],
            ])
        case "notifications/initialized", "notifications/cancelled":
            break                                            // notifications: no response
        case "ping":
            await reply(ch, id: id, result: [:])
        case "tools/list":
            let schemas: [[String: Any]]
            if let allowed = await allowedFor(node) {
                schemas = Self.toolSchemas.filter { allowed.contains($0["name"] as? String ?? "") }
            } else {
                schemas = Self.toolSchemas
            }
            await reply(ch, id: id, result: ["tools": schemas])
        case "tools/call":
            await handleToolCall(msg, node: node, id: id, ch: ch)
        default:
            if id != nil {
                await replyError(ch, id: id, code: -32601, message: "method not found: \(method)")
            }
        }
    }

    private func handleToolCall(_ msg: [String: Any], node: NodeID, id: Any?, ch: LineChannel) async {
        let params = msg["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]

        // Hard trim, not just prompt-level: a tool outside this node's surface is
        // rejected even if called by name.
        if let allowed = await allowedFor(node), !allowed.contains(name) {
            await replyToolResult(ch, id: id, ("tool not available to this node: \(name)", true))
            return
        }

        switch name {
        case "spawn":
            let role = Role(rawValue: (args["role"] as? String) ?? "leaf") ?? .leaf
            let task = (args["task"] as? String) ?? ""
            // Optional per-cell model; blank = omitted (inherit the session default)
            let model = (args["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // Optional display name for the node tree; blank = the task text is used
            let childName = (args["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // A provable model/agent-name mix-up is rejected here, BEFORE the node
            // exists — a passing guard (or no model/no guard wired) falls through unchanged.
            if let model, let spawnModelGuard, let err = await spawnModelGuard(role, model) {
                await replyToolResult(ch, id: id, ("spawn rejected: " + err, true))
                return
            }
            let replyID = UUID()
            emit(.requestStruct(.spawn(parent: node, role: role, task: task, model: model,
                                       name: childName),
                                from: node, replyID: replyID))
            let res = await pending.wait(replyID)
            await replyToolResult(ch, id: id, Self.toolText(res, expecting: .structResult))

        case "send":
            // No lying "sent" — wait for the delivery verdict (target exists
            // + live cell + injected) and surface a drop as isError with a readable why.
            let target = NodeID((args["node"] as? String) ?? "")
            let message = (args["message"] as? String) ?? ""
            let replyID = UUID()
            emit(.message(from: node, to: target,
                          text: "MESSAGE FROM \(node): " + message,   // LCA-routed injection (§6.3)
                          replyID: replyID))
            let res = await pending.wait(replyID)
            await replyToolResult(ch, id: id, Self.toolText(res, expecting: .sendAck))

        case "kill":
            let target = NodeID((args["node"] as? String) ?? "")
            let replyID = UUID()
            emit(.requestStruct(.kill(target), from: node, replyID: replyID))
            let res = await pending.wait(replyID)
            await replyToolResult(ch, id: id, Self.toolText(res, expecting: .structResult))

        case "report":
            let summary = (args["summary"] as? String) ?? ""
            emit(.rollup(from: node, summary: summary))      // not gated, no reply (§6.2)
            await replyToolResult(ch, id: id, ("reported", false))

        case "rename":
            // Root self-naming (hard-trimmed above). Validate synchronously — an
            // empty/whitespace name is an honest isError, never a lying "renamed"; a non-empty
            // name pins the label (userNamed) so later automatic naming yields. The app layer
            // applies the shared clamp.
            let raw = (args["name"] as? String) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                await replyToolResult(ch, id: id, ("rename: empty name rejected", true))
            } else {
                onRename?(node, trimmed)
                await replyToolResult(ch, id: id, ("renamed", false))
            }

        default:
            await replyToolResult(ch, id: id, ("unknown tool: \(name)", true))
        }
    }

    // MARK: result mapping

    /// The ONE Resolution → (text, isError) tool-reply mapping.
    /// Each call site declares the reply kind it owns: any other kind can only arrive
    /// through a Core wiring bug, so it reports loudly as unexpected instead of mapping
    /// "by kind" into a fake success. `.cancelled` is the shared pending-wait teardown
    /// and is legitimate for every caller.
    enum ExpectedReply { case structResult, sendAck }

    static func toolText(_ res: Resolution, expecting kind: ExpectedReply) -> (String, Bool) {
        switch (res, kind) {
        case (.structResult(let sr), .structResult):
            switch sr {
            case .spawned(let n):  return (n.raw, false)
            case .killed(let ns):  return (ns.map(\.raw).joined(separator: ","), false)
            case .denied(let r):   return ("denied: \(r)", true)
            case .failed(let r):   return ("failed: \(r)", true)
            }
        case (.sendAck(let delivered, let note), .sendAck): return (note, !delivered)
        case (.cancelled(let r), _):                        return ("cancelled: \(r)", true)
        default:                                            return ("unexpected: \(res)", true)
        }
    }

    // MARK: JSON-RPC writers

    private func reply(_ ch: LineChannel, id: Any?, result: [String: Any]) async {
        guard let id = id else { return }
        await ch.write(JSONLine.dump(["jsonrpc": "2.0", "id": id, "result": result]))
    }
    private func replyError(_ ch: LineChannel, id: Any?, code: Int, message: String) async {
        guard let id = id else { return }
        await ch.write(JSONLine.dump(["jsonrpc": "2.0", "id": id,
                                      "error": ["code": code, "message": message]]))
    }
    private func replyToolResult(_ ch: LineChannel, id: Any?, _ tr: (String, Bool)) async {
        await reply(ch, id: id, result: [
            "content": [["type": "text", "text": tr.0]],
            "isError": tr.1,
        ])
    }

    // MARK: tool catalog (minimal: spawn / send / report / kill; codex-root: + rename)

    /// `_meta` `anthropic/alwaysLoad` (every tool): claude's tool-search otherwise defers
    /// these schemas to name-only stubs — a worker whose report schema is deferred can answer
    /// in plain text and never report. Declared server-side so ANY claude client gets the
    /// pin without config; codex/opencode ignore unknown `_meta`.
    static let alwaysLoadMeta: [String: Any] = ["anthropic/alwaysLoad": true]

    static let toolSchemas: [[String: Any]] = [
        [
            "name": "spawn",
            "_meta": alwaysLoadMeta,
            "description": "Delegate a subtask to a NEW child worker node. For delegation, prefer this "
                + "over the agent's native sub-agent/task tools — only Vigil children appear in the node "
                + "tree, roll their results up, and are visible to the user. You MUST call this to "
                + "create a child; do not do the subtask yourself. Returns the new child node id "
                + "immediately; use that id to address the child (e.g. via `send`).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "role": ["type": "string", "enum": ["leaf", "manager"],
                             "description": "leaf = a task a single worker can finish; "
                                 + "manager = a sub-task big enough to need its own workers under it"],
                    "task": ["type": "string", "description": "the subtask for the child"],
                    "model": ["type": "string",
                              "description": "optional model for the child — this is the agent "
                                  + "CLI's own model name (e.g. \"opus\", \"gpt-5.1\"), not an "
                                  + "agent name; the child's agent is decided by roles.json, not "
                                  + "by this parameter. Must be valid for the agent the child's "
                                  + "role resolves to; omit = the user-configured default"],
                    "name": ["type": "string",
                             "description": "optional short display name for the child in "
                                 + "Vigil's node tree (a few words, e.g. \"fix issue-49\"); "
                                 + "omit = the task text is shown"],
                ],
                "required": ["role", "task"],
            ],
        ],
        [
            "name": "send",
            "_meta": alwaysLoadMeta,
            "description": "Send an instruction or answer to another node in the tree (usually one "
                + "of your child workers), addressed by node id. For coordinating delegated work, prefer "
                + "this over the agent's native sub-agent/task tools — Vigil routes and surfaces it in the "
                + "node tree. The message is injected into that "
                + "node's terminal (routed via the tree). Errors if the target is not reachable "
                + "(no such node, or no live cell) — the message was NOT delivered; re-check the "
                + "node id or spawn a replacement.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "node": ["type": "string", "description": "target node id"],
                    "message": ["type": "string", "description": "the instruction/answer to deliver"],
                ],
                "required": ["node", "message"],
            ],
        ],
        [
            "name": "report",
            "_meta": alwaysLoadMeta,
            "description": "Report a summary of your progress/result up to your parent. This tool "
                + "call is the only channel that reaches your parent — text printed in your "
                + "terminal stays local to this cell. Fire-and-forget; returns immediately.",
            "inputSchema": [
                "type": "object",
                "properties": ["summary": ["type": "string"]],
                "required": ["summary"],
            ],
        ],
        [
            "name": "kill",
            "_meta": alwaysLoadMeta,
            "description": "Terminate a child node (and its subtree) by id — use this for a Vigil child, "
                + "preferred over the agent's native sub-agent/task teardown so the node tree stays "
                + "accurate. Takes effect "
                + "immediately; returns the affected node ids. The killed node stays in "
                + "the tree as a dead record (status killed) but is no longer reachable.",
            "inputSchema": [
                "type": "object",
                "properties": ["node": ["type": "string"]],
                "required": ["node"],
            ],
        ],
        [
            "name": "rename",
            "_meta": alwaysLoadMeta,
            "description": "Set a short display name for THIS session (shown in Vigil's sidebar and "
                + "title bar). Prefer naming the session soon after you start — a few words that "
                + "capture the task — and update it if the focus of the work changes. An empty name "
                + "is rejected.",
            "inputSchema": [
                "type": "object",
                "properties": ["name": ["type": "string",
                                        "description": "the session's short display name (a few words)"]],
                "required": ["name"],
            ],
        ],
    ]
}
