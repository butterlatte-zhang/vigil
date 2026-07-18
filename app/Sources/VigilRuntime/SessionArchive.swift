import Foundation
import VigilCore

// History persistence (pointer approach), replayable after restart — the READ-BACK layer.
//
// Vigil persists two things per session, both under a STABLE directory
// (~/Library/Application Support/Vigil/sessions/<dirName>/):
//   orchestration.jsonl — the forensic trail the Orchestrator already writes
//                         (cell_launch/exit/kill/agent_prompt…), the tree's edges,
//                         statuses, timeline AND the node → CLI transcript join key;
//   meta.json           — session identity written by the app layer (name/project/agent).
//
// Everything else — the conversation content — stays a POINTER into the CLI's own
// transcript cache (claude's ~/.claude/projects/*.jsonl). Vigil never copies it: the CLI
// rotates/deletes → the pointer dangles → the UI degrades to "history purged by <cli>" while
// the skeleton (Vigil's own data) remains viewable. Vigil defers to the subordinate tool's
// own native lifecycle rather than owning the content itself.
//
// Replay is a pure function of the jsonl lines (unit-tested, deterministic); all file
// I/O sits in the thin load/list/meta helpers around it.

/// Session identity for the history list — written at launch, rewritten on rename.
public struct SessionArchiveMeta: Codable, Equatable, Sendable {
    public var id: String            // archive dir basename
    public var name: String
    public var projectName: String?
    public var projectCwd: String?
    public var agent: String         // "claude" — names the CLI in the "purged" message
    public var model: String?
    public var createdAt: Date
    /// The ROOT node's CLI session id — the resume key (`claude --resume`). Hook-captured,
    /// newest wins since resume forks a new id; nil = meta predating this field, or a
    /// session that never prompted → the UI falls back to the read-only HistoryPane.
    public var rootSessionId: String?
    /// The user filed this session away — it leaves its project group and lives in the
    /// sidebar's Archived section instead. Only meaningful for DEAD sessions: a live
    /// incarnation always writes nil (resume un-archives), and the live-row archive
    /// action closes the session first. nil = false.
    public var archived: Bool?
    /// The name is user/agent-chosen (a manual ⌘⇧R rename, or a root's `rename` MCP call),
    /// not an auto-derived title — the auto-namer must yield to it. Persisted so a resumed
    /// incarnation restores the pin instead of letting a later fallback clobber the custom
    /// name. nil = false (pre-rename meta).
    public var nameIsCustom: Bool?

    public init(id: String, name: String, projectName: String?, projectCwd: String?,
                agent: String, model: String?, createdAt: Date,
                rootSessionId: String? = nil, archived: Bool? = nil,
                nameIsCustom: Bool? = nil) {
        self.id = id; self.name = name
        self.projectName = projectName; self.projectCwd = projectCwd
        self.agent = agent; self.model = model; self.createdAt = createdAt
        self.rootSessionId = rootSessionId
        self.archived = archived
        self.nameIsCustom = nameIsCustom
    }
}

/// A dead session rebuilt from its orchestration.jsonl: the tree skeleton
/// (nodes/roles/statuses/timeline, reusing the live domain types so the UI renders it with the
/// same code paths) + the per-node transcript pointers.
public struct ArchivedSession {
    public let tree: Tree?                       // nil = log empty/corrupt (no root launch)
    public let transcripts: [NodeID: String]     // node → CLI transcript path (pointer)
    public let sessionIds: [NodeID: String]      // node → CLI session id (resume key)
    public let nodeKinds: [NodeID: AgentCLIKind] // node → CLI family (per-node resume wording)
    public let firstEventAt: Date?
    public let lastEventAt: Date?                // the history clock: durations freeze here

