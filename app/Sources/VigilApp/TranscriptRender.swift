import SwiftUI
import Foundation
import VigilRuntime
import VigilCore

// Self-rendered history: the center pane of a dead session/dead node is not a
// "button + frozen frame" — instead Vigil reads claude's transcript jsonl itself and
// renders one screen of read-only plain text, with a bottom "press Enter to resume" line
// replacing the input box. This is the parser + shared view; both hosts (HistoryPane for
// dead sessions / DeadNodePane for dead nodes in a live session) use it.
// Pointer philosophy: content still follows the CLI's native lifecycle — when the file
// is gone, honestly say it's gone, never copy.

// MARK: - Parsed blocks

/// One rendered block of a claude transcript. `id` is the parse order (stable within
/// one parse; never persisted).
struct TranscriptItem: Identifiable, Equatable {
    enum Kind: Equatable { case user, assistant, tools, notice }
    let id: Int
    let kind: Kind
    let text: String
}

enum TranscriptRender {
    /// Transcripts can reach tens of MB — render the recent tail, never an unbounded parse.
    /// The head gets an honest "earlier content omitted" notice.
    /// runtime.json historyTailCapMB (default 8) takes effect immediately.
    static var maxTailBytes: Int { RuntimeTuning.current.historyTailCapMB * 1024 * 1024 }
    static let maxItems = 400

