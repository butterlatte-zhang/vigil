import Foundation
import VigilCore

/// Late-bound Effect sink so SessionStore (which takes `perform` at init) and the
/// Orchestrator (which needs the store) can reference each other without an init cycle.
final class EffectRouter: @unchecked Sendable {
    var sink: (@MainActor (Effect) -> Void)?
}

/// The L3+L4 assembly (DOCTRINE §1): owns the SessionStore, both UDS gateways, the cell
/// registry, the harness, and the per-session socket/work dirs. It is the store's
/// `perform` target — Effects flow OUT here into real cells, UDS deliveries, and routing.
/// State still only enters via Command and leaves via Effect (the iron law); this class
/// is just where Effects meet the world.
@MainActor
public final class Orchestrator {
    public let store: SessionStore
    public let registry = CellRegistry()
    public let sessionDir: String

    private let harness: Harness          // launches CHILD cells (claude agents)
    private let rootHarness: Harness?     // launches the ROOT cell (e.g. a pre-seasoned shell)
    private let backendFactory: @MainActor (NodeID) -> TerminalBackend
    private let pending = PendingReplies()
    private let router = EffectRouter()

    /// Dead-node afterlife, live-session side: node → CLI transcript pointer (the
    /// same join key the archive replays from agent_prompt lines) …
    public private(set) var transcripts: [NodeID: String] = [:]
    /// … and each dead cell's last rendered frame, captured at teardown before the
    /// backend leaves the registry — the fallback when the transcript pointer dangles.
    public private(set) var frozenScreens: [NodeID: String] = [:]
    /// Node → CLI session id (hook payload, newest wins — resume forks a new
    /// id). The root's entry feeds meta.rootSessionId, the resume key.
    public private(set) var sessionIds: [NodeID: String] = [:]
    /// Node → resolved CLI family, captured at launch. Drives kind-specific
    /// observability — opencode has no external JSONL to tail-read (SQLite store), so its
    /// send-delivery confirmation degrades honestly instead of false-failing (registerDelivery).
    public private(set) var nodeKinds: [NodeID: AgentCLIKind] = [:]

    /// Fires (once per connecting node) when an agent connects to the MCP channel — Vigil's
    /// "agent is online" signal for auto-orchestration of a user-launched session.
    public var onAgentConnected: (@MainActor (NodeID) -> Void)?
    /// A user prompt was submitted to the agent (UserPromptSubmit hook) — feeds auto-naming.
    public var onAgentPrompt: (@MainActor (NodeID, [String: Any]) -> Void)?
    /// The agent's turn ended (Stop hook) — the auto-namer re-reads here: claude writes
    /// its ai-title during the turn, so a first turn has no title at prompt time yet.
    public var onAgentStop: (@MainActor (NodeID, [String: Any]) -> Void)?
    /// The captured MAIN codex rollout path for a node (fires on every codex capture, incl.
    /// turnEnded — codex fires NO stop hook so onAgentStop never runs for it). Feeds codex's honest
    /// fallback naming (first user_message of the main session; no ai-title / export title source).
    public var onCodexRollout: (@MainActor (NodeID, String) -> Void)?
    /// Opencode transcript export bridge — the app layer injects the `opencode export`
    /// subprocess (off-main, binary-agnostic runtime), returning the raw export JSON for a
    /// session id. nil in tests that drive `recordOpenCodeCapture` directly.
    public var openCodeExporter: (@Sendable (String) async -> String?)?
    /// A root self-named its session via the `rename` MCP tool. The app layer applies the
    /// name to the session label and pins it as user-chosen so later automatic naming yields.
    public var onSessionRename: (@MainActor (NodeID, String) -> Void)?

    private let sockDir: String       // SHORT path: UDS sun_path caps at ~104 chars
    public let hookSock: String       // per-session UDS endpoints (shared with the PATH shim)
    public let mcpSock: String
    private let configRoot: String
    private let workRoot: String
    private let rootCwd: String?      // optional cwd for the ROOT cell (e.g. ~ for a plain terminal)

    private var hookListener: UDSListener?
    private var mcpListener: UDSListener?
    /// Scrape fallback for the deny blind spot — internal for tests.
    private(set) var permWatcher: PermWatcher?
    private(set) var turnWatcher: TurnWatcher?
    /// Send-delivery reconciler — internal so tests drive tick()/register.
    private(set) var deliveryTracker: DeliveryTracker?
    /// Delivery-tracker knobs, applied when the tracker is stood up in start(). Internal so
    /// tests can zero the grace (deterministic reinject) and shrink the retry budget.
    /// nil (product default) = runtime.json deliveryMaxAttempts / deliveryReinjectGrace-
    /// Seconds, point-read at tracker stand-up.
    var deliveryTuning: (maxAttempts: Int?, grace: TimeInterval?) = (nil, nil)
    /// Per-node transcript byte offset already scanned for API errors, so
    /// each error line is reported exactly once (advanced on every turn-end check).
    private var apiScanOffset: [NodeID: UInt64] = [:]

    /// Nodes that routed a rollup (report) UP since their CURRENT turn opened —
    /// set on `.rollup`, cleared on `.turnStarted`. Lets the API-error turn-death
    /// notification tell the truth (report already delivered → usually no re-run) instead
    /// of unconditionally claiming "no report received" when a report was in fact received:
    /// a report can be delivered moments before the turn's wrap-up hits an API error, and
    /// the manager must not be told to re-run already-finished work.
    private var reportedSinceTurnStart: Set<NodeID> = []

    /// Report watchdog: nodes Vigil has an OUTSTANDING real delivery to (initial task prompt
    /// or a `send`, confirmed via the same agent_prompt signal AutoNamer relies on — a real
    /// prompt reached the agent's context) that hasn't been answered by a report yet.
    /// Per-delivery, not lifetime: cleared on `.rollup` (a report answers the delivery it was
    /// asked for). Armed from TWO sites: `recordAgentPrompt` (claude's hook payload text, which
    /// skips the watchdog's own reminder and a `<task-notification>` — system-originated, not a
    /// manager ask) and the `.route` effect handler's delivered-message branch (kind-agnostic —
    /// the only re-arm path for codex/opencode, whose capture sites arm once per sid/pointer
    /// change, not per delivery). Without the per-delivery clearing a worker's own silent
    /// continuation turns after it already reported would keep getting nagged forever (the
    /// lifetime-set bug this replaced). A bare `--resume` with nobody talking to it never sets
    /// this, so a later idle turnEnded on it is correctly not a "silent worker" — Vigil never
    /// asked it anything.
    private var watchdogDelivered: Set<NodeID> = []
    /// A reminder was nudged into this node and no report() has arrived since —
    /// the ping-pong guard. Cleared the moment a `.rollup` lands (checkReportWatchdog's
    /// bounding invariant: never a second unanswered nudge in flight).
    private var watchdogReminderOutstanding: Set<NodeID> = []
    /// One deferred watchdog decision per node, armed by a silent `turnEnded` and cancelled by
    /// the next `turnStarted` (mirrors `spawnWatchdogs`). Deferred because claude's Stop hook
    /// fires BEFORE it appends the `turn_duration` system line the background-agent exemption
    /// reads (verified same-second on real transcripts) — firing immediately would race it.
    private var pendingWatchdogChecks: [NodeID: DispatchWorkItem] = [:]
    /// Grace before a deferred watchdog decision fires — long enough for claude to have
    /// written `turn_duration` after the Stop hook. Test-injectable, like `deliveryTuning`.
    var watchdogGraceSeconds: TimeInterval = 2.0

