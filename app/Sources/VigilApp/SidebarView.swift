import SwiftUI
import AppKit
import VigilCore
import VigilRuntime   // ArchivedSessionSummary (history rows)

// Sidebar: no inline node tree here (it lives in TreePanel.swift, top-right overlay).
// Structure: traffic lights + collapse · pinned new-chat/search · projects › sessions · Chats
// (scratch). Collapsing hides the WHOLE sidebar (no 58pt strip); the traffic lights +
// expand button then re-appear in the main top bar (Views.swift). There is no bottom
// account area (settings go through the ⌘, menu); the right edge is an 8pt
// drag-to-resize strip.
// Views only read state and call AppModel/SessionVM methods — the iron law.

struct SidebarView: View {
    @Bindable var app: AppModel
    @Environment(\.vg) private var vg
    @State private var searching = false
    // The query text lives on AppModel (app.searchQuery) so the rendered order and ⌘1–9
    // filter on ONE source; `searching` stays view-local (it only decides whether the
    // field is shown, not what gets filtered).
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topRow(vg)
            pinnedRows(vg)
            list(vg)
        }
        .frame(width: app.railWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(vg.panelSolid)
        .overlay(alignment: .trailing) { resizeHandle }
    }

    /// Trailing-edge resize strip. AppKit-backed (see PaneResizeHandle): refuses
    /// window-drag, owns the resize cursor, and drives the width through closures.
    private var resizeHandle: some View {
        PaneResizeHandle(
            axis: .horizontal,
            valueAtStart: { app.railWidth },
            onChange: { app.setRailWidth($0) },
            onEnd: { app.persistRailWidth() }
        )
        .frame(width: 8)
        .accessibilityIdentifier("side.resizeHandle")
    }

    // MARK: - top: traffic lights + collapse (SPEC pad 14 10 8 16, gap 8)

    private func topRow(_ vg: VGTokens) -> some View {
        HStack(spacing: 8) {
            TrafficLightsRow()
            Spacer()
            SideIconBtn(vg: vg, action: { app.toggleSidebar() }) { SidebarGlyph() }
                .accessibilityIdentifier("rail.collapseToggle")
                .help("Collapse sidebar")
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 8, trailing: 10))
        .background(TitlebarDragSurface())  // restores double-click-to-zoom on the blank drag area
    }

    // MARK: - pinned: new chat + search (SPEC pad 2 8 4)

    private func pinnedRows(_ vg: VGTokens) -> some View {
        VStack(spacing: 1) {
            SideRow(vg: vg, action: { app.newChat() }) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(vg.text2)
                    .frame(width: 16)
                Text("New chat").font(VGFont.ui(13.5)).foregroundStyle(vg.text)
            }
            .accessibilityIdentifier("side.newChat")

            if searching {
                TextField("Search sessions…", text: $app.searchQuery)
                    .textFieldStyle(.plain)
                    .font(VGFont.ui(13)).foregroundStyle(vg.text)
                    .focused($searchFocused)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(vg.card, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(vg.hair2, lineWidth: 1))
                    .padding(EdgeInsets(top: 2, leading: 2, bottom: 3, trailing: 2))
                    .accessibilityIdentifier("side.searchField")
                    .onExitCommand { app.searchQuery = ""; searching = false }
                    .onChange(of: searchFocused) { _, f in
                        // Blur with an empty query folds the field back into its icon row.
                        if !f && app.searchTerm.isEmpty {
                            app.searchQuery = ""
                            searching = false
                        }
                    }
            } else {
                SideRow(vg: vg, action: { searching = true; searchFocused = true }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(vg.text2)
                        .frame(width: 16)
                    Text("Search").font(VGFont.ui(13.5)).foregroundStyle(vg.text)
                }
                .accessibilityIdentifier("side.search")
            }

            // Zero footprint when there's no known update — no reserved row, no dead space.
            if let version = app.updateAvailableVersion {
                UpdatePill(vg: vg, version: version, action: { app.checkForUpdates() })
                    .accessibilityIdentifier("side.updateAvailable")
            }
        }
        .padding(EdgeInsets(top: 2, leading: 8, bottom: 4, trailing: 8))
    }

    // MARK: - list: projects › rows · Chats · Settings

    /// Search filter: project-name hit → all its rows; otherwise only
    /// name-matching rows (live AND dead alike); project visible when either matches.
    /// Filtering forces projects open and lifts the >5 cap. The filter/order primitives
    /// (searchTerm, filteredRows, sectionOpen, visibleProjects) live on AppModel so this view
    /// and ⌘1–9 share ONE source; the view just reads them.
    private var q: String { app.searchTerm }

    private func list(_ vg: VGTokens) -> some View {
        // 30s tick keeps the relative session timestamps live (same idiom as NotifStack).
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let projView = app.visibleProjects()
            let chatRows = app.filteredRows(app.chatsProject)
            let cfgRows = app.filteredRows(app.settingsProject)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Projects section: shown only if search has hits; normally shown even when there are no projects (includes the add entry).
                    if q.isEmpty || !projView.isEmpty {
                        sectionHeader("Projects", key: "projects", vg) {
                            SideIconBtn(vg: vg, size: 24, action: { app.addProjectViaPanel() }) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .accessibilityIdentifier("side.addProject")
                            .help("Add project (choose a folder)")
                        }
                        if sectionOpen("projects") {
                            ForEach(projView, id: \.project.id) { pv in
                                ProjectBlock(app: app, project: pv.project, rows: pv.rows,
                                             forcedOpen: !q.isEmpty, now: ctx.date, vg: vg)
                            }
                        }
                    }
                    // Chats/Settings: built-in pseudo-project sections — the section header is the group, rows laid out directly.
                    pseudoSection("Chats", key: "chats", project: app.chatsProject,
                                  rows: chatRows, now: ctx.date, vg: vg) {
                        SideIconBtn(vg: vg, size: 24, action: { app.openLauncher(in: app.chatsProject.id) }) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .accessibilityIdentifier("side.chats.new")
                        .help("New chat (no project)")
                    }
                    pseudoSection("Settings", key: "settings", project: app.settingsProject,
                                  rows: cfgRows, now: ctx.date, vg: vg) {
                        SideIconBtn(vg: vg, size: 24, action: { app.openConfigWorkspace() }) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .accessibilityIdentifier("side.settings.configure")
                        .help("Send an agent to change config (⌘,)")
                    }
                    archivedSection(now: ctx.date, vg: vg)
                    if !q.isEmpty && projView.isEmpty && chatRows.isEmpty && cfgRows.isEmpty
                        && app.filteredArchivedRows().isEmpty {
                        Text("No sessions match \"\(app.searchQuery)\"")
                            .font(VGFont.ui(12)).foregroundStyle(vg.text3)
                            .padding(EdgeInsets(top: 16, leading: 10, bottom: 16, trailing: 10))
                    }
                }
                .padding(EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Thin overlay scroller: `.hidden` can't suppress the fat native bar under
            // "Always show scroll bars", so this installs a custom overlay scroller instead.
            .scrollIndicators(.automatic)
            .vgNativeOverlayScrollers()
        }
    }

    private func sectionOpen(_ key: String) -> Bool { app.sectionOpen(key) }

    private func sectionHeader<A: View>(_ title: String, key: String, _ vg: VGTokens,
                                        @ViewBuilder accessory: () -> A) -> some View {
        SectionHeader(title: title, key: key, open: sectionOpen(key), vg: vg,
                      onToggle: { withAnimation(VGMotion.panel) { app.toggleSection(key) } },
                      accessory: accessory)
    }

    /// Chats/Settings section body: the pseudo-project's merged rows laid out directly (no project row), sharing the >5 collapse.
    @ViewBuilder
    private func pseudoSection<A: View>(_ title: String, key: String, project: ProjectVM,
                                        rows: [RailRow], now: Date, vg: VGTokens,
                                        @ViewBuilder accessory: () -> A) -> some View {
        sectionHeader(title, key: key, vg, accessory: accessory)
        if sectionOpen(key) {
            GroupRows(app: app, project: project, rows: rows, leftPad: 12,
                      capped: q.isEmpty, now: now, vg: vg)
        }
    }

    /// The Archived section holds filed-away sessions across ALL projects, pinned
    /// below Settings. Same section anatomy as Chats/Settings, with two deltas:
    /// no accessory button (nothing to create here) and the rows carry
    /// an Unarchive hover action instead of Archive.
    @ViewBuilder
    private func archivedSection(now: Date, vg: VGTokens) -> some View {
        let rows = app.filteredArchivedRows()
        if q.isEmpty || !rows.isEmpty {
            sectionHeader("Archived", key: "archived", vg) { EmptyView() }
            if sectionOpen("archived") {
                GroupRows(app: app, project: app.archivedProject, rows: rows, leftPad: 12,
                          capped: q.isEmpty, now: now, vg: vg, unarchiveRows: true)
            }
        }
    }
}

