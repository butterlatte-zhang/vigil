import SwiftUI
import AppKit
import Foundation
import VigilCore
import VigilGhosttyTerminal
import VigilRuntime
import class VigilGhosttyTerminal.AppTerminalView   // ghostty terminal host view
import enum VigilGhosttyTerminal.TerminalDebugLog   // terminal observability sink
import struct VigilGhosttyTerminal.TerminalDebugCategory

// L5 app state. Multi-session lives ABOVE the store (one Orchestrator == one root);
// AppModel owns Projects, each Project owns SessionVMs (plus a SCRATCH bucket). The iron
// law holds: views read store state and send Commands; nothing here mutates a tree or a
// cell directly.

// MARK: - Design status (maps domain NodeStatus/NodeKind → the design's node states)

enum DStatus: Equatable { case running, idle, waiting, done, failed, killed, starting, subagent, stalled, queued, errored }

func designStatus(_ node: Node) -> DStatus {
    if node.kind == .observed { return .subagent }
    switch node.status {
    case .running:  return .running
    case .idle:     return .idle
    case .waiting:  return .waiting
    case .done:     return .done
    case .failed:   return .failed
    case .killed:   return .killed
    case .starting: return .starting
    case .stalled:  return .stalled
    case .queued:   return .queued
    case .errored:  return .errored
    }
}

func statusText(_ d: DStatus) -> String {
    switch d {
    case .running:  return "Running"
    case .idle:     return "Idle"
    case .waiting:  return "Awaiting approval"
    case .done:     return "Done"
    case .failed:   return "Failed"
    case .killed:   return "Terminated"
    case .starting: return "Starting"
    case .subagent: return "Running"
    // Spawn didn't connect (the process may never have been born) ≠ waiting for authorization — must not borrow the permission card's wording
    case .stalled:  return "spawn didn't connect"
    // The message is blocked by the human's input line (suspended) ≠ waiting for authorization — the process is alive, just queued
    case .queued:   return "Message queued"
    // An API error cut the turn short, no Stop hook ≠ waiting for authorization — the process is alive and resumable
    case .errored:  return "Turn ended abnormally"
    }
}

func statusColor(_ d: DStatus, _ vg: VGTokens) -> Color {
    switch d {
    case .running:  return vg.accent
    case .idle:     return vg.text2
    case .waiting:  return vg.warn
    case .done:     return vg.green
    case .failed:   return vg.red
    case .killed:   return vg.text3
    case .starting: return vg.text3
    case .subagent: return vg.text2
    case .stalled:  return vg.warn
    case .queued:   return vg.warn
    case .errored:  return vg.warn   // yellow-dot attention: no card, the sidebar yellow dot suffices
    }
}

// MARK: - Status dot (unified)

/// The ONE status-dot classifier. Both the sidebar session row and the top-right node
/// tree render their dot through this single switch — a single source of truth: the
/// classification of a state into a visual bucket lives here and nowhere else; the two
/// surfaces differ only in the granularity of their INPUT (per-node status+unseen for the
/// tree; a session rollup for the sidebar) and in how each paints a bucket (the sidebar
/// draws nothing for `.plain`, the tree a hollow ring).
///
///   spinner — starting / running: a turn is in flight;
///   yellow  — needs a glance. waiting / stalled / queued are LIVE conditions (yellow
///             regardless of `unseen`; they clear when the condition resolves). errored /
///             failed are EVENTS: yellow until the user views the node, then default;
///   blue    — a run finished and you haven't looked (idle turn-end OR terminal done),
///             one-time, cleared by viewing the node;
///   plain   — default: killed (a deliberate end carries no attention), or an already-seen
///             completion / acknowledged error.
enum DotClass: Equatable { case spinner, blue, yellow, plain }

func dotClass(_ status: NodeStatus, unseen: Bool) -> DotClass {
    switch status {
    case .starting, .running:      return .spinner
    case .waiting, .stalled, .queued: return .yellow          // live condition — condition-cleared, not view-cleared
    case .errored, .failed:        return unseen ? .yellow : .plain   // event — view-to-clear
    case .idle, .done:             return unseen ? .blue : .plain     // completion — view-to-clear
    case .killed:                  return .plain               // deliberate termination = default
    }
}

/// The one-time blue "unseen completion" fill — a fixed system blue in both themes (not
/// accent-following), shared verbatim by the sidebar row and the tree row so they read as
/// one marker.
func dotBlue(_ vg: VGTokens) -> Color { Color(hex: vg.theme == .dark ? 0x0A84FF : 0x007AFF) }

/// Per-node "unseen" transition rule — the pure core the reconcile
/// loop applies for every node whose status changed. `watching` = the user is looking at
/// this exact node right now (selected + session focused), so a completion/error that
/// lands under their eyes counts as already seen. Live conditions (waiting/stalled/queued)
/// are NOT view-to-clear, so they never enter the unseen set.
enum UnseenMutation: Equatable { case mark, clear, none }

func unseenMutation(prev: NodeStatus?, now: NodeStatus, watching: Bool) -> UnseenMutation {
    guard prev != now else { return .none }   // idempotent: a re-derivation to the same state must not re-light
    // Resuming work / (re)starting / a deliberate kill wipes any stale mark: spinner or
    // the default state supersedes whatever the row was showing.
    if now == .running || now == .starting || now == .killed { return .clear }
    switch now {
    case .idle, .done, .errored, .failed: return watching ? .clear : .mark
    default:                              return .none   // waiting / stalled / queued
    }
}

// (vgRelTime → VGDuration.relative — the three duration formatters unified into one namespace.)

// MARK: - Launcher options (CONTRACT §B)

// The launcher's agent choices come from agents.json (AgentEntry,
// VigilCore/ConfigFiles.swift). Honesty (§F1): only claude-kind entries are enabled.

// MARK: - Binary paths (derivation unchanged; hoisted so AppModel and SessionVM share it)

// MARK: - UI-test seams (T2 XCUITest)

/// Injection points for the Xcode-shell UI tests — ALL inert unless the XCUITest runner
/// sets the env vars (launchEnvironment). No product logic changes semantics here:
///   VIGIL_UITEST=1            isolate state (skip UserDefaults restore AND persist)
///   VIGIL_SEED_PROJECT=<dir>  seed one project (fixed id "seedproj") — bypasses NSOpenPanel
///   VIGIL_FAKE_AGENT_CMD=<sh> launch cells with ScriptHarness (fake agent) instead of claude
enum UITestSupport {
    private static let env = ProcessInfo.processInfo.environment
    static var enabled: Bool { env["VIGIL_UITEST"] == "1" }
    static var seedProjectPath: String? { env["VIGIL_SEED_PROJECT"] }
    static var fakeAgentCommand: String? { env["VIGIL_FAKE_AGENT_CMD"] }
}

/// Sessions live in ~/Library/Application Support/Vigil/sessions/<dir>/ so
/// orchestration.jsonl + meta.json survive session close and app restart. The
/// UI-test seam mirrors the UserDefaults isolation: a pid-scoped temp root, never the
/// user's real history.
enum VigilArchive {
    static let root: String = UITestSupport.enabled
        ? NSTemporaryDirectory() + "vigil-uitest-archive-\(getpid())"
        : SessionArchive.rootDir
}

enum VigilBins {
    /// The real claude path lives in agents.json (probe-seeded) and is
    /// resolved per launch by the harness; this is only the last-resort fallback when
    /// no registry entry exists. CLAUDE_BIN keeps the highest priority (tests/smoke).
    static let claude = ProcessInfo.processInfo.environment["CLAUDE_BIN"]
        ?? CLIProber.probe().first { $0.kind == "claude" }?.bin ?? "claude"
    static let codex = ProcessInfo.processInfo.environment["CODEX_BIN"] ?? "codex"
    static let opencode = ProcessInfo.processInfo.environment["OPENCODE_BIN"]
        ?? CLIProber.probe().first { $0.kind == "opencode" }?.bin ?? "opencode"
    // Shim paths = siblings of argv[0], one derivation shared with vigil-smoke.
    static let hook = SiblingBins.locate().hook
    static let mcp = SiblingBins.locate().mcp
}

// MARK: - SessionVM (one live root session)

@MainActor
@Observable
final class SessionVM: Identifiable {
    let id: String
    var name: String
    private(set) var orch: Orchestrator

    var selectedID: NodeID

    // Tree-panel show/hide = two keys:
    //   treeCollapsed —— the state itself. A fresh manager starts hidden (true); the system
    //     auto-expands once when the first worker appears (watchTreeForAutoExpand).
    //   treeUserToggled —— the user-sovereignty key. Once the user has toggled by hand, the
    //     auto logic yields permanently (it cedes only the decision, not the motion — a hand
    //     toggle still rides VGMotion.panel).
    var treeCollapsed = true
    private(set) var treeUserToggled = false
    private var treeAutoExpanded = false

    /// Tree-panel "hide finished" key: whether finished (done/failed/killed) nodes are
    /// filtered out of the tree panel (guards against dead-node pileup in long sessions).
    /// Shown by default — keeping dead nodes visible in the tree is the point.
    var hideFinishedNodes = false

    // The sidebar row status has only three visible states — spinner (live) / yellow dot
    // (attention) / blue dot (done and you haven't looked yet). The blue dot = an "unseen
    // done" marker: the indicator drops from live to rest AND this session isn't focused
    // right now → it lights; clicking the row (select) or it spinning up again → it goes
    // out. Everything else stays hidden.
    private(set) var completedUnseen = false
    /// AppModel wires this to "is activeSession me right now" — looking at it when it
    /// finishes = seen, so the blue dot stays dark. Direct-constructed VMs (tests/snapshots)
    /// default to unfocused.
    var isFocused: () -> Bool = { false }
    private var lastIndicator: SessionIndicator = .live

    // MARK: per-node unseen (the node-tree twin of completedUnseen)
    //
    // completedUnseen is SESSION granularity (one blue dot per row); this is NODE
    // granularity (one dot per tree row). The two coexist and each manages its own clear:
    // markCompletionSeen keeps its existing session semantics untouched, and selecting a
    // NODE clears only that node here. A node enters this set when it lands in a
    // "look-at-me" state (idle/done → blue, errored/failed → yellow) behind the user's
    // back, and leaves it when the user selects that node.
    private(set) var unseenNodes: Set<NodeID> = []
    private var lastNodeStatuses: [NodeID: NodeStatus] = [:]

    /// The given node has a completion/error the user hasn't looked at yet — drives the
    /// tree row's blue/yellow (with dotClass). Live conditions (waiting/stalled/queued)
    /// are NOT tracked here; they light yellow off their status directly.
    func isNodeUnseen(_ id: NodeID) -> Bool { unseenNodes.contains(id) }

    // Launcher preferences, recorded on the session. `access` is the agent-native
    // permission level — wired at launch via ClaudeCodeHarness(permissionMode:);
    // `model` goes to `claude --model` the same way (nil = claude's own default).
    // `agentKey` = the agents.json registry entry driving the ROOT (and the children's
    // fallback) — resolved per launch by the harness.
    var agentKey: String = "claude"
    var access: PermissionMode = .standard
    var model: String?

    /// The root session's CLI family, resolved from the registry at init. opencode has
    /// no transcript_path so AutoNamer must read its title via `opencode export` rather than
    /// tailing a JSONL — this is the switch. `.claude` when there's no registry / non-opencode.
    let rootKind: AgentCLIKind

    /// When this LOGICAL session was first created — drives the sidebar's relative
    /// timestamp (real clock, never fabricated). A resumed incarnation inherits the
    /// original meta date: one row = one logical session, resume is not a new session.
    let createdAt: Date

    /// The root claude's session id, hook-captured (newest wins — resume forks
    /// a new id). Persisted into meta.json as THE resume key for a later incarnation.
    private(set) var rootSessionId: String?

