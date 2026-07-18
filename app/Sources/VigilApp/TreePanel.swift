import SwiftUI
import VigilCore

// Node-tree panel (SPEC §1 top-right overlay column ①): the session's node tree, in
// a floating top-right card (322pt, radius 16, card bg). Toggled by the
// top-bar tree button (per-session `treeCollapsed`).
// Row click = select that node (the terminal follows). Iron law: read-only + VM calls.
//
// The runtime column is REAL time from the MODEL's clock stamps: startedAt = task
// creation (spawned by the store), endedAt = terminal moment. The
// panel renders them purely — no local clock state, so panel rebuilds (toggle / session
// switch) can never reset or cross-wire the column. "—" for ghosts (still starting).

struct TreePanel: View {
    @Bindable var session: SessionVM
    @Environment(\.vg) private var vg

    var body: some View {
        // The tree doesn't become unusable from dead nodes piling up: finished
        // (done/failed/killed) nodes can be hidden with one click. Filtering happens in
        // flatten (connectors recomputed from the visible subset); the root never hides.
        let rows = flattenTree(session.store.tree, hideFinished: session.hideFinishedNodes)
        let finished = session.store.tree.nodes.values
            .filter { $0.status.isTerminal && $0.id != session.store.tree.rootID }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Tree").font(VGFont.ui(14, weight: .semibold)).foregroundStyle(vg.text)
                Spacer()
                if finished > 0 {
                    Button(session.hideFinishedNodes ? "Show finished \(finished)" : "Hide finished") {
                        session.hideFinishedNodes.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(VGFont.ui(11)).foregroundStyle(vg.text3)
                    .accessibilityIdentifier("tree.finishedToggle")
                }
                Text("\(rows.count) nodes").font(VGFont.ui(11)).foregroundStyle(vg.text3)
            }
            .padding(EdgeInsets(top: 2, leading: 4, bottom: 8, trailing: 4))

            // 1s tick keeps the runtime column live while the panel is open. The
            // ScrollViewReader auto-focuses the selected row: the tree can outgrow the
            // card, so a selection changed anywhere (sidebar row / ⌘⇧[] / ⌘⇧U / notification
            // card — all funnel through `selectedID`) must scroll itself into view, and
            // opening the card lands on the current selection. One truth source: `session.selectedID`.
            ScrollViewReader { proxy in
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(rows, id: \.node.id) { row in
                                TreePanelRow(session: session, row: row,
                                             time: nodeRuntimeText(row.node, now: ctx.date), vg: vg)
                                    .id(row.node.id)
                            }
                        }
                    }
                    // Native overlay scrollbar: thin, rounded, translucent, shows on
                    // scroll then auto-fades (SPEC §1 tree-panel inner scroll). `.automatic`
                    // lets the indicator show; `vgNativeOverlayScrollers` pins the backing
                    // NSScrollView to overlay style so it stays thin even under the system
                    // "Always show scroll bars" pref (which otherwise draws the fat legacy bar).
                    .scrollIndicators(.automatic)
                    .vgNativeOverlayScrollers()
                    .frame(maxHeight: 400)
                }
                .onAppear { focusSelected(proxy, rows: rows, animated: false) }
                .onChange(of: session.selectedID) { _, _ in
                    focusSelected(proxy, rows: rows, animated: true)
                }
            }
        }
        .vgOverlayCard(vg, minHeight: 258)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tree.panel")
    }

    /// Scroll the selected row into view (centered). Only fires when the selection has a
    /// visible row (`treeScrollTarget`) — a selection hidden by the hide-finished toggle stays put
    /// rather than scrolling to nowhere. Animated on selection change, instant on open.
    private func focusSelected(_ proxy: ScrollViewProxy, rows: [TreeDisplayRow],
                               animated: Bool) {
        guard let target = treeScrollTarget(rows: rows, selected: session.selectedID)
        else { return }
        if animated {
            withAnimation(VGMotion.gated(.easeInOut(duration: 0.18))) { proxy.scrollTo(target, anchor: .center) }
        } else {
            proxy.scrollTo(target, anchor: .center)
        }
    }
}

