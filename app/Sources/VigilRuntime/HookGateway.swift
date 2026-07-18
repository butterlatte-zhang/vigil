import Foundation
import VigilCore

/// The hook channel server (DOCTRINE §5.1). Claude's hooks are a
/// pure OBSERVATION feed — no PreToolUse blocking, no permissionDecision write-back;
/// approvals happen in claude's own terminal via its native permission flow. One hook
/// firing = one short-lived connection, one envelope line, fire-and-forget:
///   • UserPromptSubmit ("prompt")  → onPrompt (auto-namer) + `.clearNotices` — the user
///     is talking to that terminal again, its wait is over.
///   • PermissionRequest ("perm-request") → `.permRequested` — a permission box appeared
///     (fires once per box, payload has prompt_id/tool_name/tool_input but NO tool_use_id).
///   • PostToolUse ("post-tool") → `.resolveNotice(via: .postTool)` — the tool ran, so
///     its approval (if any) resolved; pairing tuple = prompt_id + tool_name +
///     canonicalized tool_input, tool_use_id tags the log only.
/// Nothing is ever written back — the shim never waits, so fail-open is trivially true.
public final class HookGateway: @unchecked Sendable {
    private let emit: @Sendable (Command) -> Void
    /// UserPromptSubmit context — fire-and-forget input for auto-naming.
    private let onPrompt: (@Sendable (NodeID, [String: Any]) -> Void)?
    /// Stop context: claude appends its ai-title DURING the turn, so
    /// the auto-namer must re-read the transcript when the turn ENDS — at prompt time
    /// the title of a first turn does not exist yet.
    private let onStop: (@Sendable (NodeID, [String: Any]) -> Void)?

    public init(emit: @escaping @Sendable (Command) -> Void,
                onPrompt: (@Sendable (NodeID, [String: Any]) -> Void)? = nil,
                onStop: (@Sendable (NodeID, [String: Any]) -> Void)? = nil) {
        self.emit = emit; self.onPrompt = onPrompt; self.onStop = onStop
    }

    /// Handle one hook connection: read the envelope, emit the matching Command, close.
    public func handle(_ ch: LineChannel) async {
        guard let line = await ch.readLine(), let env = JSONLine.parse(line) else {
            await ch.close(); return
        }
        let node = NodeID((env["node"] as? String) ?? "?")
        let event = (env["event"] as? String) ?? ""
        let payload = Self.payloadDict(env)

        switch HookEvent(rawValue: event) {  // the mount side writes the same enum
        case .prompt:                        // UserPromptSubmit
            onPrompt?(node, payload)
            emit(.turnStarted(node))         // the turn opens before the wait clears
            emit(.clearNotices(node))
        case .stop:                          // Stop (turn ended) → idle/waiting divider
            onStop?(node, payload)           // + auto-namer re-read (ai-title is written to disk within the turn)
            emit(.turnEnded(node, gen: nil))   // Stop is the authoritative close, ignore the generation
        case .permRequest:                   // PermissionRequest (box appeared)
            let tool = payload["tool_name"] as? String
            let summary = Self.inputSummary(payload["tool_input"])
            emit(.permRequested(from: node, info: PermNoticeInfo(
                promptID: payload["prompt_id"] as? String,
                toolName: tool,
                toolInput: Self.canonicalJSON(payload["tool_input"]),
                inputSummary: summary,
                text: "Awaiting approval · \(tool ?? "?")\(summary.map { "(\($0))" } ?? "")")))
        case .postTool:                      // PostToolUse (tool ran → approval resolved)
            emit(.resolveNotice(from: node, match: PermResolveMatch(
                promptID: payload["prompt_id"] as? String,
                toolName: payload["tool_name"] as? String,
                toolInput: Self.canonicalJSON(payload["tool_input"]),
                toolUseID: payload["tool_use_id"] as? String), via: .postTool))
        case nil:
            break                            // unknown events: observe-only channel, drop
                                             // (e.g. "notification" — a live agent's stale
                                             // settings.json stays harmless)
        }
        await ch.close()
    }

    // MARK: parsing

    /// The envelope may carry claude's hook JSON either as a JSON-encoded string
    /// (`payload`) or an inline object (`request`). Tolerate both.
    static func payloadDict(_ env: [String: Any]) -> [String: Any] {
        if let s = env["payload"] as? String, let d = JSONLine.parse(s) { return d }
        if let d = env["payload"] as? [String: Any] { return d }
        if let d = env["request"] as? [String: Any] { return d }
        return [:]
    }

    /// Canonical tool_input string — the pairing component of the (prompt_id, tool_name,
    /// tool_input) tuple. Both PermissionRequest and PostToolUse pass through HERE,
    /// so sorted-keys serialization makes "verbatim-equal" robust to dict key order.
    static func canonicalJSON(_ any: Any?) -> String? {
        guard let any = any else { return nil }
        if let s = any as? String { return s }
        guard JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "\(any)" }
        return s
    }

    /// Short human-readable digest of tool_input for the card (display only, never a key).
    static func inputSummary(_ any: Any?) -> String? {
        guard let d = any as? [String: Any] else { return nil }
        let s = (d["command"] as? String)            // Bash
            ?? (d["file_path"] as? String)           // Edit/Write/Read
            ?? (d["pattern"] as? String)             // Grep/Glob
            ?? (d["url"] as? String)                 // WebFetch
            ?? canonicalJSON(d)
        guard let s = s, !s.isEmpty else { return nil }
        return s.count > 60 ? String(s.prefix(60)) + "…" : s
    }
}