    /// Stable archive dir (VigilArchive.root/<dirName>): the Orchestrator writes
    /// orchestration.jsonl here, we write meta.json — the pair outlives the session.
    let archiveDir: String
    private let projectName: String?

    /// The owning Project's directory — where the root cell actually runs
    /// (Orchestrator.launchCell); breadcrumbs must show this, not a work/ path.
    private let rootCwd: String

    /// Exact task handed to Orchestrator.start for this incarnation. Retained as a
    /// read-only diagnostic/contract value so tests and future diagnostics can verify the
    /// full launch payload (orchestration.jsonl intentionally truncates it to 80 chars).
    let rootLaunchTask: String

    private let claudeBin: String, codexBin: String, opencodeBin: String, hookBin: String, mcpBin: String
    private let namer: AutoNamer
    private var trustHandled: Set<String> = []
    private var trustTask: Task<Void, Never>?

    var store: SessionStore { orch.store }

    /// `archiveDir`/`resumeSessionId`/`createdAt` non-nil = a RESUME incarnation:
    /// same archive dir (jsonl appends across incarnations), the root cell
    /// boots `claude --resume <sid>` instead of a task, identity dates carry over.
    init(id: String, name: String, rootCwd: String, initialTask: String,
         access: PermissionMode = .standard, model: String? = nil,
         projectName: String? = nil,
         agentKey: String = "claude", userConfigDir: String? = nil,
         archiveDir: String? = nil, resumeSessionId: String? = nil,
         createdAt: Date? = nil, nameIsCustom: Bool = false,
         terminalTheme: String? = nil,
         terminalColorSource: TerminalColorSource? = nil) {
        self.id = id
        self.name = name
        // A resumed session restores its custom-name pin so the codex first-message
        // auto-name fallback keeps yielding to the name the user/agent chose.
        self.userNamed = nameIsCustom
        self.rootCwd = rootCwd
        self.rootLaunchTask = initialTask
        self.access = access
        self.model = model
        self.agentKey = agentKey
        // Root uses the session agentKey as its registry entry (roles.root.agent is
        // ignored for root, HarnessResolve) — read that entry's kind. No registry / unknown
        // key = claude, the built-in default family.
        self.rootKind = userConfigDir.flatMap { AgentRegistry.load(dir: $0)?[agentKey]?.kind } ?? .claude
        self.projectName = projectName
        self.createdAt = createdAt ?? Date()
        self.rootSessionId = resumeSessionId
        self.archiveDir = archiveDir ?? VigilArchive.root + "/" + SessionArchive.newSessionDirName()
        let claudeBin = VigilBins.claude, codexBin = VigilBins.codex
        let opencodeBin = VigilBins.opencode
        let hookBin = VigilBins.hook, mcpBin = VigilBins.mcp
        self.claudeBin = claudeBin; self.codexBin = codexBin; self.opencodeBin = opencodeBin
        self.hookBin = hookBin; self.mcpBin = mcpBin
        self.namer = AutoNamer()

        // §5.1: Vigil LAUNCHES the worker itself, wired to the structured channels —
        // MCP tools (spawn/send/report/kill) + observation hooks + the manager skill. We invoke
        // the real claude binary directly (NOT the user's shell function) with our own flags;
        // nothing in the user's shell/global config is touched. This is the proven path
        // (§12.5 / vigil-smoke): the real claude TUI runs in the terminal and the tree /
        // notices / spawn / auto-naming all hang off its MCP+hook traffic. Permissions
        // are agent-native — the session's permissionMode goes to claude via the shared
        // harness instance (workers inherit it), Vigil never gates tool calls.
        // The session dir IS the stable archive dir — orchestration.jsonl lands
        // where history can read it back after close/restart. Sockets stay in /tmp
        // (Orchestrator, sun_path cap).
        let sessionDir = self.archiveDir     // (the init param archiveDir is String?, don't confuse them)
        let configRoot = sessionDir + "/config"
        // The root label is the session's agent registry key ("codex", "opencode",
        // a relay entry…) — never a hardcoded "claude". Rides cell_launch → history too.
        let root = Node(id: NodeID("root"), role: .manager, status: .running, title: agentKey)
        // UI-test seam: XCUITest sets VIGIL_FAKE_AGENT_CMD → cells run the scriptable fake
        // agent (never a real claude). Everything else in the session is production-real.
        let harness: Harness
        if let fakeCmd = UITestSupport.fakeAgentCommand {
            harness = ScriptHarness(command: fakeCmd)
        } else {
            // userConfigDir non-nil switches the harness onto the
            // launch-scoped point-read of agents.json/roles.json — bin/env/extraArgs
            // per registry entry, per-role model/prompt injection, next-spawn hot.
            // DispatchHarness routes each launch to the resolved entry's CLI family
            // (claude / codex) — a heterogeneous tree (root=claude, worker.agent="codex").
            harness = DispatchHarness(claudeBin: claudeBin, codexBin: codexBin,
                                      opencodeBin: opencodeBin,
                                      hookBin: hookBin, mcpBin: mcpBin,
                                      configRoot: configRoot, printMode: false,
                                      permissionMode: access, model: model,
                                      userConfigDir: userConfigDir, agentKey: agentKey,
                                      terminalTheme: terminalTheme,
                                      terminalColorSource: terminalColorSource)
        }
        // rootCwd: the owning Project's directory. Root resume rides the Orchestrator
        // (per-launch) — the harness stays resume-agnostic between cells.
        // One canonical size authority shared by every cell in this session. All cells
        // render into the same center pane, so whichever is on-screen keeps this at the true
        // settled grid; a newly-spawned (off-screen) worker reads it to fork its child at that
        // width instead of the 24×80 default, and a selected cell converges its surface/PTY to
        // it on attach — no birth-time narrow hard-wrap. See CanonicalPaneSize / TerminalSizePipeline.
        let canonical = CanonicalPaneSize()
        let o = Orchestrator(rootNode: root, harness: harness, sessionDir: sessionDir,
                             rootCwd: rootCwd,
                             resumeRootSessionId: resumeSessionId) {
            _ in
            let backend = GhosttyViewBackend(cols: 120, rows: 32,   // libghostty terminal core
                                             terminalColorSource: terminalColorSource)
            backend.canonical = canonical
            return backend
        }
        self.orch = o
        self.selectedID = o.store.tree.rootID
        // The plain bottom shell shares the same terminal protocol endpoint as agent cells.
        // Its login prompt can query OSC 10/11 before SwiftUI mounts a surface too.
        self.makeBottomShellBackend = {
            GhosttyViewBackend(cols: 120, rows: 32, terminalColorSource: terminalColorSource)
        }
        o.onAgentPrompt = { [weak self] node, payload in
            guard let self = self, node == self.store.tree.rootID else { return }
            // The resume key rides every UserPromptSubmit — persist on
            // change so meta.json always holds the NEWEST id (resume forks a new one).
            if let sid = payload["session_id"] as? String, sid != self.rootSessionId {
                self.rootSessionId = sid
                self.persistArchiveMeta()
            }
            if let tp = payload["transcript_path"] as? String,
               RuntimeTuning.current.autoName {   // runtime.json switch
                // The ai-title is written to disk mid-turn — start a
                // short poll of the tail the moment the prompt fires, and as soon as the title
                // appears push it to the tab/top bar (don't wait for the turn to end).
                self.namer.watch(transcriptPath: tp, currentName: self.name)
            }
        }
        // Stop = a one-shot reread at turn close, as a fallback for the watch
        // (extra-long turns, deadline expiry, and claude regenerating the ai-title each turn).
        o.onAgentStop = { [weak self] node, payload in
            guard let self = self, node == self.store.tree.rootID,
                  RuntimeTuning.current.autoName else { return }
            self.namer.cancelWatch()         // turn is closed, the mid-turn poll stops here
            // opencode: no transcript_path — session.idle carries only session_id through
            // the plugin; name via `opencode export <sid>`. claude/codex keep the JSONL tail.
            if self.rootKind == .opencode {
                let sid = (payload["session_id"] as? String) ?? self.rootSessionId
                if let sid, !sid.isEmpty {
                    self.namer.considerOpenCode(sessionId: sid, opencodeBin: self.opencodeBin,
                                                currentName: self.name)
                }
                return
            }
            // codex naming: codex fires no Stop hook, so this handler never runs for it —
            // codex is named via onCodexRollout below (the main rollout's first user_message). Guard
            // anyway so a claude-shaped tail is never force-fit on a codex rollout.
            if self.rootKind == .codex { return }
            let tp = (payload["transcript_path"] as? String) ?? self.orch.transcripts[node]
            if let tp { self.namer.consider(transcriptPath: tp, currentName: self.name) }
        }
        // codex honest fallback naming: codex has no ai-title (claude) / export title (opencode)
        // and fires no Stop hook — so name from the MAIN rollout's first user_message (never a
        // sub-agent's sub-task). Fires on every codex capture (turnEnded/exit); the namer's
        // in-flight dedup + userNamed guard keep it idempotent and yield to a manual rename.
        o.onCodexRollout = { [weak self] node, rolloutPath in
            guard let self = self, node == self.store.tree.rootID,
                  self.rootKind == .codex, !self.userNamed,
                  RuntimeTuning.current.autoName else { return }
            self.namer.considerCodex(rolloutPath: rolloutPath, currentName: self.name)
        }
        // ⌘⇧R: once the user hand-names a session, AutoNamer yields — a manual
        // title is a custom-title that must not be clobbered by the next ai-title reread.
        namer.onName = { [weak self] title in
            guard let self, !self.userNamed else { return }
            self.setName(title)
        }
        // Any root can self-name via the MCP tool. Apply it to the root session label
        // and pin it as user-chosen (renameByUser sets userNamed), so every automatic naming
        // source yields afterward. The MCP layer exposes rename only to roots and rejects an
        // empty name; clamp to the shared naming length here as a final app-layer guard.
        o.onSessionRename = { [weak self] node, rawName in
            guard let self, node == self.store.tree.rootID,
                  let clamped = AutoNamer.clamp(rawName) else { return }
            self.renameByUser(clamped)
        }
        // The opencode transcript-export bridge (runtime is binary-agnostic). Runs the
        // official `opencode export` off-main; the runtime materializes the snapshot pointer
        // so opencode dead nodes get replay (their transcript lives in SQLite, no external JSONL).
        o.openCodeExporter = { [opencodeBin] sid in
            await Task.detached {
                AutoNamer.runOpenCodeExportRaw(sessionId: sid, opencodeBin: opencodeBin)
            }.value
        }
        do { try o.start(rootTask: rootLaunchTask) } catch { o.store.note("start failed: \(error)") }
        // Tree afterlife: a resume incarnation grafts the previous life's skeleton
        // into the live tree (dead workers show, per-node resume targets) and adopts
        // its transcript/sessionId pointers (gaps backfilled from transcript basenames).
        if resumeSessionId != nil, let a = SessionArchive.load(dir: sessionDir) {
            if let t = a.tree { o.store.send(.restoreSkeleton(t)) }
            o.adoptArchive(a)
            // The skeleton is grafted in before
            // watchTreeForAutoExpand is registered, and observation only fires on "change" — so
            // a resume that carries a tree would never auto-expand. Expand once right here
            // (without consuming the user-sovereignty key: a hand toggle still takes over anytime).
            if o.store.tree.count > 1 {
                treeAutoExpanded = true
                treeCollapsed = false
            }
        }
        persistArchiveMeta()
        startTrustWatcher()
        watchTreeForAutoExpand()
        watchForSessionEnd()
        lastIndicator = sessionIndicator(badge: badge, tree: store.tree)
        watchIndicator()
        // Seed the per-node baseline so pre-existing states (fresh running root, a resumed
        // tree rebuilt as idle) are NOT treated as fresh transitions — only status changes
        // AFTER init light a dot (mirrors lastIndicator's seed above).
        lastNodeStatuses = store.tree.nodes.mapValues { $0.status }
        watchNodeAttention()
    }