    /// Read + parse the transcript tail. nil = file missing/unreadable (the caller
    /// tells cleaned/never apart via TranscriptPointer); [] = readable but nothing
    /// renderable (empty session).
    static func load(path: String?, maxBytes: Int = maxTailBytes) -> [TranscriptItem]? {
        guard let path else { return nil }
        // opencode export is ONE JSON object (info + messages), not JSONL — tail-reading
        // would shred the JSON. Read whole (exports are a few KB–hundreds KB) + parse as JSON.
        if isOpenCodeExport(path) {
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            return parseOpenCode(raw)
        }
        guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        let truncated = start > 0
        if truncated, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])   // drop the partial first line
        }
        // codex rollout jsonl uses its own shape (event_msg); claude JSONL takes the
        // original path. Discriminate by filename (codex = `rollout-<ts>-<uuid>.jsonl`,
        // claude = `<sid>.jsonl`) — honest, self-contained, no schema.
        return isCodexRollout(path)
            ? parseCodex(text, truncatedHead: truncated)
            : parse(text, truncatedHead: truncated)
    }

    /// codex rollout file detection: basename `rollout-` prefix (under CodexHarness codex-home/sessions).
    static func isCodexRollout(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.hasPrefix("rollout-")
    }

    /// opencode export snapshot detection: basename `opencode-` prefix (written by Orchestrator under sessionDir).
    static func isOpenCodeExport(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.hasPrefix("opencode-")
    }

    /// jsonl text → blocks. Tolerant by design (the format is claude-internal): unknown
    /// types and malformed lines are skipped, tool_use runs collapse into one "tool call"
    /// line, meta/system/thinking lines never render. Pure function — unit-tested.
    static func parse(_ jsonl: String, truncatedHead: Bool = false) -> [TranscriptItem] {
        var out: [TranscriptItem] = []
        var toolNames: [String] = []      // first-seen order
        var toolCounts: [String: Int] = [:]
        var nextID = 0

        func append(_ kind: TranscriptItem.Kind, _ text: String) {
            out.append(TranscriptItem(id: nextID, kind: kind, text: text))
            nextID += 1
        }
        func flushTools() {
            guard !toolNames.isEmpty else { return }
            let total = toolCounts.values.reduce(0, +)
            let parts = toolNames.prefix(6).map { name -> String in
                let n = toolCounts[name] ?? 1
                return n > 1 ? "\(name) ×\(n)" : name
            }
            let more = toolNames.count > 6 ? "…" : ""
            append(.tools, "⚒ Tool calls ×\(total) · " + parts.joined(separator: ", ") + more)
            toolNames = []; toolCounts = [:]
        }

        for line in jsonl.split(separator: "\n") {
            guard let obj = JSONLine.parse(String(line)),
                  let type = obj["type"] as? String else { continue }
            let message = obj["message"] as? [String: Any]

            switch type {
            case "user":
                if (obj["isMeta"] as? Bool) == true { continue }
                guard let text = userText(message?["content"]) else { continue }
                flushTools()
                // Interruption markers are claude-injected, not the human typing —
                // render dim (same as claude TUI), not as a user prompt bar.
                append(text.hasPrefix("[Request interrupted") ? .notice : .user, text)
            case "assistant":
                guard let content = message?["content"] as? [[String: Any]] else { continue }
                for part in content {
                    switch part["type"] as? String {
                    case "text":
                        let t = (part["text"] as? String ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { continue }
                        flushTools()
                        append(.assistant, t)
                    case "tool_use":
                        let name = part["name"] as? String ?? "?"
                        if toolCounts[name] == nil { toolNames.append(name) }
                        toolCounts[name, default: 0] += 1
                    default:
                        continue     // thinking/redacted…: never rendered
                    }
                }
            default:
                continue             // ai-title/system/attachment/file-history-snapshot…
            }
        }
        flushTools()

        var capped = false
        if out.count > maxItems {
            out = Array(out.suffix(maxItems))
            capped = true
        }
        if truncatedHead || capped {
            out.insert(TranscriptItem(id: -1, kind: .notice,
                                      text: "── Earlier content omitted (transcript too long) ──"), at: 0)
        }
        return out
    }

    // MARK: codex rollout jsonl

    /// codex rollout jsonl → blocks. Render source = `event_msg` (cleanest, no env-context
    /// noise):
    ///   - payload.type==user_message  → payload.message = **pure user prompt** (the
    ///     env_context wrapper lives only in response_item role=user, not in user_message);
    ///   - payload.type==agent_message → payload.message = assistant reply (phase final_answer);
    ///   - exec/tool/patch begin events → collapse into one ⚒ line (mirrors claude's tool
    ///     collapse, best-effort);
    ///   - everything else (task_started/complete/token_count/reasoning/world_state/response_item…) skipped.
    /// Honesty red line: render only reliably-parsed user/agent messages; collapse tool
    /// events without inventing semantics. Pure function, pinned by unit tests.
    static func parseCodex(_ jsonl: String, truncatedHead: Bool = false) -> [TranscriptItem] {
        var out: [TranscriptItem] = []
        var toolNames: [String] = []
        var toolCounts: [String: Int] = [:]
        var nextID = 0

        func append(_ kind: TranscriptItem.Kind, _ text: String) {
            out.append(TranscriptItem(id: nextID, kind: kind, text: text))
            nextID += 1
        }
        func flushTools() {
            guard !toolNames.isEmpty else { return }
            let total = toolCounts.values.reduce(0, +)
            let parts = toolNames.prefix(6).map { name -> String in
                let n = toolCounts[name] ?? 1
                return n > 1 ? "\(name) ×\(n)" : name
            }
            let more = toolNames.count > 6 ? "…" : ""
            append(.tools, "⚒ Tool calls ×\(total) · " + parts.joined(separator: ", ") + more)
            toolNames = []; toolCounts = [:]
        }
        func tool(_ name: String) {
            if toolCounts[name] == nil { toolNames.append(name) }
            toolCounts[name, default: 0] += 1
        }

        for line in jsonl.split(separator: "\n") {
            guard let obj = JSONLine.parse(String(line)),
                  obj["type"] as? String == "event_msg",
                  let p = obj["payload"] as? [String: Any],
                  let etype = p["type"] as? String else { continue }
            switch etype {
            case "user_message":
                let msg = (p["message"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !msg.isEmpty else { continue }
                flushTools()
                append(.user, msg)
            case "agent_message":
                let msg = (p["message"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !msg.isEmpty else { continue }
                flushTools()
                append(.assistant, msg)
            case "exec_command_begin":
                tool("shell")
            case "mcp_tool_call_begin":
                tool((p["tool"] as? String) ?? (p["server"] as? String) ?? "mcp")
            case "patch_apply_begin":
                tool("apply_patch")
            default:
                continue     // reasoning/token_count/task_*/world_state…: not rendered
            }
        }
        flushTools()

        var capped = false
        if out.count > maxItems {
            out = Array(out.suffix(maxItems))
            capped = true
        }
        if truncatedHead || capped {
            out.insert(TranscriptItem(id: -1, kind: .notice,
                                      text: "── Earlier content omitted (transcript too long) ──"), at: 0)
        }
        return out
    }

    // MARK: opencode export JSON

    /// opencode `export --pure <sid>` JSON → blocks. Shape (1.17.18):
    ///   `{ "info": {...}, "messages": [ {"info":{"role":user|assistant}, "parts":[...] } ] }`
    /// parts.type: `text`→body (used by both user/assistant), `tool`→collapse one ⚒ line
    /// (name from part.tool), `patch`→collapse apply_patch, `reasoning`/`step-start`/
    /// `step-finish`→skip (no invention).
    /// Honesty red line: render only reliable user/assistant text; collapse tools without
    /// inventing semantics. Pure function, pinned by unit tests.
    static func parseOpenCode(_ jsonText: String) -> [TranscriptItem] {
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else { return [] }

        var out: [TranscriptItem] = []
        var toolNames: [String] = []
        var toolCounts: [String: Int] = [:]
        var nextID = 0

        func append(_ kind: TranscriptItem.Kind, _ text: String) {
            out.append(TranscriptItem(id: nextID, kind: kind, text: text)); nextID += 1
        }
        func flushTools() {
            guard !toolNames.isEmpty else { return }
            let total = toolCounts.values.reduce(0, +)
            let parts = toolNames.prefix(6).map { name -> String in
                let n = toolCounts[name] ?? 1
                return n > 1 ? "\(name) ×\(n)" : name
            }
            let more = toolNames.count > 6 ? "…" : ""
            append(.tools, "⚒ Tool calls ×\(total) · " + parts.joined(separator: ", ") + more)
            toolNames = []; toolCounts = [:]
        }
        func tool(_ name: String) {
            if toolCounts[name] == nil { toolNames.append(name) }
            toolCounts[name, default: 0] += 1
        }

        for msg in messages {
            let role = (msg["info"] as? [String: Any])?["role"] as? String
            guard let parts = msg["parts"] as? [[String: Any]] else { continue }
            for part in parts {
                switch part["type"] as? String {
                case "text":
                    let t = (part["text"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { continue }
                    flushTools()
                    append(role == "user" ? .user : .assistant, t)
                case "tool":
                    tool((part["tool"] as? String) ?? "tool")
                case "patch":
                    tool("apply_patch")
                default:
                    continue     // reasoning/step-start/step-finish/snapshot…: not rendered
                }
            }
        }
        flushTools()

        if out.count > maxItems {
            out = Array(out.suffix(maxItems))
            out.insert(TranscriptItem(id: -1, kind: .notice,
                                      text: "── Earlier content omitted (transcript too long) ──"), at: 0)
        }
        return out
    }

    // MARK: user-entry text

    /// content = plain string or [{type:"text",…}] parts; tool_result parts never
    /// render. Slash commands arrive as XML-ish wrappers — show「/cmd args」, and the
    /// echoed local-command output lines are dropped entirely.
    private static func userText(_ content: Any?) -> String? {
        var pieces: [String] = []
        if let s = content as? String {
            pieces = [s]
        } else if let arr = content as? [[String: Any]] {
            pieces = arr.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        }
        let joined = pieces.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        if joined.contains("<local-command-stdout>") { return nil }
        if let cmd = capture(joined, "<command-name>(.*?)</command-name>") {
            let args = capture(joined, "<command-args>(.*?)</command-args>") ?? ""
            return args.isEmpty ? cmd : "\(cmd) \(args)"
        }
        return joined
    }

    private static func capture(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern,
                                                options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        let v = String(s[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}

// MARK: - Session stats (/status·/usage same-source info appended at transcript end)

/// What the transcript itself can HONESTLY answer about the session: `version` /
/// `message.model` / `message.usage` ride every assistant line (one API response is
/// split across several lines sharing a requestId — usage must dedup by it), line
/// timestamps give the wall duration, `sessionId` names the resume key. What it can
/// NOT answer: dollar cost and code-change lines — `costUSD`/`durationMs` are null in
/// 2.1.x transcripts and claude's pricing math is internal. We render what's real and
/// never fabricate a $ figure.
struct TranscriptStats: Equatable {
    struct ModelUsage: Equatable {
        var model: String
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
    }
    var version: String?
    var sessionId: String?
    var wallSeconds: Int?
    var models: [ModelUsage] = []      // first-seen order
    /// Host-provided display name (meta.name) — not a transcript field.
    var sessionName: String?

    var isEmpty: Bool { version == nil && sessionId == nil && models.isEmpty }
}

extension TranscriptRender {
    /// Full-file scan — stats must cover the whole session, not the render tail.
    /// nil = file missing/unreadable (mirror of `load`).
    static func stats(path: String?) -> TranscriptStats? {
        guard let path,
              let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        if isCodexRollout(path) { return codexStats(raw) }   // codex uses its own shape
        if isOpenCodeExport(path) { return opencodeStats(raw) }   // opencode export JSON
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()

        var out = TranscriptStats()
        var firstTS: Date?, lastTS: Date?
        var seenRequests: Set<String> = []
        var order: [String] = []
        var usage: [String: TranscriptStats.ModelUsage] = [:]

        for line in raw.split(separator: "\n") {
            guard let obj = JSONLine.parse(String(line)) else { continue }
            if let v = obj["version"] as? String { out.version = v }        // last wins
            if let sid = obj["sessionId"] as? String { out.sessionId = sid }
            if let t = obj["timestamp"] as? String,
               let d = isoFrac.date(from: t) ?? iso.date(from: t) {
                if firstTS == nil { firstTS = d }
                lastTS = d
            }
            guard obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let u = message["usage"] as? [String: Any] else { continue }
            // One API response = several jsonl lines sharing a requestId with the SAME
            // usage object — count once. No stable id (format drift) = skip the line:
            // a line-uuid fallback would be unique PER LINE, so the drift it's meant to
            // absorb would turn one response into N× counted usage — better to omit than
            // fabricate.
            guard let key = (obj["requestId"] as? String) ?? (message["id"] as? String)
            else { continue }
            guard !seenRequests.contains(key) else { continue }
            seenRequests.insert(key)
            let model = message["model"] as? String ?? "?"
            if usage[model] == nil {
                usage[model] = TranscriptStats.ModelUsage(model: model)
                order.append(model)
            }
            usage[model]?.input += u["input_tokens"] as? Int ?? 0
            usage[model]?.output += u["output_tokens"] as? Int ?? 0
            usage[model]?.cacheRead += u["cache_read_input_tokens"] as? Int ?? 0
            usage[model]?.cacheWrite += u["cache_creation_input_tokens"] as? Int ?? 0
        }
        out.models = order.compactMap { usage[$0] }
        if let f = firstTS, let l = lastTS {
            out.wallSeconds = max(0, Int(l.timeIntervalSince(f)))
        }
        return out
    }

    /// codex rollout stats — render only fields that truly exist; when $ cost is
    /// unavailable, don't fabricate it (same red line as claude). session_meta gives
    /// sessionId + cli_version (version); line timestamps give wall; token_count's
    /// `info.total_token_usage` (cumulative, last one wins) gives usage (model name = the
    /// `model` field of any payload; if none found, label it "codex", since these are
    /// codex's own counts).
    static func codexStats(_ raw: String) -> TranscriptStats {
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        var out = TranscriptStats()
        var firstTS: Date?, lastTS: Date?
        var model: String?
        var usage: TranscriptStats.ModelUsage?

        for line in raw.split(separator: "\n") {
            guard let obj = JSONLine.parse(String(line)) else { continue }
            if let t = obj["timestamp"] as? String,
               let d = isoFrac.date(from: t) ?? iso.date(from: t) {
                if firstTS == nil { firstTS = d }
                lastTS = d
            }
            let p = obj["payload"] as? [String: Any]
            if let m = p?["model"] as? String { model = m }        // accept it wherever it appears
            switch obj["type"] as? String {
            case "session_meta":
                if let sid = p?["session_id"] as? String { out.sessionId = sid }
                if let v = p?["cli_version"] as? String { out.version = v }
            case "event_msg" where (p?["type"] as? String) == "token_count":
                // total_token_usage is cumulative — the last one is the whole-session total (don't sum, just overwrite).
                if let info = p?["info"] as? [String: Any],
                   let tot = info["total_token_usage"] as? [String: Any] {
                    var u = TranscriptStats.ModelUsage(model: model ?? "codex")
                    u.input = tot["input_tokens"] as? Int ?? 0
                    u.output = tot["output_tokens"] as? Int ?? 0
                    u.cacheRead = tot["cached_input_tokens"] as? Int ?? 0
                    usage = u
                }
            default:
                continue
            }
        }
        if var u = usage { u.model = model ?? u.model; out.models = [u] }
        if let f = firstTS, let l = lastTS {
            out.wallSeconds = max(0, Int(l.timeIntervalSince(f)))
        }
        return out
    }

    /// opencode export stats — render only fields that truly exist in `info`; $ cost is
    /// real (opencode provides cost) but follows the same "don't fabricate" red line: if
    /// missing, don't show it. `info.id`=sid, `info.version`, `info.model` (providerID/id
    /// joined as "opencode/big-pickle"), `info.tokens` (input/output/cache.read/write),
    /// `info.time` (created/updated millisecond timestamps give wall). Pure function, pinned
    /// by unit tests.
    static func opencodeStats(_ jsonText: String) -> TranscriptStats {
        var out = TranscriptStats()
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = obj["info"] as? [String: Any] else { return out }
        out.sessionId = info["id"] as? String
        out.version = info["version"] as? String
        var modelName = "opencode"
        if let m = info["model"] as? [String: Any] {
            let id = m["id"] as? String
            let provider = m["providerID"] as? String
            switch (provider, id) {
            case let (p?, i?): modelName = "\(p)/\(i)"
            case let (nil, i?): modelName = i
            case let (p?, nil): modelName = p
            default: break
            }
        }
        if let tok = info["tokens"] as? [String: Any] {
            var u = TranscriptStats.ModelUsage(model: modelName)
            u.input = tok["input"] as? Int ?? 0
            u.output = tok["output"] as? Int ?? 0
            if let cache = tok["cache"] as? [String: Any] {
                u.cacheRead = cache["read"] as? Int ?? 0
                u.cacheWrite = cache["write"] as? Int ?? 0
            }
            out.models = [u]
        }
        if let time = info["time"] as? [String: Any],
           let created = time["created"] as? Double, let updated = time["updated"] as? Double {
            out.wallSeconds = max(0, Int((updated - created) / 1000))
        } else if let time = info["time"] as? [String: Any],
                  let created = time["created"] as? Int, let updated = time["updated"] as? Int {
            out.wallSeconds = max(0, (updated - created) / 1000)
        }
        return out
    }

    /// Same count abbreviation as claude: 629 / 4.8k / 4.5m (one decimal, trailing zero dropped).
    static func fmtTokens(_ n: Int) -> String {
        func trim(_ v: Double) -> String {
            let s = String(format: "%.1f", v)
            return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
        }
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return trim(Double(n) / 1000) + "k" }
        return trim(Double(n) / 1_000_000) + "m"
    }

    // (fmtWall → VGDuration.wall — three duration formatters unified into one namespace.)
}

// MARK: - Read-only transcript view (shared: HistoryPane + DeadNodePane)

/// The one-screen plain-text rendering, typeset like the claude TUI itself: user prompt =
/// full-width dim bar with a `>`
/// prefix; assistant = `●` bullet + body at full foreground; tool runs = one dim
/// indented line; terminal-ish 12 mono with breathing line spacing. Items are
/// preparsed (the host loads them in .task / injects them in tests); newest content is
/// what you came for → anchor bottom.
struct TranscriptReadView: View {
    let items: [TranscriptItem]
    /// /status·/usage same-source info card, appended at the end of the conversation (nil = don't render).
    var stats: TranscriptStats? = nil
    @Environment(\.vg) private var vg

    private static let bodySize: CGFloat = 12
    private static let detailSize: CGFloat = 10.8
    private static let bodyLineSpacing: CGFloat = 3

    var body: some View {
        // GeometryReader + minHeight: short transcripts read top-down like the live
        // terminal (bottom anchor alone would sink them to the pane floor);
        // long ones still open at the newest content (anchor bottom).
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { item in row(item) }
                    if let stats, !stats.isEmpty { statsCard(stats) }
                }
                .padding(EdgeInsets(top: 16, leading: 16, bottom: 18, trailing: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: geo.size.height, alignment: .top)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.automatic)
            .vgNativeOverlayScrollers()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcript.read")
    }

    // MARK: stats card (render only fields that truly exist in the transcript; don't fabricate $ cost when unavailable)

    private func statsCard(_ s: TranscriptStats) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let v = s.version { statsRow("Version:", v) }
            if let n = s.sessionName { statsRow("Session name:", n) }
            if let sid = s.sessionId { statsRow("Session ID:", sid) }
            if !s.models.isEmpty {
                statsRow("Model:", s.models.map(\.model).joined(separator: ", "))
            }
            if let w = s.wallSeconds {
                statsRow("Total duration (wall):", VGDuration.wall(seconds: w))
            }
            if !s.models.isEmpty {
                Text("Usage by model:")
                    .font(VGFont.mono(Self.detailSize)).foregroundStyle(vg.text3)
                    .padding(.top, 3)
                ForEach(s.models, id: \.model) { m in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(m.model):")
                            .font(VGFont.mono(Self.detailSize)).foregroundStyle(vg.text2)
                        Text("\(TranscriptRender.fmtTokens(m.input)) input · "
                             + "\(TranscriptRender.fmtTokens(m.output)) output · "
                             + "\(TranscriptRender.fmtTokens(m.cacheRead)) cache read · "
                             + "\(TranscriptRender.fmtTokens(m.cacheWrite)) cache write")
                            .font(VGFont.mono(Self.detailSize)).foregroundStyle(vg.text2)
                    }
                    .padding(.leading, 14)
                }
            }
        }
        .textSelection(.enabled)
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(vg.hair, lineWidth: 1))
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcript.stats")
    }

    private func statsRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .font(VGFont.mono(Self.detailSize, weight: .medium)).foregroundStyle(vg.text3)
                .frame(width: 170, alignment: .leading)
            Text(value)
                .font(VGFont.mono(Self.detailSize)).foregroundStyle(vg.text2)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func row(_ item: TranscriptItem) -> some View {
        switch item.kind {
        case .user:
            // claude TUI's user row: full-width light background bar + dim `>` prefix, body at full brightness.
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(">").font(VGFont.mono(Self.bodySize, weight: .medium))
                    .foregroundStyle(vg.text3)
                Text(item.text).font(VGFont.mono(Self.bodySize)).foregroundStyle(vg.text)
                    .lineSpacing(Self.bodyLineSpacing)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(vg.text.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
        case .assistant:
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("•").font(VGFont.ui(Self.bodySize - 1, weight: .medium)).foregroundStyle(vg.text2)
                Text(item.text).font(VGFont.mono(Self.bodySize)).foregroundStyle(vg.text)
                    .lineSpacing(Self.bodyLineSpacing)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 9)
        case .tools:
            Text(item.text).font(VGFont.mono(Self.detailSize)).foregroundStyle(vg.text3)
                .padding(.leading, 27)
        case .notice:
            Text(item.text).font(VGFont.mono(Self.detailSize)).foregroundStyle(vg.text3)
                .padding(.horizontal, 9)
        }
    }
}

/// The bottom bar replacing the input box: a
/// prompt-shaped hint line. `hint` nil = read-only (no resume credential) — explain
/// rather than pretend it can resume.
struct ResumeHintBar: View {
    let hint: String?
    var readOnlyText: String = "Read-only — no resume credentials"
    let axID: String
    @Environment(\.vg) private var vg

    var body: some View {
        HStack(spacing: 9) {
            Text("❯").font(VGFont.mono(12, weight: .semibold))
                .foregroundStyle(hint != nil ? vg.accent : vg.text3)
            Text(hint ?? readOnlyText)
                .font(VGFont.mono(11.5)).foregroundStyle(vg.text3)
            Spacer(minLength: 12)
            if hint != nil {
                HStack(spacing: 5) {
                    Text("Press").font(VGFont.ui(10.5)).foregroundStyle(vg.text3)
                    KeyCap("Enter", vg)
                    Text("to resume").font(VGFont.ui(10.5)).foregroundStyle(vg.text3)
                }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 18, bottom: 11, trailing: 18))
        .overlay(alignment: .top) { Rectangle().fill(vg.hair).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(axID)
    }
}
