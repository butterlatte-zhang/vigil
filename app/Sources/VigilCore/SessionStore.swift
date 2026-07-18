import Foundation
import Observation

/// The single source of truth for a running session = the cell tree + observation
/// notices (DOCTRINE §1). Unidirectional: everything enters via `send(_:)`; the view is
/// a pure function of the published state; world-changes leave only as `Effect`s.
/// Struct changes (spawn/kill) apply IMMEDIATELY — permission
/// levels are the agent tool's native mechanism (claude --permission-mode), and
/// out-of-envelope approvals happen in the agent's OWN terminal. Vigil observes
/// (permRequested/resolveNotice/clearNotices feed the notification UI) instead of gating.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var tree: Tree
    public private(set) var notices: [AgentNotice] = []
    public private(set) var log: [String] = []          // never silent-fail (§5.2)

    @ObservationIgnored private var seq: UInt64 = 0
    @ObservationIgnored private var nodeSeq: UInt64 = 0
    @ObservationIgnored private let perform: @MainActor (Effect) -> Void
    @ObservationIgnored private let now: () -> Date    // injectable clock (honest arrivals, deterministic tests)
    @ObservationIgnored private var deliveredReplies: Set<UUID> = []   // replyID delivered once (§6.4)

    /// Bootstrap (DOCTRINE §2.7): app plants the root directly — the session's
    /// start, not a struct request.
    public init(root: Node, now: @escaping () -> Date = { Date() },
                perform: @escaping @MainActor (Effect) -> Void) {
        precondition(root.parent == nil, "root must have no parent")
        var root = root
        if root.startedAt == nil { root.startedAt = now() }   // bootstrap = task creation
        self.tree = Tree(root: root)
        self.now = now
        self.perform = perform
    }

    // MARK: ingress

    public func send(_ command: Command) {
        switch command {
        case .nodeOnline(let id):
            tree.setStatus(id, .running); note("node online: \(id)")
        case .nodeExited(let id, let code):
            selfDeath(id, status: (code ?? 0) == 0 ? .done : .failed,
                      why: "exited(code=\(code.map(String.init) ?? "nil"))")
        case .nodeFailed(let id, let reason):
            selfDeath(id, status: .failed, why: "failed(\(reason))")

        case .requestStruct(let req, let from, let replyID):
            applyStructNow(req, from: from, replyID: replyID)

        case .rollup(let from, let summary):
            applyRollup(from: from, summary: summary)
        case .message(let from, let to, let text, let replyID):
            routeMessage(from: from, to: to, text: text, replyID: replyID)

        case .permRequested(let from, let info):
            permRequested(from: from, info: info)
        case .resolveNotice(let from, let match, let via):
            resolveNotice(from: from, match: match, via: via)
        case .clearNotices(let id):
            clearNotices(id)
        case .turnStarted(let id):
            turnStarted(id)
        case .turnEnded(let id, let gen):
            turnEnded(id, gen: gen)
        case .restoreSkeleton(let archived):
            restoreSkeleton(archived)
        case .resumeNode(let id, let sid):
            resumeNode(id, sessionID: sid)
        case .spawnStalled(let id):
            spawnStalled(id)
        case .spawnRecovered(let id):
            spawnRecovered(id)
        case .injectQueued(let id, let pending, let epoch):
            injectQueued(id, pending: pending, epoch: epoch)
        case .injectSettled(let id, let epoch):
            injectSettled(id, epoch: epoch)
        case .turnErrored(let id):
            turnErrored(id)
        }
    }

    // MARK: attention-state derivation (dual-state coverage)
    // A node can carry SEVERAL concurrent attention signals at once — a permission card,
    // a stall, a queued-inject card. Letting each writer setStatus(literal)
    // unconditionally means whoever wrote last wins and settle's hard `.waiting` guard
    // could deadlock a node that is simultaneously stalled + queued. Instead every place
    // that touches a node's attention status routes through this ONE deriver, so the
    // resulting status is a pure priority function of the signals in flight.
    //   terminal → keep (sticky-terminal); perm card → .waiting; stalled spawn → .stalled;
    //   API-error turn death → .errored; queued-inject card → .queued;
    //   else restingStatus.

    private func attentionStatus(_ id: NodeID) -> NodeStatus {
        guard let n = tree[id] else { return .idle }
        if n.status.isTerminal { return n.status }
        if notices.contains(where: { $0.nodeID == id && $0.kind != .injectQueued }) { return .waiting }
        if stalledSpawns.contains(id) { return .stalled }
        if erroredNodes.contains(id) { return .errored }
        if notices.contains(where: { $0.nodeID == id && $0.kind == .injectQueued }) { return .queued }
        return restingStatus(id)
    }

    // MARK: spawn liveness (honest reporting of fake liveness — a node on the tree ≠ a live process)

    @ObservationIgnored private var stalledSpawns: Set<NodeID> = []
    /// Nodes whose turn died on an API error (no Stop hook) and have not
    /// yet been re-engaged. Same discipline as stalledSpawns — an attention flag consumed
    /// by attentionStatus, cleared on the next turnStarted / clearNotices / teardown.
    @ObservationIgnored private var erroredNodes: Set<NodeID> = []
    /// The last inject-signal epoch APPLIED per node. RealCell
    /// stamps queued/settled emissions with a per-cell monotonic epoch under its lock, so
    /// a signal that reorders across the MainActor hop and lands out of order is dropped
    /// here (epoch not newer than the last applied). Cleared on cell teardown / resume,
    /// where a fresh incarnation restarts its own epoch counter at 0.
    @ObservationIgnored private var injectSignalEpoch: [NodeID: UInt64] = [:]

    /// The world-side watchdog saw no agent_connected inside the window: the cell's
    /// process may never have been born. The node goes
    /// `.stalled` — its OWN status: attention tier like waiting, but its
    /// copy is "spawn didn't connect", never "waiting for authorization" — a possibly-unborn spawn must not
    /// impersonate a permission prompt. Terminal nodes ignore a late verdict
    /// (sticky-terminal discipline).
    private func spawnStalled(_ id: NodeID) {
        guard let n = tree[id], !n.status.isTerminal else { return }
        stalledSpawns.insert(id)
        tree.setStatus(id, attentionStatus(id))   // stalled unless a perm card outranks it
        note("spawn stalled [\(id)]: no agent_connected — the cell may never have spawned (#30)")
    }

    /// The stalled node's agent connected after all — consume the stall flag and let the
    /// deriver recompute: a standing perm card keeps it at the human (waiting), a
    /// queue card leaves it .queued, otherwise it settles to resting.
    private func spawnRecovered(_ id: NodeID) {
        guard stalledSpawns.remove(id) != nil else { return }
        guard let n = tree[id], !n.status.isTerminal else { return }
        tree.setStatus(id, attentionStatus(id))
        note("spawn recovered [\(id)]: agent connected")
    }

    // MARK: honest reporting of API-error turn death. When claude strangles a turn
    // on an API error it fires no Stop hook (README "an API-error ending has no Stop hook"), and the
    // parent would wait forever for a report that never comes. The world side reads the transcript's
    // error line to decide, entering via Command; the node falls to .errored (an independent
    // attention state, dispatched by attentionStatus in priority order waiting > stalled > errored).
    // Cleared on: the next turnStarted (continued run) / clearNotices (re-engage) /
    // cascadeTeardown (death).

    private func turnErrored(_ id: NodeID) {
        guard let n = tree[id], !n.status.isTerminal else { return }   // sticky terminal: a late verdict is discarded
        erroredNodes.insert(id)
        tree.setStatus(id, attentionStatus(id))   // errored unless a perm card outranks it
        note("turn errored [\(id)]: API error cut the turn short, no Stop hook (issue-37)")
    }

    // MARK: the queue must speak up — a task message held behind the human's own typing must
    // not look like a dead task. The signal source is RealCell's hold loop (grace already
    // applied there — quick clears never reach here); the card dies when the hold
    // releases, never via click. Status is derived (attentionStatus), never a literal:
    // a node can be stalled AND queued at once, and the priority owns the outcome.

    /// True when this signal is stale = its epoch is not newer than the last one applied
    /// for the node (the orphan-card reorder). A fresh, in-order signal records its epoch.
    private func staleInjectSignal(_ id: NodeID, epoch: UInt64) -> Bool {
        if let last = injectSignalEpoch[id], epoch <= last { return true }
        injectSignalEpoch[id] = epoch
        return false
    }

    /// A routed message is HELD and outlived the grace. One card per node, upserted
    /// in place: id/seq/arrivedAt survive a count refresh so the stack doesn't churn and
    /// the clock stays the FIRST hold moment.
    private func injectQueued(_ id: NodeID, pending: Int, epoch: UInt64) {
        guard let n = tree[id], !n.status.isTerminal else {
            // The settle callback races cell death — a late queued signal must never
            // resurrect a dead record.
            return note("inject queued dropped: no live node \(id)")
        }
        if staleInjectSignal(id, epoch: epoch) {
            // A settle already overtook this refresh — applying it would rebuild an
            // orphan card the settle just removed.
            return note("inject queued dropped: stale epoch \(epoch) for \(id)")
        }
        let text = "\(pending) message(s) queued — waiting for the input line to free up"
        if let i = notices.firstIndex(where: { $0.nodeID == id && $0.kind == .injectQueued }) {
            let old = notices[i]
            notices[i] = AgentNotice(id: old.id, seq: old.seq, nodeID: id, kind: .injectQueued,
                                     text: text, arrivedAt: old.arrivedAt)
        } else {
            seq += 1
            notices.append(AgentNotice(seq: seq, nodeID: id, kind: .injectQueued,
                                       text: text, arrivedAt: now()))
        }
        tree.setStatus(id, attentionStatus(id))
        note("inject queued [\(id)] pending=\(pending) epoch=\(epoch)")
    }

    /// The hold released (delivered / fail-open / cell death): the card dies with it and
    /// the node is re-derived (a stall / perm card still standing keeps it at attention).
    private func injectSettled(_ id: NodeID, epoch: UInt64) {
        if staleInjectSignal(id, epoch: epoch) {
            return note("inject settled dropped: stale epoch \(epoch) for \(id)")
        }
        let had = notices.contains { $0.nodeID == id && $0.kind == .injectQueued }
        notices.removeAll { $0.nodeID == id && $0.kind == .injectQueued }
        guard had else { return }
        settle(id)
        note("inject settled [\(id)] epoch=\(epoch)")
    }

    // MARK: tree afterlife — on resume, graft the previous incarnation's skeleton back into the live tree + revive a single node on demand

    /// Graft a replayed previous-incarnation skeleton under the live root: every node
    /// enters with its replayed TERMINAL status (dead record — display + per-node
    /// resume target). Live truth wins: ids already present are never overwritten.
    /// The id mint jumps past every restored n<k> so future spawns cannot collide.
    private func restoreSkeleton(_ archived: Tree) {
        var grafted = 0
        for id in archived.subtree(of: archived.rootID) {
            if id.raw.hasPrefix("n"), let k = UInt64(id.raw.dropFirst()) {
                nodeSeq = max(nodeSeq, k)
            }
            guard id != archived.rootID, tree[id] == nil, var n = archived[id] else { continue }
            let parent = n.parent.flatMap { tree[$0] != nil ? $0 : nil } ?? tree.rootID
            n.parent = nil; n.children = []
            // A degraded parent (leaf in the replay) falls back to root — mirrors
            // SessionArchive.replay's own tolerance; the skeleton must survive.
            if (try? tree.spawn(parent: parent, child: n)) != nil
                || (try? tree.spawn(parent: tree.rootID, child: n)) != nil {
                grafted += 1
            }
        }
        note("restored skeleton: \(grafted) node(s) from previous incarnation")
    }

    /// Re-incarnate ONE dead node in place (revive exactly the one you click — workers never
    /// mass-revive). relaunch clears the frozen terminal state, so the sticky-terminal guard
    /// re-arms for the NEW lifetime; the cell relaunch leaves as an Effect.
    private func resumeNode(_ id: NodeID, sessionID: String) {
        guard let n = tree[id] else { return note("resume: no such node \(id)") }
        guard n.status.isTerminal else {
            return note("resume ignored: \(id) not terminal (\(n.status))")
        }
        tree.relaunch(id, status: .starting, startedAt: now())
        injectSignalEpoch.removeValue(forKey: id)   // new incarnation restarts epochs at 0
        perform(.resumeCell(node: tree[id]!, sessionID: sessionID))
        note("resume \(id): cell relaunching with --resume")
    }

    // MARK: turn lifecycle — the real running/idle signal; UserPromptSubmit opens
    // a turn, Stop closes it. A user DENY/ESC cancels the turn with NO hook at all —
    // the TurnWatcher scrape closes exactly this hole by emitting .turnEnded when the
    // running anchor leaves the screen.

    @ObservationIgnored private var openTurns: [NodeID: Int] = [:]
    @ObservationIgnored private var turnCounter = 0

    /// Nodes with an OPEN turn (UserPromptSubmit seen, no Stop yet) still marked
    /// running — the TurnWatcher's scrape scope (interrupt blind spot). The gen
    /// rides along so the watcher's verdict names WHICH turn it judged:
    /// an ESC'd turn never leaves this set by itself, so without the gen a stale
    /// verdict could land on the user's next prompt and kill it mid-run.
    public var openTurnRunningNodes: [(node: NodeID, gen: Int)] {
        openTurns.compactMap { id, gen in
            tree[id]?.status == .running ? (id, gen) : nil
        }
    }

    private func turnStarted(_ id: NodeID) {
        guard let n = tree[id], !n.status.isTerminal else { return }
        turnCounter += 1
        openTurns[id] = turnCounter        // new prompt = new gen; an ESC-unclosed old turn re-gens in place
        erroredNodes.remove(id)            // a new turn = the previous API-dead turn has been continued
        tree.setStatus(id, .running)
    }

    private func turnEnded(_ id: NodeID, gen: Int?) {
        if let gen, openTurns[id] != gen { return }   // wrong-gen / late scrape verdict: silently discard
        openTurns[id] = nil
        guard let n = tree[id], !n.status.isTerminal else { return }
        tree.setStatus(id, attentionStatus(id))   // waiting/stalled/queued/idle by priority
        note("turn ended [\(id)] -> \(tree[id]!.status)")
    }

    /// What a node with nothing left to attend to should show: mid-turn → running,
    /// turn closed → idle.
    private func restingStatus(_ id: NodeID) -> NodeStatus {
        openTurns[id] != nil ? .running : .idle
    }

    // MARK: struct apply (immediate — spawn/kill take effect immediately, no human approval waited on)

    private func applyStructNow(_ req: StructRequest, from: NodeID, replyID: UUID) {
        do {
            let result = try applyStruct(req, from: from)
            deliverOnce(replyID, .structResult(result))
        } catch TreeError.notInSubtree(let target, let caller) {
            // Cross-subtree kill — deny with readable text, tree untouched
            deliverOnce(replyID, .structResult(.denied(reason: "node \(target.raw) not in your subtree")))
            note("kill DENIED [\(from)]: \(target) not in \(caller)'s subtree")
        } catch {
            deliverOnce(replyID, .structResult(.failed(reason: "\(error)")))
            note("struct apply FAILED [\(from)]: \(error)")
        }
    }

    private func applyStruct(_ req: StructRequest, from: NodeID) throws -> StructResult {
        switch req {
        case .spawn(let parent, let role, let task, let model, let name):
            nodeSeq += 1
            // An explicit dispatch-time name wins the tree label; blank = task text.
            // The status dot + id badge to its left are untouched.
            let label = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let child = Node(id: NodeID("n\(nodeSeq)"), role: role, status: .starting,
                             title: (label?.isEmpty == false ? label! : task),
                             model: model, startedAt: now())
            try tree.spawn(parent: parent, child: child)
            perform(.spawnCell(node: tree[child.id]!, task: task))
            note("spawned \(child.id) (\(role)) under \(parent)")
            return .spawned(child.id)
        case .kill(let id):
            // Kill SEALS the whole subtree as dead records — the target and every
            // descendant STAY in the tree (clickable history), structure intact; only
            // live cells are reaped (already-dead descendants keep their frozen backend).
            // The target must be in the caller's subtree.
            let reaped = try tree.kill(id, by: from)    // live cells to tear down (target first)
            let sealed = tree.subtree(of: id)           // whole subtree — all dead records now
            for n in sealed { tree.setEnded(n, now()) } // freeze every node's clock (setEnded is sticky)
            cascadeTeardown(sealed)                     // drop the whole subtree's notices
            perform(.killCells(reaped))                 // reap only the live cells
            note("killed \(id): sealed \(sealed.map(\.raw)); reaped \(reaped.map(\.raw))")
            return .killed(sealed)
        }
    }

    // MARK: node self-death (DOCTRINE §2.6 / §6.4) — symmetric with kill

    private func selfDeath(_ id: NodeID, status: NodeStatus, why: String) {
        guard let node = tree[id] else { return note("self-death: no such node \(id)") }
        // Terminal status is sticky: a kill's teardown SIGTERMs the cell, and its
        // backend then reports THAT exit as a late nodeExited/nodeFailed — without
        // this guard the echo rewrites the terminal status (seen with the ghostty
        // backend: done → failed).
        if node.status.isTerminal {
            return note("self-death ignored: \(id) already terminal (\(node.status)) [\(why)]")
        }
        let sealed = tree.subtree(of: id)            // id + descendants — all become dead records
        cascadeTeardown(sealed)                      // drop the whole subtree's notices
        tree.setStatus(id, status)                   // dead node STAYS with its natural terminal status
        // Descendants STAY in the tree as dead records (structure preserved) — a dead
        // sub-manager's workers are never removed from the tree.
        // Setting the target terminal FIRST means sealSubtree skips it.
        let reaped = tree.sealSubtree(id)            // live descendants → .killed; returns their cells
        for n in sealed { tree.setEnded(n, now()) }  // freeze every node's clock (setEnded is sticky)
        // The dying node ITSELF is spared — its process already ended and its
        // backend is frozen on the final screen (the dead-node pane's lastFrame);
        // a teardown here would destroy exactly what the afterlife displays. Only
        // still-live descendants get reaped.
        if !reaped.isEmpty { perform(.killCells(reaped)) }
        note("self-death \(id) -> \(status) [\(why)]; sealed \(sealed.map(\.raw)); reaped \(reaped.map(\.raw))")
    }

    /// Teardown for dead nodes: drop their observation notices (a dead terminal has
    /// nothing left to attend to); still-standing permission cards count as resolved
    /// via node-death in the dogfood log. `deliverOnce` dedup stays for in-flight
    /// replies — struct requests resolve synchronously now, but the once-only guard
    /// (§6.4) is kept conservatively so a racing teardown can never double-deliver.
    private func cascadeTeardown(_ ids: [NodeID]) {
        let set = Set(ids)
        for id in set {
            openTurns[id] = nil                          // dead nodes have no turns
            stalledSpawns.remove(id)                     // …and no stall to recover
            erroredNodes.remove(id)                      // …and no API-error continuation
            injectSignalEpoch.removeValue(forKey: id)    // …and no inject epoch to track
        }
        let dropped = notices.filter { set.contains($0.nodeID) }
        notices.removeAll { set.contains($0.nodeID) }
        logResolved(dropped, via: .nodeDeath)
    }

    // MARK: observation notices
    // Cards are perm events plus the queued-inject card (there is no separate
    // idle/waiting-for-input slot — that would double-card the same box, see
    // NoticeKind): one card per box appearance, lives until the approval resolves.

    /// A permission box appeared (PermissionRequest). The hook fires exactly
    /// once per box (no debounce, no re-fire), so every fire is a NEW card — identical
    /// same-turn tuples become separate cards and resolve FIFO.
    private func permRequested(from: NodeID, info: PermNoticeInfo) {
        guard tree[from] != nil else { return note("perm notice: no such node \(from)") }
        seq += 1
        notices.append(AgentNotice(seq: seq, nodeID: from, kind: .permission, text: info.text,
                                   promptID: info.promptID, toolName: info.toolName,
                                   toolInput: info.toolInput, inputSummary: info.inputSummary,
                                   arrivedAt: now()))
        perform(.permLog(PermLogEntry(event: "perm_request", nodeID: from, kind: .permission,
                                      promptID: info.promptID, toolName: info.toolName,
                                      via: nil)))
        tree.setStatus(from, attentionStatus(from))   // .waiting (perm outranks queued/stalled)
        note("perm notice [\(from)] \(info.toolName ?? "?") prompt=\(info.promptID ?? "-")")
    }

    /// The approval actually resolved. match non-nil = PostToolUse pairing on the tuple
    /// (promptID, toolName, toolInput verbatim) — removes the OLDEST matching card (FIFO).
    /// match nil = node-wide (scrape saw the box vanish; a user deny cancels the whole
    /// turn, so everything pending there is dead). PostToolUse fires after
    /// EVERY tool execution — the un-carded ones are not perm events: silent no-op.
    private func resolveNotice(from: NodeID, match: PermResolveMatch?, via: NoticeResolvedVia) {
        // The queue card answers to injectSettled only — perm machinery (even a
        // node-wide scrape sweep) must not consume it.
        let candidates = notices.enumerated().filter { (_, n) in
            n.nodeID == from && n.kind != .injectQueued &&
            (match.map { n.promptID == $0.promptID && n.toolName == $0.toolName
                         && n.toolInput == $0.toolInput } ?? true)
        }
        guard !candidates.isEmpty else { return }
        // FIFO: tuple pairing consumes one card per resolution; node-wide takes all.
        let hit = match != nil ? [candidates.min(by: { $0.1.seq < $1.1.seq })!] : candidates
        let ids = Set(hit.map { $0.1.id })
        notices.removeAll { ids.contains($0.id) }
        logResolved(hit.map { $0.1 }, via: via, toolUseID: match?.toolUseID)
        settle(from)
        note("perm resolved [\(from)] via \(via.rawValue) ×\(hit.count)")
    }

    /// The user re-engaged that terminal (UserPromptSubmit) — every wait there is over,
    /// whatever the kind: a still-standing permission card at prompt time is the deny
    /// blind spot's tail and counts as resolved via prompt.
    private func clearNotices(_ id: NodeID) {
        let dropped = notices.filter { $0.nodeID == id }
        notices.removeAll { $0.nodeID == id }
        logResolved(dropped, via: .prompt)
        erroredNodes.remove(id)   // a human speaking again in this terminal = the API-dead turn has been taken over
        // Recompute from whatever attention signals remain (a stall survives a prompt).
        if let n = tree[id], n.status == .waiting || n.status == .queued || n.status == .errored {
            tree.setStatus(id, attentionStatus(id))
        }
    }

    /// Re-derive the node's status from whatever attention signals remain. Called after a
    /// card is removed (resolveNotice / injectSettled): no hard `.waiting` guard, so a node
    /// that is simultaneously stalled + queued can never deadlock — the deriver's priority
    /// decides, and a still-standing card of a higher tier keeps it at the human.
    private func settle(_ id: NodeID) {
        guard let n = tree[id], !n.status.isTerminal else { return }
        tree.setStatus(id, attentionStatus(id))
    }

    /// Dogfood egress for resolved permission cards. Queue cards are not
    /// perm events — a prompt/teardown sweep that drops one leaves the telemetry alone.
    private func logResolved(_ dropped: [AgentNotice], via: NoticeResolvedVia,
                             toolUseID: String? = nil) {
        for n in dropped where n.kind != .injectQueued {
            perform(.permLog(PermLogEntry(event: "perm_resolve", nodeID: n.nodeID, kind: n.kind,
                                          promptID: n.promptID, toolName: n.toolName,
                                          toolUseID: toolUseID, via: via.rawValue)))
        }
    }

    // MARK: routing / rollup (§6.2)

    /// Upward aggregation: record summary, relay to parent along the edge (§6.5).
    /// Currently single level (child → direct parent).
    private func applyRollup(from: NodeID, summary: String) {
        guard tree[from] != nil else { return note("rollup: no such node \(from)") }
        tree.setRollup(from, summary)
        if let parent = tree[from]?.parent {
            perform(.route(to: parent, text: "CHILD_ROLLUP:\(summary)",
                           viaPath: tree.path(from: from, to: parent), replyID: nil))
        }
        note("rollup [\(from)] \(summary)")
    }

    /// Send never falsely reports delivery: every drop resolves the sender's reply as a
    /// failure and leaves a routeFailed Effect for the orchestration.jsonl trail — a send
    /// that cannot reach its target must be VISIBLE to the manager, not a silent note.
    private func routeMessage(from: NodeID, to: NodeID, text: String, replyID: UUID?) {
        func fail(_ reason: String, ackNote: String) {
            note("route FAILED: \(reason) \(from)->\(to)")
            perform(.routeFailed(from: from, to: to, reason: reason))
            if let replyID { deliverOnce(replyID, .sendAck(delivered: false, note: ackNote)) }
        }
        guard let target = tree[to] else {
            return fail("no such node",
                        ackNote: "node \(to) not reachable: no such node in the tree (killed or never existed)")
        }
        guard !target.status.isTerminal else {
            // self-death / kill keep the node for display, but its cell is gone (§2.6)
            return fail("node terminal (\(target.status))",
                        ackNote: "node \(to) not reachable: node is \(target.status), no live cell")
        }
        let p = tree.path(from: from, to: to)
        guard !p.isEmpty else {
            return fail("no path", ackNote: "node \(to) not reachable: no route from \(from)")
        }
        perform(.route(to: to, text: text, viaPath: p, replyID: replyID))
        note("route \(from)->\(to) via \(p.map(\.raw).joined(separator: "->"))")
    }

    // MARK: util

    private func deliverOnce(_ replyID: UUID, _ r: Resolution) {
        guard !deliveredReplies.contains(replyID) else { return }   // §6.4 once
        deliveredReplies.insert(replyID)
        perform(.deliver(replyID: replyID, r))
    }
    /// Append to the never-silent-fail log (§5.2). Public so the runtime layer
    /// can record Effect-side notes into the same single source of truth.
    public func note(_ s: String) { log.append(s) }
}