    /// Who killed whom (send-in-flight → target killed), so the delivery-failure
    /// receipt stays honest. A send whose target died is a terminal dead-end — "you may need
    /// to resend" is misleading (resend to a node that no longer exists?), and when the caller
    /// IS the killer the receipt is pure noise → stay silent. Attributed at the kill request.
    private var killedBy: [NodeID: NodeID] = [:]

    /// Non-nil = this session's ROOT cell continues an earlier CLI
    /// conversation (`--resume`); the sid also seeds the live sessionIds map.
    private let resumeRootSessionId: String?

    /// How long a real new spawn may go without agent_connected before it
    /// is honestly reported stalled. Injectable so T1 can drive the window in ms;
    /// nil (product default) = runtime.json spawnStallSeconds, read at watchdog arm
    /// (file edits apply to the next armed spawn).
    private let spawnStallOverride: TimeInterval?
    var spawnStallSeconds: TimeInterval {
        spawnStallOverride ?? TimeInterval(RuntimeTuning.current.spawnStallSeconds)
    }

    /// Inject pacing knobs, applied to every cell launched from here. Internal so
    /// tests can shrink the clocks. maxWait nil (product default) = runtime.json
    /// injectHoldTimeoutSeconds, point-read at cell birth.
    var injectTuning: (poll: TimeInterval, maxWait: TimeInterval?, noticeDelay: TimeInterval)
        = (0.5, nil, 2.0)

    public init(rootNode: Node, harness: Harness, sessionDir: String,
                rootCwd: String? = nil, rootHarness: Harness? = nil,
                resumeRootSessionId: String? = nil,
                spawnStallSeconds: TimeInterval? = nil,
                backendFactory: @escaping @MainActor (NodeID) -> TerminalBackend) {
        self.harness = harness
        self.rootHarness = rootHarness
        self.sessionDir = sessionDir
        self.rootCwd = rootCwd
        self.resumeRootSessionId = resumeRootSessionId
        self.spawnStallOverride = spawnStallSeconds
        self.backendFactory = backendFactory
        // Sockets must live on a SHORT path (sockaddr_un.sun_path is ~104 bytes); a deep
        // temp sessionDir would overflow it. Keep config/work under sessionDir, sockets in /tmp.
        let token = String(UUID().uuidString.prefix(8))
        let sd = "/tmp/vigil-\(getpid())-\(token)"
        self.sockDir = sd
        self.hookSock = sd + "/hook.sock"
        self.mcpSock = sd + "/mcp.sock"
        self.configRoot = (sessionDir as NSString).appendingPathComponent("config")
        self.workRoot = (sessionDir as NSString).appendingPathComponent("work")

        let router = self.router
        self.store = SessionStore(root: rootNode, perform: { eff in router.sink?(eff) })
        router.sink = { [weak self] eff in self?.perform(eff) }
    }