/// Section header: title + a rotating little arrow, click collapses/expands the
/// whole section; the section's action button hangs on the right, visible only
/// while the pointer is over the header. The accessory keeps its layout
/// slot via opacity so the header never jumps and its AX id stays in the tree
/// (T1b/axdriver contract); hit-testing is gated to the hovered state.
private struct SectionHeader<A: View>: View {
    let title: String
    let key: String
    let open: Bool
    let vg: VGTokens
    let onToggle: () -> Void
    let accessory: A
    @State private var hover = false

    init(title: String, key: String, open: Bool, vg: VGTokens,
         onToggle: @escaping () -> Void, @ViewBuilder accessory: () -> A) {
        self.title = title
        self.key = key
        self.open = open
        self.vg = vg
        self.onToggle = onToggle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: 5) {
                    Text(title).font(VGFont.ui(12.5)).foregroundStyle(vg.text3)
                    Text("›").font(VGFont.ui(11)).foregroundStyle(vg.text3)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .animation(VGMotion.gated(.easeInOut(duration: 0.18)), value: open)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("side.section.\(key)")
            .padding(EdgeInsets(top: 16, leading: 12, bottom: 8, trailing: 4))
            Spacer(minLength: 4)
            accessory
                .opacity(hover ? 1 : 0)
                .allowsHitTesting(hover)
                .padding(.top, 8)
                .padding(.trailing, 4)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: - Group rows (merged column + >5 collapsed by default + expand all)

/// One group's merged rows with the >5 cap. `capped` false (searching) shows all hits.
private struct GroupRows: View {
    @Bindable var app: AppModel
    @Bindable var project: ProjectVM
    let rows: [RailRow]
    let leftPad: CGFloat
    let capped: Bool
    let now: Date
    let vg: VGTokens
    /// Rows inside the Archived section flip their hover action to Unarchive.
    var unarchiveRows = false

    /// Reads runtime.json's sidebarCollapseThreshold (default 5, takes effect immediately).
    static var cap: Int { RuntimeTuning.current.sidebarCollapseThreshold }

    var body: some View {
        // The visible subset comes from AppModel.shownRows — the SAME fold logic
        // visibleSessionRows (⌘1–9) counts, so the rendered rows and ⌘N never diverge.
        let shown = app.shownRows(rows, project: project)
        ForEach(shown) { row in
            switch row {
            case .live(let s):
                SessionRow(app: app, session: s, leftPad: leftPad, now: now, vg: vg)
            case .dead(let d):
                DeadRow(app: app, item: d, leftPad: leftPad, now: now, vg: vg,
                        unarchive: unarchiveRows)
            }
        }
        if capped && rows.count > Self.cap {
            Button {
                withAnimation(VGMotion.panel) { app.toggleShowAllRows(project) }
            } label: {
                Text(project.showAllRows ? "Collapse" : "Show all (\(rows.count))")
                    .font(VGFont.ui(12)).foregroundStyle(vg.text3)
                    .padding(EdgeInsets(top: 0, leading: leftPad, bottom: 0, trailing: 10))
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("side.group.\(project.id).showAll")
        }
    }
}

// MARK: - Project block (row + expanded merged rows)

private struct ProjectBlock: View {
    @Bindable var app: AppModel
    @Bindable var project: ProjectVM
    let rows: [RailRow]
    let forcedOpen: Bool
    let now: Date
    let vg: VGTokens
    @State private var hover = false

    var body: some View {
        let expanded = forcedOpen || project.expanded
        // "selected" = this project's launcher page is open (SPEC: whole-row pill).
        let selected = app.currentProjectID == project.id && app.activeSessionID == nil
        VStack(alignment: .leading, spacing: 0) {
            Button {
                // Collapse changes go through AppModel (iron law + persistence hook point); the view never mutates state directly.
                if app.currentProjectID == project.id { app.toggleProjectExpanded(project) }
                else { app.selectProject(project.id) }
            } label: {
                HStack(spacing: 9) {
                    NotebookGlyph(open: expanded, vg: vg)
                    // The project name uses the same font size as session rows, regular —
                    // hierarchy is expressed by indentation and icon, not by bolding.
                    Text(project.name)
                        .font(VGFont.ui(13.5))
                        .foregroundStyle(project.sessions.isEmpty ? vg.text2 : vg.text)
                        .lineLimit(1).truncationMode(.tail)
                        .layoutPriority(1)
                    if selected || hover {
                        Text("›").font(VGFont.ui(12)).foregroundStyle(vg.text2)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .animation(VGMotion.gated(.easeInOut(duration: 0.18)), value: expanded)
                            .frame(width: 12)
                    }
                    Spacer(minLength: 4)
                    if !expanded && project.badgeTotal > 0 && !hover && !selected {
                        Circle().fill(vg.warn).frame(width: 8, height: 8).padding(.trailing, 2)
                    }
                    if selected || hover {
                        SideIconBtn(vg: vg, size: 24, action: { app.openLauncher(in: project.id) }) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .accessibilityIdentifier("rail.project.\(project.id).newSession")
                        .help("New session in this project")
                    }
                }
                .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 8))
                .frame(height: 34)
                .background((selected || hover) ? vg.hoverBG : .clear,
                            in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("rail.project.\(project.id)")
            .onHover { hover = $0 }
            .padding(.bottom, 3)

            if expanded {
                if rows.isEmpty && forcedOpen == false {
                    Text("No conversations yet")
                        .font(VGFont.ui(12.5)).foregroundStyle(vg.text3)
                        .padding(EdgeInsets(top: 2, leading: 36, bottom: 8, trailing: 10))
                } else {
                    GroupRows(app: app, project: project, rows: rows, leftPad: 36,
                              capped: !forcedOpen, now: now, vg: vg)
                }
            }
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Session row (h35 · name · status dot · relative time)

/// Session-row indicator — a PURE derivation of node statuses + unread badge; a session
/// has NO lifecycle state of its own:
///   attention — a node waits for the human (waiting) or unread notices exist: static
///               yellow dot, summoning the human (a spinner here would hide "it needs YOU");
///   live      — ONLY running/starting count as working: SpinnerRing;
///   rest      — idle / whole tree terminal (done/failed).
/// Priority attention > live: a human being needed somewhere outranks other nodes
/// still working.
/// The status dot has only three visible states — spinner (live) / yellow dot (attention) /
/// blue dot (rest AND completedUnseen: done but you haven't looked, one click dismisses it,
/// see SessionVM.watchIndicator). Everything else stays blank.
enum SessionIndicator: Equatable { case attention, live, rest }

/// Session status ROLLUP — derived from the single dot classifier (the classification
/// switch lives only in `dotClass`; this reduces per-node buckets to one session bucket,
/// an aggregation, not a second switch). `unseen: true` here means the rollup reports
/// attention for any errored/failed node — session granularity keeps its own semantics
/// (a session-level card doesn't clear per-node-view; the tree row does). Failed counts
/// as attention — an abnormal exit warrants a glance.
func sessionIndicator(badge: Int, tree: Tree) -> SessionIndicator {
    if badge > 0 { return .attention }
    var hasSpinner = false
    for n in tree.nodes.values {
        switch dotClass(n.status, unseen: true) {
        case .yellow:  return .attention
        case .spinner: hasSpinner = true
        case .blue, .plain: break
        }
    }
    return hasSpinner ? .live : .rest
}

/// The sidebar row's dot bucket — the rollup plus the session-level completedUnseen
/// (which keeps its own granularity). One-time blue only when the whole session came
/// to rest behind the user's back; everything else follows the rollup.
func sessionDotClass(badge: Int, tree: Tree, completedUnseen: Bool) -> DotClass {
    switch sessionIndicator(badge: badge, tree: tree) {
    case .attention: return .yellow
    case .live:      return .spinner
    case .rest:      return completedUnseen ? .blue : .plain
    }
}

private struct SessionRow: View {
    @Bindable var app: AppModel
    @Bindable var session: SessionVM
    let leftPad: CGFloat
    let now: Date
    let vg: VGTokens

    var body: some View {
        let dot = sessionDotClass(badge: session.badge, tree: session.store.tree,
                                  completedUnseen: session.completedUnseen)
        SidebarRowShell(name: session.name, nameColor: vg.text,
                        date: session.createdAt,
                        focused: app.activeSessionID == session.id,
                        axID: "rail.session.\(session.id)",
                        leftPad: leftPad, now: now, vg: vg,
                        // Archiving a live row means silent shutdown + file away
                        // (rest-harvester semantics; the row moves to Archived).
                        hoverAction: RowHoverAction(
                            icon: "archivebox", help: "Archive",
                            axID: "rail.session.\(session.id).archive",
                            action: { app.archiveSession(session.id) }),
                        action: { app.select(session: session.id) }) {
            // Unified dot: same four buckets as the node tree, classified once in
            // dotClass. `.plain` = a seen/rest session draws nothing.
            switch dot {
            case .yellow:
                Circle().fill(vg.warn).frame(width: 8, height: 8)
                    .accessibilityIdentifier("rail.session.\(session.id).status.attention")
            case .spinner:
                SpinnerRing(size: 11, line: 1.5, base: vg.text.opacity(0.1), top: vg.text2)
                    .accessibilityIdentifier("rail.session.\(session.id).status.live")
            case .blue:
                // Unseen-done marker is a fixed system blue (not accent-following),
                // shared verbatim with the node tree row.
                Circle().fill(dotBlue(vg))
                    .frame(width: 8, height: 8)
                    .accessibilityIdentifier("rail.session.\(session.id).status.done")
            case .plain:
                EmptyView()
            }
        }
    }
}

// MARK: - Dead row (dead-session rows stay in the group: gray dot, click to resume)

private struct DeadRow: View {
    @Bindable var app: AppModel
    let item: ArchivedSessionSummary
    let leftPad: CGFloat
    let now: Date
    let vg: VGTokens
    /// True inside the Archived section — the hover action flips to Unarchive.
    var unarchive = false

    var body: some View {
        // Click = view (a read-only history view of the self-rendered transcript); Enter
        // inside the view is what resumes.
        // The status dot expresses only the three visible states "running / waiting on
        // you / done-unread" — a dead session belongs to "other states", left blank (the
        // name is already dimmed, the row itself carries dead semantics).
        SidebarRowShell(name: item.name, nameColor: vg.text2,
                        date: item.createdAt ?? item.modifiedAt,
                        focused: app.selectedHistoryID == item.id,
                        axID: "side.history.\(item.id)",
                        leftPad: leftPad, now: now, vg: vg,
                        hoverAction: unarchive
                            ? RowHoverAction(icon: "tray.and.arrow.up", help: "Unarchive",
                                             axID: "side.history.\(item.id).unarchive",
                                             action: { app.setHistoryArchived(item.id, false) })
                            : RowHoverAction(icon: "archivebox", help: "Archive",
                                             axID: "side.history.\(item.id).archive",
                                             action: { app.setHistoryArchived(item.id, true) }),
                        action: { app.openHistory(item.id) }) {
            EmptyView()
        }
    }
}

/// A row's hover-revealed trailing action (archive / unarchive) — shown in the
/// time stamp's slot while the pointer is on the row.
struct RowHoverAction {
    let icon: String        // SF Symbol name
    let help: String
    let axID: String
    let action: () -> Void
}

/// Shared row shell for SessionRow and DeadRow: h35 · r10 · focused/hover pill ·
/// name · indicator slot · relative time. The two rows differ only in name tone
/// (live text / dead text2), indicator (status matrix / blank), focus source, action
/// and AX id — all injected; no date → no time column (dead rows with no stamps).
/// Hovering swaps the time stamp for the row's trailing action button; both stay
/// in the view tree (opacity swap) so T1b/axdriver can always reach the button's AX id.
private struct SidebarRowShell<Indicator: View>: View {
    let name: String
    let nameColor: Color
    let date: Date?
    let focused: Bool
    let axID: String
    let leftPad: CGFloat
    let now: Date
    let vg: VGTokens
    let hoverAction: RowHoverAction?
    let action: () -> Void
    let indicator: Indicator
    @State private var hover = false

    init(name: String, nameColor: Color, date: Date?, focused: Bool, axID: String,
         leftPad: CGFloat, now: Date, vg: VGTokens,
         hoverAction: RowHoverAction? = nil, action: @escaping () -> Void,
         @ViewBuilder indicator: () -> Indicator) {
        self.name = name
        self.nameColor = nameColor
        self.date = date
        self.focused = focused
        self.axID = axID
        self.leftPad = leftPad
        self.now = now
        self.vg = vg
        self.hoverAction = hoverAction
        self.action = action
        self.indicator = indicator()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(name)
                    .font(VGFont.ui(13.5)).foregroundStyle(nameColor)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                indicator
                trailing
            }
            .padding(EdgeInsets(top: 0, leading: leftPad, bottom: 0, trailing: 10))
            .frame(height: 35)
            .background((focused || hover) ? vg.hoverBG : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(axID)
        .onHover { hover = $0 }
        .padding(.bottom, 3)
    }

    /// Time stamp ⇄ action button. The button reveals on hover and REPLACES the time
    /// (the row must not widen); rows without a hoverAction keep the plain time column.
    @ViewBuilder
    private var trailing: some View {
        if let hoverAction {
            ZStack(alignment: .trailing) {
                if let date {
                    Text(VGDuration.relative(date, now: now))
                        .font(VGFont.ui(12)).foregroundStyle(vg.text3)
                        .opacity(hover ? 0 : 1)
                }
                SideIconBtn(vg: vg, size: 24, action: hoverAction.action) {
                    Image(systemName: hoverAction.icon)
                        .font(.system(size: 12, weight: .medium))
                }
                .accessibilityIdentifier(hoverAction.axID)
                .help(hoverAction.help)
                .opacity(hover ? 1 : 0)
                .allowsHitTesting(hover)
            }
        } else if let date {
            Text(VGDuration.relative(date, now: now))
                .font(VGFont.ui(12)).foregroundStyle(vg.text3)
        }
    }
}

// MARK: - Shared bits

/// Pinned-row shell: gap 10, pad 7×10, r8, hover hov5.
private struct SideRow<C: View>: View {
    let vg: VGTokens
    let action: () -> Void
    @ViewBuilder let content: C
    @State private var hover = false
    init(vg: VGTokens, action: @escaping () -> Void, @ViewBuilder content: () -> C) {
        self.vg = vg; self.action = action; self.content = content()
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { content; Spacer(minLength: 0) }
                .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
                .background(hover ? vg.hoverBGSoft : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Sidebar update pill — "Update · 0.1.3" — rendered only while an update is known
/// (AppModel.updateAvailableVersion), directly below Search and above the Projects group
/// header. Click runs the same standard-Sparkle-UI flow as the Settings buttons
/// (AppModel.checkForUpdates).
private struct UpdatePill: View {
    let vg: VGTokens
    let version: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                Text("Update · \(version)")
                    .font(VGFont.ui(12.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(vg.accent)
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
            .background(vg.accent.opacity(hover ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("A new Vigil version is available")
    }
}

/// Square icon button (28×28 default / 24×24 in rows), r8, hover hov7.
struct SideIconBtn<C: View>: View {
    let vg: VGTokens
    var size: CGFloat = 28
    let action: () -> Void
    @ViewBuilder let content: C
    @State private var hover = false
    init(vg: VGTokens, size: CGFloat = 28, action: @escaping () -> Void,
         @ViewBuilder content: () -> C) {
        self.vg = vg; self.size = size; self.action = action; self.content = content()
    }
    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(vg.text2)
                .frame(width: size, height: size)
                .background(hover ? vg.hoverBGStrong : .clear,
                            in: RoundedRectangle(cornerRadius: size < 28 ? 6 : 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Sidebar-toggle glyph: 15×12 rounded rect, 1.5px border, radius 3, solid 4.5px left bar.
struct SidebarGlyph: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3).strokeBorder(.primary, lineWidth: 1.5)
            .frame(width: 15, height: 12)
            .overlay(alignment: .leading) {
                Rectangle().fill(.primary).frame(width: 4.5)
                    .clipShape(.rect(topLeadingRadius: 1.5, bottomLeadingRadius: 1.5))
            }
            .opacity(0.9)
    }
}

/// Project notebook glyph 17×17: rounded page (11.2×12.6 r2.8) + three binding ticks on
/// the left; the open state tilts the whole page -10°.
/// Shared with the launcher's project chip (CenterView2).
struct NotebookGlyph: View {
    let open: Bool
    let vg: VGTokens
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2.8)
                .strokeBorder(vg.text2, lineWidth: 1.4)
                .frame(width: 11.2, height: 12.6)
                .offset(x: 3.2, y: 2.2)
            ForEach(0..<3, id: \.self) { i in
                Rectangle().fill(vg.text2)
                    .frame(width: 1.5, height: 1.4)
                    .offset(x: 1.7, y: 5.6 + CGFloat(i) * 2.9)
            }
        }
        .frame(width: 17, height: 17)
        .rotationEffect(.degrees(open ? -10 : 0))
        .animation(VGMotion.gated(.easeInOut(duration: 0.15)), value: open)
    }
}

/// Continuously spinning ring: `base` full ring + `top` arc rotating 0.8s linear.
struct SpinnerRing: View {
    let size: CGFloat
    let line: CGFloat
    let base: Color
    let top: Color
    @State private var spin = false
    var body: some View {
        ZStack {
            Circle().strokeBorder(base, lineWidth: line)
            Circle().trim(from: 0, to: 0.26)
                .stroke(top, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .padding(line / 2)
                .rotationEffect(.degrees(spin ? 360 : 0))
        }
        .frame(width: size, height: size)
        .onAppear {
            // Reduce-Motion exception (the ONE deliberately un-gated animation):
            // this is an indeterminate progress spinner — its rotation *is* the "working"
            // signal. Freezing it to a static 26% arc reads as a hung/broken control, which
            // is worse for everyone. Continuous progress indicators are a recognised
            // Reduce-Motion exception (the system's own spinners keep turning). Status is
            // additionally conveyed by the sidebar's colour dot + text, so no info is lost.
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                spin = true
            }
        }
    }
}
