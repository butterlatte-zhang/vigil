import Foundation
import VigilCore

// Codex transcript/resume deep integration — the codex-side sid + transcript capture surface.
//
// The three families each capture their sid a different way (honesty red line: read exactly
// what can be read from the outside):
//   - claude   → the UserPromptSubmit hook sends session_id + transcript_path (claude field names);
//   - opencode → the plugin's session.idle→stop sends session_id only (transcript is in SQLite,
//                no external JSONL);
//   - codex    → **sends nothing**. codex neither honors claude-style hooks.json nor emits
//                prompt/stop events, but every codex node has an isolated CODEX_HOME
//                (CodexHarness.codexHome), and after a turn the rollout jsonl immediately lands at
//                `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ISO-ts>-<uuid>.jsonl`
//                (codex 0.144.1). session_id = the trailing uuid of the file name
//                = line 0 session_meta's payload.session_id (doubly redundant). Vigil scans this
//                directory directly to recover the sid/pointer and feeds it into the SAME
//                `agent_prompt` orchestration event as claude — replay needs no change.
//
// The pointer philosophy: the rollout belongs to codex's native lifecycle; we
// only store the pointer, and if the file is gone the UI honestly says so.
public enum CodexRollout {

    /// The capture result: session id (resume credential) + newest rollout file path (transcript pointer).
    public struct Capture: Equatable, Sendable {
        public let sessionId: String
        public let path: String
        public init(sessionId: String, path: String) {
            self.sessionId = sessionId; self.path = path
        }
    }

    /// Scan for the newest rollout under codexHome and return (sessionId, path). Not found = nil
    /// (honest degradation: no rollout → no credential, no transcript, never fabricate an empty shell).
    public static func capture(codexHome: String) -> Capture? {
        guard let path = newestRollout(codexHome: codexHome),
              let sid = sessionId(rolloutPath: path) else { return nil }
        return Capture(sessionId: sid, path: path)
    }

    /// Take the newest **main-session** rollout-*.jsonl under codexHome/sessions/ by file name (which
    /// contains an ISO timestamp, so lexical order = time order). A resume may append to the same file
    /// or open a new one — "newest wins" is correct for both behaviors (same rule as claude's rotation).
    /// Uses `enumerator(atPath:)` to get relative paths and rejoin them onto codexHome — avoiding the
    /// URL-form enumerator, which would resolve the `/var`→`/private/var` symlink (the returned path
    /// must match the shape of the codexHome the caller passed in, for stable comparison).
    ///
    /// Sub-agent pollution: codex 0.144+ multi-agent (`multi_agent_version: v1`) has a task-spawned
    /// sub-agent write its OWN rollout into the SAME CODEX_HOME/sessions/ dir — later timestamp than the
    /// main session, so a naive "newest wins" binds the node to the LAST sub-agent (its filename uuid
    /// is the sub-thread id, NOT a resume credential, and its transcript is a delegated sub-task, not the
    /// main conversation). We must bind to the main session. Sub-agent rollouts carry `thread_source:"subagent"`
    /// (+ `source.subagent.thread_spawn`, `agent_role:"worker"`); the main carries `thread_source:"user"`.
    /// So: sort candidates newest-first and return the first whose session_meta is NOT a sub-agent.
    /// (The main is always written first, so a non-sub-agent always exists in a live codex-home; if only
    /// sub-agent rollouts are visible we return nil — honest degradation, never a sub-thread credential.)
    public static func newestRollout(codexHome: String) -> String? {
        let sessionsDir = (codexHome as NSString).appendingPathComponent("sessions")
        guard let en = FileManager.default.enumerator(atPath: sessionsDir) else { return nil }
        var rels: [String] = []
        for case let rel as String in en {
            let name = (rel as NSString).lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            rels.append(rel)
        }
        // Newest-first by basename (lexical = chronological). Read each candidate's session_meta only
        // until the first main-session rollout is found (worst case reads all — a handful of files).
        let ordered = rels.sorted { ($0 as NSString).lastPathComponent > ($1 as NSString).lastPathComponent }
        for rel in ordered {
            let full = (sessionsDir as NSString).appendingPathComponent(rel)
            if !isSubagentRollout(rolloutPath: full) { return full }
        }
        return nil
    }

