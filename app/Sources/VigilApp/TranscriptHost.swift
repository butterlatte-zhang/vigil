import SwiftUI

// The shared host shell for DeadNodePane and HistoryPane.
// The center areas of the two "view a dead session / dead node transcript" panes share
// the same .task double read (tail-read items + full-scan stats), focused + onKeyPress(.return)
// Enter-to-resume, bottom ResumeHintBar, vg.term background + AX container. Collapsed into one
// here; header row / body / credential source / AX id are all injected — the real differences
// between the two call sites (a live session's dead node has a frozen-frame fallback, the
// history header has a tree-card overlay column and root-crowned stats) stay in their own
// panes, out of the host.

/// Shared transcript-viewing shell: header row · self-rendered content · bottom
/// ResumeHintBar; owns focus, the Enter-to-resume key, and the off-main double read.
/// This read shape is the correct baseline (do not change): `.task` + `Task.detached`,
/// tail-read + full-scan together off the main thread.
struct TranscriptHostView<TaskID: Equatable, Header: View, Content: View>: View {
    let transcriptPath: String?
    /// Restarts the load (and re-grabs focus) when it changes — the history pane keys
    /// on session+selection, the dead-node pane on the transcript path itself.
    let taskID: TaskID
    let axID: String
    let hint: String?
    let readOnlyText: String
    let hintAxID: String
    /// Non-nil = Enter resumes (the hint bar should say so via `hint`); nil = read-only.
    let onResume: (() -> Void)?
    /// Test seam (T1b, same rationale as LauncherView's): ViewInspector renders
    /// un-hosted views where .task never fires, so tests inject pre-parsed items/stats.
    let preloadedItems: [TranscriptItem]?
    let preloadedStats: TranscriptStats?
    /// Applied to freshly LOADED stats only (never to preloaded ones — the seam injects
    /// them final): the history pane crowns root stats with the session name here.
    let mapStats: (TranscriptStats?) -> TranscriptStats?
    let header: Header
    let content: ([TranscriptItem]?, TranscriptStats?) -> Content

    @State private var items: [TranscriptItem]?
    @State private var stats: TranscriptStats?
    @FocusState private var focused: Bool
    @Environment(\.vg) private var vg

    init(transcriptPath: String?, taskID: TaskID, axID: String,
         hint: String?, readOnlyText: String, hintAxID: String,
         onResume: (() -> Void)?,
         preloadedItems: [TranscriptItem]? = nil,
         preloadedStats: TranscriptStats? = nil,
         mapStats: @escaping (TranscriptStats?) -> TranscriptStats? = { $0 },
         @ViewBuilder header: () -> Header,
         @ViewBuilder content: @escaping ([TranscriptItem]?, TranscriptStats?) -> Content) {
        self.transcriptPath = transcriptPath
        self.taskID = taskID
        self.axID = axID
        self.hint = hint
        self.readOnlyText = readOnlyText
        self.hintAxID = hintAxID
        self.onResume = onResume
        self.preloadedItems = preloadedItems
        self.preloadedStats = preloadedStats
        self.mapStats = mapStats
        self.header = header()
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content(preloadedItems ?? items, preloadedStats ?? stats)
            ResumeHintBar(hint: hint, readOnlyText: readOnlyText, axID: hintAxID)
        }
        .background(vg.term)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(axID)
        .focusable()
        .focusEffectDisabled()      // Enter needs focus, but the blue focus ring doesn't belong to this UI
        .focused($focused)
        .onKeyPress(.return) { handleReturn() }
        .task(id: taskID) {
            focused = true
            guard preloadedItems == nil else { return }
            // Stats is a full-file scan (usage must cover the whole session), sent off to a background thread together with the tail-read.
            let path = transcriptPath
            let (it, st) = await Task.detached {
                (TranscriptRender.load(path: path), TranscriptRender.stats(path: path))
            }.value
            items = it
            stats = mapStats(st)
        }
    }

    /// The Enter verdict, kept off the view chain so T1a can pin it directly
    /// (ViewInspector cannot drive onKeyPress): no resume credentials = .ignored
    /// (the key keeps bubbling), otherwise fire and swallow.
    func handleReturn() -> KeyPress.Result {
        guard let onResume else { return .ignored }
        onResume()
        return .handled
    }
}
