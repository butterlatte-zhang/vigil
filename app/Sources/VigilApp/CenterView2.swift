import SwiftUI
import Foundation
import VigilCore
#if os(macOS)
import AppKit
#endif


// Center pane (SPEC §4).
// Two top-level states: LauncherView (project has no focused session — the "what shall we
// build" card) and TerminalPane (breadcrumb → real terminal: the terminal is the
// native, only input surface — approvals happen in claude's own TUI, not in Vigil chrome).
// Iron law holds: everything goes through SessionVM methods → store.send(Command);
// nothing here touches a cell or the tree directly.

// MARK: - Launcher (SPEC §4.1)

struct LauncherView: View {
    let app: AppModel
    let project: ProjectVM
    @Environment(\.vg) private var vg

    // The task text lives in a reference model, NOT view @State — keystrokes only
    // re-evaluate LauncherPromptField (which reads it); this body never reads .text, so
    // the title and the selector chips stop rebuilding per keystroke.
    @State private var prompt: LauncherPromptModel
    @State private var agent: String

    // Test seam (T1b): ViewInspector cannot mutate @State on a view that is not hosted
    // in a window, so wiring tests inject the launcher's starting agent here. Production
    // call sites pass nothing → the agent seeds from launcher.json's default.
    // The launcher is project · agent · prompt — no model or
    // access pickers (permission defaults all-on; model tier = roles.json per-role).
    init(app: AppModel, project: ProjectVM,
         initialTask: String = "", initialAgent: String? = nil) {
        self.app = app
        self.project = project
        _prompt = State(initialValue: LauncherPromptModel(
            text: initialTask.isEmpty
                ? (app.launcherPrefill(for: project.id) ?? "")
                : initialTask))
        _agent = State(initialValue: initialAgent ?? app.defaultAgent)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("What do you want to build in \(project.name)?")
                .font(VGFont.ui(29, weight: .bold)).tracking(-0.4)
                .foregroundStyle(vg.text)
                .multilineTextAlignment(.center)
                .padding(.bottom, 26)

            inputCard
        }
        .padding(.horizontal, 70)
        .padding(.bottom, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(vg.term)
        .onAppear {
            // Structural identity keeps this view's @State across project switches, so
            // a prefill set AFTER first render (onboarding/reconfigure) seeds here.
            // (Focus-on-appear lives in PromptNSTextView.)
            if prompt.text.isEmpty, let p = app.launcherPrefill(for: project.id) {
                prompt.text = p
            }
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Multiline task input (textarea minH 64, transparent, placeholder text-3).
            // NSTextView representable — TextField(axis:.vertical) re-measures the
            // whole text per keystroke and chokes on pasted briefs; see LauncherPrompt.swift.
            LauncherPromptField(model: prompt, vg: vg, onSubmit: submit)

            // Selector row (gap 4, marginT 10): project · agent only — the model tier
            // lives in roles.json per-role, and access defaults all-on
            // (tighten via roles.json access).
            HStack(spacing: 4) {
                projectMenu
                agentMenu
                Spacer(minLength: 8)
                submitButton
            }
            .padding(.top, 10)

            // Zero-hit warning: the startup probe found NO agent CLI at all.
            // Submit stays enabled — agents.json may hold a hand-filled exotic path
            // the probe doesn't know; this is guidance, not a gate.
            if app.cliProbe?.isEmpty == true {
                Text("No claude / codex / opencode CLI detected — install one and restart Vigil, " +
                     "or set the bin path manually in agents.json under the settings directory")
                    .font(VGFont.ui(11)).foregroundStyle(vg.warn)
                    .padding(.top, 8)
                    .accessibilityIdentifier("launcher.noAgentBanner")
            }
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 11, trailing: 14))
        .background(vg.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(vg.hair, lineWidth: 1))
        .shadow(color: vg.shadowSmColor, radius: vg.shadowSmRadius, y: vg.shadowSmY)
        .frame(maxWidth: 620)
    }

    // Project picker: switch which project this task launches in, without a
    // round-trip through the sidebar; tail entry = add a new project folder.
    private var projectMenu: some View {
        Menu {
            ForEach(app.projects) { p in
                Button {
                    app.openLauncher(in: p.id)
                } label: {
                    if p.id == project.id {
                        Label(p.name, systemImage: "checkmark")
                    } else {
                        Text(p.name)
                    }
                }
            }
            Divider()
            Button("Add project…") { app.addProjectViaPanel() }
        } label: {
            SelectorChip(text: project.name, textColor: vg.text2, vg: vg) {
                NotebookGlyph(open: false, vg: vg)
                    .scaleEffect(12.0 / 17.0)   // chip glyph scale, 17→12
                    .frame(width: 12, height: 12)
            }
        }
        .launcherChip()
        .accessibilityIdentifier("launcher.projectPicker")
        .help("Which project the task goes to · add a new project here")
    }

    // Agent picker — entries from agents.json. Honesty red line: only wired-and-verified
    // kinds (claude, codex, opencode) are usable; a `custom`-kind entry is VISIBLE but
    // DISABLED — never run one CLI behind another's label.
    private var agentMenu: some View {
        Menu {
            ForEach(app.agentEntries, id: \.key) { e in
                if e.usable {
                    Button(e.key) { agent = e.key }
                } else {
                    Button("\(e.key) (unavailable)") {}.disabled(true)
                }
            }
        } label: {
            SelectorChip(text: agent, textColor: vg.text2, vg: vg) {
                PersonGlyph(vg: vg)
            }
        }
        .launcherChip()
        .accessibilityIdentifier("launcher.agentPicker")
        // claude/codex/opencode are all wired; only `custom` entries stay disabled
        // (honesty red line).
        .help("Which agent drives the manager · entries come from agents.json · custom kinds are disabled until wired")
    }

    private var submitButton: some View {
        Button(action: submit) {
            Text("↑")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(vg.accent, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Submit goes through "plain Enter" (PromptNSTextView.keyDown), while ⌘Enter/⇧Enter
        // insert a newline. Clicking this button still submits.
        .accessibilityIdentifier("launcher.submit")
        .help("Dispatch manager (Enter)")
    }

    private func submit() {
        // submissionText = the full text after attachment chips expand into
        // escaped paths (just `text` when there are no chips). The task is delivered to
        // the agent, which reads the path text itself with the Read tool.
        // Access/model are not chosen here — all-on default + roles.json per-role tier.
        app.launchSession(in: project.id, task: prompt.submissionText, agent: agent)
        app.launcherPrefill = nil   // one-shot: the onboarding prompt was sent
        prompt.text = ""
    }
}

private extension View {
    /// The launcher selector chips' shared Menu styling: plain-button menu, no indicator,
    /// hugged size.
    func launcherChip() -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// Person glyph 12×12 (launcher agent chip): head circle + shoulders arc.
private struct PersonGlyph: View {
    let vg: VGTokens
    var body: some View {
        ZStack(alignment: .top) {
            Circle().strokeBorder(vg.text2, lineWidth: 1.6)
                .frame(width: 5.4, height: 5.4).offset(y: 0.6)
            Circle().trim(from: 0.55, to: 0.95)
                .stroke(vg.text2, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 10.5, height: 10.5).offset(y: 5.4)
        }
        .frame(width: 12, height: 12)
        .clipped()
    }
}

/// Launcher selector chip: prefix glyph + 12px text-2 label + ▾, padding 5×9, radius 7,
/// hover text 6% (SPEC §4.1 selector common form).
private struct SelectorChip<Prefix: View>: View {
    let text: String
    let textColor: Color
    let vg: VGTokens
    @ViewBuilder let prefix: Prefix
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            prefix
            Text(text).font(VGFont.ui(12)).foregroundStyle(textColor)
            Text("▾").font(VGFont.ui(9)).foregroundStyle(vg.text3)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(hover ? vg.hoverBG : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hover = $0 }
    }
}

// MARK: - Terminal pane (SPEC §4.2)

struct TerminalPane: View {
    let app: AppModel
    @Bindable var session: SessionVM
    @Environment(\.vg) private var vg

    // Debug float for structural events (spawn/kill are instant): watch the
    // store log and surface matching new entries for 3s at the bottom-right.
    @State private var debugToast: String?
    @State private var logSeen = 0
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb

            // Real terminal — the sacred call-site rules (CURRENT_MAP §2):
            // ① focusOnAppear unconditionally — the terminal IS the only input surface
            //   (you talk to claude in its own TUI)
            // ② .id forces a fresh host on session/node switch
            // ③ nil view (ghost / not yet spawned) → ProgressView.
            // ④ terminal-status node (killed — and self-death's done/failed): the
            //   PTY is gone; the center shows the read-only afterlife instead of a
            //   ghost spinner — transcript pointer + frozen last frame.
            Group {
                if session.selectedNode.status.isTerminal {
                    let id = session.selectedID
                    DeadNodePane(node: session.selectedNode,
                                 transcriptPath: session.transcriptPath(id),
                                 lastFrame: session.lastFrame(id),
                                 kind: session.nodeKind(id),
                                 onResume: session.canResume(id)
                                     ? { session.resumeNode(id) } : nil)
                } else if let view = session.terminalView(session.selectedID) {
                    TerminalHost(terminal: view, vg: vg, prefs: app.terminalPrefs,
                                 focusOnAppear: true)
                } else {
                    // Ghost node: 22px spinner ring centered.
                    ZStack {
                        vg.term
                        SpinnerRing(size: 22, line: 2.5,
                                    base: vg.text.opacity(0.1), top: vg.text3)
                    }
                }
            }
            .id("\(session.id)-\(session.selectedID.raw)")
            // XCUITest needs a real AX element to carry the id — a bare Group around an
            // NSViewRepresentable exposes none, so surface it as an AX container.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("center.terminal")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Top-right overlay column (SPEC §1): anchored to the terminal area rather than
            // the whole pane, starting 14pt below the terminal header's divider, not covering
            // the header row. Mounted outside .id — when switching nodes rebuilds the terminal
            // host, TreePanel's @State (observation clock) must not reset with it. The tree
            // panel is still bound to this session, the notification stack is app-level
            // global (its non-terminal mount point is in AppBody).
            .overlay(alignment: .topTrailing) {
                OverlayColumn(app: app, treeSession: session)
                    .padding(.vertical, 14).padding(.trailing, 16)
            }
            // The bottom-right orchestration-toast mount point is removed (all floating
            // toasts hidden). The debugToast state and the orchestrationToastLine feed chain
            // are kept (runtime.json switch and the tests stay untouched) — restoring it just
            // means re-mounting the overlay.

            // Bottom terminal panel (⌘J / top.termToggle): a plain $SHELL that
            // slides out under the center terminal. Hidden by default → no layout change
            // (snapshots unchanged). The process lives on SessionVM.bottomShell, not here.
            if session.bottomShellVisible {
                BottomTerminalPanel(app: app, session: session, vg: vg)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(VGMotion.panel, value: session.bottomShellVisible)
        .background(vg.term)
        // Focus rule: opening hands focus to the shell (panel's focusOnAppear); hiding/closing
        // returns it to the center terminal (the unconditional-focus product rule holds).
        .onChange(of: session.bottomShellVisible) { _, visible in
            if !visible { app.focusTerminalInput() }
        }
        .onAppear { logSeen = session.store.log.count }
        .onChange(of: session.id) { logSeen = session.store.log.count }
        .onChange(of: session.store.log.count) { _, n in
            let log = session.store.log
            defer { logSeen = n }
            guard logSeen < n, logSeen <= log.count else { return }
            // logSeen still advances via the defer, so flipping the switch on later never
            // dumps the backlog. The gate lives in `orchestrationToastLine` (testable).
            guard let hit = Self.orchestrationToastLine(
                in: log[logSeen..<n],
                enabled: RuntimeTuning.current.orchestrationToasts) else { return }
            debugToast = hit
            toastTask?.cancel()
            toastTask = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled { debugToast = nil }
            }
        }
    }

    /// The structural toast is opt-in (runtime.json `orchestrationToasts`, default off):
    /// notification CARDS are limited to permission events; this bottom-right float is
    /// spawn/kill noise. When disabled, no line is ever surfaced regardless of the log;
    /// when enabled, the last new "spawned …"/"killed …" line wins. Pure so the
    /// default-off / on-shows contract is unit-testable without a live view.
    static func orchestrationToastLine(in slice: ArraySlice<String>,
                                       enabled: Bool) -> String? {
        guard enabled else { return nil }
        return slice.last { $0.contains("spawned") || $0.contains("killed") }
    }

    // Terminal header — role glyph · title (root = "main task") · model · status · cwd.
    // Keeps the `center.breadcrumb` AX id.
    // Layout = the shared NodeHeaderRow, structurally same as HistoryPane.header.
    private var breadcrumb: some View {
        let node = session.selectedNode
        let d = designStatus(node)
        return NodeHeaderRow(
            role: roleGlyphKind(node),
            roleHelp: node.kind == .observed ? "Subtask" : roleText(node.role),
            title: title(node),
            model: session.model,
            status: statusText(d),
            axID: "center.breadcrumb",   // XCUITest: expose the row as an AX container
            vg: vg) {
            Text(cwdText(d))
                .font(VGFont.mono(11)).foregroundStyle(vg.text3)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    /// Root shows "root" (the top bar already carries the session name); other nodes show
    /// their task title, falling back to the raw node id.
    private func title(_ node: Node) -> String {
        if node.id == session.store.tree.rootID { return "root" }
        return node.title.isEmpty ? node.id.raw : node.title
    }

    /// Ghost (starting) nodes have no cell yet — say so instead of showing a fake path.
    private func cwdText(_ d: DStatus) -> String {
        d == .starting ? "— (starting)" : homeAbbrev(session.cwd(session.selectedID))
    }

    private func homeAbbrev(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Bottom terminal panel (plain shell)

/// The bottom slide-out panel hosting a plain `$SHELL` (SessionVM.bottomShell). Chrome only:
/// a top drag-handle to resize, a header with a × that ends the shell, and the real terminal
/// host below. The panel never touches the PTY — × calls SessionVM.closeBottomShell, resize
/// calls AppModel.setBottomShellHeight (iron law: the view drives the model, not the process).
struct BottomTerminalPanel: View {
    let app: AppModel
    @Bindable var session: SessionVM
    let vg: VGTokens
    /// Height at the moment a resize drag begins, so the gesture applies a delta (dragging the
    /// handle up grows the panel).
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            header
            terminalBody
        }
        .frame(height: app.bottomShellHeight)
        .frame(maxWidth: .infinity)
        .background(vg.term)
        .overlay(alignment: .top) { Rectangle().fill(vg.hair).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bottom.terminal")
    }

    /// 6pt grab strip along the top edge — drag to resize, resize-up cursor, height persisted
    /// on release (AppModel clamps to its range).
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 6)
            .contentShape(Rectangle())
            .accessibilityIdentifier("bottom.terminal.resizeHandle")
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        let start = dragStartHeight ?? app.bottomShellHeight
                        if dragStartHeight == nil { dragStartHeight = start }
                        app.setBottomShellHeight(start - g.translation.height)
                    }
                    .onEnded { _ in
                        dragStartHeight = nil
                        app.persistBottomShellHeight()
                    }
            )
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(vg.text3)
            Text("Terminal").font(VGFont.ui(11.5, weight: .medium)).foregroundStyle(vg.text2)
            Spacer(minLength: 12)
            Button(action: { session.closeBottomShell() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(vg.text3)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bottom.terminal.close")
            .help("Close terminal (ends the shell)")
        }
        .padding(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 10))
        .overlay(alignment: .bottom) { Rectangle().fill(vg.hair).frame(height: 1) }
    }

    @ViewBuilder
    private var terminalBody: some View {
        if let view = session.bottomShell?.terminalView {
            TerminalHost(terminal: view, vg: vg, prefs: app.terminalPrefs, focusOnAppear: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // No surface (headless/test backend, or the shell is between incarnations).
            ZStack {
                vg.term
                SpinnerRing(size: 18, line: 2, base: vg.text.opacity(0.1), top: vg.text3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Dead-node pane

/// The center pane for a TERMINAL node in a LIVE session. Its PTY is gone; what shows
/// is Vigil's OWN rendering of the CLI transcript (read directly, never copied): one
/// screen of plain text + a bottom "press Enter to resume" line replaces the input box.
/// Pointer dangling → honest note + the frozen last frame as fallback. Takes plain data
/// so T1b can drive it without a live session; `preloadedItems` is the test seam
/// (un-hosted views never run .task).
struct DeadNodePane: View {
    let node: Node
    let transcriptPath: String?
    let lastFrame: String?
    /// The node's OWN CLI family — drives the resume hint's real syntax (claude
    /// `--resume` / codex `resume` / opencode `--session`) and the cleaned-source label,
    /// never the root session's family.
    let kind: AgentCLIKind
    /// Per-node resume: non-nil = this node's CLI session id is known → the bottom
    /// bar offers Enter-to-resume. nil = read-only afterlife.
    var onResume: (() -> Void)? = nil
    var preloadedItems: [TranscriptItem]? = nil
    var preloadedStats: TranscriptStats? = nil
    @Environment(\.vg) private var vg

    // Shell = the shared TranscriptHostView: focus + Enter + off-main double
    // read live there; this pane keeps its own header and the frozen-frame fallback.
    var body: some View {
        TranscriptHostView(
            transcriptPath: transcriptPath,
            taskID: transcriptPath,
            axID: "center.deadnode",
            hint: onResume != nil
                ? "Press Enter to resume this agent (\(kind.resumeSyntax))" : nil,
            readOnlyText: "Read-only — this node has no resume credentials",
            hintAxID: "deadnode.resumeHint",
            onResume: onResume,
            preloadedItems: preloadedItems,
            preloadedStats: preloadedStats,
            header: { hintRow },
            content: { items, stats in
                content(items: items, stats: stats)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            })
    }

    /// One row: what happened, plainly. Actions live in the bottom bar (Enter) now.
    private var hintRow: some View {
        HStack(spacing: 9) {
            Circle().fill(statusColor(designStatus(node), vg)).frame(width: 9, height: 9)
            Text("\(statusText(designStatus(node))) · this node's process has ended · \(sourceText)")
                .font(VGFont.ui(12)).foregroundStyle(vg.text3)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
        }
        .padding(EdgeInsets(top: 10, leading: 18, bottom: 9, trailing: 18))
        .overlay(alignment: .bottom) { Rectangle().fill(vg.hair).frame(height: 1) }
    }

    private var pointerState: TranscriptPointer.State { TranscriptPointer.state(transcriptPath) }

    private var sourceText: String {
        switch pointerState {
        case .available: return "conversation record below"
        case .cleaned:   return "transcript cleaned up by \(kind.rawValue)"
        case .never:     return "no transcript record"
        }
    }

    /// Self-rendered transcript; pointer dead / nothing renderable → the frozen last
    /// frame from teardown (never fake a screen), else an honest note.
    /// `items`/`stats` arrive resolved from the host (preloaded ?? loaded).
    @ViewBuilder
    private func content(items: [TranscriptItem]?, stats: TranscriptStats?) -> some View {
        if let it = items, !it.isEmpty {
            TranscriptReadView(items: it, stats: stats)
        } else if let frame = lastFrame,
                  !frame.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ScrollView {
                Text(frame)
                    .font(VGFont.mono(11.5))
                    .foregroundStyle(vg.text2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(EdgeInsets(top: 14, leading: 18, bottom: 18, trailing: 18))
            }
            .scrollIndicators(.automatic)
            .vgNativeOverlayScrollers()
        } else if pointerState == .available, items == nil {
            SpinnerRing(size: 22, line: 2.5, base: vg.text.opacity(0.1), top: vg.text3)
        } else {
            Text(pointerState == .cleaned
                     ? "History cleaned up by \(kind.rawValue), and no frozen frame"
                     : "No transcript record, and no frozen frame")
                .font(VGFont.ui(12.5)).foregroundStyle(vg.text3)
        }
    }
}

/// Node → glyph mapping, the ONE place it lives: observed subagent = .sub,
/// otherwise by role — an exhaustive switch, so adding a Role case breaks the build
/// here instead of silently forking the two headers' hand-written ternaries.
func roleGlyphKind(_ node: Node) -> RoleGlyph.Kind {
    if node.kind == .observed { return .sub }
    switch node.role {
    case .manager: return .manager
    case .leaf:    return .leaf
    }
}

/// Shared node header row (used by both TerminalPane.breadcrumb and HistoryPane.header):
/// role glyph · title · model · status · [read-only history badge] · trailing column, hairline
/// bottom border. Differences are injected: the live breadcrumb carries a role help +
/// the `center.breadcrumb` AX container and trails with the cwd; the history header
/// adds the read-only badge and trails with the archive date.
struct NodeHeaderRow<Trailing: View>: View {
    let role: RoleGlyph.Kind
    var roleHelp: String? = nil
    let title: String
    let model: String?
    let status: String?
    var readOnlyBadge: Bool = false
    var axID: String? = nil
    let vg: VGTokens
    let trailing: Trailing

    init(role: RoleGlyph.Kind, roleHelp: String? = nil, title: String, model: String?,
         status: String?, readOnlyBadge: Bool = false, axID: String? = nil, vg: VGTokens,
         @ViewBuilder trailing: () -> Trailing) {
        self.role = role
        self.roleHelp = roleHelp
        self.title = title
        self.model = model
        self.status = status
        self.readOnlyBadge = readOnlyBadge
        self.axID = axID
        self.vg = vg
        self.trailing = trailing()
    }

    var body: some View {
        let row = HStack(spacing: 9) {
            glyph
            // Mixed font sizes (title 14 / model mono 11.5 / status 12): the outer stack's
            // default CENTER alignment floats the smaller texts' baselines above the title's
            // ("root · default Idle" reads misaligned). Baseline-align the text run only —
            // the glyph and the trailing controls stay center-aligned, no magic offsets.
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(title)
                    .font(VGFont.ui(14, weight: .semibold)).foregroundStyle(vg.text)
                    .lineLimit(1).truncationMode(.tail)
                Text("· \(model ?? "default")")
                    .font(VGFont.mono(11.5)).foregroundStyle(vg.text3)
                    .lineLimit(1)
                if let status {
                    Text(status).font(VGFont.ui(12)).foregroundStyle(vg.text3)
                }
                if readOnlyBadge {
                    Text("Read-only history")
                        .font(VGFont.ui(10.5, weight: .medium)).foregroundStyle(vg.text3)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(vg.text.opacity(0.07), in: Capsule())
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(EdgeInsets(top: 11, leading: 18, bottom: 10, trailing: 18))
        return Group {
            if let axID {
                row.accessibilityElement(children: .contain)
                    .accessibilityIdentifier(axID)
            } else {
                row
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(vg.hair).frame(height: 1) }
    }

    @ViewBuilder
    private var glyph: some View {
        if let roleHelp {
            RoleGlyph(kind: role, vg: vg).help(roleHelp)
        } else {
            RoleGlyph(kind: role, vg: vg)
        }
    }
}

/// 15×15 role glyph: a two-node mini-tree, the FILLED node says
/// which one you are — manager fills the parent, leaf fills the child; observed subagents
/// get a three-node chain with the tail filled.
struct RoleGlyph: View {   // Reused by HistoryPane's header row.
    enum Kind { case manager, leaf, sub }
    let kind: Kind
    let vg: VGTokens

    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 16
            func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, fill: Bool, w: CGFloat) {
                let rect = CGRect(x: (x - r) * s, y: (y - r) * s, width: r * 2 * s, height: r * 2 * s)
                let p = Path(ellipseIn: rect)
                if fill { ctx.fill(p, with: .color(vg.text2)) }
                else { ctx.stroke(p, with: .color(vg.text2), lineWidth: w * s) }
            }
            func elbow(_ pts: [(CGFloat, CGFloat)], w: CGFloat) {
                var p = Path()
                p.move(to: CGPoint(x: pts[0].0 * s, y: pts[0].1 * s))
                for pt in pts.dropFirst() { p.addLine(to: CGPoint(x: pt.0 * s, y: pt.1 * s)) }
                ctx.stroke(p, with: .color(vg.text2),
                           style: StrokeStyle(lineWidth: w * s, lineCap: .round, lineJoin: .round))
            }
            switch kind {
            case .manager:
                circle(4.2, 3.8, 1.9, fill: true, w: 1.5)
                elbow([(4.2, 5.9), (4.2, 10.0), (7.8, 10.0)], w: 1.5)
                circle(10.6, 10, 1.9, fill: false, w: 1.5)
            case .leaf:
                circle(4.2, 3.8, 1.9, fill: false, w: 1.5)
                elbow([(4.2, 5.9), (4.2, 10.0), (7.8, 10.0)], w: 1.5)
                circle(10.6, 10, 1.9, fill: true, w: 1.5)
            case .sub:
                circle(3.1, 2.9, 1.55, fill: false, w: 1.4)
                elbow([(3.1, 4.6), (3.1, 7.6), (5.6, 7.6)], w: 1.4)
                circle(7.3, 7.6, 1.55, fill: false, w: 1.4)
                elbow([(7.3, 9.3), (7.3, 12.3), (9.8, 12.3)], w: 1.4)
                circle(11.5, 12.3, 1.55, fill: true, w: 1.4)
            }
        }
        .frame(width: 15, height: 15)
    }
}
