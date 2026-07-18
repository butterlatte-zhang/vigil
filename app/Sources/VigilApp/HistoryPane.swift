import SwiftUI
import AppKit
import VigilCore
import VigilRuntime

// The center pane of a dead session is one screen of read-only plain text that Vigil
// renders by reading the transcript itself (mirroring claude/codex app's review), with a
// bottom "press Enter to resume" line replacing the input box — clicking a row is just
// "look", Enter is "revive". The tree skeleton lives in the top-right floating card
// (HistoryTreePanel, mounted via OverlayColumn, auto-expands when there's a tree); click
// any node to see its transcript, and a child node's Enter resumes the session and revives
// that node (revive whichever you click). Pointer philosophy: content follows the CLI's
// native lifecycle — when the file is gone, honestly say "already cleaned", never copy.
// No SessionStore here by design: this is a value snapshot of a finished session, not
// live state; selection/tree keys live on AppModel (historyNodeID/historyTreeCollapsed).

struct HistoryPane: View {
    let app: AppModel
    let summary: ArchivedSessionSummary
    @Environment(\.vg) private var vg

    /// Test seam (T1b, same rationale as LauncherView's): ViewInspector renders
    /// un-hosted views where .task never fires, so tests inject the loaded archive and
    /// pre-parsed transcript items. Production passes nil: the archive comes from
    /// AppModel.openHistory, items parse in the host's .task.
    private let preloaded: ArchivedSession?
    private let preloadedItems: [TranscriptItem]?
    private let preloadedStats: TranscriptStats?

    init(app: AppModel, summary: ArchivedSessionSummary,
         preloaded: ArchivedSession? = nil, preloadedItems: [TranscriptItem]? = nil,
         preloadedStats: TranscriptStats? = nil) {
        self.app = app
        self.summary = summary
        self.preloaded = preloaded
        self.preloadedItems = preloadedItems
        self.preloadedStats = preloadedStats
    }

    private var archived: ArchivedSession? { preloaded ?? app.historyArchive }
    private var selectedID: NodeID? { app.historyNodeID ?? archived?.tree?.rootID }
    /// The SELECTED node's OWN CLI family — from the archive's per-node kind map
    /// (cell_launch `kind`), falling back to the session's registry key parsed as a kind,
    /// else claude. Drives both the resume syntax and the cleaned-history label per node.
    private var selKind: AgentCLIKind {
        if let sel = selectedID, let k = archived?.nodeKinds[sel] { return k }
        return AgentCLIKind(rawValue: summary.meta?.agent ?? "") ?? .claude
    }
    private var agentName: String { selKind.rawValue }
    private var transcriptPath: String? {
        guard let a = archived, let sel = selectedID else { return nil }
        return a.transcripts[sel]
    }

    // Shell = the shared TranscriptHostView: focus + Enter + off-main double
    // read live there; this pane keeps its own header, the overlay column and the
    // pointer-state notes.
    var body: some View {
        let name = summary.name
        let isRoot = selectedID == archived?.tree?.rootID
        return TranscriptHostView(
            transcriptPath: transcriptPath,
            taskID: "\(summary.id)-\(selectedID?.raw ?? "")",
            axID: "history.pane",
            hint: resumeHint,
            readOnlyText: "Read-only — this archive has no resume credentials (old data or a very short session)",
            hintAxID: "history.resumeHint",
            onResume: resumeHint == nil ? nil : { app.resumeSelectedHistory() },
            preloadedItems: preloadedItems,
            preloadedStats: preloadedStats,
            mapStats: { st in
                var s = st
                if isRoot { s?.sessionName = name }   // the meta name belongs only to the session (root), workers don't borrow it
                return s
            },
            header: { header },
            content: { items, stats in
                content(items: items, stats: stats)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The top-right overlay column (tree card + notification stack) anchors
                    // below the header row's divider — same placement as TerminalPane; the
                    // tree card must not cover the header row. AppBody does not mount the
                    // global column in history mode.
                    .overlay(alignment: .topTrailing) {
                        OverlayColumn(app: app, treeSession: nil)
                            .padding(.vertical, 14).padding(.trailing, 16)
                    }
            })
    }

    // MARK: header — same structure as the live-session breadcrumb: the session name is
    // stated once in the top bar; here root = "main task", worker = its task name, with
    // role glyph/model/status aligned with TerminalPane.
    // Layout = the shared NodeHeaderRow, structurally same as TerminalPane.breadcrumb.

