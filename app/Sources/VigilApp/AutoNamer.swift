import Foundation
import VigilRuntime

// Auto-names a session from the title claude itself maintains: claude 2.1.x
// already runs a small background model over the same conversation and appends the result
// to the session transcript JSONL as `{"type":"ai-title","aiTitle":"..."}` lines (one per
// turn; official reader = findLast). A user `/rename` lands as a `custom-title` line and
// must never be overwritten by the auto title. So instead of running our own naming pass we just
// read the transcript tail — best-effort, the format is claude-internal and may change;
// parse failure = keep the current name. File I/O runs off the main actor; the result is
// applied on it. No throttle beyond in-flight dedup: this is a local file read, zero cost.

@MainActor
final class AutoNamer {
    private var inFlight = false
    private var watchTask: Task<Void, Never>?
    var onName: ((String) -> Void)?

    init() {}

    deinit { watchTask?.cancel() }

    func consider(transcriptPath: String, currentName: String) {
        guard !inFlight, !transcriptPath.isEmpty else { return }
        inFlight = true
        Task.detached {
            let title = AutoNamer.extractTitle(from: AutoNamer.tail(transcriptPath))
            await MainActor.run {
                self.inFlight = false
                if let title = title, !title.isEmpty, title != currentName { self.onName?(title) }
            }
        }
    }

    /// opencode naming: opencode has no claude-style `ai-title` JSONL — the title opencode
    /// itself maintains lives in its SQLite store (`~/.local/share/opencode/opencode.db`),
    /// read out via the OFFICIAL `opencode export <sid>` command (JSON `{"info":{"title":…}}`),
    /// NOT the raw db (a version-drift guard — pinned opencode 1.17.16, upgrade checklist in
    /// OBSERVABILITY §8.5). session.idle carries the sid through the plugin. Off-main spawn,
    /// same in-flight dedup as `consider`; best-effort — spawn/parse failure keeps the name.
    func considerOpenCode(sessionId: String, opencodeBin: String, currentName: String) {
        guard !inFlight, !sessionId.isEmpty, !opencodeBin.isEmpty else { return }
        inFlight = true
        Task.detached {
            let title = AutoNamer.runOpenCodeExport(sessionId: sessionId, opencodeBin: opencodeBin)
            await MainActor.run {
                self.inFlight = false
                if let title = title, !title.isEmpty, title != currentName { self.onName?(title) }
            }
        }
    }

    /// codex naming honest fallback: codex has NO claude-style `ai-title` and NO official
    /// `export` title (opencode) — it doesn't auto-generate a session title at all. But the MAIN
    /// rollout's first `user_message` IS the user's own first prompt; derive a title from its first
    /// line (bounded), never fabricating an AI title. (newestRollout binds to the main session, so
    /// this reads the user's prompt, not a sub-agent's delegated sub-task.) Fires on
    /// every codex capture; the in-flight dedup + `title != currentName` short-circuit keep it idempotent.
    ///
    /// The CLI's own "Session name" lives in `state_5.sqlite` `threads.title` and is the first
    /// user message VERBATIM for every CLI session (only the cloud-backed desktop app
    /// AI-summarizes), so this fallback matches codex-native behavior. Reading the sqlite title
    /// directly instead would give the same result while being more fragile (WAL + schema drift).
    /// For a hand-chosen worker name instead, use spawn(name:).
    func considerCodex(rolloutPath: String, currentName: String) {
        guard !inFlight, !rolloutPath.isEmpty else { return }
        inFlight = true
        Task.detached {
            let title = AutoNamer.codexFallbackTitle(rolloutPath: rolloutPath)
            await MainActor.run {
                self.inFlight = false
                if let title = title, !title.isEmpty, title != currentName { self.onName?(title) }
            }
        }
    }