    // MARK: unseen-done dot (it's done and you haven't looked)

    /// The row was clicked / the session got focus — the completion is seen. Session
    /// granularity clears here; the NODE you land on (selectedID) is on screen in the same
    /// beat, so its per-node tree dot clears too: switching INTO a session
    /// from the sidebar must not leave the viewed node's tree dot blue and force a second
    /// click in the tree — the focus-arrival twin of select()'s view-to-clear.
    func markCompletionSeen() {
        completedUnseen = false
        unseenNodes.remove(selectedID)
    }

    /// Observation loop over the derived indicator (same re-arming idiom as
    /// watchTreeForAutoExpand): live→rest while unfocused = a turn finished behind
    /// your back → light the dot; anything that leaves rest puts the session back to
    /// work → the stale dot dies.
    private func watchIndicator() {
        withObservationTracking {
            _ = sessionIndicator(badge: badge, tree: store.tree)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = sessionIndicator(badge: self.badge, tree: self.store.tree)
                if now != self.lastIndicator {
                    if now == .rest, self.lastIndicator == .live, !self.isFocused() {
                        self.completedUnseen = true
                    } else if now != .rest {
                        self.completedUnseen = false
                    }
                    self.lastIndicator = now
                }
                self.watchIndicator()
            }
        }
    }

    /// Per-node twin of watchIndicator: observe every node's status and, on any change,
    /// reconcile the unseen set. `store.tree` is a value type, so ANY status change
    /// replaces the whole `tree` property and fires onChange (no short-circuit blind spot).
    private func watchNodeAttention() {
        withObservationTracking {
            for n in store.tree.nodes.values { _ = n.status }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconcileUnseen()
                self.watchNodeAttention()
            }
        }
    }

    /// Apply the pure `unseenMutation` rule to every node whose status changed since the
    /// last pass. Internal (not private) so T1 can drive it synchronously after a store
    /// command instead of pumping the async observation loop.
    func reconcileUnseen() {
        let focused = isFocused()
        for (id, node) in store.tree.nodes {
            let now = node.status
            let watching = focused && id == selectedID
            switch unseenMutation(prev: lastNodeStatuses[id], now: now, watching: watching) {
            case .mark:  unseenNodes.insert(id)
            case .clear: unseenNodes.remove(id)
            case .none:  break
            }
        }
        // Invariant guard: the node you are actively viewing is never "unseen".
        // The per-node `watching` branch above already clears it on the transition itself;
        // this pins the invariant by construction against any focus/selection timing where
        // the completing transition wasn't observed while watching (completed under the
        // user's eyes but the tree dot stayed blue). Idempotent.
        if focused { unseenNodes.remove(selectedID) }
        // Drop bookkeeping for nodes that left the tree (kill keeps them, so this is rare —
        // only a full rebuild would); prevents a stale prev from re-marking a reused id.
        lastNodeStatuses = store.tree.nodes.mapValues { $0.status }
        unseenNodes.formIntersection(store.tree.nodes.keys)
    }

    // MARK: session end (a clean root exit = the session is archived into history state)

    /// Fires ONCE when the root finished CLEANLY (.done) and nothing else in the tree
    /// still runs — the session's process side is over, so the owner (AppModel) flips
    /// it into a history row + history view. failed/killed roots deliberately do NOT
    /// transition: the dead-node pane keeps the frozen frame for diagnosis (honesty
    /// beats tidiness on a crash).
    var onSessionEnded: (() -> Void)?
    private var endFired = false

    private var allWorkDone: Bool {
        store.tree.root.status == .done && !store.tree.nodes.values.contains {
            $0.kind == .cell && !$0.status.isTerminal
        }
    }

    private func watchForSessionEnd() {
        guard !endFired else { return }
        withObservationTracking {
            _ = allWorkDone
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.endFired else { return }
                if self.allWorkDone {
                    self.endFired = true
                    self.onSessionEnded?()
                } else {
                    self.watchForSessionEnd()
                }
            }
        }
    }

    // MARK: per-node resume (click a node to revive it)

    /// The node can be re-incarnated: its CLI session id is known (hook-captured live,
    /// or adopted/derived from the archive at resume).
    func canResume(_ id: NodeID) -> Bool { orch.sessionIds[id] != nil }

    /// Re-incarnate ONE dead node's agent (`claude --resume <its sid>`). The tree flip
    /// and cell relaunch travel Command→Effect; UI only asks.
    func resumeNode(_ id: NodeID) {
        guard let sid = orch.sessionIds[id] else { return }
        store.send(.resumeNode(id, sessionID: sid))
    }

    /// Rename (AutoNamer or any future manual path) — the archive meta follows so the
    /// history list shows the final name, not the launch-time prefix.
    func setName(_ newName: String) {
        name = newName
        persistArchiveMeta()
    }

    /// ⌘⇧R: the user's manual rename. Locks AutoNamer out for this session
    /// (a custom-title wins over ai-title) and persists the new label. Empty is ignored.
    private(set) var userNamed = false
    func renameByUser(_ newName: String) {
        let t = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        userNamed = true
        setName(t)
    }

    /// meta.json = the session's identity card for the history list. Written at
    /// launch and on rename; content is identity only — the tree/timeline truth stays
    /// in orchestration.jsonl.
    private func persistArchiveMeta() {
        SessionArchive.writeMeta(
            SessionArchiveMeta(id: (archiveDir as NSString).lastPathComponent, name: name,
                               projectName: projectName, projectCwd: rootCwd,
                               agent: agentKey, model: model, createdAt: createdAt,
                               rootSessionId: rootSessionId,
                               nameIsCustom: userNamed ? true : nil),
            dir: archiveDir)
    }

    // MARK: tree panel keys

    /// User clicked the top-bar tree toggle: from now on the auto key yields to the
    /// user; the motion itself stays the shared panel animation.
    func userToggleTree() {
        treeUserToggled = true
        withAnimation(VGMotion.panel) { treeCollapsed.toggle() }
    }

    /// Auto key: hidden for a fresh manager, expands ONCE when the first worker appears
    /// — unless the user already exercised their key. Re-arms via observation tracking
    /// until it fired or the user took over (works even while the session is off-screen).
    private func watchTreeForAutoExpand() {
        guard !treeAutoExpanded, !treeUserToggled else { return }
        withObservationTracking {
            _ = store.tree.count
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.treeUserToggled, !self.treeAutoExpanded, self.store.tree.count > 1 {
                    self.treeAutoExpanded = true
                    withAnimation(VGMotion.panel) { self.treeCollapsed = false }
                }
                self.watchTreeForAutoExpand()
            }
        }
    }

    // MARK: bottom terminal panel (plain shell)

    /// The per-session bottom shell (BottomShell.swift): a plain `$SHELL` on the same
    /// host-PTY + surface chain as the center terminal, with all agent machinery stripped.
    /// Lazily created on first open; nil once terminated (× / natural exit) so the next open
    /// spawns a fresh shell. NOT a tree node — invisible to the harvester by construction.
    private(set) var bottomShell: BottomShell?
    /// Panel visible state. Hiding (⌘J again) keeps the process alive — the panel is a view of
    /// the shell, not the shell itself; re-showing re-attaches the same running process.
    var bottomShellVisible = false
    /// Test seam: the backend the bottom shell forks — production builds a ghostty surface,
    /// tests inject a headless (real fork) or spy backend before opening the panel.
    var makeBottomShellBackend: () -> TerminalBackend = { GhosttyViewBackend(cols: 120, rows: 32) }

    /// ⌘J / the top-bar term toggle: flip the panel. Show → start the shell if needed (focus
    /// is handed to it by the panel view on appear); hide → keep the process, panel closes.
    func toggleBottomShell() { setBottomShell(visible: !bottomShellVisible) }

    /// Explicit set (toggle's primitive; also drives the panel's × → false path indirectly).
    func setBottomShell(visible: Bool) {
        if visible {
            if bottomShell == nil {
                let sh = BottomShell(cwd: rootCwd, makeBackend: makeBottomShellBackend)
                sh.onEnded = { [weak self] in self?.handleBottomShellEnded() }
                bottomShell = sh
            }
            bottomShell?.start()
        }
        bottomShellVisible = visible
    }

    /// The panel's × button: close the panel AND end the shell process. Next open = new shell.
    func closeBottomShell() {
        bottomShell?.terminate()
        bottomShell = nil
        bottomShellVisible = false
    }

    /// The shell ended on its own (user typed `exit`): drop the panel; next ⌘J spawns fresh.
    private func handleBottomShellEnded() {
        bottomShell = nil
        bottomShellVisible = false
    }

    var badge: Int { store.notices.count }
    var statusDot: DStatus { designStatus(store.tree.root) }

    /// The given node has an unread observation notice (drives rail dots).
    func hasNotice(_ id: NodeID) -> Bool {
        store.notices.contains { $0.nodeID == id }
    }

    /// Selected node, falling back to root if the selection vanished (killed subtree).
    var selectedNode: Node { store.tree[selectedID] ?? store.tree.root }

    func select(_ id: NodeID) {
        selectedID = id
        // Viewing the node = confirmed: its unseen completion/error dot clears. Same
        // "viewing a row clears its dot" rule as markCompletionSeen, one node granularity down.
        unseenNodes.remove(id)
        // The surface attaches on selection, firing a SIGWINCH resize + repaint that blanks
        // the running anchor from the scrape source; tell the TurnWatcher so it does not
        // misread that transient as an interrupt and idle a live turn.
        orch.noteNodeSelected(id)
    }

    func cwd(_ id: NodeID) -> String {
        // Mirrors Orchestrator.launchCell: every node — root and workers alike —
        // runs in the project directory; isolation is the agent's own choice.
        rootCwd
    }

    func terminalView(_ id: NodeID) -> AppTerminalView? {
        (orch.registry.backend(id) as? GhosttyViewBackend)?.view
    }

    // Dead-node afterlife: the pane's two data sources — the node → transcript
    // pointer (same join key as the archive) and the frozen last frame from teardown.
    func transcriptPath(_ id: NodeID) -> String? { orch.transcripts[id] }
    func lastFrame(_ id: NodeID) -> String? { orch.frozenScreens[id] }

    /// The node's OWN CLI family (live launchKind, or grafted-archive fallback), so a
    /// dead node's afterlife shows its family's real resume syntax — never the root's. A
    /// node not yet in the map (ghost) falls back to the root family.
    func nodeKind(_ id: NodeID) -> AgentCLIKind { orch.nodeKinds[id] ?? rootKind }

    // The folder-trust gate ("Do you trust the files in this folder?") blocks a fresh
    // claude on first run in a new cwd. The launcher already made the user explicitly pick
    // this project AND a permission level — that IS a declaration of trust in the
    // directory; auto-answering "1" here executes that declaration, it does not take over
    // the user's input. Mirror vigil-smoke: poll the rendered screen and answer.
    private func startTrustWatcher() {
        trustTask = Task { [weak self] in
            for _ in 0..<120 {  // ~2 min of best-effort watching
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                for nid in self.orch.registry.nodeIDs where !self.trustHandled.contains(nid.raw) {
                    let screen = self.orch.registry.backend(nid)?.renderScreen() ?? ""
                    let s = screen.lowercased()
                    if s.contains("trust the files") || s.contains("do you trust") {
                        self.orch.registry.backend(nid)?.send("1\r")
                        self.trustHandled.insert(nid.raw)
                    }
                }
            }
        }
    }

    func shutdown() {
        trustTask?.cancel(); namer.cancelWatch()
        bottomShell?.terminate(); bottomShell = nil   // the shell dies with its session
        orch.stop()
    }
}

// MARK: - ProjectVM (a directory that owns sessions, CONTRACT §B)