    private var header: some View {
        let node = selectedID.flatMap { archived?.tree?[$0] }
        let isRoot = selectedID == archived?.tree?.rootID
        return NodeHeaderRow(
            role: node.map(roleGlyphKind) ?? .manager,
            title: isRoot || node == nil
                ? "root"
                : (node!.title.isEmpty ? node!.id.raw : node!.title),
            model: summary.meta?.model,
            status: node.map { statusText(designStatus($0)) },
            readOnlyBadge: true,
            vg: vg) {
            if let d = summary.createdAt {
                Text(d.formatted(date: .abbreviated, time: .shortened))
                    .font(VGFont.mono(11)).foregroundStyle(vg.text3)
            }
        }
    }

    // MARK: content — the selected node's self-rendered transcript
    // `items`/`stats` arrive resolved from the host (preloaded ?? loaded).

    @ViewBuilder
    private func content(items: [TranscriptItem]?, stats: TranscriptStats?) -> some View {
        if archived == nil {
            note("Orchestration log missing or corrupt — this session cannot be rebuilt")
        } else if let it = items, !it.isEmpty {
            TranscriptReadView(items: it, stats: stats)
        } else {
            switch TranscriptPointer.state(transcriptPath) {
            case .available:
                if items != nil {
                    note("No renderable conversation content in the transcript")
                } else {
                    SpinnerRing(size: 22, line: 2.5, base: vg.text.opacity(0.1), top: vg.text3)
                }
            case .cleaned:
                note("History cleaned up by \(agentName) — conversation content unreachable")
            case .never:
                note("This node has no transcript record (never received a prompt)")
            }
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(VGFont.ui(12.5)).foregroundStyle(vg.text3)
    }

    // MARK: Enter-to-resume — the wording IS the semantics; don't promise when the credential is absent

    private var rootResumable: Bool {
        summary.meta?.rootSessionId != nil && summary.meta?.projectCwd != nil
    }

    private var resumeHint: String? {
        guard rootResumable, let a = archived, let sel = selectedID else { return nil }
        if sel == a.tree?.rootID { return "Press Enter to resume this conversation (\(selKind.resumeSyntax))" }
        return a.resumeKey(for: sel) != nil
            ? "Press Enter to resume the conversation and revive this node (\(selKind.resumeSyntax))"
            : "This node has no resume credentials — press Enter to resume the session itself"
    }
}

// MARK: - Transcript pointer semantics, shared with the dead-node pane

/// The pointer's three honest states — never pretend content exists.
enum TranscriptPointer {
    enum State { case available, cleaned, never }

    static func state(_ path: String?) -> State {
        guard let path else { return .never }
        return FileManager.default.fileExists(atPath: path) ? .available : .cleaned
    }
}

// MARK: - History tree panel (the top-right floating card; auto-expands when opening a history that has a tree)

/// The frozen tree card for a dead session — same 322pt top-right card as the live
/// TreePanel, mounted by OverlayColumn while history is showing. Row click = select
/// that node (the center re-renders its transcript); durations freeze at the archive's
/// last event; dots are static fills (nothing runs here, ever).
struct HistoryTreePanel: View {
    let app: AppModel
    let archive: ArchivedSession
    @Environment(\.vg) private var vg

    var body: some View {
        if let tree = archive.tree {
            let rows = flattenTree(tree)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Tree · History")
                        .font(VGFont.ui(14, weight: .semibold)).foregroundStyle(vg.text)
                    Spacer()
                    Text("\(rows.count) nodes").font(VGFont.ui(11)).foregroundStyle(vg.text3)
                }
                .padding(EdgeInsets(top: 2, leading: 4, bottom: 8, trailing: 4))

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Row layout = the shared NodeRow. There is no transcript-pointer
                        // label column — rows are structurally the same as the live tree
                        // panel's finished nodes; the pointer's three honest states are
                        // stated once, in the center (HistoryPane.content).
                        ForEach(rows, id: \.node.id) { row in
                            NodeRow(row: row,
                                    time: nodeRuntimeText(row.node,
                                                          now: archive.lastEventAt ?? Date()),
                                    selected: app.historyNodeID == row.node.id,
                                    hoverBG: vg.hoverBG,
                                    timeLeadingPad: 10,
                                    axID: "history.node.\(row.node.id.raw)",
                                    vg: vg,
                                    action: { app.historyNodeID = row.node.id }) {
                                // History nodes are all terminal — the dot is always a
                                // static fill (never the live spinner; this is a frozen
                                // record, nothing runs).
                                Circle().fill(statusColor(designStatus(row.node), vg))
                                    .frame(width: 9, height: 9)
                            }
                        }
                    }
                }
                // Native overlay scrollbar (same as the live TreePanel — this is its
                // frozen sibling in the same overlay card, kept visually identical).
                .scrollIndicators(.automatic)
                .vgNativeOverlayScrollers()
                .frame(maxHeight: 400)
            }
            .vgOverlayCard(vg)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("history.tree.panel")
        }
    }
}