    /// Stand up the session: dirs, both UDS gateways, then the root cell (DOCTRINE §2.7).
    public func start(rootTask: String) throws {
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Claim the session dir the moment it becomes live. The heartbeat is then
        // refreshed by the host's 60s harvester (touchLiveLock); removed in stop().
        SessionLock.write(dir: sessionDir)
        try FileManager.default.createDirectory(atPath: sockDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        for d in [configRoot, workRoot] {
            FileIO.createDirectory(d, report: ioReport)   // leave a trace on failure instead of swallowing it silently
        }

        let emit: @Sendable (Command) -> Void = { [weak self] cmd in
            Task { @MainActor in self?.receive(cmd) }
        }
        let hookGW = HookGateway(emit: emit, onPrompt: { [weak self] node, payload in
            Task { @MainActor in
                self?.recordAgentPrompt(node, payload: payload)   // node→transcript join key
                self?.onAgentPrompt?(node, payload)
            }
        }, onStop: { [weak self] node, payload in
            Task { @MainActor in
                self?.onAgentStop?(node, payload)
                self?.captureOpenCodeSession(node)   // turn closed → capture the opencode transcript snapshot
            }
        })
        let mcpSrv = MCPToolServer(emit: emit, pending: pending, onConnect: { [weak self] node in
            Task { @MainActor in
                self?.orchLog("agent_connected", ["node": node.raw])
                self?.noteAgentConnected(node)      // stop the clock / recover a stall
                self?.onAgentConnected?(node)
            }
        }, onRename: { [weak self] node, name in
            Task { @MainActor in self?.onSessionRename?(node, name) }
        }, nodeInfo: { [weak self] node in
            // Role-scoped tool surface: the server asks the live tree who a
            // connection is before listing/serving tools. kind gates the codex-root rename tool.
            // Bind the weak capture to a local `let` first: a weak `self` is a mutable var, and
            // referencing it from inside the @Sendable MainActor.run closure is a Swift 6 error.
            let orch = self
            return await MainActor.run {
                guard let orch, let n = orch.store.tree[node] else { return nil }
                return (n.role, node == orch.store.tree.rootID, orch.nodeKinds[node] ?? .claude)
            }
        }, spawnModelGuard: { [weak self] role, model in
            // The child harness's own guard (DispatchHarness → HarnessResolve), asked with
            // the SAME cwd launchCell resolves a spawned child against (every node runs at
            // rootCwd; only the ephemeral no-project scratch path differs, and it has no
            // per-project .vigil/roles.json to matter). Spawned children always launch through
            // `harness`, never `rootHarness` (see launchCell), so that is the one asked here.
            let orch = self
            return await MainActor.run {
                guard let orch else { return nil }
                let cwd = orch.rootCwd ?? orch.workRoot
                return orch.harness.spawnModelGuardError(model: model, role: role, cwd: cwd)
            }
        })

        let hl = UDSListener(path: hookSock)
        try hl.start { ch in Task { await hookGW.handle(ch) } }
        self.hookListener = hl

        let ml = UDSListener(path: mcpSock)
        try ml.start { ch in Task { await mcpSrv.handle(ch) } }
        self.mcpListener = ml

        // Deny blind spot fallback: poll only nodes holding an unresolved
        // permission card; world reads → Command ingress, no store side channel.
        let watcher = PermWatcher(
            notices: { [weak self] in self?.store.notices ?? [] },
            screen: { [weak self] id in self?.registry.backend(id)?.renderScreen() },
            emit: emit)
        watcher.start()
        self.permWatcher = watcher

        // Interrupt blind spot fallback: ESC/deny ends the turn with NO Stop
        // hook → the node would spin forever. Poll only open-turn running nodes; the
        // running anchor leaving the screen = the turn is over (Command ingress, no
        // side channel — the same iron-law stance as PermWatcher).
        let tw = TurnWatcher(
            openTurnNodes: { [weak self] in self?.store.openTurnRunningNodes ?? [] },
            screen: { [weak self] id in self?.registry.backend(id)?.renderScreen() },
            emit: emit)
        tw.start()
        self.turnWatcher = tw

        // Honest send-delivery. A send reaching the PTY is not proof it entered
        // the target's context — confirm against the transcript, reinject on turn death,
        // report an honest failure to the caller. Reads transcripts (world) → Commands only.
        let dt = DeliveryTracker(
            readSince: { [weak self] node, off in self?.transcriptSince(node, off) ?? "" },
            fileLength: { [weak self] node in self?.transcriptLength(node) ?? 0 },
            status: { [weak self] node in self?.store.tree[node]?.status },
            reinject: { [weak self] node, text in self?.reinjectForDelivery(node, text) },
            onConfirmed: { [weak self] node, text in
                self?.orchLog("delivery_confirmed", ["to": node.raw, "text": String(text.prefix(80))]) },
            onFailed: { [weak self] target, caller, text, attempts, reason in
                self?.onDeliveryFailed(target: target, caller: caller, text: text,
                                       attempts: attempts, reason: reason) },
            // Explicit test tuning wins; product default = runtime.json.
            maxAttempts: deliveryTuning.maxAttempts
                ?? RuntimeTuning.current.deliveryMaxAttempts,
            reinjectGrace: deliveryTuning.grace
                ?? TimeInterval(RuntimeTuning.current.deliveryReinjectGraceSeconds))
        dt.start()
        self.deliveryTracker = dt

        if let sid = resumeRootSessionId { sessionIds[store.tree.rootID] = sid }
        launchCell(node: store.tree.root, task: rootTask, markOnline: false,  // root: already running
                   resumeSessionId: resumeRootSessionId)
        // A resume starts with a TUI whose turn is already closed, waiting for
        // input — no turn is running, so the Stop hook will never come to flip the status
        // (the truth only comes from turn hooks). The launch path's .running relies on
        // the "inject initial task → Stop" loop; resume has no such loop, so it must honestly
        // fall to idle at the start, or the sidebar spins forever. .turnEnded fits exactly:
        // turn closed → idle/waiting.
        if resumeRootSessionId != nil { store.send(.turnEnded(store.tree.rootID, gen: nil)) }
    }

    /// Tree afterlife: adopt a previous incarnation's pointers into the live
    /// maps — live capture always wins. sessionIds gaps backfill from the transcript
    /// pointer's basename: claude's transcript IS `<sessionId>.jsonl` (probe-verified).
    public func adoptArchive(_ a: ArchivedSession) {
        for (n, t) in a.transcripts where transcripts[n] == nil { transcripts[n] = t }
        for n in Set(a.transcripts.keys).union(a.sessionIds.keys) where sessionIds[n] == nil {
            if let sid = a.resumeKey(for: n) { sessionIds[n] = sid }
        }
        // A grafted dead node that never relaunches this run keeps its OWN family so
        // the afterlife pane shows the right resume syntax (live launchCell always wins).
        for (n, k) in a.nodeKinds where nodeKinds[n] == nil { nodeKinds[n] = k }
    }

    /// Refresh this session's live.lock heartbeat. Driven by the host app's existing
    /// 60s harvester tick (no extra timer) so a resume from ANOTHER instance sees a fresh
    /// claim; a crashed instance stops calling this and its lock expires (self-heal).
    public func touchLiveLock() { SessionLock.write(dir: sessionDir) }

    /// A node was selected in the UI — its surface is about to attach, firing a SIGWINCH
    /// resize + repaint that transiently blanks the running anchor from the scrape source.
    /// Forward to the TurnWatcher so that repaint window is not misread as an interrupt.
    /// Harmless for an idle node — the
    /// watcher only judges nodes with an open running turn.
    public func noteNodeSelected(_ node: NodeID) { turnWatcher?.noteAttention(node) }

    public func stop() {
        SessionLock.remove(dir: sessionDir)   // clean release — resume is free again
        permWatcher?.stop(); permWatcher = nil
        turnWatcher?.stop(); turnWatcher = nil
        deliveryTracker?.stop(); deliveryTracker = nil
        for w in spawnWatchdogs.values { w.cancel() }    // no verdicts after teardown
        spawnWatchdogs.removeAll(); stalledSpawns.removeAll()
        for w in pendingWatchdogChecks.values { w.cancel() }   // no deferred nudge after teardown
        pendingWatchdogChecks.removeAll()
        hookListener?.stop(); mcpListener?.stop()
        let cells = registry.nodeIDs.compactMap { registry.remove($0) }
        let sd = sessionDir
        Task {
            await withTaskGroup(of: Void.self) { g in
                for c in cells { g.addTask { await c.terminate() } }
            }
            // The session is dead — reclaim the per-node codex-homes' re-downloadable
            // caches (~38MB/node). After the terminations, so no live child re-fills them.
            CodexHomePrune.pruneSession(dir: sd)
        }
        try? FileManager.default.removeItem(atPath: sockDir)
    }

    // MARK: spawn liveness watchdog (cell_launch → agent_connected timing window.
    // honest reporting of fake liveness: a node on the tree ≠ a live process — the same-family
    // rule applies. Only REAL new spawns are timed — resume/replay re-incarnations have no fresh
    // task→connect loop to wait on; root and workers share the rule.)
    //
    // The stop-the-clock signal agent_connected =
    // vigil-mcp's UDS `{node}` handshake line (MCPToolServer.handle's first line), which claude
    // fires as soon as it loads the MCP server during the **startup** phase — not on the first
    // tool call. So the 15s window measures "did the process start", independent of turn length;
    // on a slow machine / large context, MCP loading >15s will mis-report a stall once and then
    // recover (self-healing, just log noise).
    // This assumption is pinned by GatewayTests.testAgentConnectedFiresOnHandshakeBeforeAnyRpc.
    // ⚠️ Scope = harnesses that bring up the vigil-mcp shim (currently: claude). A future harness
    // without the shim (codex worker) would mis-report on every spawn — when wiring it in, the
    // watchdog must be gated by harness capability or change its window source.

    /// One armed timer per in-flight spawn; internal (private(set)) so T1 can pin
    /// arm/skip/cancel without sleeping through real windows.
    private(set) var spawnWatchdogs: [NodeID: DispatchWorkItem] = [:]
    /// Reported stalled, not yet recovered — gates the spawn_recovered line so a
    /// never-stalled connect emits nothing extra (normal path: zero new events).
    private(set) var stalledSpawns: Set<NodeID> = []

    private func armSpawnWatchdog(_ id: NodeID) {
        spawnWatchdogs[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.spawnWatchdogFired(id) }
        }
        spawnWatchdogs[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + spawnStallSeconds, execute: work)
    }

    private func spawnWatchdogFired(_ id: NodeID) {
        guard spawnWatchdogs.removeValue(forKey: id) != nil else { return }  // cancelled race
        guard let n = store.tree[id], !n.status.isTerminal else { return }   // died meanwhile
        stalledSpawns.insert(id)
        orchLog("spawn_stalled", ["node": id.raw, "window_s": spawnStallSeconds])
        store.send(.spawnStalled(id))
    }

    private func cancelSpawnWatchdog(_ id: NodeID) {
        spawnWatchdogs.removeValue(forKey: id)?.cancel()
        stalledSpawns.remove(id)     // a dead node has no recovery left to report
    }

    /// MCP handshake arrived for `node`: stop the clock; a node already
    /// reported stalled recovers here — forensic line + indicator clear. Internal
    /// (not private) so T1 can drive the connect side without a UDS round trip.
    func noteAgentConnected(_ node: NodeID) {
        spawnWatchdogs.removeValue(forKey: node)?.cancel()
        if stalledSpawns.remove(node) != nil {
            orchLog("spawn_recovered", ["node": node.raw])
            store.send(.spawnRecovered(node))
        }
        captureCodexSession(node)   // capture codex sid early (MCP handshake = session_meta already written to disk)
    }

