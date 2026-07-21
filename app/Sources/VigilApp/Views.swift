import SwiftUI
import VigilCore
import VigilRuntime
import class VigilGhosttyTerminal.AppTerminalView   // ghostty terminal host view
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

// A pixel-faithful port of the "Vigil home" design. Window: sidebar (SidebarView.swift) ·
// main area = top bar (50pt) + center (launcher | terminal | empty, CenterView2.swift) ·
// top-right overlay column = node-tree panel (TreePanel.swift) + notification stack
// (NotifStack.swift). Plus a toast. There is no settings page — settings are
// files in ~/.config/vigil (UserConfig.swift); ⌘, opens the user-config workspace.

// MARK: - Root

struct RootView: View {
    @Bindable var app: AppModel

    var body: some View {
        let vg = app.tokens
        AppBody(app: app)
        .background(vg.term)
        .background(WindowConfigurator())
        .environment(\.vg, vg)
        // A config pin is authoritative for native controls too. Follow-system stays nil so
        // SwiftUI/AppKit continues tracking the OS instead of freezing a resolved snapshot.
        .preferredColorScheme(app.themePreference.preferredColorScheme)
        // Every one of Vigil's own floating toasts (the
        // bottom-center toast, the bottom-right orchestration toast) is hidden — the mount
        // points are removed. AppModel.toast/showToast are kept as inert state (the info is
        // still recoverable from the logs/tests) — restoring it just means re-mounting the overlay.
        .ignoresSafeArea()
        .onAppear {
            // Without this, a `swift run` executable launches as a non-activating app and
            // keystrokes go to the launching terminal. Become a regular, frontmost app.
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            AppIcon.install()
        }
    }
}

// MARK: - App body (sidebar + main: top bar › center)

