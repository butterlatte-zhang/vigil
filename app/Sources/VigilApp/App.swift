import SwiftUI
import VigilCore
import VigilRuntime

// VigilApp — the top (L5) shell layer of the architecture:
// titlebar breadcrumb · rail (Projects › Sessions › inline tree) · center (launcher |
// terminal pane) · notification stack overlay (observation notices only, no decision
// chrome). State flows only Command-in / Effect-out through each session's SessionStore.

/// The root Scene. Deliberately NOT `@main`: VigilApp is a library target (SwiftPM is the core),
/// and each thin entry shell calls `VigilRootApp.main()` itself — `Sources/Vigil`
/// (`swift run Vigil`) and the Xcode shell `shell/VigilShell` (T2 XCUITest host).
public struct VigilRootApp: App {
    @State private var app = AppModel()

    public init() {}

    public var body: some Scene {
        WindowGroup("Vigil") {
            RootView(app: app)
                .frame(minWidth: 1100, minHeight: 680)
                .task { app.bootstrapIfNeeded() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 980)
        .commands {
            // Settings are files, not a page: ⌘, opens ~/.config/vigil as a project instead
            // of a dedicated settings UI. Reconfigure opens blank, while submitted Settings
            // tasks are transparently directed to the universal README.
            CommandGroup(replacing: .appSettings) {
                Button("User config…") { app.openConfigWorkspace() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // Session shortcuts are all ⌘-modified so they never collide with
            // keystrokes destined for the terminal (the only input surface).
            CommandGroup(replacing: .newItem) {
                // ⌘T opens the launcher in the current project; with no current project it
                // falls back to the Chats bucket, the same action as the sidebar's "new chat".
                Button("New session") { app.newChat() }
                    .keyboardShortcut("t", modifiers: .command)
                // The sidebar has no add-project button by design; the menu keeps the entry
                // reachable once a first project exists.
                Button("Add project…") { app.addProjectViaPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            // All session/node/navigation key bindings converge in this one menu; the
            // declaration table is VigilKeymap (App.swift), so tests assert against the same
            // table and key registration isn't scattered across Views.
            CommandMenu("Session") {
                ForEach(1...9, id: \.self) { n in
                    Button("Switch to #\(n)") { app.selectIndex(n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
                Divider()
                ForEach(VigilKeymap.all) { binding in
                    Button(binding.title) { binding.run(app) }
                        .keyboardShortcut(binding.key, modifiers: binding.modifiers)
                }
            }
        }
    }
}

// The single registry of Vigil's global keyboard shortcuts beyond ⌘,/⌘T/⌘O
// (system-menu homes) and ⌘1–9 (dynamic ForEach). Declarative so the Commands block above
// stays one call site AND KeymapTests can assert the whole map (key/modifiers/uniqueness)
// without a running event loop. Red line: EVERY entry is ⌘-modified — a GUI-only
// modifier the terminal/agent TUI never receives — so none can steal a key the agent needs
// (Escape / ⇧Enter / ⌥Enter / Ctrl-series pass straight through, see
// AppTerminalView+Input.performKeyEquivalent). GhosttyTheme unbinds these same combos so a
// focused terminal cannot swallow them before the menu (keyIsBinding path).
struct VigilKeyBinding: Identifiable {
    let id: String                 // stable slug (also the test anchor)
    let title: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let run: @MainActor (AppModel) -> Void
}

enum VigilKeymap {
    static let all: [VigilKeyBinding] = [
        // Bottom terminal (a plain-shell panel) — ⌘J toggles it. The terminal is
        // unconditionally focused already, so a dedicated focus key is unnecessary;
        // focusTerminalInput() lives on as the focus-return target when the panel hides.
        VigilKeyBinding(id: "toggleBottomTerminal", title: "Toggle bottom terminal",
                        key: "j", modifiers: .command) { $0.activeSession?.toggleBottomShell() },
        // sidebar
        VigilKeyBinding(id: "toggleSidebar", title: "Show / hide sidebar",
                        key: "b", modifiers: .command) { $0.toggleSidebar() },
        // session-level switching (⌃⌘[ / ⌃⌘]) + jump to attention (⌘⇧U)
        VigilKeyBinding(id: "prevSession", title: "Previous session",
                        key: "[", modifiers: [.command, .control]) { $0.selectAdjacentSession(-1) },
        VigilKeyBinding(id: "nextSession", title: "Next session",
                        key: "]", modifiers: [.command, .control]) { $0.selectAdjacentSession(1) },
        VigilKeyBinding(id: "jumpAttention", title: "Jump to latest alert",
                        key: "u", modifiers: [.command, .shift]) { $0.jumpToLatestAttention() },
        // node-level switching (⌘⇧[ / ⌘⇧])
        VigilKeyBinding(id: "prevNode", title: "Previous node",
                        key: "[", modifiers: [.command, .shift]) { $0.selectAdjacentNode(-1) },
        VigilKeyBinding(id: "nextNode", title: "Next node",
                        key: "]", modifiers: [.command, .shift]) { $0.selectAdjacentNode(1) },
        // session actions (⌘⇧R rename / ⌘⇧W close = silent-reap semantics)
        VigilKeyBinding(id: "renameSession", title: "Rename session",
                        key: "r", modifiers: [.command, .shift]) { $0.renameActiveSession() },
        VigilKeyBinding(id: "closeSession", title: "Close session",
                        key: "w", modifiers: [.command, .shift]) { $0.closeActiveSession() },
    ]
}