    /// claude's ai-title is written to disk **during the turn** — so at
    /// prompt submission we start a short poll watching the transcript tail and apply the title the
    /// moment it appears (without waiting for the turn to end).
    /// First record a **baseline** at the start (the old title left by the previous
    /// turn) — claude rewrites ai-title every turn, and without a baseline the first tick of turn ≥2
    /// would match the old title and finish, degrading "name during the turn" to only holding for the
    /// first turn. Only a title **different from the baseline** counts as this turn's new title.
    /// A new prompt's watch supersedes the old one; on Stop, cancelWatch + a one-shot re-read as a
    /// backstop (it covers over-long turns / format drift). File I/O runs on a detached thread;
    /// applied back on the main thread.
    func watch(transcriptPath: String, currentName: String,
               interval: TimeInterval = 1.5, deadline: TimeInterval = 120) {
        guard !transcriptPath.isEmpty else { return }
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            let baseline = await Task.detached {
                AutoNamer.extractTitle(from: AutoNamer.tail(transcriptPath))
            }.value
            let rounds = max(1, Int(deadline / max(interval, 0.01)))
            for _ in 0..<rounds {
                guard !Task.isCancelled else { return }
                let title = await Task.detached {
                    AutoNamer.extractTitle(from: AutoNamer.tail(transcriptPath))
                }.value
                guard !Task.isCancelled else { return }
                if let title, !title.isEmpty, title != baseline {
                    if title != currentName { self?.onName?(title) }
                    return                     // this turn's new title is in — the watch's job is done
                }
                try? await Task.sleep(seconds: interval)
            }
        }
    }

    /// The hook point for Stop / session shutdown: terminate the in-turn poll in place (stops it
    /// from spinning against a frozen transcript until the deadline).
    func cancelWatch() {
        watchTask?.cancel()
        watchTask = nil
    }

    // MARK: off-main work

    /// JSONL text → session title. custom-title (user /rename) beats ai-title regardless
    /// of order; otherwise the LAST ai-title wins (claude re-appends it every turn).
    /// no local sample of the custom-title line exists and the field name is unverified — tolerate
    /// both `customTitle` and `title`.
    nonisolated static func extractTitle(from text: String) -> String? {
        var aiTitle: String?
        for line in text.split(separator: "\n").reversed() {
            guard let obj = JSONLine.parse(String(line)),
                  let type = obj["type"] as? String else { continue }
            if type == "custom-title" {
                if let t = clamp((obj["customTitle"] as? String) ?? (obj["title"] as? String)) {
                    return t
                }
            } else if type == "ai-title", aiTitle == nil {
                aiTitle = clamp(obj["aiTitle"] as? String)
            }
        }
        return aiTitle
    }

    /// opencode export JSON → session title. Shape: `{"info":{"title":"..."},...}`.
    /// opencode seeds un-named sessions with a `New session - <ISO ts>` placeholder — skip
    /// it so the sidebar never shows the boilerplate (keep the launch prefix instead).
    /// Tolerant like `extractTitle`: any parse miss = nil = keep the current name.
    nonisolated static func extractOpenCodeTitle(fromExportJSON text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = obj["info"] as? [String: Any],
              let title = clamp(info["title"] as? String) else { return nil }
        if title.hasPrefix("New session") { return nil }   // opencode's un-named placeholder, don't apply as a name
        return title
    }

    /// codex fallback title: the first line of the main rollout's first user_message, clamped
    /// like the other families' titles. Honest — it is the user's literal first prompt, not an AI
    /// title (codex has no title source). nil (keep the launch name) when no user prompt is on disk yet.
    nonisolated static func codexFallbackTitle(rolloutPath: String) -> String? {
        guard let msg = CodexRollout.firstUserMessage(rolloutPath: rolloutPath) else { return nil }
        let firstLine = msg.split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init) ?? msg
        return clamp(firstLine)
    }

    /// Run `opencode export --pure <sid>` with the RESOLVED binary (never the shell wrapper,
    /// same red line as claudeBin) and pull the title. `--pure` skips user plugins (faster,
    /// no side effects). Output is a few KB → read-then-wait can't deadlock. Best-effort:
    /// spawn/nonzero-exit/parse failure all collapse to nil.
    nonisolated static func runOpenCodeExport(sessionId: String, opencodeBin: String) -> String? {
        guard let json = runOpenCodeExportRaw(sessionId: sessionId, opencodeBin: opencodeBin)
        else { return nil }
        return extractOpenCodeTitle(fromExportJSON: json)
    }

    /// The RAW `opencode export --pure <sid>` JSON — the transcript-review snapshot source (title +
    /// full messages). Same resolved-binary red line and best-effort contract as the title
    /// path; a few-KB payload → read-then-wait can't deadlock. nil on spawn/nonzero/empty.
    nonisolated static func runOpenCodeExportRaw(sessionId: String, opencodeBin: String) -> String? {
        guard !sessionId.isEmpty, !opencodeBin.isEmpty else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: opencodeBin)
        p.arguments = ["export", "--pure", sessionId]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let json = String(decoding: data, as: UTF8.self)
        return json.isEmpty ? nil : json
    }

    private nonisolated static func tail(_ path: String, _ maxBytes: Int = 512 * 1024) -> String {
        guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Shared naming-length clamp (trim + cap at 50, reused by the codex `rename` tool path
    /// in AppModel). nil = empty after trim.
    nonisolated static func clamp(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if s.count > 50 { s = String(s.prefix(50)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? nil : s
    }
}