    // MARK: Command ingress interception (API-error turn death)

    /// Every world-sourced Command (hooks / watchers / MCP) funnels here before the store.
    /// A turn end is the moment to ask "did this turn end normally or was it strangled by an
    /// API error?" — claude fires NO Stop hook on an API-error death (README "an API-error ending
    /// has no Stop hook"), so
    /// the transcript's error line is the only durable signal. Reading it is not a state
    /// change; any resulting state touch is a Command back into the store (iron law).
    @MainActor func receive(_ cmd: Command) {
        store.send(cmd)
        switch cmd {
        case .turnEnded(let node, _):
            // Baseline BEFORE checkTurnError advances apiScanOffset — the watchdog's
            // background-agent exemption must scan exactly the transcript this turn appended.
            let baseline = apiScanOffset[node] ?? 0
            checkTurnError(node)
            captureCodexSession(node)   // turn refresh of codex sid/pointer (newest wins)
            checkReportWatchdog(node, baseline: baseline)   // silent-worker nudge (deferred)
        case .turnStarted(let node):
            reportedSinceTurnStart.remove(node)   // a fresh turn resets the report flag
            pendingWatchdogChecks.removeValue(forKey: node)?.cancel()   // a new turn moots any pending nudge decision
        case .rollup(let node, _):
            reportedSinceTurnStart.insert(node)   // this node reported up during this turn
            watchdogReminderOutstanding.remove(node)   // a report answers any outstanding nudge
            watchdogDelivered.remove(node)   // and answers the delivery it was asked for — see recordAgentPrompt
        case .requestStruct(let req, let caller, _):
            // Attribute a kill to its caller for the whole sealed subtree (store.send
            // above already applied it, so terminal targets are visible + still in the tree).
            if case .kill(let target) = req, store.tree[target]?.status.isTerminal == true {
                for n in store.tree.subtree(of: target) { killedBy[n] = caller }
            }
        default:
            break
        }
    }

    /// A turn just ended for `node`: scan the transcript appended since the last check for
    /// an API-error line. Found → the node goes .errored (attention tier, own copy — never
    /// impersonating "waiting for authorization") and the parent manager is
    /// auto-notified so it stops waiting
    /// for a report that will never come. The offset advances every check so one error
    /// line fires exactly once. Root / parentless node → note only (nowhere to escalate).
    private func checkTurnError(_ node: NodeID) {
        guard transcripts[node] != nil else { return }
        let baseline = apiScanOffset[node] ?? 0
        let content = transcriptSince(node, baseline)
        apiScanOffset[node] = transcriptLength(node)
        guard let reason = TranscriptScan.apiErrorSnippet(inJSONL: content) else { return }
        orchLog("turn_errored", ["node": node.raw, "reason": reason])
        store.send(.turnErrored(node))
        if let parent = store.tree[node]?.parent, store.tree[parent]?.status.isTerminal == false {
            // This system message plus the sidebar's .errored yellow dot are
            // the parent's visible signal. best-effort (replyID nil, not entered into delivery
            // tracking, to avoid a meta-loop) — the durable signal is the .errored status itself.
            // Branch on whether this node already reported up THIS turn. Claiming "no report
            // received" when a report was in fact delivered misleads the manager into re-running
            // finished work, so tell the truth about the report either way.
            let text = reportedSinceTurnStart.contains(node)
                ? "SYSTEM: worker \(node.raw) turn ended with an API error after its report was delivered — the report was received, so a re-run is usually unnecessary."
                : "SYSTEM: worker \(node.raw) turn ended abnormally with an API error and sent no report — you may need to re-run it."
            store.send(.message(from: node, to: parent, text: text, replyID: nil))
        } else {
            store.note("node \(node.raw) API error cleanup: no live parent, note only (nowhere to report)")
        }
    }

    // MARK: report watchdog — the "silent dummy report" fallback

    /// Reminder text: states the mechanism (report is the only upstream channel) and
    /// asks for immediate action — the machine version of a manual `send` nudge.
    static let reportWatchdogText =
        "Vigil report watchdog: this turn ended without a report(...) call. Text printed in " +
        "this terminal stays local to this cell — your parent is still waiting. If the work " +
        "is finished or blocked, send a short summary up now via the report tool."