@MainActor
@Observable
final class ProjectVM: Identifiable {
    let id: String            // UUID string
    var name: String          // default = directory basename
    var cwd: String           // absolute path
    var expanded: Bool = true
    var sessions: [SessionVM] = []
    /// More than 5 rows collapse by default; the tail "show all (N)" row flips this.
    var showAllRows: Bool = false
    /// Sum of the children's badges (shown on the collapsed project row).
    var badgeTotal: Int { sessions.reduce(0) { $0 + $1.badge } }

    init(id: String, name: String, cwd: String) {
        self.id = id
        self.name = name
        self.cwd = cwd
    }
}

// MARK: - Rail row (within a project group, live and dead sessions merge into one column, one row = one logical session)

/// One sidebar row under a project group — live (a running SessionVM) or dead (an
/// archived summary whose click = resume). Merged and time-sorted by AppModel.rows(for:).
@MainActor
enum RailRow: Identifiable {
    case live(SessionVM)
    case dead(ArchivedSessionSummary)

    // Identifiable crosses isolation (ForEach diffs off-actor) — both ids are immutable
    // Sendable lets, so the nonisolated read is safe by construction.
    nonisolated var id: String {
        switch self {
        case .live(let s): "live-\(s.id)"
        case .dead(let d): "dead-\(d.id)"
        }
    }
    var name: String {
        switch self {
        case .live(let s): s.name
        case .dead(let d): d.name
        }
    }
    var date: Date? {
        switch self {
        case .live(let s): s.createdAt
        case .dead(let d): d.createdAt ?? d.modifiedAt
        }
    }
}

// MARK: - Sidebar UI record (collapse/expand/selection state persisted, restored on restart)

/// Everything foldable/selectable the user can leave behind in the sidebar, as one
/// codable snapshot: per-project expanded / show-all, the focused project, the selected
/// row, and the whole-rail collapse. A focused LIVE session persists as its archive id —
/// after a restart that row IS the history row, so the selection survives the process
/// (the process dies, the session lives on). The section headers (projects/chats/settings)
/// and the rail width reuse their own earlier keys and are not re-registered here.
struct SidebarUIRecord: Codable, Equatable {
    var collapsedProjects: [String] = []
    var showAllProjects: [String] = []
    var currentProjectID: String? = nil
    var selectedArchiveID: String? = nil
    var railCollapsed = false
}

// MARK: - AppModel (top-level: projects › sessions)

@MainActor
@Observable
final class AppModel {
    var projects: [ProjectVM] = []
    var currentProjectID: String? = nil
    var activeSessionID: String? = nil {     // nil + currentProject ⇒ center shows the launcher
        // Terminal-debug lines route to the focused session's dir — a repro is worked in one
        // session, so follow the focus. No-op (and no sink touch) while the mode is off.
        didSet { refreshTerminalDebugTarget() }
    }
    /// History replay: dead sessions read back from the stable archive root. Explicitly
    /// refreshed (bootstrap / close) — never scanned during render.
    var history: [ArchivedSessionSummary] = []
    var selectedHistoryID: String? = nil     // non-nil ⇒ center shows the read-only HistoryPane
    // The history view = self-rendered transcript + Enter to
    // resume. Opening history loads the archive synchronously (openHistory); tree/selection/
    // panel-fold are the history view's own three keys — mirroring the live SessionVM key
    // layout, but their lifecycle follows selectedHistoryID.
    var historyArchive: ArchivedSession? = nil
    var historyNodeID: NodeID? = nil         // the node selected in the history tree (whose transcript the center renders)
    var historyTreeCollapsed = true          // with a tree (>1 node), expand on open
    /// The RESOLVED token theme (dark/light) the whole UI + terminal render from. In
    /// follow-system mode it tracks the live OS scheme; a pin holds it fixed. Never set this
    /// directly from config — go through `applyConfig` / `resolveTheme` so the preference and
    /// the system source stay the single source of truth.
    var theme: VGTheme = .dark {
        didSet { if theme != oldValue { terminalAppearanceInputChanged() } }
    }
    /// appearance.json `theme` as the user wrote it: pin vs. follow-system.
    var themePreference: VGThemePreference = .system
    var accent: VGAccent = .blue {
        didSet { if accent != oldValue { terminalAppearanceInputChanged() } }
    }
    /// appearance.json `terminal` block — ghostty render knobs,
    /// hot-applied by the AppModel appearance transaction. TerminalHost keeps an idempotent
    /// fallback for its initial mount.
    var terminalPrefs: VGTerminalPrefs = .defaults {
        didSet { if terminalPrefs != oldValue { terminalAppearanceInputChanged() } }
    }
    /// One per AppModel, shared by every session/backend it creates. The values are already
    /// xterm OSC wire specs and update in place, so an existing dark-screen worker answers its
    /// next OSC 10/11 query from the same effective colors the live ghostty surface renders.
    /// It stays empty until the first successful ghostty apply; a failed initial config must not
    /// publish a guessed color pair that may disagree with the controller's actual config.
    @ObservationIgnored let terminalColorSource: TerminalColorSource
    @ObservationIgnored private var terminalAppearanceSyncDeferralDepth = 0
    var railCollapsed = false
    /// Sidebar width — user-resizable via the trailing drag handle, persisted.
    var railWidth: CGFloat = 248
    /// Bottom terminal panel height (plain shell) — user-resizable via the top
    /// drag handle, persisted. App-global (one height for every session's panel).
    var bottomShellHeight: CGFloat = 260
    var toast: String?

    // The config dir is the only settings surface — no settings page.
    // These are the APPLIED values: loaded at bootstrap, hot-reloaded by the watcher.
    // theme/accent live above; the launcher seeds from these three.
    let configStore: ConfigStore
    private let configInjected: Bool         // tests inject a store → config flow runs in UITest mode

    /// The OS dark/light source driving follow-system theme. Production =
    /// NSApp.effectiveAppearance KVO; tests inject a fake for determinism. Not observable —
    /// it's a pure input, and its onChange drives `theme` (which IS observable).
    @ObservationIgnored private let appearanceSource: SystemAppearanceSource

    // Terminal observability: the file sink + the applied mode (so hot config re-applies and
    // session-switch target refreshes are both cheap idempotent checks against this cache).
    private let terminalDebugSink = TerminalDebugFileSink()
    private var terminalDebugMode: TerminalDebugLogMode = .off

    // Built-in pseudo-projects — peers of the projects section, pinned below it, never
    // persisted into the projects array. Chats = free conversations not tied to a repo
    // (cwd = <config>/chats, created on first use); Settings = the config workspace
    // itself (cwd = ~/.config/vigil).
    let chatsProject: ProjectVM
    let settingsProject: ProjectVM
    /// Pseudo-bucket backing the sidebar's Archived section — exists only for the
    /// shared GroupRows fold state (>N cap / show-all) and AX ids. It never owns live
    /// sessions and never joins allProjects (not a launch target, no ⌘1-9 slot).
    let archivedProject: ProjectVM
    /// Sidebar section collapse: keys "projects" / "chats" / "settings" /
    /// "archived".
    var collapsedSections: Set<String> = []
    /// Sidebar search-box text. Lifted out of SidebarView's local
    /// @State so the render order AND ⌘1–9 filter on ONE source (visibleSessionRows) —
    /// mirror drift between the two would misalign ⌘N from what's on screen. Empty unless
    /// the user is actively searching; the view clears it when the field folds away.
    var searchQuery: String = ""
    /// The normalized search predicate (trimmed + lowercased) both the sidebar rows and the
    /// ⌘N counting filter on. Empty ⇒ no filter / full render order.
    var searchTerm: String { searchQuery.trimmingCharacters(in: .whitespaces).lowercased() }
    var defaultModel: String? = nil
    /// Permission defaults wide-open for every family — the launcher does not
    /// pick a level; tightening moves to roles.json per-role `access` (settings-as-
    /// files). This is the session-wide fallback that a per-role override beats.
    var defaultAccess: PermissionMode = .bypass
    /// launcher.json's default agent (registry key) — seeds the agent chip.
    var defaultAgent: String = "claude"
    /// agents.json as loaded (hot-watched). UI reads `agentEntries`.
    private(set) var registry: AgentRegistry = AgentRegistry(entries: [])
    /// The CLI probe result (nil = probe skipped — UITest without the
    /// VIGIL_PROBE_DIRS seam). [] drives the launcher's zero-hit banner.
    private(set) var cliProbe: [DetectedCLI]? = nil
    /// One-shot launcher prompt prefill (onboarding/reconfigure); consumed by submit.
    /// (Every session launches wide-open, the settings agent included, so there is no
    /// per-visit permission override to carry.)
    var launcherPrefill: String? = nil
    /// README.md is the one settings guide shared by every agent family. Name it in the
    /// task instead of relying on a vendor-specific auto-loaded instruction filename.
    static let configOnboardingPrompt = "Read README.md in this Settings directory, then follow its agent-neutral setup instructions to set up Vigil for me."
    static let configTaskPreamble = "Before editing Vigil settings, read README.md in this Settings directory and follow its field definitions and agent-neutral instructions."

    /// The only prefill currently shipped is Settings onboarding. Keep it project-bound:
    /// `launcherPrefill` is process-global state, while LauncherView can be rebuilt through
    /// several project-selection paths that do not all call openLauncher.
    func launcherPrefill(for projectID: String) -> String? {
        projectID == settingsProject.id ? launcherPrefill : nil
    }

    /// Reconfigure launchers intentionally open blank, but every submitted Settings task
    /// still needs the same guide discovery across Claude/Codex/OpenCode. Only the two
    /// canonical, already-prefixed forms bypass wrapping: merely mentioning README.md (even
    /// in a negative instruction) must not accidentally suppress the universal preamble.
    static func taskForConfigWorkspace(_ task: String) -> String {
        if task == configOnboardingPrompt || task.hasPrefix(configTaskPreamble) { return task }
        guard !task.isEmpty else { return configTaskPreamble }
        return configTaskPreamble + "\n\nUser request:\n" + task
    }

    /// The launcher's agent dropdown: registry entries, or the builtin claude entry
    /// when agents.json is absent/empty (a missing file must not leave the agent surface empty).
    var agentEntries: [AgentEntry] {
        registry.entries.isEmpty
            ? AgentRegistry.builtinFallback(claudeBin: claudeBin).entries
            : registry.entries
    }

    let claudeBin: String
    let codexBin: String
    let opencodeBin: String
    let hookBin: String
    let mcpBin: String
    private var seq = 0
    private var bootstrapped = false
    private var toastTask: Task<Void, Never>?

    private static let projectsKey = "vigil.projects.v1"
    /// Claude keeps its native dynamic policy; dark-screen OSC queries are answered from the
    /// shared live TerminalColorSource instead of freezing light/dark at session construction.
    static let agentTerminalTheme = ClaudeCodeHarness.terminalTheme
    private struct ProjectRecord: Codable { var id: String; var name: String; var cwd: String }