    /// The node's CLI resume key: the hook-captured session id, else derived from the
    /// transcript pointer's basename (claude's transcript IS `<sessionId>.jsonl`, so
    /// archives without a captured session id are still revivable). One derivation,
    /// shared by the live adopt (Orchestrator) and the history view's Enter-to-resume.
    public func resumeKey(for node: NodeID) -> String? {
        if let sid = sessionIds[node] { return sid }
        guard let t = transcripts[node] else { return nil }
        let base = ((t as NSString).lastPathComponent as NSString).deletingPathExtension
        return UUID(uuidString: base) != nil ? base : nil
    }
}

/// One row of the history list — cheap to build (meta + presence check only; the full
/// replay happens when the session is opened).
public struct ArchivedSessionSummary: Identifiable, Equatable {
    public let id: String            // dir basename
    public let dir: String
    public let meta: SessionArchiveMeta?
    public let modifiedAt: Date?     // orchestration.jsonl mtime — fallback sort key

    public var name: String { meta?.name ?? id }
    public var createdAt: Date? { meta?.createdAt }
    /// Archived rows leave their project group for the Archived section.
    public var isArchived: Bool { meta?.archived == true }
}

public enum SessionArchive {

    // MARK: stable root

    /// ~/Library/Application Support/Vigil/sessions — the stable home replacing
    /// NSTemporaryDirectory (which the OS purges, killing replays). Env override
    /// VIGIL_ARCHIVE_ROOT is the isolation seam for T2/XCUITest runs.
    public static let rootDir: String = {
        if let env = ProcessInfo.processInfo.environment["VIGIL_ARCHIVE_ROOT"], !env.isEmpty {
            return env
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Vigil/sessions").path
    }()

    /// Human-browsable + unique + lexically sortable: 20260707-153000-ab12cd34.
    public static func newSessionDirName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: now) + "-" + String(UUID().uuidString.prefix(8)).lowercased()
    }

    // MARK: meta.json

    public static func writeMeta(_ meta: SessionArchiveMeta, dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileIO.writeJSON(meta, to: dir + "/meta.json", encoder: enc)
    }

    public static func readMeta(dir: String) -> SessionArchiveMeta? {
        guard let data = FileManager.default.contents(atPath: dir + "/meta.json") else {
            return nil
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(SessionArchiveMeta.self, from: data)
    }

    /// Flip the archived flag in place. A dir with no meta.json gets a minimal identity
    /// synthesized from the dir name so the flag has somewhere to live — everything
    /// else in it stays empty/derivable.
    public static func setArchived(dir: String, _ flag: Bool) {
        var meta = readMeta(dir: dir) ?? SessionArchiveMeta(
            id: (dir as NSString).lastPathComponent,
            name: (dir as NSString).lastPathComponent,
            projectName: nil, projectCwd: nil, agent: "", model: nil,
            createdAt: Date())
        meta.archived = flag ? true : nil     // false is encoded as key-absent (clean meta)
        writeMeta(meta, dir: dir)
    }

    // MARK: replay (pure — the unit-testable brain)

    /// Rebuild the tree skeleton from orchestration.jsonl lines. Tolerant by design:
    /// malformed lines and unknown events are skipped (the log is append-only and grows
    /// new event kinds), a missing parent attaches under root, and the first terminal
    /// event wins (mirrors SessionStore's sticky-terminal rule — the teardown SIGTERM
    /// echo must not rewrite a clean done).
    public static func replay(lines: [String]) -> ArchivedSession {
        var tree: Tree?
        var transcripts: [NodeID: String] = [:]
        var sessionIds: [NodeID: String] = [:]
        var nodeKinds: [NodeID: AgentCLIKind] = [:]
        var terminal: Set<NodeID> = []
        var firstTS: Date?, lastTS: Date?

        for line in lines {
            guard let obj = JSONLine.parse(line),
                  let event = obj["event"] as? String else { continue }
            let ts = (obj["ts"] as? String).flatMap(OrchClock.parse)   // shared contract
            if let ts {
                if firstTS == nil { firstTS = ts }
                lastTS = ts
            }
            let node = (obj["node"] as? String).map(NodeID.init)

            switch event {
            case "cell_launch":
                guard let node else { continue }
                // Per-node CLI family (newest wins on resume relaunch). Used by the
                // history view to render each dead node's OWN resume syntax.
                if let k = (obj["kind"] as? String).flatMap(AgentCLIKind.init(rawValue:)) {
                    nodeKinds[node] = k
                }
                let role = Role(rawValue: obj["role"] as? String ?? "") ?? .leaf
                let n = Node(id: node, role: role,
                             status: .killed,     // no terminal event = died with the app
                             // An explicit dispatch-time name rides "title"; older
                             // records (and unnamed nodes) fall back to the task text.
                             title: obj["title"] as? String ?? obj["task"] as? String ?? "",
                             model: obj["model"] as? String,
                             startedAt: ts)
                if tree == nil {
                    guard (obj["root"] as? Bool) == true || obj["parent"] == nil else { continue }
                    tree = Tree(root: n)
                } else if tree?[node] == nil {
                    let rootID = tree!.rootID
                    let parent = (obj["parent"] as? String).map(NodeID.init) ?? rootID
                    // A vanished/leaf parent degrades to a flat row under root — the
                    // skeleton must survive imperfect logs.
                    if (try? tree?.spawn(parent: parent, child: n)) == nil {
                        try? tree?.spawn(parent: rootID, child: n)
                    }
                } else {
                    // A second cell_launch for a known node = a resume re-incarnation
                    // in the same session dir — clear the previous lifetime's frozen
                    // terminal state so the new lifetime's exit/kill stamp fresh
                    // (otherwise replay freezes at the FIRST exit forever).
                    terminal.remove(node)
                    tree?.relaunch(node, status: .killed, startedAt: ts)
                }

            case "agent_prompt":
                if let node, let t = obj["transcript"] as? String {
                    transcripts[node] = t        // claude rotates files; newest pointer wins
                }
                if let node, let sid = obj["session_id"] as? String {
                    sessionIds[node] = sid       // resume forks a new id; newest wins
                }

            case "exit":
                guard let node, tree?[node] != nil, !terminal.contains(node) else { continue }
                terminal.insert(node)
                tree?.setStatus(node, (obj["code"] as? Int ?? 0) == 0 ? .done : .failed)
                if let ts { tree?.setEnded(node, ts) }

            case "kill":
                guard let node, tree?[node] != nil, !terminal.contains(node) else { continue }
                terminal.insert(node)
                tree?.setStatus(node, .killed)
                if let ts { tree?.setEnded(node, ts) }

            default:
                continue     // route/agent_connected/future events: timeline only
            }
        }
        return ArchivedSession(tree: tree, transcripts: transcripts, sessionIds: sessionIds,
                               nodeKinds: nodeKinds, firstEventAt: firstTS, lastEventAt: lastTS)
    }

    // MARK: load + list (thin I/O shells)

    public static func load(dir: String) -> ArchivedSession? {
        guard let raw = try? String(contentsOfFile: dir + "/orchestration.jsonl",
                                    encoding: .utf8) else { return nil }
        return replay(lines: raw.split(separator: "\n").map(String.init))
    }

    /// All sessions under `root`, newest first. A session = a dir holding an
    /// orchestration.jsonl; anything else in the root is ignored.
    public static func list(root: String) -> [ArchivedSessionSummary] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        return names.compactMap { name -> ArchivedSessionSummary? in
            let dir = root + "/" + name
            let logPath = dir + "/orchestration.jsonl"
            guard fm.fileExists(atPath: logPath) else { return nil }
            let mtime = (try? fm.attributesOfItem(atPath: logPath))?[.modificationDate] as? Date
            return ArchivedSessionSummary(id: name, dir: dir,
                                          meta: readMeta(dir: dir), modifiedAt: mtime)
        }
        .sorted {
            ($0.createdAt ?? $0.modifiedAt ?? .distantPast)
                > ($1.createdAt ?? $1.modifiedAt ?? .distantPast)
        }
    }
}