struct AppBody: View {
    @Bindable var app: AppModel
    var body: some View {
        HStack(spacing: 0) {
            if !app.railCollapsed {
                // The whole rail slides out/in to the left, content follows the layout animation.
                SidebarView(app: app)
                    .transition(.move(edge: .leading))
            }
            VStack(spacing: 0) {
                TopBar(app: app)
                center
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Global notification cards: non-terminal states (launcher /
                    // empty) mount the overlay column here; the terminal and history states'
                    // overlay columns each mount below the header-row divider,
                    // mutually exclusive, never coexisting.
                    .overlay(alignment: .topTrailing) {
                        if app.activeSession == nil, app.selectedHistory == nil {
                            OverlayColumn(app: app, treeSession: nil)
                                .padding(.vertical, 14).padding(.trailing, 16)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var center: some View {
        if let s = app.activeSession {
            // The top-right overlay column mounts on the terminal area inside TerminalPane
            // (below the terminal-header divider), not covering the header row — see CenterView2.swift.
            TerminalPane(app: app, session: s)
        } else if let h = app.selectedHistory {
            // Read-only replay of a dead session (live focus and history focus
            // are mutually exclusive — AppModel clears one when the other is set).
            HistoryPane(app: app, summary: h)
        } else if let p = app.current {
            LauncherView(app: app, project: p)
                // LauncherView owns its prompt as @State. Give each project a distinct
                // identity so a first-run Settings prefill cannot survive an in-place
                // project-menu switch and get submitted into an ordinary repository.
                .id(p.id)
        } else {
            NoProjectView(app: app)
        }
    }
}

// MARK: - Main top bar (SPEC §1: h50 · collapsed-sidebar chrome · title · tree toggle)

struct TopBar: View {
    @Bindable var app: AppModel
    @Environment(\.vg) private var vg

    var body: some View {
        let s = app.activeSession
        HStack(spacing: 10) {
            if app.railCollapsed {
                TrafficLightsRow()
                    .padding(.trailing, 2)
                SideIconBtn(vg: vg, action: { app.toggleSidebar() }) { SidebarGlyph() }
                    .accessibilityIdentifier("rail.collapseToggle")
                    .help("Expand sidebar")
                Rectangle().fill(vg.hair).frame(width: 1, height: 20).padding(.horizontal, 2)
            }
            Text(title)
                .font(VGFont.ui(14, weight: .semibold)).foregroundStyle(vg.text)
                .lineLimit(1).truncationMode(.tail)
            if app.activeSession == nil && app.current != nil
                && app.selectedHistoryID == nil {
                Text("· New task").font(VGFont.ui(11)).foregroundStyle(vg.text3)
            }
            // The header row's "read-only history" badge already conveys the view's nature, so
            // the top bar keeps only the session name.
            Spacer()
            if let s {
                // Bottom terminal toggle (⌘J twin): a plain $SHELL panel in the
                // center bottom. Sits next to the tree toggle, terminal-state only.
                TermToggleButton(open: s.bottomShellVisible, vg: vg) { s.toggleBottomShell() }
                // user key: a manual tap takes over the show/hide decision (auto-expand yields from then on, motion unchanged).
                TreeToggleButton(open: !s.treeCollapsed, help: "Toggle node tree", vg: vg) {
                    s.userToggleTree()
                }
            } else if app.selectedHistoryID != nil,
                      (app.historyArchive?.tree?.count ?? 0) > 1 {
                // History twin: flips the history tree card.
                // Same glyph, same AX id — one semantic control, two center states.
                TreeToggleButton(open: !app.historyTreeCollapsed,
                                 help: "Toggle node tree (history)", vg: vg) {
                    withAnimation(VGMotion.panel) { app.historyTreeCollapsed.toggle() }
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(TitlebarDragSurface())  // restores double-click-to-zoom on the blank drag area
        .overlay(alignment: .bottom) { Rectangle().fill(vg.hair).frame(height: 1) }
    }

    private var title: String {
        if let s = app.activeSession { return s.name }
        if let h = app.selectedHistory { return h.name }
        return app.current?.name ?? "Vigil"
    }
}

/// Tree-panel toggle (30×30 r8): open → accent glyph on acc14; closed → text-2, clear.
/// One control, two center states: the terminal state binds it to the
/// session's treeCollapsed (via userToggleTree), the history state to
/// app.historyTreeCollapsed — TopBar passes the state and the flip; same AX id.
private struct TreeToggleButton: View {
    let open: Bool
    let help: String
    let vg: VGTokens
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            TreeGlyph()
                .foregroundStyle(open ? vg.accent : vg.text2)
                .frame(width: 30, height: 30)
                .background(open ? vg.accent.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("top.treeToggle")
        .help(help)
    }
}

/// Bottom-terminal toggle (30×30 r8), same chrome as TreeToggleButton: open → accent glyph
/// on acc14, closed → text-2 clear. Bound to the active session's bottomShellVisible; ⌘J is
/// the keyboard twin (VigilKeymap.toggleBottomTerminal).
private struct TermToggleButton: View {
    let open: Bool
    let vg: VGTokens
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "terminal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(open ? vg.accent : vg.text2)
                .frame(width: 30, height: 30)
                .background(open ? vg.accent.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("top.termToggle")
        .help("Toggle bottom terminal (⌘J)")
    }
}

/// 15×15 tree glyph traced from the design: square node → down line → bar → leaf circle.
private struct TreeGlyph: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            RoundedRectangle(cornerRadius: 2).fill(.primary)
                .frame(width: 5, height: 5).offset(x: 2, y: 1.5)
            Rectangle().fill(.primary).frame(width: 1.5, height: 6.5).offset(x: 4, y: 6.5)
            Rectangle().fill(.primary).frame(width: 5.5, height: 1.5).offset(x: 4, y: 11.5)
            Circle().fill(.primary).frame(width: 4.6, height: 4.6).offset(x: 10.5, y: 10.2)
        }
        .frame(width: 15, height: 15)
    }
}

// MARK: - Top-right overlay column (tree panel + notification cards, SPEC §1)

struct OverlayColumn: View {
    let app: AppModel
    /// Non-nil only when mounted over a terminal pane — the tree panel is per-session
    /// chrome and stays bound to the showing session; the card stack below is app-global,
    /// so the column also mounts session-less (launcher/settings/empty).
    let treeSession: SessionVM?
    var body: some View {
        ScrollView {
            VStack(alignment: .trailing, spacing: 12) {
                if let s = treeSession, !s.treeCollapsed {
                    // vg-card open/close (≈220ms fade-in + 14px slide from the right).
                    TreePanel(session: s)
                        .transition(.vgCard)
                } else if treeSession == nil, app.selectedHistoryID != nil,
                          !app.historyTreeCollapsed, let a = app.historyArchive {
                    // The history view's frozen tree card: auto-expands whenever there's a tree,
                    // clicking a node = the center renders that node's transcript.
                    HistoryTreePanel(app: app, archive: a)
                        .transition(.vgCard)
                }
                NotifStack(app: app)
            }
        }
        // Native overlay scrollbar (thin/rounded/translucent, auto-fading) instead of the
        // fat legacy scroller `.hidden` couldn't suppress under "Always show scroll bars".
        .scrollIndicators(.automatic)
        .vgNativeOverlayScrollers()
        // Keep card shadow/material edges from being clipped into a hard edge by the ScrollView.
        .scrollClipDisabled()
        .frame(width: VGLayout.overlayWidth)
    }
}

/// Empty state when no project exists yet (bootstrap does not auto-create sessions).
struct NoProjectView: View {
    @Bindable var app: AppModel
    @Environment(\.vg) private var vg

    var body: some View {
        VStack(spacing: 14) {
            Text("Start with a project")
                .font(VGFont.ui(21, weight: .bold)).foregroundStyle(vg.text)
            Text("A project = a code repository. Vigil's manager works inside the project directory.")
                .font(VGFont.ui(12.5)).foregroundStyle(vg.text3)
            Button("Add project…") { app.addProjectViaPanel() }
                .buttonStyle(PrimaryBtn(vg: vg))
                .accessibilityIdentifier("center.empty.addProject")
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(vg.term)
    }
}

/// A small keyboard-cap chip, e.g. `a` / `space`.
struct KeyCap: View {
    let label: String; let vg: VGTokens
    init(_ label: String, _ vg: VGTokens) { self.label = label; self.vg = vg }
    var body: some View {
        Text(label).font(VGFont.mono(11, weight: .medium)).foregroundStyle(vg.text2)
            .padding(.horizontal, label.count > 1 ? 7 : 6).padding(.vertical, 2)
            .background(vg.text.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(vg.hair2, lineWidth: 1))
    }
}

// MARK: - Terminal host (real ghostty view)

struct TerminalHost: NSViewRepresentable {
    let terminal: AppTerminalView
    let vg: VGTokens
    /// appearance.json terminal knobs — a prefs change updates this
    /// view (observable AppModel) → updateNSView → applyTheme picks it up hot.
    var prefs: VGTerminalPrefs = .defaults
    var focusOnAppear: Bool = false

    /// hiddenTitleBar lesson (CONTRACT §3.1): terminal drags must never move the window.
    /// Doubles as the drag-drop target — files→escaped paths, images→written to
    /// disk as paths, text→as-is, injected via surface.sendText (with 2004h on, ghostty wraps
    /// it as a real paste, claude turns the path into [Image #N]). The child view
    /// AppTerminalView registers no drag types, so the
    /// drop naturally lands here.
    final class Container: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        weak var terminal: AppTerminalView?

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            TerminalHost.wantsDrop(sender.draggingPasteboard) ? .copy : []
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            TerminalHost.wantsDrop(sender.draggingPasteboard) ? .copy : []
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let surface = terminal?.vigilSurface,
                  let plan = PasteIngest.dropPlan(sender.draggingPasteboard) else { return false }
            TerminalHost.execute(plan) { _ = surface.sendText($0) }
            return true
        }
    }

    static func wantsDrop(_ pb: NSPasteboard) -> Bool {
        if !PasteIngest.fileURLs(from: pb).isEmpty { return true }
        if pb.string(forType: .string)?.isEmpty == false { return true }
        return (pb.types ?? []).contains {
            UTType($0.rawValue)?.conforms(to: .image) == true
        }
    }

    /// A single segment is injected immediately; for multiple segments (several local images)
    /// each is fed before scheduling the next — the inter-segment gap gives claude time to turn
    /// the previous path into [Image #N] (PasteIngest.dropPlan decides the gap).
    static func execute(_ plan: PasteIngest.PastePlan,
                        send: @escaping (String) -> Void,
                        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void
                            = { delay, work in
                                DispatchQueue.main.asyncAfter(deadline: .now() + delay,
                                                              execute: work)
                            }) {
        switch plan {
        case .insertText(let text):
            send(text)
        case .insertTextSegments(let segments, let delay):
            sendSegment(segments, at: 0, delay: delay, send: send, scheduleAfter: scheduleAfter)
        }
    }

    private static func sendSegment(_ segments: [String], at index: Int, delay: TimeInterval,
                                    send: @escaping (String) -> Void,
                                    scheduleAfter: @escaping (TimeInterval,
                                                              @escaping () -> Void) -> Void) {
        guard index < segments.count else { return }
        send(segments[index])
        guard index + 1 < segments.count else { return }
        scheduleAfter(delay) {
            sendSegment(segments, at: index + 1, delay: delay,
                        send: send, scheduleAfter: scheduleAfter)
        }
    }

    func makeNSView(context: Context) -> NSView {
        let container = Container()
        container.terminal = terminal
        container.registerForDraggedTypes([.fileURL, .png, .tiff, .string])
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
        ])
        applyTheme()
        // Plain terminal: focus it so you type directly. Agent modes: the bottom box takes over.
        if focusOnAppear {
            DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Container)?.terminal = terminal   // swap the drop target along with the node switch
        // Reparenting on node switch: SwiftUI reuses the representable with a new
        // terminal instance under the same .id only across sessions; the guard keeps
        // a stale subview from lingering when it does.
        if terminal.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            terminal.translatesAutoresizingMaskIntoConstraints = false
            nsView.addSubview(terminal)
            NSLayoutConstraint.activate([
                terminal.topAnchor.constraint(equalTo: nsView.topAnchor, constant: 8),
                terminal.bottomAnchor.constraint(equalTo: nsView.bottomAnchor, constant: -6),
                terminal.leadingAnchor.constraint(equalTo: nsView.leadingAnchor, constant: 14),
                terminal.trailingAnchor.constraint(equalTo: nsView.trailingAnchor, constant: -14),
            ])
        }
        applyTheme()
    }

    /// Theme flows through the app-level ghostty config; VGGhosttyTheme diff-guards so
    /// repeated SwiftUI updates cost nothing (CONTRACT §3.2).
    private func applyTheme() {
        VGGhosttyTheme.apply(vg, prefs: prefs)
    }
}

// MARK: - Toast

struct ToastView: View {
    let text: String
    @Environment(\.vg) private var vg
    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(vg.green).frame(width: 7, height: 7)
            Text(text).font(VGFont.ui(13, weight: .medium)).foregroundStyle(vg.text)
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(vg.panelSolid, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(vg.hair2, lineWidth: 1))
        .shadow(color: vg.shadowColor, radius: 20, y: 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Reusable controls

struct TrafficLight: View {
    let hex: UInt32; let act: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: act) {
            Circle().fill(Color(hex: hex)).frame(width: 12, height: 12)
                .overlay { if hover { Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1) } }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Traffic-light trio: the theme-independent
/// close/minimize/zoom trio (SPEC §1 hardcoded hex), shared by the sidebar top row and the collapsed-rail
/// top bar — the hex/action triplets live in one place, not two.
struct TrafficLightsRow: View {
    var body: some View {
        HStack(spacing: 8) {
            TrafficLight(hex: 0xFF5F57) { NSApp.keyWindow?.performClose(nil) }
            TrafficLight(hex: 0xFEBC2E) { NSApp.keyWindow?.performMiniaturize(nil) }
            TrafficLight(hex: 0x28C840) { NSApp.keyWindow?.performZoom(nil) }
        }
    }
}

// MARK: - Titlebar double-click (zoom / minimize) restore

/// The macOS title-bar double-click action, resolved from the global
/// `AppleActionOnDoubleClick` preference (System Settings ▸ Desktop & Dock).
enum TitlebarDoubleClickAction: Equatable {
    case zoom       // "Maximize"
    case minimize   // "Minimize"
    case fill       // "Fill" (macOS 15+)
    case none       // "None"
}

/// Maps the raw `AppleActionOnDoubleClick` value to an action. This is the whole
/// point of the T1 test: honour the user's System Settings choice instead of
/// hard-coding zoom. `nil` (key unset / unreadable) and unknown strings both
/// fall back to `.zoom`, the platform default.
func titlebarDoubleClickAction(preference: String?) -> TitlebarDoubleClickAction {
    switch preference {
    case "Minimize": return .minimize
    case "None":     return .none
    case "Fill":     return .fill
    case "Maximize": return .zoom
    default:         return .zoom   // nil or unknown → system default
    }
}

/// Background surface for the self-drawn top bar / sidebar top row. Because the
/// window is `.hiddenTitleBar` + `.fullSizeContentView`, there is no native
/// title bar left to receive the system double-click-to-zoom gesture. This view
/// restores it: a single click / drag moves the window (via `performDrag`), and
/// a double click performs the user's preferred title-bar action.
///
/// It is attached with `.background(...)`, so it sits *behind* the bar's SwiftUI
/// content. Interactive controls (traffic lights, toggles, dropdowns) are drawn
/// in front and win hit-testing, so their clicks never reach here — only clicks
/// on the blank drag area do. The no-misfire-on-buttons requirement is
/// therefore satisfied by z-order, not by geometry math.
struct TitlebarDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        // We drive the window drag ourselves (the window refuses background drags,
        // see WindowConfigurator.configureChrome); refusing here too keeps
        // `mouseDown` delivered to us even if that policy ever changes.
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                Self.performTitlebarDoubleClick(on: window)
            } else {
                // The only window-drag surface: the window itself refuses
                // background drags, so blank-titlebar drag is provided here.
                window?.performDrag(with: event)
            }
        }

        static func performTitlebarDoubleClick(on window: NSWindow?) {
            guard let window else { return }
            let pref = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
            switch titlebarDoubleClickAction(preference: pref) {
            case .zoom:     window.performZoom(nil)
            case .minimize: window.performMiniaturize(nil)
            case .fill:     window.fillToVisibleFrame()
            case .none:     break
            }
        }
    }
}