    init(configStore: ConfigStore? = nil, appearanceSource: SystemAppearanceSource? = nil) {
        let store = configStore ?? ConfigStore(dir: ConfigStore.defaultDir)
        self.configStore = store
        self.configInjected = configStore != nil
        self.terminalColorSource = TerminalColorSource()
        #if os(macOS)
        self.appearanceSource = appearanceSource ?? NSAppAppearanceSource()
        #else
        self.appearanceSource = appearanceSource ?? StubAppearanceSource()
        #endif
        self.chatsProject = ProjectVM(id: "builtin-chats", name: "Chats",
                                      cwd: store.dir + "/chats")
        self.settingsProject = ProjectVM(id: "builtin-settings", name: "Settings",
                                         cwd: store.dir)
        // cwd intentionally empty: nothing joins this bucket by cwd — its rows are the
        // archived-flag filter over history (archivedRows), not a directory match.
        self.archivedProject = ProjectVM(id: "builtin-archived", name: "Archived", cwd: "")
        claudeBin = VigilBins.claude
        codexBin = VigilBins.codex
        opencodeBin = VigilBins.opencode
        hookBin = VigilBins.hook
        mcpBin = VigilBins.mcp
        // Normalize files/images from the terminal's Cmd+V (vendored readClipboard
        // seams in the host transform; plain text falls back to nil, zero behavior change).
        // Process-level, one-shot.
        PasteIngest.installTerminalHook()
        // On-disk images are temporary; on exit clean only the ones we own (replay
        // can no longer resume an image claude never read — a known boundary).
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            PasteImageStore.shared.cleanupAll()
            // Normal quit releases every held live.lock so those sessions resume
            // freely on next launch (a crash instead leaves stale locks that self-heal).
            MainActor.assumeIsolated {
                self?.allSessions.forEach { SessionLock.remove(dir: $0.archiveDir) }
            }
        }
        // A live OS light⇄dark flip re-resolves the theme (only while
        // follow-system). Wired last so the closure captures a fully-formed self.
        self.appearanceSource.onChange = { [weak self] in self?.systemAppearanceChanged() }
    }

    // MARK: derived

    /// Every session bucket, in sidebar order: user projects, then the built-ins.
    var allProjects: [ProjectVM] {
        projects + [chatsProject, settingsProject]
    }

    var current: ProjectVM? {
        guard let id = currentProjectID else { return nil }
        return allProjects.first { $0.id == id }
    }

    var activeSession: SessionVM? {
        guard let id = activeSessionID else { return nil }
        return allSessions.first { $0.id == id }
    }

    /// Stable flattening (project order, then chats/settings) — drives ⌘1-9.
    var allSessions: [SessionVM] {
        allProjects.flatMap(\.sessions)
    }

    var tokens: VGTokens { .make(theme, accent) }

    /// Resolve the exact pair used by both VGGhosttyTheme.configuration and the host's OSC
    /// stand-in. This is evaluated after every theme/accent/prefs change, never frozen into a
    /// SessionVM; all existing sessions retain the shared TerminalColorSource instead.
    private func effectiveTerminalColorSpecs(
        vg: VGTokens,
        prefs: VGTerminalPrefs
    ) -> (foreground: String, background: String) {
        return (
            foreground: VGGhosttyTheme.oscColorSpec(
                hex: VGGhosttyTheme.effectiveColorHex(prefs.foreground,
                                                       fallback: vg.termFG)),
            background: VGGhosttyTheme.oscColorSpec(
                hex: VGGhosttyTheme.effectiveColorHex(prefs.background,
                                                       fallback: vg.termBG))
        )
    }

    /// Property-observer entry for direct/manual mutations. Config reloads defer these callbacks
    /// and publish once after all three appearance inputs have landed.
    private func terminalAppearanceInputChanged() {
        guard terminalAppearanceSyncDeferralDepth == 0 else { return }
        synchronizeTerminalAppearance()
    }

    /// Commit order is deliberate: a failed ghostty config must leave the OSC answer source on
    /// the last surface configuration that actually rendered. Only after the shared controller
    /// confirms the target do we publish its exact effective foreground/background atomically.
    @discardableResult
    func synchronizeTerminalAppearance() -> Bool {
        let vg = tokens
        let prefs = terminalPrefs
        guard VGGhosttyTheme.apply(vg, prefs: prefs) else { return false }
        let colors = effectiveTerminalColorSpecs(vg: vg, prefs: prefs)
        terminalColorSource.update(terminalTheme: vg.theme.rawValue,
                                   foreground: colors.foreground,
                                   background: colors.background)
        return true
    }

    var selectedHistory: ArchivedSessionSummary? {
        guard let id = selectedHistoryID else { return nil }
        return history.first { $0.id == id }
    }

    // MARK: bootstrap & persistence

    /// Restore projects only — sessions are live processes and are never auto-started.
    /// projects empty → center shows the "add a project" empty state; otherwise →
    /// launcher. Config files load (and start hot-watching) here; the very first
    /// run (no config JSON yet) opens the onboarding config workspace instead.
    func bootstrapIfNeeded() {
        guard !bootstrapped else { return }
        bootstrapped = true
        // UI-test seam: isolated, deterministic start — never touch the user's persisted
        // projects; optionally seed one project from env (bypasses NSOpenPanel). The
        // config flow runs only for an explicitly injected store (never the real dir).
        if UITestSupport.enabled {
            if let seed = UITestSupport.seedProjectPath {
                let p = ProjectVM(id: "seedproj",
                                  name: (seed as NSString).lastPathComponent, cwd: seed)
                projects.append(p)
                openLauncher(in: p.id)
            }
            refreshHistory()                 // isolated root (VigilArchive) — safe
            if configInjected { setupConfig() }
            return
        }
        restoreProjects()
        restoreRailWidth()
        restoreBottomShellHeight()
        restoreCollapsedSections()
        let onboarding = setupConfig()
        refreshHistory()                     // list history right on restart
        reapOrphans()                        // clear children a prior hard-kill stranded
        startHarvester()                     // silent harvesting of rest sessions
        // Replay the fold/selection state (must be after refreshHistory — a history-row
        // selection needs to be verifiable as existing). Skip the replay when onboarding already
        // owns the center; no archive, or the recorded project was deleted → fall back to the
        // first project's launcher.
        if !onboarding {
            restoreSidebarUI()
            if currentProjectID == nil, let first = projects.first {
                openLauncher(in: first.id)
            }
        }
    }

    // MARK: config (settings-as-files — load · hot reload · onboarding)

    /// Install-on-first-run → load → watch. Returns true when first-run onboarding
    /// took over the center (the config workspace is showing).
    ///
    /// The CLI probe runs EVERY start (claude→codex→opencode, real binaries
    /// only — CLIProber) and rewrites detected.json, the fact file the settings agent
    /// reads instead of probing itself; on first run it also seeds agents.json +
    /// launcher.json's default agent. UITest without VIGIL_PROBE_DIRS skips the probe —
    /// a machine-dependent scan must not leak into deterministic tests.
    @discardableResult
    private func setupConfig() -> Bool {
        let firstRun = configStore.isFirstRun
        let probeSeamSet = ProcessInfo.processInfo.environment["VIGIL_PROBE_DIRS"] != nil
        let detected: [DetectedCLI]? =
            (UITestSupport.enabled && !probeSeamSet) ? nil : CLIProber.probe()
        configStore.ensureInstalled(detected: detected ?? [])
        if let d = detected {
            cliProbe = d
            CLIProber.writeDetected(d, dir: configStore.dir)
        }
        applyConfig(configStore.load())
        configStore.startWatching { [weak self] cfg in self?.applyConfig(cfg) }
        if firstRun { openConfigWorkspace(onboarding: true) }
        return firstRun
    }

    /// File values → running state. Also the hot-reload landing point (agent edits a
    /// JSON → watcher → here); theme keeps the no-animation switch rule (SPEC §0.6).
    func applyConfig(_ c: VigilConfig) {
        // Theme, accent, and terminal prefs form one render transaction. Their property
        // observers cover direct/manual changes, while a config reload batches the three. A
        // depth counter (not a Bool) keeps synchronous Observation re-entry transaction-safe.
        terminalAppearanceSyncDeferralDepth += 1
        defer {
            terminalAppearanceSyncDeferralDepth -= 1
            if terminalAppearanceSyncDeferralDepth == 0 { synchronizeTerminalAppearance() }
        }
        // Adopt the preference, then resolve against the live OS scheme — a
        // pin lands its scheme; "auto" lands the system's and starts tracking flips.
        themePreference = c.themePreference
        resolveTheme()
        if accent != c.accent { accent = c.accent }
        // Ghostty render knobs — observable for mounted hosts, while the
        // batched transaction below is the authoritative runtime apply.
        if terminalPrefs != c.terminal { terminalPrefs = c.terminal }
        defaultModel = c.model
        defaultAccess = c.access
        defaultAgent = c.agent
        registry = c.registry
        // runtime.json takes effect immediately: every use site (harvester / inject / history cap /
        // sidebar cap / auto-namer / dogfood log) reads RuntimeTuning.current.
        RuntimeTuning.current = c.runtime
        applyTerminalDebug(c.runtime.terminalDebugLog)
    }

    // MARK: - terminal observability wiring

    /// Map the runtime.json mode → geometry-safe category set and (un)install the file sink.
    /// Off → `TerminalDebugLog.disable()` (hot paths early-exit on one bool read) + close the file
    /// + reset the sink to a no-op. Never enables `.input`/`.output`/`.ime` — those categories
    /// describe real terminal bytes, and the red line is geometry/event metadata only.
    func applyTerminalDebug(_ mode: TerminalDebugLogMode) {
        guard mode != terminalDebugMode else { return }
        terminalDebugMode = mode
        switch mode {
        case .off:
            TerminalDebugLog.disable()
            TerminalDebugLog.sink = { _ in }
            terminalDebugSink.close()
        case .standard, .metrics:
            terminalDebugSink.setTarget(sessionDir: activeSession?.archiveDir)
            let sink = terminalDebugSink
            TerminalDebugLog.sink = { sink.write($0) }
            TerminalDebugLog.enable(Self.debugCategories(for: mode))
        }
    }

    /// Repoint the sink at the focused session's dir when the mode is on; a no-op while off.
    private func refreshTerminalDebugTarget() {
        guard terminalDebugMode != .off else { return }
        terminalDebugSink.setTarget(sessionDir: activeSession?.archiveDir)
    }

    /// Geometry-safe categories only. `.metrics` = HostPTY winsize + surface commit verdicts;
    /// `.standard` adds surface lifecycle. `.input`/`.output`/`.ime` are deliberately excluded.
    private static func debugCategories(for mode: TerminalDebugLogMode) -> TerminalDebugCategory {
        switch mode {
        case .off:      return []
        case .metrics:  return [.metrics]
        case .standard: return [.metrics, .lifecycle]
        }
    }

    /// First-run onboarding + ⌘, reconfigure: the config workspace IS the built-in
    /// Settings pseudo-project — open its launcher.
    /// `onboarding` (FIRST RUN ONLY — Settings never handled before) additionally prefills the
    /// guide prompt: the configuring agent reads README.md + detected.json and writes the JSONs back.
    /// The settings agent runs wide-open like every session — no special access seed. Every
    /// later visit (sidebar Settings icon / ⌘, / new chat in Settings) opens BLANK.
    func openConfigWorkspace(onboarding: Bool = false) {
        configStore.ensureInstalled()
        openLauncher(in: settingsProject.id)
        if onboarding {
            // Submitted verbatim for Claude/Codex/OpenCode alike. README.md carries both
            // the complete field reference and the shared setup workflow.
            launcherPrefill = Self.configOnboardingPrompt
        }
    }

    // MARK: history (pointer scheme, replayable on restart)

    /// Re-list the archive root. Live sessions' dirs are excluded — a session enters
    /// history the moment it stops being a running orchestrator (close or app restart).
    func refreshHistory() {
        let liveDirs = Set(allSessions.map(\.archiveDir))
        history = SessionArchive.list(root: VigilArchive.root)
            .filter { !liveDirs.contains($0.dir) }
    }

    /// Orphan-reap: on startup, before any resume, terminate agent children that a
    /// prior hard-killed (SIGKILL) Vigil left stranded — an interactive claude ignores the
    /// PTY hangup, survives as a registered background agent, and then makes `claude
    /// --resume <sid>` refuse ("running as a background agent (bg)") until killed by hand.
    /// Runs off-main (a few sysctl reads + exact-pid signals) so it never blocks the launch;
    /// finishes well before the user can click a dead row. Sessions held by a LIVE instance
    /// (this app's own not-yet-started session isn't on disk yet; another running Vigil's
    /// sessions carry a fresh live.lock) are skipped by construction — see OrphanReaper.
    private func reapOrphans() {
        let root = VigilArchive.root
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcomes = OrphanReaper.reapAll(root: root)
            // With every stray child now dead, sweep the dead sessions' codex-home
            // caches (re-downloadable ~38MB/node; live-locked sessions are skipped) —
            // catches hard-kill leftovers and history that stop() never pruned.
            let freed = CodexHomePrune.pruneAllDead(root: root)
            let n = outcomes.filter { $0.action == .reapedTERM || $0.action == .reapedKILL }.count
            DispatchQueue.main.async {
                if n > 0 { self?.showToast("Reaped \(n) orphaned agent process(es) from a prior session") }
                if freed >= 10 << 20 { self?.showToast("Reclaimed \(freed >> 20) MB of codex caches from dead sessions") }
            }
        }
    }

    /// A project group's dead rows — joined by meta.projectCwd == project.cwd.
    /// Orphans (cwd no longer among the projects) are not displayed; re-adding
    /// the folder brings them back (a known boundary). Rows the user filed
    /// away (meta.archived) leave their group — they live in the Archived section instead.
    func archivedSessions(for p: ProjectVM) -> [ArchivedSessionSummary] {
        history.filter { $0.meta?.projectCwd == p.cwd && !$0.isArchived }
    }

    /// The group's single merged column — live + dead rows, newest first. The view
    /// renders these verbatim (cap/expand is view-side state on the ProjectVM).
    func rows(for p: ProjectVM) -> [RailRow] {
        (p.sessions.map(RailRow.live) + archivedSessions(for: p).map(RailRow.dead))
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    // MARK: archive (file sessions away into the sidebar's Archived section)

    /// The Archived section's rows: every filed-away history entry, across ALL projects
    /// (orphans included — archiving is how a de-projected row stays reachable). Live
    /// sessions never appear here: archiving a live row closes it first.
    var archivedRows: [RailRow] {
        history.filter(\.isArchived).map(RailRow.dead)
    }

    // MARK: sidebar visible order (ONE source for render + ⌘1–9)
    //
    // SidebarView renders rows via rows(for:) (reverse-chron, merged live+dead, honoring
    // section-collapse / project-expand / the >5 fold / search); selectIndex must count the
    // same set in the same order, or ⌘1–9 disagrees with what's on screen. These helpers are
    // the single source both the view and selectIndex compose from, so they cannot disagree.

    /// A project group's rows after the search filter — a project-name hit keeps every row,
    /// otherwise only name-matching rows survive (live AND dead alike). Mirrors the view's
    /// old private filteredRows, now the shared one.
    func filteredRows(_ p: ProjectVM) -> [RailRow] {
        let rows = rows(for: p)
        let term = searchTerm
        if term.isEmpty || p.name.lowercased().contains(term) { return rows }
        return rows.filter { $0.name.lowercased().contains(term) }
    }

    /// The Archived section's rows after the search filter (its rows aren't project-scoped).
    func filteredArchivedRows() -> [RailRow] {
        let term = searchTerm
        return term.isEmpty ? archivedRows
                            : archivedRows.filter { $0.name.lowercased().contains(term) }
    }

    /// Is a sidebar section (projects/chats/settings/archived) expanded right now? Searching
    /// force-expands every section so hits are never hidden behind a collapsed chevron.
    func sectionOpen(_ key: String) -> Bool {
        !searchTerm.isEmpty || !collapsedSections.contains(key)
    }

    /// The subset of a group's rows the sidebar actually renders after the >5 fold — folded-
    /// away rows get no ⌘N slot. Searching lifts the cap (every hit shows). Mirrors GroupRows.
    func shownRows(_ rows: [RailRow], project p: ProjectVM) -> [RailRow] {
        let capped = searchTerm.isEmpty
        let cap = RuntimeTuning.current.sidebarCollapseThreshold
        let hidden = capped && !p.showAllRows ? max(0, rows.count - cap) : 0
        return hidden > 0 ? Array(rows.prefix(cap)) : rows
    }

    /// Projects visible in the Projects section (after the search filter), each paired with
    /// its filtered rows — a project drops out only while searching with no name-match and no
    /// row hits. Shared by the sidebar ForEach and visibleSessionRows.
    func visibleProjects() -> [(project: ProjectVM, rows: [RailRow])] {
        let term = searchTerm
        return projects.compactMap { p in
            let rows = filteredRows(p)
            if !term.isEmpty && !p.name.lowercased().contains(term) && rows.isEmpty { return nil }
            return (p, rows)
        }
    }

    /// The sidebar's session rows, top to bottom, EXACTLY as rendered — the single ordered
    /// source shared by the view and ⌘1–9 (selectIndex). Honors section collapse, project
    /// expand, the >5 fold and the live search filter. Project header rows are launch targets,
    /// not sessions, so they carry no ⌘N slot: only live/dead session rows count. Section
    /// order = Projects › Chats › Settings › Archived (the list's VStack order).
    func visibleSessionRows() -> [RailRow] {
        var out: [RailRow] = []
        if sectionOpen("projects") {
            for pv in visibleProjects() where !searchTerm.isEmpty || pv.project.expanded {
                out += shownRows(pv.rows, project: pv.project)
            }
        }
        if sectionOpen("chats") {
            out += shownRows(filteredRows(chatsProject), project: chatsProject)
        }
        if sectionOpen("settings") {
            out += shownRows(filteredRows(settingsProject), project: settingsProject)
        }
        if sectionOpen("archived") {
            out += shownRows(filteredArchivedRows(), project: archivedProject)
        }
        return out
    }

    /// Archive a LIVE session: silent shutdown first (exact rest-harvester semantics —
    /// the process dies, the session survives), then flag the dir. The row re-appears
    /// under Archived immediately; un-archiving / resuming brings it back to life-as-usual.
    func archiveSession(_ id: String) {
        guard let vm = allSessions.first(where: { $0.id == id }) else { return }
        let dir = vm.archiveDir
        closeSession(id)                          // refreshes history + persists UI state
        SessionArchive.setArchived(dir: dir, true)
        refreshHistory()
    }

    /// Archive / un-archive a dead (history) row in place — the row just changes sections.
    func setHistoryArchived(_ id: String, _ flag: Bool) {
        guard let s = history.first(where: { $0.id == id }) else { return }
        SessionArchive.setArchived(dir: s.dir, flag)
        refreshHistory()
    }

    /// Focus a history record: the center flips to the read-only HistoryPane (self-rendered
    /// transcript + Enter to resume). Any live focus is dropped (and every
    /// live-surface navigation drops the history selection — the two are mutually
    /// exclusive center states). The archive loads HERE, synchronously (small jsonl):
    /// the pane and the overlay tree card both read it; selection starts at root, and
    /// the tree card auto-expands when a previous life actually had workers.
    func openHistory(_ id: String) {
        guard let s = history.first(where: { $0.id == id }) else { return }
        selectedHistoryID = id
        activeSessionID = nil
        let a = SessionArchive.load(dir: s.dir)
        historyArchive = a
        historyNodeID = a?.tree?.rootID
        historyTreeCollapsed = (a?.tree?.count ?? 0) <= 1
        persistSidebarUI()
    }

    /// The history view's Enter key: revive the selected node — root = the
    /// session resume; a dead worker = session resume + that node's own re-incarnation
    /// (child nodes are handled the same way). No resume key → resumeSession falls back to read-only.
    func resumeSelectedHistory() {
        guard let s = selectedHistory else { return }
        resumeSession(s, focusNode: historyNodeID)
    }

    /// A clean root exit (.done and no still-running cell in the tree)
    /// = the end of the session's process side — archive it into a history row immediately; if
    /// the user is looking at it → the center switches seamlessly to that same archive's history
    /// view (Enter to come back anytime). A crash (failed/killed root) does NOT take this path:
    /// the dead-node pane keeps the frozen frame for diagnosis.
    private func watchSessionEnd(_ vm: SessionVM) {
        vm.onSessionEnded = { [weak self, weak vm] in
            guard let self, let vm else { return }
            let archiveId = (vm.archiveDir as NSString).lastPathComponent
            let wasFocused = self.activeSessionID == vm.id
            self.closeSession(vm.id)
            if wasFocused { self.openHistory(archiveId) }
        }
        // The focus check for the unseen-done blue dot — looking at it the moment it finishes = seen, so the dot won't light.
        vm.isFocused = { [weak self, weak vm] in
            guard let self, let vm else { return false }
            return self.activeSessionID == vm.id
        }
    }

    // MARK: cross-instance liveness (the one shared resume precondition)

    /// The verdict for resuming a session dir: `.free` = no live holder, resume may
    /// proceed; `.heldElsewhere` = another running app instance still owns it (live.lock:
    /// pid alive + heartbeat fresh) → refuse, read-only replay only.
    enum SessionLiveness: Equatable { case free, heldElsewhere }

    /// The shared liveness check. A dir already live IN THIS instance is never "elsewhere" —
    /// its callers short-circuit (focus the live session) before reaching this, so a live
    /// verdict here always means a *different* app instance. Internal (not private) so T1a
    /// can assert both verdicts without spinning up a real orchestrator.
    func sessionLiveness(dir: String) -> SessionLiveness {
        SessionLock.isLive(dir: dir) ? .heldElsewhere : .free
    }

    // MARK: resume (click a dead session = re-hatch in the same archive dir)

    /// Re-incarnate a dead session: root boots `claude --resume <rootSessionId>` in the
    /// original project cwd (claude's resume is cwd-scoped), the SAME archive dir keeps
    /// accumulating orchestration.jsonl. Workers do NOT mass-revive — the manager's
    /// context remembers, it re-spawns what it needs. No resume key / no cwd (old data, very
    /// short session) → the read-only HistoryPane, never a fake resume.
    /// `focusNode` (child nodes): a non-root dead worker selected in
    /// the history view — after the session revives, that node re-incarnates too (click a node
    /// to revive it, the key comes from adoptArchive; a node with no key is only selected, not
    /// faux-revived).
    func resumeSession(_ summary: ArchivedSessionSummary, focusNode: NodeID? = nil) {
        // Already live IN THIS INSTANCE (double click / stale summary) → just focus it.
        if let live = allSessions.first(where: { $0.archiveDir == summary.dir }) {
            select(session: live.id)
            return
        }
        // Cross-instance liveness gate (shared precondition): another running Vigil instance
        // still holds this session's dir live (live.lock: pid alive + fresh heartbeat) → refuse
        // resume so two apps never drive the same claude --resume into one orchestration.jsonl.
        // Fall back to read-only replay (occupied, not revivable here); a crashed instance's
        // stale lock expires and this frees up on its own. resumeNode/identity continuation ride
        // this gate transitively (both reach the live tree only AFTER this session resumes).
        if sessionLiveness(dir: summary.dir) == .heldElsewhere {
            openHistory(summary.id)
            showToast("Session is held by another Vigil instance; read-only")
            return
        }
        guard let meta = summary.meta, let sid = meta.rootSessionId,
              let cwd = meta.projectCwd else {
            openHistory(summary.id)
            return
        }
        // Reviving an archived row un-archives it — a live session always belongs
        // to its project group, and the flag must not linger for its next death.
        if summary.isArchived { SessionArchive.setArchived(dir: summary.dir, false) }
        seq += 1
        let project = allProjects.first { $0.cwd == cwd }
        let vm = SessionVM(id: "s\(seq)", name: summary.name, rootCwd: cwd, initialTask: "",
                           access: defaultAccess, model: meta.model,
                           projectName: project?.name ?? meta.projectName,
                           agentKey: meta.agent,
                           userConfigDir: configStore.dir,
                           archiveDir: summary.dir, resumeSessionId: sid,
                           createdAt: meta.createdAt,
                           nameIsCustom: meta.nameIsCustom ?? false,
                           terminalTheme: Self.agentTerminalTheme,
                           terminalColorSource: terminalColorSource)
        // orphans (their project row was removed) no longer show, but resume still needs a
        // landing spot → the chats bucket; cwd stays the original directory (claude resume is
        // cwd-scoped).
        watchSessionEnd(vm)
        let p = project ?? chatsProject
        p.sessions.insert(vm, at: 0)
        p.expanded = true
        currentProjectID = p.id
        activeSessionID = vm.id
        selectedHistoryID = nil
        if let n = focusNode, n != vm.store.tree.rootID, vm.store.tree[n] != nil {
            vm.select(n)
            if vm.canResume(n) { vm.resumeNode(n) }
        }
        refreshHistory()                   // the revived dir leaves the history list
        persistSidebarUI()
    }

    // MARK: rest harvester (the automatic "silent close" path)

    /// rest (no attention, no running/starting) + unfocused + sustained ≥N minutes → silent
    /// shutdown. The row survives as history (meta.rootSessionId is there), click to resume —
    /// the process dies, the session lives on.
    /// N = runtime.json harvestAfterMinutes (default 60; <=0 = don't harvest).
    static var harvestAfter: TimeInterval {
        TimeInterval(RuntimeTuning.current.harvestAfterMinutes) * 60
    }
    /// Blind-spot fallback threshold (hours→seconds); <=0 = off. Applies only to trees stuck in attention/stalled with no live node.
    static var harvestStuckAfter: TimeInterval {
        TimeInterval(RuntimeTuning.current.harvestStuckAfterHours) * 3600
    }
    /// LRU clock: the moment a session enters rest = its last-active moment; shared
    /// by rest harvesting (entry ②) and count-cap eviction (entry ①). Waking/focusing clears it.
    private var restSince: [String: Date] = [:]
    /// Blind-spot fallback clock: the start of a tree lingering in attention/stalled with no running/starting node.
    private var stuckSince: [String: Date] = [:]
    private var harvestTask: Task<Void, Never>?

    /// Refresh every live session's live.lock heartbeat on the harvester tick — one
    /// shared 60s timer for both the reap clock and the liveness lease (saves a timer). A
    /// session closed this same sweep already released its lock (orch.stop) and left
    /// allSessions, so we never re-write a just-freed lock.
    private func refreshLiveLocks() {
        for vm in allSessions { vm.orch.touchLiveLock() }
    }

    private func startHarvester() {
        guard harvestTask == nil else { return }
        harvestTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self else { return }
                self.refreshLiveLocks()          // keep our sessions' live.lock fresh
                self.harvestRestSessions(now: Date())
            }
        }
    }

    /// True iff any node is actively running/starting — the red line for BOTH harvest
    /// paths and the LRU eviction: a tree with a live node is NEVER auto-closed.
    private func hasLiveNode(_ vm: SessionVM) -> Bool {
        vm.store.tree.nodes.values.contains { $0.status == .running || $0.status == .starting }
    }

    /// One sweep of the harvest clock. Internal (not private) so T1a can drive time.
    /// Two paths: (②) clean-rest sessions past `harvestAfter`; (blind-spot) sessions stuck
    /// in attention/stalled with NO live node past `harvestStuckAfter`. Live trees and the
    /// focused session are spared on both paths.
    func harvestRestSessions(now: Date) {
        for vm in allSessions {
            let ind = sessionIndicator(badge: vm.badge, tree: vm.store.tree)
            let focused = vm.id == activeSessionID

            // ② clean-rest clock — also the LRU key for the live-session cap.
            if ind == .rest && !focused {
                let since = restSince[vm.id] ?? now
                restSince[vm.id] = since
                if Self.harvestAfter > 0, now.timeIntervalSince(since) >= Self.harvestAfter {
                    restSince[vm.id] = nil; stuckSince[vm.id] = nil
                    closeSession(vm.id)    // silent: archive stays, resume brings it back
                    continue
                }
            } else {
                restSince[vm.id] = nil     // woke up / got focus / went busy → clock resets
            }

            // Blind-spot fallback — attention/stalled that never clears, but only when nothing is
            // actually running (hasLiveNode == false). Never touches a live tree.
            if ind == .attention && !focused && !hasLiveNode(vm) {
                let since = stuckSince[vm.id] ?? now
                stuckSince[vm.id] = since
                if Self.harvestStuckAfter > 0,
                   now.timeIntervalSince(since) >= Self.harvestStuckAfter {
                    restSince[vm.id] = nil; stuckSince[vm.id] = nil
                    closeSession(vm.id)
                    continue
                }
            } else {
                stuckSince[vm.id] = nil
            }
        }
        let live = Set(allSessions.map(\.id))
        restSince = restSince.filter { live.contains($0.key) }
        stuckSince = stuckSince.filter { live.contains($0.key) }
    }

    /// Entry ①: enforce `maxLiveSessions`. Called when a new root session is spawned;
    /// if the live-session count exceeds the cap, evict the longest-resting (oldest
    /// restSince) non-focused rest sessions — same silent semantics as the rest harvester
    /// (archive stays, resumable). Live/attention/focused trees are NEVER evicted (a
    /// selling-point red line); when nothing evictable remains we don't block the spawn, just toast.
    /// Internal (not private) so T1a can drive time.
    func enforceLiveSessionCap(now: Date) {
        let cap = RuntimeTuning.current.maxLiveSessions
        guard cap > 0 else { return }                 // <=0 = unlimited, bypass
        var overflow = allSessions.count - cap
        guard overflow > 0 else { return }

        // Evictable = clean-rest, non-focused, no live node; oldest restSince first.
        let evictable = allSessions
            .filter { vm in
                vm.id != activeSessionID
                    && !hasLiveNode(vm)
                    && sessionIndicator(badge: vm.badge, tree: vm.store.tree) == .rest
            }
            .sorted { (restSince[$0.id] ?? now) < (restSince[$1.id] ?? now) }

        for vm in evictable where overflow > 0 {
            restSince[vm.id] = nil; stuckSince[vm.id] = nil
            closeSession(vm.id)
            overflow -= 1
        }
        if overflow > 0 {
            showToast("\(allSessions.count) live trees over the cap and all busy")
        }
    }

    private func persistProjects() {
        guard !UITestSupport.enabled else { return }   // UI tests never pollute real defaults
        let recs = projects.map { ProjectRecord(id: $0.id, name: $0.name, cwd: $0.cwd) }
        if let data = try? JSONEncoder().encode(recs) {
            UserDefaults.standard.set(data, forKey: Self.projectsKey)
        }
    }

    private func restoreProjects() {
        guard let data = UserDefaults.standard.data(forKey: Self.projectsKey),
              let recs = try? JSONDecoder().decode([ProjectRecord].self, from: data) else { return }
        // A project whose cwd is the config dir does not show under Projects — its
        // sessions/history live in the built-in Settings section instead.
        projects = recs.filter { $0.cwd != configStore.dir }
            .map { ProjectVM(id: $0.id, name: $0.name, cwd: $0.cwd) }
    }

    // MARK: projects

    /// NSOpenPanel → ProjectVM (name = directory basename), persist, open its launcher.
    func addProjectViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add project"
        panel.message = "Choose a project directory"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let cwd = url.path
        if let existing = allProjects.first(where: { $0.cwd == cwd }) {
            openLauncher(in: existing.id)    // config dir lands in the built-in Settings section
            showToast("Project already exists")
            return
        }
        let p = ProjectVM(id: UUID().uuidString, name: url.lastPathComponent, cwd: cwd)
        projects.append(p)
        persistProjects()
        openLauncher(in: p.id)
    }

    /// Switch to a project: has sessions → focus the first; none → launcher.
    func selectProject(_ id: String) {
        guard let p = allProjects.first(where: { $0.id == id }) else { return }
        currentProjectID = id
        p.expanded = true
        activeSessionID = p.sessions.first?.id
        selectedHistoryID = nil
        persistSidebarUI()
    }

    /// "New chat": launcher in the current project; no current →
    /// the built-in Chats bucket.
    func newChat() {
        openLauncher(in: currentProjectID ?? chatsProject.id)
    }

    /// Show the launcher in a project (new-task state; no session focused). The
    /// onboarding prefill is workspace-bound: any other launcher opens blank.
    /// Built-in buckets materialize their cwd here (the Chats dir is created only on first use).
    func openLauncher(in projectID: String) {
        guard let p = allProjects.first(where: { $0.id == projectID }) else { return }
        if p.id == chatsProject.id || p.id == settingsProject.id {
            try? FileManager.default.createDirectory(atPath: p.cwd,
                                                     withIntermediateDirectories: true)
        }
        launcherPrefill = nil
        currentProjectID = projectID
        p.expanded = true
        activeSessionID = nil
        selectedHistoryID = nil
        persistSidebarUI()
    }

    // MARK: sessions

    /// Launcher submit: name = first 13 chars of the task ("…" when longer, the "new task"
    /// placeholder when empty); insert at the head of the project's sessions; focus it.
    /// Honesty boundary (§F1): only entries whose CLI kind has a wired harness are
    /// launchable; refuse custom/unknown kinds instead of silently substituting another
    /// agent. `model` nil lets the selected CLI use its own default.
    /// `agent` is an agents.json registry key.
    /// Settings-workspace tasks are transparently pointed at the universal README even
    /// though the reconfigure launcher itself intentionally opens blank.
    @discardableResult
    func launchSession(in projectID: String, task: String,
                       agent: String, access: PermissionMode = .bypass,
                       model: String? = nil) -> SessionVM? {
        guard let entry = agentEntries.first(where: { $0.key == agent }), entry.usable
        else { return nil }
        guard let p = allProjects.first(where: { $0.id == projectID }) else { return nil }
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = t.isEmpty ? "New task" : (t.count > 13 ? String(t.prefix(13)) + "…" : t)
        let initialTask = p.id == settingsProject.id ? Self.taskForConfigWorkspace(t) : t
        seq += 1
        let vm = SessionVM(id: "s\(seq)", name: name, rootCwd: p.cwd,
                           initialTask: initialTask,
                           access: access, model: model,
                           projectName: p.name,
                           agentKey: agent, userConfigDir: configStore.dir,
                           terminalTheme: Self.agentTerminalTheme,
                           terminalColorSource: terminalColorSource)
        watchSessionEnd(vm)
        p.sessions.insert(vm, at: 0)
        p.expanded = true
        currentProjectID = projectID
        activeSessionID = vm.id
        showToast("Dispatched manager in \(p.name) · \(agent)")
        enforceLiveSessionCap(now: Date())   // entry ①: over the cap → evict the longest-idle rest tree
        persistSidebarUI()
        return vm
    }

    /// Focus a session; also set the current project when it lives under one.
    func select(session id: String) {
        guard let vm = allSessions.first(where: { $0.id == id }) else { return }
        if let p = allProjects.first(where: { $0.sessions.contains { $0.id == id } }) {
            currentProjectID = p.id
            p.expanded = true
        }
        activeSessionID = id
        selectedHistoryID = nil
        vm.markCompletionSeen()              // one click, the blue dot disappears
        persistSidebarUI()
    }

    /// A notification card was clicked: focus its session AND the
    /// source node's terminal — cross-session jump in one tap. Cards are perm events
    /// only: click never clears — the card dies only when the approval actually resolves.
    func openNotice(sessionID: String, node: NodeID) {
        guard let vm = allSessions.first(where: { $0.id == sessionID }) else { return }
        select(session: sessionID)
        vm.select(node)
    }

    /// ⌘1–9: jump to the Nth session row the sidebar shows, top to bottom (1-based). Behaves
    /// exactly like clicking that row — a live row switches to it, a dead row opens its
    /// read-only history view — with NO liveness filtering. The
    /// order IS the render order (visibleSessionRows), so what the user counts on screen and
    /// what ⌘N picks can never disagree. Out of range = no-op.
    func selectIndex(_ n: Int) {
        let rows = visibleSessionRows()
        guard n >= 1, n <= rows.count else { return }
        switch rows[n - 1] {
        case .live(let s): select(session: s.id)
        case .dead(let d): openHistory(d.id)
        }
    }

    // MARK: keyboard navigation (registered in one place, App.swift VigilKeymap)

    /// ⌃⌘] / ⌃⌘[: move focus to the next/prev session in sidebar order (wraps). No
    /// session focused → focus the first; empty → no-op.
    func selectAdjacentSession(_ delta: Int) {
        let all = allSessions
        guard !all.isEmpty else { return }
        guard let cur = activeSessionID,
              let i = all.firstIndex(where: { $0.id == cur }) else {
            select(session: all[0].id)
            return
        }
        let n = ((i + delta) % all.count + all.count) % all.count
        select(session: all[n].id)
    }

    /// ⌘⇧] / ⌘⇧[: move the active session's node selection to the next/prev node in the
    /// SAME order the tree panel shows (DFS, honoring hide-finished), wrapping. Terminal
    /// follows the selection (TerminalPane reads selectedNode). No active session → no-op.
    func selectAdjacentNode(_ delta: Int) {
        guard let vm = activeSession else { return }
        let ids = flattenTree(vm.store.tree, hideFinished: vm.hideFinishedNodes).map(\.node.id)
        guard !ids.isEmpty else { return }
        let i = ids.firstIndex(of: vm.selectedID) ?? 0
        let n = ((i + delta) % ids.count + ids.count) % ids.count
        vm.select(ids[n])
    }

    /// ⌘J: focus the middle terminal (the only input surface) — makes the active
    /// node's terminal view first responder so keystrokes reach the agent TUI directly.
    /// No live terminal (launcher / dead node / ghost) → no-op.
    func focusTerminalInput() {
        guard let vm = activeSession, let view = vm.terminalView(vm.selectedID) else { return }
        view.window?.makeFirstResponder(view)
    }

    /// The keyboard version of the notification card's "bring you to the scene": every node that
    /// currently wants a human — reusing the ONE central attention truth (SessionStore.
    /// attentionStatus drives node.status waiting/stalled/queued; notices drive the badge),
    /// never a second derivation. Stable order: session order × tree order, so ⌘⇧U cycles
    /// deterministically.
    func attentionTargets() -> [(session: String, node: NodeID)] {
        var out: [(String, NodeID)] = []
        for vm in allSessions {
            guard sessionIndicator(badge: vm.badge, tree: vm.store.tree) == .attention else { continue }
            for row in flattenTree(vm.store.tree) {
                let s = row.node.status
                if s == .waiting || s == .stalled || s == .queued || vm.hasNotice(row.node.id) {
                    out.append((vm.id, row.node.id))
                }
            }
        }
        return out
    }

    /// ⌘⇧U: jump to the attention target (perm/stalled/queued/notice). If the current
    /// focus already sits on one, advance to the next (cycle through them); else the
    /// first. Nothing pending → a quiet toast, no navigation.
    func jumpToLatestAttention() {
        let targets = attentionTargets()
        guard !targets.isEmpty else { showToast("No pending alerts"); return }
        let curIdx = targets.firstIndex {
            $0.session == activeSessionID && activeSession?.selectedID == $0.node
        }
        let next = curIdx.map { targets[($0 + 1) % targets.count] } ?? targets[0]
        openNotice(sessionID: next.session, node: next.node)
    }

    /// ⌘⇧W: close (silent shutdown) the ACTIVE session — same semantics as the rest
    /// harvester, NOT a kill: the archive stays, the row survives as resumable history.
    func closeActiveSession() {
        guard let id = activeSessionID else { return }
        closeSession(id)
    }

    /// ⌘⇧R: rename the active session (manual custom-title over AutoNamer). A small
    /// native prompt — Vigil naming its OWN row, not an agent interaction.
    func renameActiveSession() {
        guard let vm = activeSession else { return }
        let alert = NSAlert()
        alert.messageText = "Rename session"
        alert.informativeText = "After you name it manually, auto-naming (AutoNamer) will no longer override it."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = vm.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            vm.renameByUser(field.stringValue)
            persistSidebarUI()
        }
    }

    /// Tear down a session's orchestrator FIRST, then drop it; focus a neighbour, or
    /// fall back to the project's launcher when it was the last one. There is
    /// no user-facing entry point — callers are the rest harvester and tests; the
    /// archive stays on disk, so the session survives as a resumable history row.
    func closeSession(_ id: String) {
        guard let p = allProjects.first(where: { $0.sessions.contains { $0.id == id } }),
              let idx = p.sessions.firstIndex(where: { $0.id == id }) else { return }
        p.sessions[idx].shutdown()
        p.sessions.remove(at: idx)
        if activeSessionID == id {
            if p.sessions.isEmpty {
                openLauncher(in: p.id)
            } else {
                let neighbour = p.sessions[min(idx, p.sessions.count - 1)]
                activeSessionID = neighbour.id
                neighbour.markCompletionSeen()   // focusing after the fact also counts as "seen" — the blue dot dies
            }
        }
        refreshHistory()                     // the closed session's archive is now history
        persistSidebarUI()
    }

    // MARK: chrome

    /// Sidebar collapse/expand — always through here so both call sites (sidebar's own
    /// button + the top-bar expand button) share the measured motion (VGMotion.sidebar).
    func toggleSidebar() {
        withAnimation(VGMotion.sidebar) { railCollapsed.toggle() }
        persistSidebarUI()
    }

    // MARK: sidebar UI state (collapse/expand/selection state persisted — see SidebarUIRecord)

    private static let sidebarUIKey = "vigil.sidebarUI.v1"

    /// Every bucket carrying persistable fold state: the session buckets + the Archived
    /// pseudo-bucket (it holds no sessions, but its show-all fold should survive).
    private var foldableProjects: [ProjectVM] { allProjects + [archivedProject] }

    /// Current fold/selection state as one record (pure derivation — T1a testable).
    func sidebarUISnapshot() -> SidebarUIRecord {
        SidebarUIRecord(
            collapsedProjects: foldableProjects.filter { !$0.expanded }.map(\.id),
            showAllProjects: foldableProjects.filter(\.showAllRows).map(\.id),
            currentProjectID: currentProjectID,
            selectedArchiveID: selectedHistoryID
                ?? activeSession.map { ($0.archiveDir as NSString).lastPathComponent },
            railCollapsed: railCollapsed)
    }

    /// Replay a record onto freshly restored projects/history. Stale ids (project
    /// removed, archive cleaned) are silently ignored. Navigation first, folds LAST —
    /// openLauncher force-expands its project, and the recorded fold must win (the
    /// record was taken after that same forcing at the time). Ends with one persist so
    /// the stored record never lags the mid-restore writes from openLauncher/openHistory.
    func applySidebarUI(_ r: SidebarUIRecord) {
        railCollapsed = r.railCollapsed      // during app startup, no motion needed, set it directly
        if let pid = r.currentProjectID, allProjects.contains(where: { $0.id == pid }) {
            openLauncher(in: pid)
        }
        if let hid = r.selectedArchiveID, history.contains(where: { $0.id == hid }) {
            openHistory(hid)
        }
        for p in foldableProjects {
            p.expanded = !r.collapsedProjects.contains(p.id)
            p.showAllRows = r.showAllProjects.contains(p.id)
        }
        persistSidebarUI()
    }

    /// Called by EVERY mutation that moves a fold or the selection (cheap: one small
    /// JSON blob). Same UITest seam as the sibling persist methods.
    func persistSidebarUI() {
        guard !UITestSupport.enabled else { return }
        if let data = try? JSONEncoder().encode(sidebarUISnapshot()) {
            UserDefaults.standard.set(data, forKey: Self.sidebarUIKey)
        }
    }

    private func restoreSidebarUI() {
        guard let data = UserDefaults.standard.data(forKey: Self.sidebarUIKey),
              let r = try? JSONDecoder().decode(SidebarUIRecord.self, from: data)
        else { return }
        applySidebarUI(r)
    }

    /// Project chevron click (view calls in, never mutates — the iron law; also the
    /// persistence choke point for the fold).
    func toggleProjectExpanded(_ p: ProjectVM) {
        p.expanded.toggle()
        persistSidebarUI()
    }

    /// "show all (N)" / "collapse" tail row — same choke-point rationale.
    func toggleShowAllRows(_ p: ProjectVM) {
        p.showAllRows.toggle()
        persistSidebarUI()
    }

    // MARK: sidebar sections (all three section headers — projects/chats/settings — can collapse, state goes to UserDefaults)

    private static let sectionsKey = "vigil.sectionsCollapsed.v1"

    func toggleSection(_ key: String) {
        if collapsedSections.contains(key) { collapsedSections.remove(key) }
        else { collapsedSections.insert(key) }
        guard !UITestSupport.enabled else { return }
        UserDefaults.standard.set(Array(collapsedSections), forKey: Self.sectionsKey)
    }

    private func restoreCollapsedSections() {
        guard let arr = UserDefaults.standard.stringArray(forKey: Self.sectionsKey)
        else { return }
        collapsedSections = Set(arr)
    }

    // MARK: sidebar width (drag-resizable)

    private static let railWidthKey = "vigil.railWidth.v1"
    static let railWidthRange: ClosedRange<CGFloat> = 180...420

    /// Live during the drag: clamp only — no animation (the hand IS the animation).
    func setRailWidth(_ w: CGFloat) {
        railWidth = min(Self.railWidthRange.upperBound,
                        max(Self.railWidthRange.lowerBound, w))
    }

    func persistRailWidth() {
        guard !UITestSupport.enabled else { return }
        UserDefaults.standard.set(Double(railWidth), forKey: Self.railWidthKey)
    }

    private func restoreRailWidth() {
        guard let v = UserDefaults.standard.object(forKey: Self.railWidthKey) as? Double
        else { return }
        setRailWidth(CGFloat(v))
    }

    // MARK: bottom terminal panel height (shell panel, drag-resizable)

    private static let bottomShellHeightKey = "vigil.bottomShellHeight.v1"
    static let bottomShellHeightRange: ClosedRange<CGFloat> = 120...640

    /// Live during the drag: clamp only (the hand is the animation).
    func setBottomShellHeight(_ h: CGFloat) {
        bottomShellHeight = min(Self.bottomShellHeightRange.upperBound,
                                max(Self.bottomShellHeightRange.lowerBound, h))
    }

    func persistBottomShellHeight() {
        guard !UITestSupport.enabled else { return }
        UserDefaults.standard.set(Double(bottomShellHeight), forKey: Self.bottomShellHeightKey)
    }

    private func restoreBottomShellHeight() {
        guard let v = UserDefaults.standard.object(forKey: Self.bottomShellHeightKey) as? Double
        else { return }
        setBottomShellHeight(CGFloat(v))
    }

    func showToast(_ msg: String) {
        toast = msg
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            self?.toast = nil
        }
    }

    /// Theme switches must not animate (SPEC §0.6 — prevents the token-crossfade flash).
    func pick(theme t: VGTheme) {
        withTransaction(\.disablesAnimations, true) { theme = t }
    }
    func pick(accent a: VGAccent) { accent = a }

    // MARK: - follow-system appearance

    /// Recompute the effective theme from the current preference + live OS scheme, and push it
    /// (diff-guarded — `pick` no-ops via the SwiftUI equality on `theme`, and VGGhosttyTheme's
    /// own guard covers the terminal). Called on every applyConfig and on every OS flip.
    func resolveTheme() {
        let t = themePreference.resolve(systemIsDark: appearanceSource.isDark)
        if theme != t { pick(theme: t) }
    }

    /// The OS appearance changed (KVO). Only re-resolves while following system — a pin is
    /// deliberately deaf to system flips.
    private func systemAppearanceChanged() {
        guard themePreference.followsSystem else { return }
        resolveTheme()
    }
}