    /// A turn just ended for `node`: if it has an outstanding delivery (`watchdogDelivered`,
    /// per-delivery not lifetime — see its doc comment), no report arrived THIS turn
    /// (`reportedSinceTurnStart`), and no reminder is already outstanding for it, ARM a
    /// deferred decision — never fire synchronously. Two reasons: (1) a new turn starting
    /// during the grace moots the whole question (handled by `.turnStarted` cancelling
    /// `pendingWatchdogChecks`); (2) the background-agent exemption needs the transcript's
    /// `turn_duration` line, which claude's Stop hook fires BEFORE writing (same-second race
    /// on real transcripts) — reading it synchronously here would frequently miss it. Every
    /// guard checked here is RE-CHECKED at fire time in `fireReportWatchdog`, since state can
    /// change during the grace window. Bounded by construction:
    /// `watchdogReminderOutstanding` blocks a second nudge until a `.rollup` clears it — the
    /// reminder itself opens a new turn, and if THAT turn also ends silently the gate is
    /// still up, so no ping-pong. Root is immune (no parent to report to).
    private func checkReportWatchdog(_ node: NodeID, baseline: UInt64) {
        guard RuntimeTuning.current.reportWatchdog else { return }
        guard node != store.tree.rootID else { return }
        guard watchdogDelivered.contains(node) else { return }
        guard !watchdogReminderOutstanding.contains(node) else { return }
        guard !reportedSinceTurnStart.contains(node) else { return }
        guard let n = store.tree[node], !n.status.isTerminal else { return }
        guard registry.cell(node) != nil else { return }
        pendingWatchdogChecks[node]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fireReportWatchdog(node, baseline: baseline) }
        }
        pendingWatchdogChecks[node] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogGraceSeconds, execute: work)
    }

    /// The deferred half of `checkReportWatchdog`: re-verify every guard (a new turn, a
    /// report, a kill, or a cell teardown may all have happened during the grace), then apply
    /// the background-agent exemption against the transcript appended since `baseline` — a
    /// silent turn is not silent when claude's own `turn_duration` line says background
    /// subagents were still pending, and nudging into that would just pollute the worker's
    /// context with a redundant reminder it cannot act on any faster. A dead cell gets no
    /// injection (same honesty rule as every other inject path).
    private func fireReportWatchdog(_ node: NodeID, baseline: UInt64) {
        guard pendingWatchdogChecks.removeValue(forKey: node) != nil else { return }   // cancelled race
        guard RuntimeTuning.current.reportWatchdog else { return }
        guard node != store.tree.rootID else { return }
        guard watchdogDelivered.contains(node) else { return }
        guard !watchdogReminderOutstanding.contains(node) else { return }
        guard !reportedSinceTurnStart.contains(node) else { return }
        guard let n = store.tree[node], !n.status.isTerminal, n.status != .running, n.status != .starting
        else { return }
        guard let cell = registry.cell(node) else { return }
        if let pending = TranscriptScan.pendingBackgroundAgents(inJSONL: transcriptSince(node, baseline)),
           pending > 0 {
            orchLog("report_watchdog_skipped",
                    ["node": node.raw, "reason": "background_agents_pending", "count": pending])
            return
        }
        watchdogReminderOutstanding.insert(node)
        orchLog("report_watchdog", ["node": node.raw])
        Task { _ = try? await cell.inject(Self.reportWatchdogText) }
    }

    // MARK: transcript tail IO (the confirmation / error-scan source)

    /// Current byte length of a node's transcript (0 if no pointer / unreadable). The
    /// confirmation baseline: content written after this is what THIS inject produced.
    private func transcriptLength(_ node: NodeID) -> UInt64 {
        guard let path = transcripts[node],
              let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return 0 }
        defer { try? h.close() }
        return (try? h.seekToEnd()) ?? 0
    }

    /// Transcript content from `offset` to EOF, capped to the last `maxBytes` so a first
    /// scan of a huge transcript never blocks the main actor. A file shorter than the
    /// offset (claude rotated / truncated) falls back to reading the capped tail.
    private func transcriptSince(_ node: NodeID, _ offset: UInt64, maxBytes: UInt64 = 256 * 1024) -> String {
        guard let path = transcripts[node],
              let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return "" }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        var start = end >= offset ? offset : 0
        if end - start > maxBytes { start = end - maxBytes }
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: delivery reconciliation callbacks

    /// Reinject an unconfirmed message via the cell's EXISTING inject FIFO (injectTail
    /// hold semantics unchanged) — a plain world-side retry of an already-authorized
    /// route Effect, not a new state transition.
    private func reinjectForDelivery(_ node: NodeID, _ text: String) {
        orchLog("delivery_retry", ["to": node.raw, "text": String(text.prefix(80))])
        guard let cell = registry.cell(node) else { return }
        Task { _ = try? await cell.inject(text) }
    }

    /// All reinjects exhausted (or the target died): the failure must be VISIBLE to the
    /// caller — a SYSTEM receipt routed back + the forensic jsonl line (no false reporting / failure visible).
    private func onDeliveryFailed(target: NodeID, caller: NodeID, text: String,
                                  attempts: Int, reason: String) {
        orchLog("delivery_failed", ["to": target.raw, "caller": caller.raw,
                                    "attempts": attempts, "reason": reason])
        store.note("delivery failed \(caller.raw)->\(target.raw): \(reason) (original \(String(text.prefix(60))))")
        guard store.tree[caller]?.status.isTerminal == false else { return }
        // A send whose target DIED in flight is a terminal dead-end — the message is
        // void, and "you may need to resend" is misleading (there is no live node to resend to).
        // When the caller is the very node that killed the target, the receipt is pure noise, so
        // stay silent (the forensic delivery_failed line above is the durable record).
        // Distinct from the genuine-loss path (below): there the target is still ALIVE, the turn
        // died, reinjects were exhausted, and a resend can legitimately help.
        if let st = store.tree[target]?.status, st.isTerminal {
            if killedBy[target] == caller { return }   // you killed it yourself — nothing to tell you
            store.send(.message(from: target, to: caller,
                text: "SYSTEM: your message to \(target.raw) was voided — that node has terminated (\(st.rawValue)); do not resend.",
                replyID: nil))
            return
        }
        store.send(.message(from: target, to: caller,
            text: "SYSTEM: your message to \(target.raw) is still unconfirmed after \(attempts) reinjection(s); you may need to resend.",
            replyID: nil))
    }

    /// Only a genuine downlink `send` (MESSAGE FROM prefix) is tracked — rollups and the
    /// SYSTEM receipt themselves must never enter the confirmation loop (meta-loop guard).
    static func isTrackedSend(_ text: String) -> Bool { text.hasPrefix("MESSAGE FROM") }

    /// Register a just-injected send for delivery confirmation. Caller (the sender) comes
    /// from the route's viaPath head; without it we cannot address a failure receipt, so skip.
    /// Returns whether the send entered the transcript-confirmation loop. false = a caller
    /// with no addressable path, or an opencode target that degraded to unconfirmed.
    @discardableResult
    private func registerDelivery(to: NodeID, caller: NodeID?, text: String) -> Bool {
        guard let caller else { return false }
        // Opencode and codex explicit delivery-confirmation downgrade (honesty redline): the
        // DeliveryTracker's confirmation evidence = the injected text appearing as a **real user
        // line** in the target transcript (TranscriptScan, claude JSONL shape).
        // opencode lands in SQLite with no external JSONL; codex does have a rollout jsonl, but the
        // user message is in `event_msg.user_message.message` (not claude's `type:user`), so a
        // claude-shaped scan never hits → registering as usual → confirm never hits → reinject on
        // turn idle → after 3 tries onFailed falsely reports a delivery failure. Neither family
        // enters the confirmation loop: log one delivery_unconfirmed for forensics and stop — never
        // counted confirmed, never falsely failed. The codex real confirmation-upgrade
        // path (parse rollout user_message and compare) is in OBSERVABILITY §8.5.
        if nodeKinds[to] == .opencode || nodeKinds[to] == .codex {
            let store = nodeKinds[to] == .codex ? "codex rollout=event_msg shape, claude scan misses"
                                                : "opencode transcript=SQLite, no external tail-read surface"
            orchLog("delivery_unconfirmed",
                    ["to": to.raw, "caller": caller.raw,
                     "reason": "\(store); injected to PTY, entered context but not externally confirmable",
                     "text": String(text.prefix(80))])
            return false
        }
        deliveryTracker?.register(target: to, caller: caller, text: text)
        return true
    }

    // MARK: the Effect sink (DOCTRINE §1 single egress)

    func perform(_ effect: Effect) {
        switch effect {
        case .spawnCell(let node, let task):
            launchCell(node: node, task: task, markOnline: true)
        case .resumeCell(let node, let sid):
            // Re-incarnate ONE dead node. The old cell (natural death
            // keeps it in the registry frozen) must leave first — its final frame
            // is already in frozenScreens; the new cell takes over the slot.
            if let old = registry.remove(node.id) { Task { await old.terminate() } }
            launchCell(node: node, task: "", markOnline: true, resumeSessionId: sid)
            // A revived worker is like a root resume — a TUI waiting for input, no turn
            // running, so nodeOnline's .running has nobody to flip it → settle to idle right here
            // (no perpetual spinning allowed).
            store.send(.turnEnded(node.id, gen: nil))
        case .killCells(let ids):
            for id in ids {
                orchLog("kill", ["node": id.raw])
                cancelSpawnWatchdog(id)     // a killed cell has no spawn to await
                // Freeze the last frame while the backend is still reachable —
                // the dead node stays selectable and this is its pointer-dangling
                // fallback content.
                if let screen = registry.backend(id)?.renderScreen(), !screen.isEmpty {
                    frozenScreens[id] = screen
                }
                if let c = registry.remove(id) { Task { await c.terminate() } }
            }
        case .route(let to, let text, let viaPath, let replyID):
            let kind = Self.routeKind(text)
            // A rollup is the report itself — worth more than the 80-char forensic snippet
            // every other route kind gets, so a dogfood run can be diagnosed without cross-
            // referencing the transcript.
            let cap = kind == "rollup" ? 400 : 80
            var logFields: [String: Any] = ["to": to.raw, "kind": kind, "text": String(text.prefix(cap))]
            if let from = viaPath.first { logFields["from"] = from.raw }   // path[0] = the sender (LCA-relayed, §6.3)
            orchLog("route", logFields)
            let caller = viaPath.first     // path[0] = the sender (LCA-relayed, §6.3)
            if let cell = registry.cell(to) {
                let pending = self.pending
                Task { [weak self] in
                    do {
                        let ack = try await cell.inject(text)
                        if let note = ack.note {
                            // forensic trail: queued-behind-typing / fail-open evidence.
                            self?.orchLog("inject_note", ["to": to.raw,
                                                          "delivered": ack.delivered, "note": note])
                        }
                        if ack.delivered {
                            // A manager message that actually reached the PTY is a genuine
                            // delivery — (re-)arm the report watchdog here, kind-agnostic
                            // (unlike recordAgentPrompt's prompt-text introspection, which only
                            // claude's hook payload carries). This is what lets a codex/opencode
                            // worker's watchdog re-arm after a `.rollup` cleared it: those
                            // harnesses' capture sites only insert on a sid/pointer change, so
                            // without this a follow-up `send` after their first report would
                            // never be nagged again. Rollups/SYSTEM receipts are excluded — only
                            // an actual ask from a manager counts as a delivery.
                            if kind == "message" { self?.watchdogDelivered.insert(to) }
                            // Keystrokes reaching the PTY ≠ delivery. A tracked
                            // send (MESSAGE FROM + replyID) is registered for transcript
                            // confirmation and answered HONESTLY (confirmation queued), never a
                            // bare "sent"; confirmation/failure land async (jsonl + SYSTEM receipt).
                            if let replyID, Self.isTrackedSend(text) {
                                // opencode / codex: no claude-shaped transcript to confirm
                                // against — registerDelivery returns false (degraded) and the ack
                                // must not promise a SYSTEM receipt that will never come.
                                let tracked = self?.registerDelivery(to: to, caller: caller, text: text) ?? false
                                let tail = tracked ? "confirming delivery (a SYSTEM receipt will follow on failure)"
                                    : "this agent's context entry cannot be externally confirmed (no delivery receipt)"
                                await pending.deliver(replyID, .sendAck(delivered: true,
                                    note: (ack.note.map { "\($0); " } ?? "") + "injected \(to.raw), " + tail))
                            } else if let replyID {
                                await pending.deliver(replyID,
                                    .sendAck(delivered: true, note: ack.note ?? "sent"))
                            }
                        } else {
                            // Non-throwing undelivered (cell died while queued) —
                            // same honesty rule as elsewhere, never ack "sent".
                            self?.failRoute(to: to, reason: ack.note ?? "not delivered",
                                            note: "route inject UNDELIVERED: \(to) \(ack.note ?? "")",
                                            replyID: replyID)
                        }
                    } catch {
                        self?.failRoute(to: to, reason: "inject failed: \(error)",
                                        note: "route inject FAILED: \(to) \(error)",
                                        ackDetail: "inject failed", replyID: replyID)
                    }
                }
            } else {
                // Node alive in the tree but its cell is gone (starting/ghost
                // window) — the drop must be visible, not a silent note.
                failRoute(to: to, reason: "no live cell",
                          note: "route dropped: no cell \(to)", replyID: replyID)
            }
        case .routeFailed(let from, let to, let reason):
            // Core-side drop: the store already failed the sender's reply; here
            // the drop joins the forensic trail alongside the successful `route` lines.
            orchLog("route_failed", ["from": from.raw, "to": to.raw, "reason": reason])
        case .deliver(let replyID, let resolution):
            Task { await pending.deliver(replyID, resolution) }
        case .permLog(let entry):
            appendPermLog(entry)
        }
    }

    /// The one world-side route-failure receipt — forensic jsonl line + store note
    /// + (when a send waits on the verdict) the honest not-delivered ack.
    /// `ackDetail` defaults to `reason`; the throwing path passes a shorter wire detail
    /// ("inject failed" without the error dump) — byte parity with the original blocks.
    private func failRoute(to: NodeID, reason: String, note: String,
                           ackDetail: String? = nil, replyID: UUID?) {
        orchLog("route_failed", ["to": to.raw, "reason": reason])
        store.note(note)
        if let replyID {
            let pending = self.pending
            Task { await pending.deliver(replyID, .sendAck(delivered: false,
                note: "node \(to.raw) not reachable: " + (ackDetail ?? reason))) }
        }
    }

    // MARK: dogfood telemetry (unconditional, per-session jsonl)

    /// One jsonl line per permission request/resolution. The wall-clock is stamped HERE
    /// (world side, real time at write) — Core stays deterministic. Timestamp schema =
    /// OrchClock, the shared write/read contract.
    /// runtime.json permDogfoodLog=false switches the file off (takes effect immediately).
    private func appendPermLog(_ e: PermLogEntry) {
        guard RuntimeTuning.current.permDogfoodLog else { return }
        var obj: [String: Any] = ["ts": OrchClock.format(Date()),
                                  "event": e.event, "node": e.nodeID.raw,
                                  "kind": e.kind.rawValue]
        if let v = e.promptID { obj["prompt_id"] = v }
        if let v = e.toolName { obj["tool"] = v }
        if let v = e.toolUseID { obj["tool_use_id"] = v }
        if let v = e.via { obj["via"] = v }
        appendJSONL(obj, file: "perm_dogfood.jsonl")
    }

    // MARK: orchestration event log (the spawn/send/rollup/kill forensic trail;
    // one jsonl line per Effect-egress event so a dogfood run can be reconstructed with
    // jq instead of transcript fingerprint matching. World-side timestamps, same
    // honesty rule as permLog: Core stays deterministic, the clock is stamped at write.)

    private func orchLog(_ event: String, _ fields: [String: Any]) {
        var obj: [String: Any] = ["ts": OrchClock.format(Date()), "event": event]
        for (k, v) in fields { obj[k] = v }
        appendJSONL(obj, file: "orchestration.jsonl")
    }

    /// Route taxonomy for the log — derived from the wire prefixes the runtime itself
    /// writes (SessionStore rollup / MCP send / review prompt), never parsed back out.
    static func routeKind(_ text: String) -> String {
        if text.hasPrefix("CHILD_ROLLUP:") { return "rollup" }
        if text.hasPrefix("MESSAGE FROM") { return "message" }
        if text.hasPrefix("SYSTEM:") { return "system" }   // auto receipt / API-error notification
        if text.hasPrefix("PERMISSION REVIEW REQUEST") { return "perm_review" }
        return "other"
    }

    /// UserPromptSubmit fired: record the node → claude transcript join key —
    /// the one mapping the archive reconstruction had to recover by fingerprinting.
    /// Internal (not private) so unit tests can drive it without a UDS round trip.
    ///
    /// Also arms the report watchdog's per-delivery `watchdogDelivered` flag — but NOT
    /// unconditionally: claude's UserPromptSubmit payload carries the submitted text under
    /// `prompt` (GatewayTests pins the shape), and two prompt origins are system-originated,
    /// not a genuine manager ask, so arming on them would recreate the old lifetime-set
    /// over-nagging bug: the watchdog's OWN reminder (it would otherwise re-arm itself) and a
    /// `<task-notification>` (an automatic system nudge, not a delivery from a parent). Every
    /// other prompt — the initial task, a real `send`, or a payload with no `prompt` key at
    /// all (the codex/opencode capture sites never call this; a test payload with no key) —
    /// arms as before.
    /// Test seam (internal, read-only): is the report watchdog currently armed for `node`,
    /// i.e. does it have an outstanding delivery a report has not yet answered? The
    /// route-delivery arm lands asynchronously (after the inject ack resolves), so a test
    /// that drives a turn right after observing the PTY bytes must wait on THIS, not on the
    /// bytes — otherwise it races the arm. Never used by product code.
    func isWatchdogArmed(_ node: NodeID) -> Bool { watchdogDelivered.contains(node) }

    func recordAgentPrompt(_ node: NodeID, payload: [String: Any]) {
        let promptText = payload["prompt"] as? String
        let isOwnReminder = promptText == Self.reportWatchdogText
        let isSystemNotification = promptText?.hasPrefix("<task-notification>") == true
        if !isOwnReminder && !isSystemNotification {
            watchdogDelivered.insert(node)
        }
        var fields: [String: Any] = ["node": node.raw]
        if let t = payload["transcript_path"] as? String {
            fields["transcript"] = t
            transcripts[node] = t     // newest pointer wins (claude rotates files)
        }
        if let sid = payload["session_id"] as? String {
            fields["session_id"] = sid
            sessionIds[node] = sid    // resume forks a new id — newest wins
        }
        orchLog("agent_prompt", fields)
    }

    /// Codex sid/transcript capture: codex fires no prompt/stop hook (recordAgentPrompt never
    /// triggers for it), but each codex node writes a rollout jsonl after a turn under its isolated
    /// CODEX_HOME. Scan it to recover the session_id (resume credential) + rollout path (afterlife
    /// pointer) and feed them into the SAME `agent_prompt` event as claude — replay/resumeKey/
    /// afterlife whole chain accepts it with zero changes. Three triggers (all idempotent, emitting
    /// an event only when the sid/pointer changes): agent_connected (MCP handshake, early capture),
    /// turnEnded (turn refresh), handleExit (the critical fallback — only a dead node needs
    /// afterlife/resume, at exit the rollout must already be on disk, guaranteeing agent_prompt is
    /// written before archiving). A non-codex node returns immediately (nodeKinds family gating).
    func captureCodexSession(_ node: NodeID) {
        guard nodeKinds[node] == .codex else { return }
        let home = CodexHarness.codexHome(configRoot: configRoot, node: node)
        guard let cap = CodexRollout.capture(codexHome: home) else { return }
        // Codex naming: surface the MAIN rollout path on EVERY capture (outside the idempotent
        // pointer guard below) — the first user_message may only land after agent_connected's early
        // capture, so naming must get another shot on each turnEnded/handleExit refresh.
        onCodexRollout?(node, cap.path)
        guard sessionIds[node] != cap.sessionId || transcripts[node] != cap.path else { return }
        transcripts[node] = cap.path       // afterlife pointer (newest wins, resume may open a new rollout)
        sessionIds[node] = cap.sessionId   // resume credential (codex's filename is not a bare uuid, must capture explicitly)
        orchLog("agent_prompt", ["node": node.raw, "transcript": cap.path,
                                 "session_id": cap.sessionId])
        watchdogDelivered.insert(node)   // same delivery-confirmed signal as recordAgentPrompt
        // root's sid → meta.rootSessionId (resume whole chain). No transcript_path: a codex rollout
        // has no claude ai-title, avoiding a claude-shaped naming poll (AutoNamer degrades honestly,
        // see AppModel).
        onAgentPrompt?(node, ["session_id": cap.sessionId])
    }

    /// Opencode transcript capture: opencode's transcript lands in SQLite (`~/.local/share/
    /// opencode/opencode.db`), with no external JSONL to store a pointer to (codex/claude both have
    /// native files). So instead of a pointer it stores a **snapshot** — via the official
    /// `opencode export <sid>` (the app-layer-injected openCodeExporter, off-main) it gets the full
    /// conversation JSON, writes `<sessionDir>/opencode-<node>.json`, points at it, and feeds it
    /// into the SAME agent_prompt event as codex/claude. The sid is delivered earlier by opencode's
    /// plugin prompt/stop hook (sessionIds[node]). Two triggers: onStop (turn closed, db is
    /// complete) + handleExit (dead-node fallback). A non-opencode / missing sid / missing exporter
    /// returns immediately (family gating + honest degradation: an export failure never writes a
    /// hollow shell).
    func captureOpenCodeSession(_ node: NodeID) {
        guard nodeKinds[node] == .opencode, let exporter = openCodeExporter,
              let sid = sessionIds[node], !sid.isEmpty else { return }
        Task { [weak self] in
            let raw = await exporter(sid)     // off-main: inside the closure a Task.detached runs opencode export
            await MainActor.run { self?.recordOpenCodeCapture(node, sid: sid, raw: raw) }
        }
    }

    /// The synchronous, deterministically-testable core of opencode capture: given the
    /// exported JSON, materialize the snapshot pointer + emit agent_prompt (idempotent — the
    /// file overwrites in place each turn; the event lands once when the pointer first sets,
    /// so replay picks it up without spamming the log). Honest degradation: empty/nil export
    /// = no file, no event (never a hollow pointer).
    func recordOpenCodeCapture(_ node: NodeID, sid: String, raw: String?) {
        guard let raw, !raw.isEmpty else { return }
        let path = (sessionDir as NSString).appendingPathComponent("opencode-\(node.raw).json")
        do { try raw.write(toFile: path, atomically: true, encoding: .utf8) }
        catch { orchLog("io_error", ["op": "opencode_export", "path": path,
                                     "error": "\(error)"]); return }
        let firstPointer = transcripts[node] != path
        transcripts[node] = path
        if firstPointer {
            orchLog("agent_prompt", ["node": node.raw, "transcript": path, "session_id": sid])
        }
        watchdogDelivered.insert(node)   // same delivery-confirmed signal as recordAgentPrompt
        onAgentPrompt?(node, ["session_id": sid])
    }

    private func appendJSONL(_ obj: [String: Any], file: String) {
        FileIO.appendJSONLine(obj, to: (sessionDir as NSString).appendingPathComponent(file))
    }

    /// The one place a swallowed IO failure becomes
    /// diagnosable — a forensic jsonl line + a user-visible store note. Passed as the `report` sink
    /// to every launch-critical FileIO write, so a full disk / permission error does not mean
    /// "the whole orchestration vanishes with zero logs the entire time". (NOT wired into the
    /// best-effort telemetry appends themselves — a failing dogfood log must not spam notes; only
    /// launch/dir writes report.)
    private func ioReport(_ op: String, _ path: String, _ err: String) {
        orchLog("io_error", ["op": op, "path": path, "error": err])
        store.note("IO failed \(op) \(path): \(err)")
    }

    // MARK: cell lifecycle

    private func launchCell(node: Node, task: String, markOnline: Bool,
                            resumeSessionId: String? = nil) {
        // Every node — root and workers alike — runs where the project lives.
        // Vigil does not pick an isolation strategy for the agent; worktrees/branches
        // are the agent's own shell decision. No project dir (tests/smoke) → per-node
        // scratch dir under the session.
        let cwd = rootCwd ?? (workRoot as NSString).appendingPathComponent(node.id.raw)
        let nodeDir = (configRoot as NSString).appendingPathComponent(node.id.raw)
        // A pre-spawn disk-write failure → fail explicitly, don't force-launch a
        // crippled cell. If the work dir or the per-node config dir (where settings.json/mcp.json
        // land) can't be created, launching anyway would give a cell with no hooks + no MCP channel
        // — "the whole orchestration vanishes" with zero diagnostics. Abort loudly instead:
        // forensic trail + note + nodeFailed.
        let cwdOK = FileIO.createDirectory(cwd, report: ioReport)
        let cfgOK = FileIO.createDirectory(nodeDir, report: ioReport)
        guard cwdOK && cfgOK else {
            orchLog("cell_launch_aborted", ["node": node.id.raw,
                                            "reason": "config/work dir creation failed"])
            store.note("spawn aborted \(node.id.raw): config/work dir creation failed, no crippled cell started")
            store.send(.nodeFailed(node.id, reason: "config/work dir creation failed"))
            return
        }

        // Root uses rootHarness (a pre-seasoned shell); children use harness (claude agents).
        let isRoot = node.id == store.tree.rootID
        let h = (isRoot ? (rootHarness ?? harness) : harness)
        // Pin the resolved family for this node before we build the spec — opencode's
        // send-delivery confirmation branches on it (registerDelivery).
        nodeKinds[node.id] = h.launchKind(role: node.role, isRoot: isRoot, cwd: cwd)
        let launch = h.launchSpec(
            task: task, cwd: cwd, nodeID: node.id,
            role: node.role, isRoot: isRoot, model: node.model,
            resumeSessionId: resumeSessionId,
            mcpEndpoint: mcpSock, hookEndpoint: hookSock,
            idCred: node.id.raw)

        var launchFields: [String: Any] = ["node": node.id.raw, "role": node.role.rawValue,
                                           "root": isRoot, "task": String(task.prefix(80))]
        // Pin the resolved family in the forensic trail so SessionArchive.replay can
        // give each dead node its OWN resume syntax (claude/codex/opencode differ) — a
        // heterogeneous tree must not show the root family's syntax for every node.
        if let k = nodeKinds[node.id] { launchFields["kind"] = k.rawValue }
        // An explicit dispatch-time name differs from the task — log it so the
        // history tree (SessionArchive rebuild) shows the same label as the live tree.
        if !node.title.isEmpty, node.title != task {
            launchFields["title"] = String(node.title.prefix(80))
        }
        if let model = node.model { launchFields["model"] = model }   // forensic trail
        if let parent = node.parent { launchFields["parent"] = parent.raw }  // tree edge
        if let sid = resumeSessionId { launchFields["resume"] = sid }  // forensic trail
        orchLog("cell_launch", launchFields)
        // Only a REAL new spawn starts the liveness clock. A resume re-incarnation
        // (root --resume or a revived worker) is a waiting TUI with no task→connect
        // loop; replay/restoreSkeleton never reaches launchCell at all.
        if resumeSessionId == nil { armSpawnWatchdog(node.id) }
        let backend = backendFactory(node.id)
        // Hold safety valve = runtime.json injectHoldTimeoutSeconds, read at
        // cell birth (launch-scoped, same as every other per-launch knob); an explicit
        // injectTuning.maxWait (tests) wins over the file.
        let cell = RealCell(nodeID: node.id, launch: launch, cwd: cwd, backend: backend,
                            initialPrompt: launch.initialPrompt,   // task via PTY, not argv
                            injectPollInterval: injectTuning.poll,
                            injectMaxQueueWait: injectTuning.maxWait
                                ?? TimeInterval(RuntimeTuning.current.injectHoldTimeoutSeconds),
                            injectHoldNoticeDelay: injectTuning.noticeDelay,
                            // runtime.json knob, point-read at cell birth
                            // (same launch-scoped convention as the inject valve above).
                            initialPromptReadyTimeout: TimeInterval(
                                RuntimeTuning.current.initialPromptReadyTimeoutSeconds),
                            onInitialPromptAck: { [weak self] id, ack in
                                // The initial prompt has no send-route caller; land its
                                // forensic note (submit retries etc.) in the same trail.
                                if let note = ack.note {
                                    Task { @MainActor in
                                        self?.orchLog("inject_note", ["to": id.raw,
                                                                      "delivered": ack.delivered, "note": note])
                                    }
                                }
                            },
                            onExit: { [weak self] id, code in
                                Task { @MainActor in self?.handleExit(id, code) }
                            },
                            onInjectHold: { [weak self] id, pending, held, epoch in
                                // The hold is user-visible — queued ⇄ settled.
                                Task { @MainActor in
                                    self?.store.send(held ? .injectQueued(id, pending: pending, epoch: epoch)
                                                          : .injectSettled(id, epoch: epoch))
                                }
                            },
                            onChildPid: { [weak self, exe = launch.executable] id, pid in
                                // Orphan-reap: persist the child pid + its identity the
                                // moment forkpty publishes it, so a hard-killed Vigil's
                                // stranded children can be reaped by exact pid next launch.
                                // exe = the path WE launch (ground truth), not read back from
                                // the process (racy pre-exec, see RealCell.reportChildPid).
                                Task { @MainActor in self?.recordCellPid(id, pid: pid, exe: exe) }
                            })
        registry.add(cell, backend: backend)
        Task { await cell.start() }
        if markOnline {
            // Best-effort: there is no explicit online signal yet; mark running on launch.
            store.send(.nodeOnline(node.id))
        }
    }

    /// Orphan-reap: record the freshly-forked child's identity to the forensic trail.
    /// `startTime` is the child's fork-time (kernel proc metadata — the child's own even
    /// during the pre-exec window, so safe to read now); `exe` is the path WE launched
    /// (ground truth passed in, never read back — the process argv is still Vigil's own until
    /// execve lands). Together they are the reaper's pid-reuse guard. sessionDir is implicit
    /// (this log lives in it). A pid with no readable start time (already gone) records 0 —
    /// the reaper's own liveness/identity guards then simply skip it.
    func recordCellPid(_ id: NodeID, pid: pid_t, exe: String) {
        guard pid > 0 else { return }
        orchLog("cell_pid", ["node": id.raw, "pid": Int(pid),
                             "startTime": ProcessInspect.startTime(pid) ?? 0,
                             "exe": exe])
    }

    private func handleExit(_ id: NodeID, _ code: Int32?) {
        // Critical fallback: only a dead node needs afterlife/resume. At exit the rollout must
        // already be on disk — capturing before the exit event guarantees codex's sid/pointer is
        // already in orchestration.jsonl when the archive rebuilds (replay to agent_prompt).
        captureCodexSession(id)
        captureOpenCodeSession(id)   // opencode same dead-node fallback (export snapshot off-main)
        orchLog("exit", code.map { ["node": id.raw, "code": Int($0)] } ?? ["node": id.raw])
        cancelSpawnWatchdog(id)     // process ended — nothing left to await
        // Natural death spares the cell — selfDeath does not put it into
        // killCells, so the frame freeze for the dead-node pane happens HERE, and the
        // backend stays in the registry showing its final screen (kill freezes in the
        // killCells handler; both paths must leave lastFrame reachable).
        if let screen = registry.backend(id)?.renderScreen(), !screen.isEmpty {
            frozenScreens[id] = screen
        }
        if let code = code {
            store.send(.nodeExited(id, code: Int(code)))
        } else {
            store.send(.nodeFailed(id, reason: "process ended without an exit code"))
        }
    }
}
