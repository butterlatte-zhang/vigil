import Foundation

/// Pure, tolerant scans of a claude transcript JSONL.
///
/// Two orchestration-layer invariants both need the transcript as ground truth:
///   • A routed `send` only truly lands when it shows up as a REAL user message
///     in the target's transcript — keystrokes reaching the PTY is not proof, since a
///     mid-turn API error discards queued input (an API error ends the turn with no
///     Stop hook; see OBSERVABILITY.md).
///   • An API-error turn death fires NO Stop hook, so its only durable anchor is
///     the transcript's own error line.
///
/// Tolerant by design (the format is claude-internal, same posture as TranscriptRender):
/// unknown types and malformed lines are skipped, never fatal.
enum TranscriptScan {

    /// True iff `payload` appears as the text of a genuine `user` entry (not an assistant
    /// reply that echoed it, not a tool_result). Whitespace is collapsed on both sides so
    /// claude's rewrapping / space-run collapsing of the submitted prompt still matches.
    static func containsUserMessage(_ payload: String, inJSONL text: String) -> Bool {
        let needle = collapse(payload)
        guard !needle.isEmpty else { return false }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = JSONLine.parse(String(line)),
                  obj["type"] as? String == "user",
                  let msg = obj["message"] as? [String: Any],
                  let body = userText(msg["content"]) else { continue }
            if collapse(body).contains(needle) { return true }
        }
        return false
    }

    /// True iff `payload` appears as a CONSUMED mid-turn injection. claude 2.1.x
    /// never writes a `type:"user"` line for a message injected while a turn is in flight; it
    /// queues the keystrokes and, when the turn boundary consumes them INTO context, records
    /// `{"attachment":{"type":"queued_command","prompt":<original text>},"type":"attachment",…}`. That
    /// consumption record is the honest "made it into context" proof for the mid-turn path — semantically
    /// the exact peer of a `user` line, so containsUserMessage OR this = truly landed.
    /// (The bare `queue-operation enqueue` is NOT consumption — the queue can still be
    /// discarded by an API-error turn death; see hasEnqueuedCommand.)
    static func containsQueuedCommand(_ payload: String, inJSONL text: String) -> Bool {
        let needle = collapse(payload)
        guard !needle.isEmpty else { return false }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = JSONLine.parse(String(line)),
                  let att = obj["attachment"] as? [String: Any],
                  att["type"] as? String == "queued_command",
                  let prompt = att["prompt"] as? String else { continue }
            if collapse(prompt).contains(needle) { return true }
        }
        return false
    }

    /// True iff `payload` is currently ENQUEUED in claude's mid-turn input queue and not yet
    /// consumed. A mid-turn inject lands first as
    /// `{"type":"queue-operation","operation":"enqueue","content":<original text>}`; claude holds it
    /// until the turn boundary. While it sits enqueued the turn is provably still live and the
    /// message WILL be delivered on close — reinjecting only duplicates it into the worker's
    /// context. This is a transcript-grounded liveness proxy, immune to a mis-scraped node
    /// status (e.g. reinjects firing repeatedly against a node the store had wrongly left
    /// non-`.running`). It is deliberately NOT a delivery confirmation —
    /// only the consumption record (containsQueuedCommand / a user line) confirms; an
    /// API-error turn death (hasApiError) releases this hold so the lost message still reinjects.
    static func hasEnqueuedCommand(_ payload: String, inJSONL text: String) -> Bool {
        let needle = collapse(payload)
        guard !needle.isEmpty else { return false }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = JSONLine.parse(String(line)),
                  obj["type"] as? String == "queue-operation",
                  obj["operation"] as? String == "enqueue",
                  let content = obj["content"] as? String else { continue }
            if collapse(content).contains(needle) { return true }
        }
        return false
    }

    /// True iff the transcript carries an API-error line. Two anchors, either suffices:
    /// the `isApiErrorMessage` flag claude stamps on the entry (reliable), or the literal
    /// "API Error" text in an assistant/system content block (fallback).
    static func hasApiError(inJSONL text: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = JSONLine.parse(String(line)) else { continue }
            if obj["isApiErrorMessage"] as? Bool == true { return true }
            if let msg = obj["message"] as? [String: Any],
               let body = assistantOrSystemText(msg["content"]),
               body.localizedCaseInsensitiveContains("API Error") { return true }
            // Some system lines carry the text at top level rather than under `message`.
            if let s = obj["content"] as? String, s.localizedCaseInsensitiveContains("API Error") {
                return true
            }
        }
        return false
    }

    // MARK: content extraction

    /// user content = plain string OR [{type:"text",text:…}] parts. tool_result parts are
    /// deliberately excluded — a tool result that quoted the payload is not the user turn.
    private static func userText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            let pieces = arr.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            return pieces.isEmpty ? nil : pieces.joined(separator: " ")
        }
        return nil
    }

    private static func assistantOrSystemText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            let pieces = arr.compactMap { $0["text"] as? String }
            return pieces.isEmpty ? nil : pieces.joined(separator: " ")
        }
        return nil
    }

    /// Collapse every run of whitespace (incl. newlines) to a single space and trim —
    /// makes the match robust to claude's line-wrapping of the submitted prompt.
    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