    /// True if the rollout's line-0 session_meta marks it as a task-spawned sub-agent thread (codex
    /// 0.144+ multi-agent), which must be excluded from main-session binding. Positive detection only:
    /// a rollout is treated as a sub-agent ONLY when it carries an explicit marker — so if codex changes
    /// the MAIN marker in a future version, we still (safely) treat the main as a main rather than drop
    /// it. Markers (any one, codex 0.144.1): `payload.thread_source == "subagent"`,
    /// `payload.source.subagent` present, or `payload.agent_role == "worker"`. A meta that can't be read
    /// = not a sub-agent (don't exclude on a parse miss). NOTE: a sub-agent's `payload.session_id` is the
    /// PARENT session id (not its own), so meta.session_id alone can't tell them apart — these top-level
    /// markers are the discriminator.
    static func isSubagentRollout(rolloutPath: String) -> Bool {
        guard let payload = firstLinePayload(rolloutPath: rolloutPath) else { return false }
        if (payload["thread_source"] as? String) == "subagent" { return true }
        if (payload["source"] as? [String: Any])?["subagent"] != nil { return true }
        if (payload["agent_role"] as? String) == "worker" { return true }
        return false
    }

    /// The rollout file's session_id: prefer deriving it from the file name tail
    /// (`rollout-<ts>-<uuid>.jsonl`, the trailing 5 hyphen-groups = the uuid, with a UUID check as a
    /// fallback); if that fails, parse line 0 session_meta (payload.session_id). The file-name method
    /// parses no large JSON (line 0 embeds the full system prompt, up to several KB), so it's the
    /// cheap, stable path.
    public static func sessionId(rolloutPath: String) -> String? {
        if let sid = sidFromName(rolloutPath) { return sid }
        return sidFromMeta(rolloutPath)
    }

    /// `rollout-2026-07-10T16-28-05-019f4b24-1b04-7ce0-9059-7da727c56bf3.jsonl`
    /// → the trailing 5 hyphen-groups = the uuid (the timestamp segment also contains hyphens, so
    /// take the trailing 5 groups).
    static func sidFromName(_ path: String) -> String? {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let parts = base.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 5 else { return nil }
        let candidate = parts.suffix(5).joined(separator: "-")
        return UUID(uuidString: candidate) != nil ? candidate : nil
    }

    /// The `payload.session_id` of line 0's `type=session_meta` (the fallback when the file-name
    /// method fails). Reads only up to the first newline (capped at 256KB, to keep line 0's huge
    /// system prompt from stalling the main actor).
    static func sidFromMeta(_ path: String) -> String? {
        guard let meta = sessionMeta(rolloutPath: path) else { return nil }
        return meta.sessionId
    }

    /// Parse line 0 session_meta: session_id + cwd (cwd is diagnostic-only for now; projectCwd goes
    /// through meta.json).
    public static func sessionMeta(rolloutPath: String, maxBytes: Int = 256 * 1024)
        -> (sessionId: String, cwd: String?)? {
        guard let payload = firstLinePayload(rolloutPath: rolloutPath, maxBytes: maxBytes),
              let sid = payload["session_id"] as? String else { return nil }
        return (sid, payload["cwd"] as? String)
    }

    /// The first `user_message` text in the rollout (`event_msg` payload.type==user_message →
    /// payload.message) = the pure first user prompt (the env_context wrapper lives only in
    /// `response_item role=user`, not in user_message). This is codex's honest fallback
    /// session title source: codex has neither claude's ai-title nor opencode's `export` title, but the
    /// user's own first prompt is a truthful name (never a fabricated AI title). Reads a bounded prefix
    /// (the first user prompt lands right after session_meta), tolerating a truncated trailing line.
    /// nil when no user_message is present yet (early capture before the first turn → keep the launch
    /// name). Only meaningful once newestRollout binds to the MAIN session (a sub-agent rollout's
    /// first user_message is the delegated sub-task, not the user's prompt).
    public static func firstUserMessage(rolloutPath: String, maxBytes: Int = 512 * 1024) -> String? {
        guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: rolloutPath))
        else { return nil }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: maxBytes)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let obj = JSONLine.parse(String(line)),
                  obj["type"] as? String == "event_msg",
                  let p = obj["payload"] as? [String: Any],
                  p["type"] as? String == "user_message",
                  let msg = p["message"] as? String else { continue }
            let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// The `payload` dict of line 0's `type=session_meta` (or nil). Reads only up to the first newline
    /// (capped at maxBytes, to keep line 0's huge system prompt from stalling the main actor). Shared by
    /// `sessionMeta` (sid/cwd) and `isSubagentRollout` (thread_source/source/agent_role).
    static func firstLinePayload(rolloutPath: String, maxBytes: Int = 256 * 1024) -> [String: Any]? {
        guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: rolloutPath))
        else { return nil }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: maxBytes)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard let nl = text.firstIndex(of: "\n") else { return nil }
        let firstLine = String(text[..<nl])
        guard let obj = JSONLine.parse(firstLine),
              obj["type"] as? String == "session_meta",
              let payload = obj["payload"] as? [String: Any] else { return nil }
        return payload
    }
}
