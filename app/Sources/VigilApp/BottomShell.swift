import Foundation
import AppKit
import VigilCore
import VigilRuntime
import class VigilGhosttyTerminal.AppTerminalView   // ghostty terminal host view

// Bottom terminal panel — the plain shell cell.
//
// A bare login `$SHELL` running on the SAME host-PTS + libghostty-surface chain the center
// terminal uses (GhosttyViewBackend = HostPTY + AppTerminalView), with EVERY agent layer
// stripped off:
//   • no MCP / no probe / no injection (it is not a RealCell — no Orchestrator, no harness)
//   • no TurnWatcher / AutoNamer / status dot
//   • NOT a node in the SessionStore tree, so it writes no orchestration.jsonl and is
//     structurally invisible to the rest harvester (which only reads the tree) — the
//     "exempt from the 30-min reaper" rule is satisfied by construction, not a special case
//   • it dies WITH its session: SessionVM.shutdown() terminates it, so a harvested / closed /
//     archived session takes its shell down too.
//
// Iron law (DOCTRINE single data flow): the VIEW never pokes the PTY. The top-bar button and
// ⌘J call SessionVM, SessionVM drives this model, this model drives the backend. The shell is
// deliberately OUTSIDE the tree (product decree: it must not enter the node tree), so its
// lifecycle rides this dedicated model rather than a Command/Effect through SessionStore — an
// honest, documented boundary, not a hole in the law.
@MainActor
@Observable
final class BottomShell {
    let cwd: String
    private let makeBackend: () -> TerminalBackend
    private var backend: TerminalBackend?
    /// Whether a shell process is currently attached (true between start() and its exit /
    /// terminate()). Distinct from the panel's VISIBLE state (SessionVM.bottomShellVisible):
    /// hiding the panel keeps the process running, so `running` stays true while hidden.
    private(set) var running = false
    /// Fires on main when the shell ends on its OWN (the user typed `exit`, or it crashed) —
    /// distinct from terminate() (the × button / session teardown). SessionVM uses it to drop
    /// the panel so the next ⌘J starts a fresh shell.
    var onEnded: (() -> Void)?

    /// The caller supplies the backend factory (AppModel.makeBottomShellBackend): production
    /// builds a visible ghostty surface, tests inject a headless (real fork) or spy backend.
    /// cols/rows there are advisory — libghostty derives the grid from the surface's pixel
    /// size, exactly as the center terminal does.
    init(cwd: String, makeBackend: @escaping () -> TerminalBackend) {
        self.cwd = cwd
        self.makeBackend = makeBackend
    }

    /// The visible surface, when the backend is a ghostty view (nil for headless / spy
    /// backends in tests) — mirrors SessionVM.terminalView's cast.
    var terminalView: AppTerminalView? { (backend as? GhosttyViewBackend)?.view }

    /// Start a fresh login shell if one isn't already attached (idempotent — a re-open while
    /// running is a no-op, so toggling the panel's visibility never respawns). After the shell
    /// ends (exit / ×) `backend` is nil again, so the next start() = a brand-new shell.
    func start() {
        guard backend == nil else { return }
        let b = makeBackend()
        backend = b
        running = true
        let (exe, args) = Self.loginShell()
        b.start(executable: exe, args: args, env: Self.shellEnv(), cwd: cwd) { [weak self] _ in
            // HostPTY delivers onEnd off-main; hop back before touching model state.
            Task { @MainActor in
                guard let self, self.running, self.backend === b else { return }
                self.running = false
                self.backend = nil
                self.onEnded?()
            }
        }
    }

    /// End the shell process (× button, or SessionVM.shutdown). Idempotent; drops the backend
    /// so a later start() spawns a new shell.
    func terminate() {
        backend?.terminate()
        backend = nil
        running = false
    }

    // MARK: - launch recipe

    /// The scratch shell as an interactive login shell. The backends set argv[0] = executable
    /// (not the leading-dash convention), so login/interactive are requested with explicit flags.
    /// Executable precedence: runtime.json `bottomShellCommand` (read hot at panel birth) →
    /// `$SHELL` → /bin/zsh (the macOS default since Catalina). An empty setting = follow $SHELL.
    static func loginShell() -> (String, [String]) {
        let configured = RuntimeTuning.current.bottomShellCommand
            .trimmingCharacters(in: .whitespaces)
        let shell = !configured.isEmpty ? configured
            : (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        return (shell, ["-l", "-i"])
    }

    /// The child env = the app's inherited env plus a forced TERM (the same value every Vigil
    /// backend/harness uses — xterm-ghostty terminfo ships nowhere, so tput/vim would hit
    /// "unknown terminal" without it). PATH is topped up by GhosttyViewBackend.ensuredPATH so
    /// a Finder-launched .app's minimal PATH still resolves the user's tools.
    static func shellEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        return env
    }
}