/// The row a selection should scroll to: the selected node's id when it has a VISIBLE
/// row, else nil (hidden by the hide-finished toggle → no scroll, never a jump to an off-list id).
/// Pure so T1 can pin selected→target without rendering the card.
func treeScrollTarget(rows: [TreeDisplayRow], selected: NodeID) -> NodeID? {
    rows.contains { $0.node.id == selected } ? selected : nil
}

/// Runtime column text — pure function of the node's model stamps: counts from
/// startedAt (task creation), freezes at endedAt (terminal). "—" while the node is
/// still a ghost (starting) or was never stamped.
func nodeRuntimeText(_ node: Node, now: Date) -> String {
    guard designStatus(node) != .starting, let start = node.startedAt else { return "—" }
    let end = node.endedAt ?? now
    return VGDuration.runtime(seconds: max(0, Int(end.timeIntervalSince(start))))
}

// MARK: - One row (h27 · connectors · dot · mono label · runtime)

private struct TreePanelRow: View {
    @Bindable var session: SessionVM
    let row: TreeDisplayRow
    let time: String
    let vg: VGTokens

    var body: some View {
        // Unified dot: the SAME classifier as the sidebar. Observed
        // subagents (no PTY, no unseen tracking of their own) stay pure spinner.
        // Everything else = dotClass(status, per-node unseen).
        let d: DotClass = row.node.kind == .observed
            ? .spinner
            : dotClass(row.node.status, unseen: session.isNodeUnseen(row.node.id))
        NodeRow(row: row, time: time,
                selected: session.selectedID == row.node.id,
                hoverBG: vg.hoverBGStrong,
                axID: "tree.node.\(row.node.id.raw)",
                vg: vg,
                action: { session.select(row.node.id) }) {
            dot(d)
        }
        // Dead nodes (done/failed/killed) dim to .5; starting nodes render as a normal
        // spinner (no dashed ring).
        .opacity(row.node.status.isTerminal ? 0.5 : 1)
    }

    /// 9×9 status dot, one bucket per DotClass: spinner while working;
    /// blue for an unseen completion (idle/done); yellow for attention (waiting/stalled/
    /// queued, or an unviewed errored/failed); hollow ring for `.plain` (the node-tree's
    /// default — a seen completion, an acknowledged error, or a killed node).
    @ViewBuilder
    private func dot(_ d: DotClass) -> some View {
        switch d {
        case .spinner:
            SpinnerRing(size: 9, line: 1.5, base: vg.spinring, top: vg.accent)
        case .blue:
            Circle().fill(dotBlue(vg)).frame(width: 9, height: 9)
        case .yellow:
            Circle().fill(vg.warn).frame(width: 9, height: 9)
        case .plain:
            Circle().strokeBorder(vg.text2, lineWidth: 1).frame(width: 9, height: 9)
        }
    }
}

// MARK: - Shared row shell (TreePanel live rows ↔ HistoryTreePanel frozen rows)

/// The one tree-row layout (h27 · connectors · 9×9 dot slot · id badge · mono label ·
/// runtime column). The two panels differ ONLY in what they inject: the dot (live spinner
/// matrix vs frozen fill), hover tone, selection source, AX namespace, and the frozen
/// panel's extra 10pt gap before the time column — none of that lives here.
struct NodeRow<Dot: View>: View {
    let row: TreeDisplayRow
    let time: String
    let selected: Bool
    let hoverBG: Color
    var timeLeadingPad: CGFloat = 0
    let axID: String
    let vg: VGTokens
    let action: () -> Void
    let dot: Dot
    @State private var hover = false