extension NSWindow {
    /// Approximates the macOS "Fill" title-bar double-click action: size the
    /// window to the current screen's visible frame.
    fileprivate func fillToVisibleFrame() {
        guard let screen = screen ?? NSScreen.main else { return }
        setFrame(screen.visibleFrame, display: true, animate: true)
    }
}

/// Strips the native macOS title bar so the app's own window-card chrome is the only one.
struct WindowConfigurator: NSViewRepresentable {
    /// UserDefaults key holding the saved main-window frame (`NSStringFromRect`). Stable —
    /// unlike SwiftUI's own autosave key, a mangled encoding of the whole view-type chain
    /// (`…VigilApp.RootView…AppWindow-1`) that breaks on any UI refactor and, on the
    /// unbundled `swift run` path, *saves but does not restore*. We persist with plain
    /// `UserDefaults.standard` (the same path the sidebar state uses — it survives; a
    /// `saveFrame(usingName:)` under our own name silently no-ops because SwiftUI already
    /// owns the window's autosave association).
    static let frameDefaultsKey = "vigil.mainWindowFrame.v1"

    /// Keep a restored frame reachable: if the saved rect still meaningfully overlaps some
    /// screen's visible area, use it as-is; otherwise (a display was unplugged / resolution
    /// changed) clamp it back onto `fallback`. Pure so it is unit-tested without a
    /// live NSScreen. `minOverlap` = how many points must stay grabbable on some screen.
    static func clampedFrame(_ desired: NSRect, visibles: [NSRect], fallback: NSRect,
                             minOverlap: CGFloat = 80) -> NSRect {
        for v in visibles {
            let hit = v.intersection(desired)
            if hit.width >= minOverlap && hit.height >= minOverlap { return desired }
        }
        var f = desired
        f.size.width = min(f.width, fallback.width)
        f.size.height = min(f.height, fallback.height)
        f.origin.x = max(fallback.minX, min(f.origin.x, fallback.maxX - f.width))
        f.origin.y = max(fallback.minY, min(f.origin.y, fallback.maxY - f.height))
        return f
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Holds the one-shot install flag + notification observers across the repeated
    /// `configure` calls (make + every SwiftUI update).
    final class Coordinator {
        var frameManaged = false
        var observers: [NSObjectProtocol] = []
        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window, context.coordinator) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { configure(v.window, context.coordinator) }
    }
    /// Window chrome policy, extracted (and internal) so it is unit-testable. Notably the
    /// window must NOT be movable by background: with the native title bar hidden, that flag
    /// would turn every blank SwiftUI region into a window-drag surface — stealing drags
    /// from the pane resize handles and moving the window from random panes. Window dragging
    /// is provided explicitly by TitlebarDragSurface behind the top-bar rows.
    static func configureChrome(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }

    private func configure(_ window: NSWindow?, _ coordinator: Coordinator) {
        guard let window else { return }
        Self.configureChrome(window)

        // Persist window size + position across launches. SwiftUI's built-in
        // frame autosave saves under a fragile type-mangled key and does NOT restore on
        // the plain `swift run vigil-app` path (verified: relaunch reopens at the default
        // size, not the last one). So we self-manage it: encode the frame ourselves and
        // store it via plain UserDefaults (which persists here), restoring through the
        // pure `clampedFrame` guard so an unplugged display can't strand the window
        // off-screen. Installed once (guarded) so restore + observers don't re-fire on
        // every SwiftUI update.
        guard !coordinator.frameManaged else { return }
        coordinator.frameManaged = true
        if let saved = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) {
            let desired = NSRectFromString(saved)
            if desired.width > 0, desired.height > 0 {
                let visibles = NSScreen.screens.map(\.visibleFrame)
                let fallback = (window.screen ?? NSScreen.main)?.visibleFrame ?? desired
                window.setFrame(Self.clampedFrame(desired, visibles: visibles, fallback: fallback),
                                display: true)
            }
        }
        let persist: (Notification) -> Void = { [weak window] _ in
            guard let window else { return }
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameDefaultsKey)
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            coordinator.observers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main, using: persist))
        }
    }
}

// MARK: - Button styles

struct PrimaryBtn: ButtonStyle {
    let vg: VGTokens
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white).fontWeight(.medium)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(vg.accent, in: RoundedRectangle(cornerRadius: 8))
            .brightness(configuration.isPressed ? -0.05 : 0)
    }
}

// MARK: - Mapping helpers

func roleText(_ r: Role) -> String { r == .manager ? "Manager" : "Leaf" }