    init(row: TreeDisplayRow, time: String, selected: Bool, hoverBG: Color,
         timeLeadingPad: CGFloat = 0, axID: String, vg: VGTokens,
         action: @escaping () -> Void, @ViewBuilder dot: () -> Dot) {
        self.row = row
        self.time = time
        self.selected = selected
        self.hoverBG = hoverBG
        self.timeLeadingPad = timeLeadingPad
        self.axID = axID
        self.vg = vg
        self.action = action
        self.dot = dot()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                ForEach(0..<row.depth, id: \.self) { level in
                    ConnectorCell(kind: connector(at: level), vg: vg)
                }
                dot
                    .padding(.leading, 2).padding(.trailing, 8)   // margin 0 8 0 2
                // Node-id badge: a pill (n5 / root) so siblings sharing a task-text
                // prefix stay distinguishable — the task text alone couldn't tell them
                // apart. Secondary tone (mono 10.5 / text3 / hov6 pill), lives in both the
                // live TreePanel and the frozen HistoryTreePanel (they share this shell).
                Text(row.node.id.raw)
                    .font(VGFont.mono(10.5, weight: .medium))
                    .foregroundStyle(vg.text3)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(vg.hoverBG, in: RoundedRectangle(cornerRadius: 4))
                    .padding(.trailing, 6)
                    .fixedSize()
                Text(row.node.title.isEmpty ? row.node.id.raw : row.node.title)
                    .font(VGFont.mono(12, weight: row.node.role == .manager ? .semibold : .regular))
                    .tracking(-0.2)
                    .foregroundStyle(vg.text)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 14)
                Text(time)
                    .font(VGFont.mono(10.5)).foregroundStyle(vg.text3)
                    .padding(.leading, timeLeadingPad)
            }
            .padding(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 6))
            .frame(height: 27)
            .background(selected ? vg.selectedBG
                                 : (hover ? hoverBG : .clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(axID)
        .onHover { hover = $0 }
    }

    private func connector(at level: Int) -> TreeConnector {
        if level < row.depth - 1 {
            return row.lineage[level] ? .blank : .vline
        }
        return row.lineage[row.depth - 1] ? .ell : .tee
    }
}

// MARK: - Flattened display rows (shared shape with the design's flatten())

/// `lineage[i]` = whether the ancestor at depth i+1 (self at the last index) is the LAST
/// child of its parent — drives the connectors: levels 0..<d-1: last-ancestor → blank,
/// else vline; level d-1: last → ell(└), else tee(├).
struct TreeDisplayRow {
    let node: Node
    let depth: Int          // root = 0
    let lineage: [Bool]     // count == depth
}

/// `hideFinished` skips terminal nodes (done/failed/killed) and recomputes lineage
/// from the VISIBLE siblings so connectors stay correct. A dead subtree stays in
/// the tree (its dead descendants are records too), so skipping a terminal parent also
/// stops recursion — the whole dead subtree hides as one. The root never hides.
func flattenTree(_ tree: VigilCore.Tree, hideFinished: Bool = false) -> [TreeDisplayRow] {
    var out: [TreeDisplayRow] = []
    func walk(_ id: NodeID, depth: Int, lineage: [Bool]) {
        guard let node = tree[id] else { return }
        out.append(TreeDisplayRow(node: node, depth: depth, lineage: lineage))
        let kids = node.children.filter {
            !hideFinished || !(tree[$0]?.status.isTerminal ?? true)
        }
        for (i, kid) in kids.enumerated() {
            walk(kid, depth: depth + 1, lineage: lineage + [i == kids.count - 1])
        }
    }
    walk(tree.rootID, depth: 0, lineage: [])
    return out
}

enum TreeConnector { case blank, vline, tee, ell }

/// One 14×27 connector cell: vline at x7 w1.5 (`--node-line`); tee/ell horizontal bar
/// x7 / top 12.75 / w8 / h1.5; ell's vertical only reaches 13.5 (SPEC §1 tree panel).
struct ConnectorCell: View {
    let kind: TreeConnector
    let vg: VGTokens
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if kind == .vline || kind == .tee {
                Rectangle().fill(vg.nodeLine).frame(width: 1.5, height: 27).offset(x: 7)
            }
            if kind == .ell {
                Rectangle().fill(vg.nodeLine).frame(width: 1.5, height: 13.5).offset(x: 7)
            }
            if kind == .tee || kind == .ell {
                Rectangle().fill(vg.nodeLine).frame(width: 8, height: 1.5).offset(x: 7, y: 12.75)
            }
        }
        .frame(width: 14, height: 27)
    }
}
