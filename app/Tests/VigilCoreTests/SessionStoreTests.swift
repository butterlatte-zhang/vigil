import XCTest
@testable import VigilCore

/// The brain, driven deterministically with no real agent: struct changes (spawn/kill/etc.)
/// apply immediately with no human decide step; notices are the observation stream
/// (permRequested/resolveNotice/clearNotices — permission events only, there is no idle
/// slot); kill/self-death cascades drop notices.
@MainActor
final class SessionStoreTests: XCTestCase {

    private func makeStore() -> (SessionStore, () -> [Effect]) {
        var effects: [Effect] = []
        let root = Node(id: NodeID("root"), role: .manager, status: .running, title: "root")
        let store = SessionStore(root: root) { effects.append($0) }
        return (store, { effects })
    }

    /// Spawn applies immediately — returns the new child's id.
    @discardableResult
    private func spawn(_ s: SessionStore, parent: NodeID, role: Role = .leaf,
                       task: String = "t", replyID: UUID = UUID()) -> NodeID {
        s.send(.requestStruct(.spawn(parent: parent, role: role, task: task),
                              from: parent, replyID: replyID))
        return s.tree[parent]!.children.last!
    }

    // MARK: immediate spawn (the load-bearing flow — no human gate)

    func testSpawnAppliesImmediatelyAndDeliversChildId() {
        let (s, effects) = makeStore()
        let reply = UUID()
        s.send(.requestStruct(.spawn(parent: NodeID("root"), role: .leaf, task: "sum 1..10"),
                              from: NodeID("root"), replyID: reply))

        // tree gained a leaf child WITHOUT any decide step
        XCTAssertEqual(s.tree.root.children.count, 1)
        let childID = s.tree.root.children[0]
        XCTAssertEqual(s.tree[childID]?.role, .leaf)

        // effects: spawnCell + deliver(.structResult(.spawned(childID)))
        let es = effects()
        XCTAssertTrue(es.contains { if case .spawnCell(let n, let t) = $0 { return n.id == childID && t == "sum 1..10" }; return false })
        XCTAssertTrue(es.contains(.deliver(replyID: reply, .structResult(.spawned(childID)))))
    }

    // MARK: dispatch-time display name (spawn name?)

    func testSpawnWithNameUsesItAsTreeTitle() {
        let (s, _) = makeStore()
        s.send(.requestStruct(.spawn(parent: NodeID("root"), role: .leaf,
                                     task: "handle all fixes for GitHub issue #49 …… a very long task brief",
                                     model: nil, name: "issue-49 fix"),
                              from: NodeID("root"), replyID: UUID()))
        let childID = s.tree.root.children[0]
        XCTAssertEqual(s.tree[childID]?.title, "issue-49 fix",
                       "explicit name = the tree label; status dot / id badge are unaffected")
    }

    func testSpawnBlankNameFallsBackToTask() {
        let (s, _) = makeStore()
        s.send(.requestStruct(.spawn(parent: NodeID("root"), role: .leaf,
                                     task: "sum 1..10", model: nil, name: "   "),
                              from: NodeID("root"), replyID: UUID()))
        let childID = s.tree.root.children[0]
        XCTAssertEqual(s.tree[childID]?.title, "sum 1..10",
                       "blank name = unspecified, keep the task text (pre-#54 shape)")
    }

    func testLeafCannotSpawnYieldsFailed() {
        let (s, effects) = makeStore()
        let leafID = spawn(s, parent: NodeID("root"), task: "leaf")
        // leaf requests its own spawn → apply throws → deliver(.failed), no new node
        let r2 = UUID()
        s.send(.requestStruct(.spawn(parent: leafID, role: .leaf, task: "nope"),
                              from: leafID, replyID: r2))
        XCTAssertEqual(s.tree.count, 2)                      // no new node
        XCTAssertTrue(effects().contains { if case .deliver(let id, .structResult(.failed)) = $0 { return id == r2 }; return false })
        // never silent-fail: the failure is logged
        XCTAssertTrue(s.log.contains { $0.contains("struct apply FAILED") })
    }

    // MARK: rollup (single level, child → parent)

    func testRollupRecordsAndRoutesToParent() {
        let (s, effects) = makeStore()
        let childID = spawn(s, parent: NodeID("root"))

        s.send(.rollup(from: childID, summary: "leaf-summary{sum=55}"))

        XCTAssertEqual(s.tree[childID]?.lastRollup, "leaf-summary{sum=55}")
        XCTAssertTrue(effects().contains { eff in
            if case .route(let to, let text, _, _) = eff { return to == NodeID("root") && text.contains("sum=55") }
            return false
        })
    }

    // MARK: observation notices (the PermissionRequest hook feeds the UI; there is no idle card)

    func testClearNoticesRemovesAndResumesRunning() {
        let (s, _) = makeStore()
        let childID = spawn(s, parent: NodeID("root"))
        s.send(.nodeOnline(childID))
        s.send(.permRequested(from: childID, info: permInfo()))
        XCTAssertEqual(s.tree[childID]?.status, .waiting)

        // user re-engaged the terminal — the gateway pairs the prompt as
        // turnStarted + clearNotices, matching the real emission order.
        s.send(.turnStarted(childID))
        s.send(.clearNotices(childID))

        XCTAssertTrue(s.notices.isEmpty)
        XCTAssertEqual(s.tree[childID]?.status, .running)    // waiting → running (turn open)
    }

    func testClearNoticesDoesNotTouchNonWaitingStatus() {
        let (s, _) = makeStore()
        let childID = spawn(s, parent: NodeID("root"))
        s.send(.nodeExited(childID, code: 0))                // terminal status .done
        s.send(.clearNotices(childID))
        XCTAssertEqual(s.tree[childID]?.status, .done)       // untouched
    }

    // MARK: spawn liveness — stalled/recovered (the Core side of honestly reporting a
    // fake-alive state: a node existing in the tree ≠ the process being alive; watchdog
    // verdicts arrive via the Command path; stalled is an independent state, it must not
    // masquerade as .waiting's "awaiting authorization" — a spawn that may never have been
    // born cannot claim to be waiting for your approval)

    func testSpawnStalledSetsStalledAndRecoveredSettlesBack() {
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.nodeOnline(c))                       // launch optimistically markOnline → running
        s.send(.spawnStalled(c))
        XCTAssertEqual(s.tree[c]?.status, .stalled,
                       "stalled = independent state (F1: doesn't ride on waiting; awaiting authorization is the perm card's word)")
        XCTAssertTrue(s.log.contains { $0.contains("spawn stalled") }, "never-silent-fail")

        s.send(.spawnRecovered(c))
        XCTAssertEqual(s.tree[c]?.status, .idle,
                       "agent_connected = indicator cleared; no open turn → resting = idle")
    }

    func testSpawnStalledIgnoresTerminalNode() {
        // A late watchdog verdict must not rewrite a dead node (same discipline as terminal-status stickiness).
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.nodeExited(c, code: 0))
        s.send(.spawnStalled(c))
        XCTAssertEqual(s.tree[c]?.status, .done)
    }

    func testSpawnRecoveredWithoutStallIsNoop() {
        // waiting may come from a real permission card — a recovered with no stall record on file must not touch it.
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.nodeOnline(c))
        s.send(.permRequested(from: c, info: permInfo()))
        XCTAssertEqual(s.tree[c]?.status, .waiting)
        s.send(.spawnRecovered(c))
        XCTAssertEqual(s.tree[c]?.status, .waiting, "a perm wait must not be cleared by an unrelated recovered")
    }

    func testSpawnRecoveredKeepsWaitingWhilePermCardPending() {
        // stalled and a permission card coexisting (rare but constructible): recovered
        // only clears the stall flag; while the card is still present, it must still read
        // waiting — settle's invariant of "only downgrade when there's nothing left to wait on."
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.spawnStalled(c))
        s.send(.permRequested(from: c, info: permInfo()))
        s.send(.spawnRecovered(c))
        XCTAssertEqual(s.tree[c]?.status, .waiting)
    }

    func testStalledNodeReturnsToStalledAfterPermResolves() {
        // A stall + a perm card coexisting, and the perm resolves first: the node must not
        // land on idle — the stall flag is still set, so attentionStatus falls back to
        // .stalled by priority (waiting > stalled). A settle that hard-checks "== .waiting"
        // would wrongly clear the stall here.
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.spawnStalled(c))
        s.send(.permRequested(from: c, info: permInfo()))
        XCTAssertEqual(s.tree[c]?.status, .waiting, "perm card present → perm takes priority")
        s.send(.resolveNotice(from: c, match: nil, via: .scrape))
        XCTAssertEqual(s.tree[c]?.status, .stalled,
                       "after perm leaves, stall still set → back to .stalled, must not fall to idle")
    }

    func testSpawnStalledFlagDiesWithTheNode() {
        // The stall flag is cleaned up on node death (cascadeTeardown); a late recovered is harmless.
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.spawnStalled(c))
        s.send(.requestStruct(.kill(c), from: NodeID("root"), replyID: UUID()))
        XCTAssertEqual(s.tree[c]?.status, .killed)
        s.send(.spawnRecovered(c))
        XCTAssertEqual(s.tree[c]?.status, .killed)
    }

    // MARK: API-error turn death = .errored (an independent attention state, mirroring
    // stalled: it doesn't ride on waiting/awaiting-authorization; it's not terminal, and
    // can be cleared by the next turn/re-engage)

    func testTurnErroredSetsErroredIndependentState() {
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.nodeOnline(c))
        s.send(.turnErrored(c))
        XCTAssertEqual(s.tree[c]?.status, .errored,
                       "errored = independent state (doesn't ride on waiting; an API-dead turn does not masquerade as awaiting authorization)")
        XCTAssertTrue(s.log.contains { $0.contains("turn errored") }, "never-silent-fail")
    }

    func testTurnErroredClearedByNewTurn() {
        // Resuming = a new turn opens: the errored flag clears, the node returns to running.
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.turnErrored(c))
        XCTAssertEqual(s.tree[c]?.status, .errored)
        s.send(.turnStarted(c))
        XCTAssertEqual(s.tree[c]?.status, .running, "new turn = recovered, errored flag cleared")
    }

    func testTurnErroredClearedByUserPrompt() {
        // A human speaking again in that terminal (UserPromptSubmit→clearNotices) also counts as recovery.
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.nodeOnline(c))
        s.send(.turnErrored(c))
        s.send(.turnEnded(c, gen: nil))                 // the turn has closed, but still errored
        XCTAssertEqual(s.tree[c]?.status, .errored)
        s.send(.clearNotices(c))
        XCTAssertEqual(s.tree[c]?.status, .idle, "re-engage clears errored → falls back to resting")
    }

    func testTurnErroredKeepsWaitingWhilePermCardPending() {
        // Priority waiting > errored: with a permission card present, errored must not downgrade it.
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.permRequested(from: c, info: permInfo()))
        s.send(.turnErrored(c))
        XCTAssertEqual(s.tree[c]?.status, .waiting)
        s.send(.resolveNotice(from: c, match: nil, via: .scrape))
        XCTAssertEqual(s.tree[c]?.status, .errored, "after perm leaves, errored still set → back to .errored")
    }

    func testTurnErroredIgnoresTerminalNode() {
        // A late verdict must not rewrite a dead node (terminal-status stickiness).
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.nodeExited(c, code: 0))
        s.send(.turnErrored(c))
        XCTAssertEqual(s.tree[c]?.status, .done)
    }

    func testTurnErroredFlagDiesWithTheNode() {
        // The errored flag is cleaned up on node death (cascadeTeardown) — no leftovers for revival/late verdicts.
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.turnErrored(c))
        s.send(.requestStruct(.kill(c), from: NodeID("root"), replyID: UUID()))
        XCTAssertEqual(s.tree[c]?.status, .killed)
    }

    // MARK: kill cascade (mirrors self-death) — the killed node STAYS as a dead
    // record, its notices drop, its cells tear down, live descendants are reaped

    func testKillKeepsNodeAsKilledDropsNoticesAndKillsCells() {
        let (s, effects) = makeStore()
        let aID = spawn(s, parent: NodeID("root"), role: .manager, task: "A")
        s.send(.permRequested(from: aID, info: permInfo()))
        XCTAssertEqual(s.notices.count, 1)

        let rKill = UUID()
        s.send(.requestStruct(.kill(aID), from: NodeID("root"), replyID: rKill))

        XCTAssertEqual(s.tree[aID]?.status, .killed)                // stays, terminal status
        XCTAssertTrue(s.notices.isEmpty)                            // dead node's notices dropped
        XCTAssertTrue(effects().contains(.deliver(replyID: rKill, .structResult(.killed([aID])))))
        XCTAssertTrue(effects().contains { if case .killCells(let ids) = $0 { return ids.contains(aID) }; return false })
    }

    // killing a sub-manager SEALS its whole subtree as dead records — every node
    // STAYS in the tree (clickable history), structure intact, live cells reaped.
    func testKillSealsSubtreeAsDeadRecords() {
        let (s, effects) = makeStore()
        let aID = spawn(s, parent: NodeID("root"), role: .manager, task: "A")
        let bID = spawn(s, parent: aID, task: "B")
        s.send(.permRequested(from: bID, info: permInfo()))

        let rKill = UUID()
        s.send(.requestStruct(.kill(aID), from: NodeID("root"), replyID: rKill))

        XCTAssertEqual(s.tree[aID]?.status, .killed)               // A stays as dead record
        XCTAssertEqual(s.tree[aID]?.children, [bID])               // structure preserved
        XCTAssertEqual(s.tree[bID]?.status, .killed)               // descendant STAYS as dead record
        XCTAssertTrue(s.notices.isEmpty)                           // both notices dropped (cascade over whole subtree)
        XCTAssertTrue(effects().contains(.deliver(replyID: rKill, .structResult(.killed([aID, bID])))))
        XCTAssertTrue(effects().contains { if case .killCells(let ids) = $0 { return ids.contains(aID) && ids.contains(bID) }; return false })
    }

    // An already-dead descendant keeps its OWN terminal status (not rewritten to
    // .killed) and its frozen cell is spared — only the still-live cell is reaped.
    func testKillPreservesAlreadyDeadDescendant() {
        let (s, effects) = makeStore()
        let aID = spawn(s, parent: NodeID("root"), role: .manager, task: "A")
        let bID = spawn(s, parent: aID, task: "B")
        let cID = spawn(s, parent: aID, task: "C")
        s.send(.nodeExited(bID, code: 0))                          // B self-died → .done

        s.send(.requestStruct(.kill(aID), from: NodeID("root"), replyID: UUID()))

        XCTAssertEqual(s.tree[aID]?.status, .killed)
        XCTAssertEqual(s.tree[bID]?.status, .done)                 // NOT rewritten
        XCTAssertEqual(s.tree[cID]?.status, .killed)
        // only the live cells (A, C) get torn down; B's frozen backend is spared.
        XCTAssertTrue(effects().contains { if case .killCells(let ids) = $0 { return ids.contains(aID) && ids.contains(cID) && !ids.contains(bID) }; return false })
    }

    /// Kill freezes the runtime clock the same way self-death does.
    func testKillFreezesRuntimeClock() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let (s, _) = makeClockedStore(now: { t0 })
        let c = spawn(s, parent: NodeID("root"))
        s.send(.requestStruct(.kill(c), from: NodeID("root"), replyID: UUID()))
        XCTAssertEqual(s.tree[c]?.endedAt, t0)
    }

    /// The clock freezes for the WHOLE sealed subtree, not just the target.
    func testKillFreezesRuntimeClockForDescendants() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let (s, _) = makeClockedStore(now: { t0 })
        let aID = spawn(s, parent: NodeID("root"), role: .manager, task: "A")
        let bID = spawn(s, parent: aID, task: "B")
        s.send(.requestStruct(.kill(aID), from: NodeID("root"), replyID: UUID()))
        XCTAssertEqual(s.tree[aID]?.endedAt, t0)
        XCTAssertEqual(s.tree[bID]?.endedAt, t0)               // descendant clock frozen too
    }

    // MARK: cross-subtree kill is denied (caller must own the target)

    func testKillSiblingSubtreeIsDenied() {
        let (s, effects) = makeStore()
        let aID = spawn(s, parent: NodeID("root"), role: .manager, task: "A")
        let cID = spawn(s, parent: NodeID("root"), task: "C")

        let r = UUID()
        s.send(.requestStruct(.kill(cID), from: aID, replyID: r))   // A kills sibling C

        XCTAssertNotNil(s.tree[cID])                                // untouched
        XCTAssertTrue(effects().contains {
            if case .deliver(let id, .structResult(.denied(let reason))) = $0 {
                return id == r && reason == "node \(cID.raw) not in your subtree"
            }
            return false
        })
        XCTAssertFalse(effects().contains { if case .killCells = $0 { return true }; return false })
    }

    func testKillParentIsDenied() {
        let (s, _) = makeStore()
        let aID = spawn(s, parent: NodeID("root"), role: .manager, task: "A")
        let bID = spawn(s, parent: aID, role: .manager, task: "B")

        s.send(.requestStruct(.kill(aID), from: bID, replyID: UUID()))   // B kills its parent A

        XCTAssertNotNil(s.tree[aID])
        XCTAssertNotNil(s.tree[bID])
    }

    func testKillInsideOwnSubtreeStillWorks() {
        let (s, effects) = makeStore()
        let aID = spawn(s, parent: NodeID("root"), role: .manager, task: "A")
        let bID = spawn(s, parent: aID, task: "B")

        let r = UUID()
        s.send(.requestStruct(.kill(bID), from: aID, replyID: r))   // A kills its own child

        XCTAssertEqual(s.tree[bID]?.status, .killed)                // stays as dead record
        XCTAssertTrue(effects().contains(.deliver(replyID: r, .structResult(.killed([bID])))))
    }

    // MARK: self-death — node stays with terminal status, descendants reaped, notices dropped

    // Self-death SEALS the whole subtree as dead records too — the descendant
    // STAYS (clickable history) with .killed, structure intact; A itself keeps its
    // natural terminal status and its cell is spared.
    func testSelfDeathSealsSubtreeAsDeadRecords() {
        let (s, effects) = makeStore()
        // root → A(manager) → B(leaf)
        let aID = spawn(s, parent: NodeID("root"), role: .manager, task: "A")
        let bID = spawn(s, parent: aID, task: "B")
        s.send(.permRequested(from: bID, info: permInfo()))

        // A crashes
        s.send(.nodeFailed(aID, reason: "boom"))

        XCTAssertEqual(s.tree[aID]?.status, .failed)               // A stays, natural terminal status
        XCTAssertEqual(s.tree[aID]?.children, [bID])               // structure preserved
        XCTAssertEqual(s.tree[bID]?.status, .killed)               // descendant STAYS as dead record
        XCTAssertTrue(s.notices.isEmpty)                           // B's notice dropped
        // only the live descendant is reaped — A's own cell already died and its
        // backend keeps the frozen last frame; a coup de grâce would destroy it.
        XCTAssertTrue(effects().contains { if case .killCells(let ids) = $0 { return ids.contains(bID) && !ids.contains(aID) }; return false })
    }

    // On self-death an already-dead descendant keeps its own status and its frozen
    // cell is spared; only the still-live descendant is reaped.
    func testSelfDeathPreservesAlreadyDeadDescendant() {
        let (s, effects) = makeStore()
        let aID = spawn(s, parent: NodeID("root"), role: .manager, task: "A")
        let bID = spawn(s, parent: aID, task: "B")
        let cID = spawn(s, parent: aID, task: "C")
        s.send(.nodeExited(bID, code: 0))                          // B self-died → .done

        s.send(.nodeFailed(aID, reason: "boom"))                   // A crashes

        XCTAssertEqual(s.tree[aID]?.status, .failed)
        XCTAssertEqual(s.tree[bID]?.status, .done)                 // NOT rewritten
        XCTAssertEqual(s.tree[cID]?.status, .killed)
        // only the live descendant C is reaped — A (natural death) and B (already
        // frozen) are both spared.
        XCTAssertTrue(effects().contains { if case .killCells(let ids) = $0 { return ids == [cID] }; return false })
    }

    /// Self-death must never put the dying node ITSELF into killCells — the
    /// process already exited naturally and the backend is holding the final screen
    /// for the dead-node pane; only its live descendants get torn down.
    func testSelfDeathKillCellsExcludesSelf() {
        let (s, effects) = makeStore()
        let aID = spawn(s, parent: NodeID("root"), role: .manager, task: "A")
        let bID = spawn(s, parent: aID, task: "B")

        s.send(.nodeExited(aID, code: 0))                          // user exits claude in A

        XCTAssertEqual(s.tree[aID]?.status, .done)
        XCTAssertTrue(effects().contains { if case .killCells(let ids) = $0 { return ids == [bID] }; return false })
        XCTAssertFalse(effects().contains { if case .killCells(let ids) = $0 { return ids.contains(aID) }; return false })
    }

    /// A leaf with no descendants has nothing to reap — natural death emits
    /// NO killCells at all (the effect stream stays honest: no empty teardown).
    func testLeafSelfDeathEmitsNoKillCells() {
        let (s, effects) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.nodeExited(c, code: 0))
        XCTAssertEqual(s.tree[c]?.status, .done)
        XCTAssertFalse(effects().contains { if case .killCells = $0 { return true }; return false })
    }

    func testNodeExitedZeroIsDone() {
        let (s, _) = makeStore()
        let childID = spawn(s, parent: NodeID("root"))
        s.send(.nodeExited(childID, code: 0))
        XCTAssertEqual(s.tree[childID]?.status, .done)
    }

    /// Terminal status is STICKY: after done, the teardown's own exit report (the cell
    /// gets SIGTERMed by killCells → backend reports a nonzero exit) must NOT rewrite
    /// the node to failed.
    func testTerminalStatusSticky_lateExitReportIgnored() {
        let (s, _) = makeStore()
        let childID = spawn(s, parent: NodeID("root"))
        s.send(.nodeExited(childID, code: 0))                      // done (terminal)
        s.send(.nodeExited(childID, code: 15))                     // teardown echo
        XCTAssertEqual(s.tree[childID]?.status, .done)             // stays done
        s.send(.nodeFailed(childID, reason: "late crash report"))
        XCTAssertEqual(s.tree[childID]?.status, .done)             // still done
    }

    // MARK: deliver-once — a reused replyID must still deliver exactly once

    func testSameReplyIDDeliversOnce() {
        let (s, effects) = makeStore()
        let r = UUID()
        s.send(.requestStruct(.spawn(parent: NodeID("root"), role: .leaf, task: "a"),
                              from: NodeID("root"), replyID: r))
        s.send(.requestStruct(.spawn(parent: NodeID("root"), role: .leaf, task: "b"),
                              from: NodeID("root"), replyID: r))   // reused replyID

        let delivers = effects().filter { if case .deliver(let id, _) = $0 { return id == r }; return false }
        XCTAssertEqual(delivers.count, 1)                          // delivered exactly once
    }

    // MARK: turn lifecycle → NodeStatus (UserPromptSubmit→Stop = running · Stop with
    // nothing pending = idle · unresolved notice = waiting · terminal only on process exit)

    func testTurnEndedWithNothingPendingGoesIdle() {
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.nodeOnline(c))
        s.send(.turnStarted(c))
        XCTAssertEqual(s.tree[c]?.status, .running)
        s.send(.turnEnded(c, gen: nil))
        XCTAssertEqual(s.tree[c]?.status, .idle)
        s.send(.turnStarted(c))                          // next prompt → running again
        XCTAssertEqual(s.tree[c]?.status, .running)
    }

    func testTurnEndedWithPendingNoticeStaysWaiting() {
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.turnStarted(c))
        s.send(.permRequested(from: c, info: permInfo()))
        XCTAssertEqual(s.tree[c]?.status, .waiting)
        s.send(.turnEnded(c, gen: nil))
        XCTAssertEqual(s.tree[c]?.status, .waiting)      // a card outranks idle
    }

    func testNoticeResolutionSettlesToIdleWhenTurnIsClosed() {
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.turnStarted(c))
        s.send(.permRequested(from: c, info: permInfo()))
        s.send(.turnEnded(c, gen: nil))                            // box still up: waiting
        XCTAssertEqual(s.tree[c]?.status, .waiting)
        s.send(.resolveNotice(from: c, match: nil, via: .scrape))
        XCTAssertEqual(s.tree[c]?.status, .idle)         // turn closed → idle, not running
    }

    func testNoticeResolutionSettlesToRunningWhenTurnIsOpen() {
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.turnStarted(c))
        s.send(.permRequested(from: c, info: permInfo()))
        XCTAssertEqual(s.tree[c]?.status, .waiting)
        s.send(.resolveNotice(from: c, match: nil, via: .postTool))
        XCTAssertEqual(s.tree[c]?.status, .running)      // mid-turn approval → keeps working
    }

    func testTurnSignalsNeverResurrectTerminalNodes() {
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.nodeExited(c, code: 0))                  // done (sticky)
        s.send(.turnStarted(c))
        s.send(.turnEnded(c, gen: nil))
        XCTAssertEqual(s.tree[c]?.status, .done)
    }

    func testTurnSignalsOnUnknownNodeAreSafeNoops() {
        let (s, _) = makeStore()
        s.send(.turnStarted(NodeID("ghost")))
        s.send(.turnEnded(NodeID("ghost"), gen: nil))
        XCTAssertEqual(s.tree.count, 1)                  // nothing exploded, nothing grew
    }

    func testStaleGenerationTurnEndedIsDropped() {
        // A scrape verdict names a generation explicitly. After ESC, the old
        // turn doesn't close (no Stop hook fires); the user submitting a new prompt swaps
        // in a new generation in place — a late verdict for the old generation must not
        // kill the new turn, while the current generation applies normally; a hook-sourced
        // gen=nil closes unconditionally (already covered by the tests above).
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.nodeOnline(c))
        s.send(.turnStarted(c))
        guard let g1 = s.openTurnRunningNodes.first(where: { $0.node == c })?.gen else {
            return XCTFail("expected an open turn for \(c)")
        }
        s.send(.turnStarted(c))                          // new prompt: same node, new generation
        guard let g2 = s.openTurnRunningNodes.first(where: { $0.node == c })?.gen else {
            return XCTFail("expected the new turn to be open")
        }
        XCTAssertNotEqual(g1, g2, "one new generation per prompt")
        s.send(.turnEnded(c, gen: g1))                   // stale-generation verdict arriving late
        XCTAssertEqual(s.tree[c]?.status, .running, "stale-generation verdict silently dropped, new turn keeps running")
        s.send(.turnEnded(c, gen: g2))                   // current-generation verdict
        XCTAssertEqual(s.tree[c]?.status, .idle)
        s.send(.turnEnded(c, gen: g2))                   // duplicate scrape verdict after close
        s.send(.turnStarted(c))
        XCTAssertEqual(s.tree[c]?.status, .running, "a duplicate stale verdict does not affect subsequent turns")
    }

    // MARK: notice slots & lifecycle (permission cards live until RESOLVED)

    /// Deterministic-clock store for grace/first-seen assertions.
    private func makeClockedStore(now: @escaping () -> Date) -> (SessionStore, () -> [Effect]) {
        var effects: [Effect] = []
        let root = Node(id: NodeID("root"), role: .manager, status: .running, title: "root")
        let store = SessionStore(root: root, now: now) { effects.append($0) }
        return (store, { effects })
    }

    private func permInfo(promptID: String? = "p1", toolName: String? = "Bash",
                          toolInput: String? = #"{"command":"git push"}"#,
                          inputSummary: String? = "git push", text: String = "Bash permission request")
    -> PermNoticeInfo {
        PermNoticeInfo(promptID: promptID, toolName: toolName, toolInput: toolInput,
                       inputSummary: inputSummary, text: text)
    }

    /// The PostToolUse-side tuple matching `permInfo` (adds tool_use_id, for logging only).
    private func match(promptID: String? = "p1", toolName: String? = "Bash",
                       toolInput: String? = #"{"command":"git push"}"#,
                       toolUseID: String? = "toolu_1") -> PermResolveMatch {
        PermResolveMatch(promptID: promptID, toolName: toolName,
                         toolInput: toolInput, toolUseID: toolUseID)
    }

    func testPermRequestedCreatesPermissionNoticeAndLogsRequest() {
        let (s, effects) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.nodeOnline(c))

        s.send(.permRequested(from: c, info: permInfo()))

        XCTAssertEqual(s.notices.count, 1)
        let n = s.notices[0]
        XCTAssertEqual(n.kind, .permission)
        XCTAssertEqual(n.promptID, "p1")
        XCTAssertEqual(n.toolName, "Bash")
        XCTAssertEqual(n.toolInput, #"{"command":"git push"}"#)
        XCTAssertEqual(n.inputSummary, "git push")
        XCTAssertEqual(s.tree[c]?.status, .waiting)
        // dogfood: the request is counted via the Effect egress (world side appends jsonl)
        XCTAssertTrue(effects().contains { eff in
            if case .permLog(let e) = eff {
                return e.event == "perm_request" && e.nodeID == c && e.promptID == "p1"
            }
            return false
        })
    }

    func testIdenticalTuplesAreSeparateCardsResolvedFIFO() {
        // PermissionRequest fires exactly once per box; identical same-turn tuples
        // (prompt_id is TURN-scoped, not per-call) are separate cards, resolved FIFO.
        let (s, effects) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.permRequested(from: c, info: permInfo()))
        s.send(.permRequested(from: c, info: permInfo()))
        XCTAssertEqual(s.notices.count, 2)
        let firstID = s.notices[0].id

        s.send(.resolveNotice(from: c, match: match(), via: .postTool))

        XCTAssertEqual(s.notices.count, 1)                        // one resolution eats ONE card
        XCTAssertNotEqual(s.notices[0].id, firstID)               // …the OLDEST one (FIFO)
        let reqs = effects().filter { if case .permLog(let e) = $0 { return e.event == "perm_request" }; return false }
        XCTAssertEqual(reqs.count, 2)                             // dogfood counts each box
    }

    func testResolveNoticeByTuplePairing() {
        // The pairing tuple: prompt_id + tool_name + tool_input verbatim. Same turn
        // (same prompt_id), two DIFFERENT boxes — PostToolUse resolves exactly its own.
        let (s, effects) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.permRequested(from: c, info: permInfo(toolInput: #"{"command":"git push"}"#)))
        s.send(.permRequested(from: c, info: permInfo(toolInput: #"{"command":"npm test"}"#)))

        s.send(.resolveNotice(from: c, match: match(toolInput: #"{"command":"git push"}"#),
                              via: .postTool))

        XCTAssertEqual(s.notices.count, 1)
        XCTAssertEqual(s.notices[0].toolInput, #"{"command":"npm test"}"#)
        XCTAssertEqual(s.tree[c]?.status, .waiting)               // one box still pending
        XCTAssertTrue(effects().contains { eff in
            if case .permLog(let e) = eff {
                return e.event == "perm_resolve" && e.via == "post-tool"
                    && e.toolUseID == "toolu_1"                   // correlation tag, not a key
            }
            return false
        })
    }

    func testResolveNoticeNodeWideClearsAllPermissionCards() {
        // match=nil (robustness/scrape semantics): the box vanished — everything pending
        // on that node is over (deny cancels the whole turn).
        let (s, effects) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.permRequested(from: c, info: permInfo(toolInput: "a")))
        s.send(.permRequested(from: c, info: permInfo(toolInput: "b")))

        s.send(.resolveNotice(from: c, match: nil, via: .scrape))

        XCTAssertTrue(s.notices.isEmpty)
        XCTAssertEqual(s.tree[c]?.status, .idle)                  // settled, no turn open
        let resolves = effects().filter { if case .permLog(let e) = $0 { return e.event == "perm_resolve" && e.via == "scrape" }; return false }
        XCTAssertEqual(resolves.count, 2)                         // one dogfood line per card
    }

    func testResolveNoticeWithoutMatchingCardIsSilentNoop() {
        // PostToolUse fires after EVERY tool execution — the un-carded ones (no permission
        // box ever appeared) must not log, must not touch status.
        let (s, effects) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.nodeOnline(c))
        let before = effects().count

        s.send(.resolveNotice(from: c, match: match(), via: .postTool))

        XCTAssertEqual(effects().count, before)
        XCTAssertEqual(s.tree[c]?.status, .running)
        XCTAssertTrue(s.notices.isEmpty)
    }

    func testUserPromptClearsCardsAndLogsPromptResolution() {
        // UserPromptSubmit (card master table): user typed in that terminal — every card there is
        // over. Any still-standing permission card resolved "via prompt" (post-deny path).
        let (s, effects) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.permRequested(from: c, info: permInfo()))

        s.send(.turnStarted(c))                   // gateway pairing: prompt opens a turn
        s.send(.clearNotices(c))

        XCTAssertTrue(s.notices.isEmpty)
        XCTAssertEqual(s.tree[c]?.status, .running)
        XCTAssertTrue(effects().contains { eff in
            if case .permLog(let e) = eff { return e.event == "perm_resolve" && e.via == "prompt" }
            return false
        })
    }

    func testNodeDeathResolvesPermissionCards() {
        let (s, effects) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.permRequested(from: c, info: permInfo()))

        s.send(.requestStruct(.kill(c), from: NodeID("root"), replyID: UUID()))

        XCTAssertTrue(s.notices.isEmpty)
        XCTAssertTrue(effects().contains { eff in
            if case .permLog(let e) = eff { return e.event == "perm_resolve" && e.via == "node-death" }
            return false
        })
    }

    func testPermissionGraceWindowOnDisplayAfter() {
        // A ~2.5s Vigil-side grace: a permission card only becomes VISIBLE after the
        // grace so instant approvals never flash a card. The notice itself exists at once
        // (resolve must be able to find it); arrivedAt is the real injected clock.
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let (s, _) = makeClockedStore(now: { t0 })
        s.send(.requestStruct(.spawn(parent: NodeID("root"), role: .leaf, task: "t"),
                              from: NodeID("root"), replyID: UUID()))
        let c = s.tree.root.children[0]
        s.send(.permRequested(from: c, info: permInfo()))

        let perm = s.notices.first { $0.kind == .permission }!
        XCTAssertEqual(perm.arrivedAt, t0)
        XCTAssertEqual(perm.displayAfter, t0.addingTimeInterval(AgentNotice.permissionGrace))
    }

    func testPermRequestedUnknownNodeIsDropped() {
        let (s, _) = makeStore()
        s.send(.permRequested(from: NodeID("ghost"), info: permInfo()))
        XCTAssertTrue(s.notices.isEmpty)
    }

    // MARK: node clock stamps (runtime truth lives in the MODEL, stamped by the
    // store's injected clock; TreePanel is a pure renderer of these fields. startedAt =
    // task creation (spawn / session bootstrap), endedAt = the terminal moment.)

    func testSpawnStampsStartedAtWithStoreClock() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let (s, _) = makeClockedStore(now: { t0 })
        s.send(.requestStruct(.spawn(parent: NodeID("root"), role: .leaf, task: "t"),
                              from: NodeID("root"), replyID: UUID()))
        let c = s.tree.root.children[0]
        XCTAssertEqual(s.tree[c]?.startedAt, t0)              // stamped at task creation
        XCTAssertNil(s.tree[c]?.endedAt)                      // still alive
    }

    func testRootStartedAtStampedAtInit() {
        // The root is planted by the app (not spawned) — the store's bootstrap stamps it.
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let (s, _) = makeClockedStore(now: { t0 })
        XCTAssertEqual(s.tree.root.startedAt, t0)
    }

    func testTerminalExitStampsEndedAt() {
        var nowDate = Date(timeIntervalSince1970: 1_000_000)
        let t0 = nowDate
        let (s, _) = makeClockedStore(now: { nowDate })
        s.send(.requestStruct(.spawn(parent: NodeID("root"), role: .leaf, task: "t"),
                              from: NodeID("root"), replyID: UUID()))
        let c = s.tree.root.children[0]

        nowDate = t0.addingTimeInterval(90)
        s.send(.nodeExited(c, code: 0))                       // → done (terminal stays in tree)

        XCTAssertEqual(s.tree[c]?.startedAt, t0)              // start untouched
        XCTAssertEqual(s.tree[c]?.endedAt, t0.addingTimeInterval(90))
    }

    func testEndedAtStickyLikeTerminalStatus() {
        // The teardown echo (SIGTERMed cell reports its own exit) must not move the
        // frozen clock — same stickiness as the terminal status itself.
        var nowDate = Date(timeIntervalSince1970: 1_000_000)
        let t0 = nowDate
        let (s, _) = makeClockedStore(now: { nowDate })
        s.send(.requestStruct(.spawn(parent: NodeID("root"), role: .leaf, task: "t"),
                              from: NodeID("root"), replyID: UUID()))
        let c = s.tree.root.children[0]
        nowDate = t0.addingTimeInterval(60)
        s.send(.nodeExited(c, code: 0))

        nowDate = t0.addingTimeInterval(300)
        s.send(.nodeExited(c, code: 15))                      // teardown echo
        s.send(.nodeFailed(c, reason: "late crash report"))

        XCTAssertEqual(s.tree[c]?.endedAt, t0.addingTimeInterval(60))
    }

    func testTurnSignalsDoNotStampEndedAt() {
        // idle/waiting are DISPLAY states, not terminal — the clock keeps running.
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let (s, _) = makeClockedStore(now: { t0 })
        s.send(.requestStruct(.spawn(parent: NodeID("root"), role: .leaf, task: "t"),
                              from: NodeID("root"), replyID: UUID()))
        let c = s.tree.root.children[0]
        s.send(.turnStarted(c))
        s.send(.turnEnded(c, gen: nil))
        XCTAssertEqual(s.tree[c]?.status, .idle)
        XCTAssertNil(s.tree[c]?.endedAt)
    }

    // MARK: message routing via LCA

    func testMessageRoutesViaTreePath() {
        let (s, effects) = makeStore()
        // root → A → B ; root → C ; message B→C should route via [B,A,root,C]
        let aID = spawn(s, parent: NodeID("root"), role: .manager, task: "A")
        let bID = spawn(s, parent: aID, task: "B")
        let cID = spawn(s, parent: NodeID("root"), task: "C")

        s.send(.message(from: bID, to: cID, text: "hi", replyID: nil))
        XCTAssertTrue(effects().contains { eff in
            if case .route(let to, let text, let via, _) = eff {
                return to == cID && text == "hi" && via == [bID, aID, NodeID("root"), cID]
            }
            return false
        })
    }

    /// Manager→worker downlink (the MCP `send` tool path): direct parent→child edge.
    /// The send's replyID rides the route Effect so the runtime can ack delivery.
    func testMessageParentToChildRoutes() {
        let (s, effects) = makeStore()
        let childID = spawn(s, parent: NodeID("root"))
        let r = UUID()
        s.send(.message(from: NodeID("root"), to: childID,
                        text: "MESSAGE FROM root: continue", replyID: r))
        XCTAssertTrue(effects().contains { eff in
            if case .route(let to, let text, _, let rid) = eff {
                return to == childID && text == "MESSAGE FROM root: continue" && rid == r
            }
            return false
        })
    }

    // MARK: send delivery verdict (send never lies about delivery)

    func testMessageToUnknownNodeFailsTheReply() {
        // Target never existed: no route Effect; the reply resolves as a failure the
        // MCP send tool can surface (isError), and the drop lands as a routeFailed
        // Effect for the orchestration.jsonl trail.
        let (s, effects) = makeStore()
        let r = UUID()
        s.send(.message(from: NodeID("root"), to: NodeID("ghost"), text: "hi", replyID: r))

        let es = effects()
        XCTAssertFalse(es.contains { if case .route = $0 { return true }; return false })
        XCTAssertTrue(es.contains { eff in
            if case .deliver(let id, .sendAck(false, let note)) = eff {
                return id == r && note.contains("not reachable")
            }
            return false
        })
        XCTAssertTrue(es.contains(.routeFailed(from: NodeID("root"), to: NodeID("ghost"),
                                               reason: "no such node")))
        XCTAssertTrue(s.log.contains { $0.contains("route FAILED") })
    }

    func testMessageToKilledNodeFailsTheReply() {
        // The killed node stays in the tree as a dead record, but its cell is
        // gone — a later send must fail (terminal-status path), not vanish.
        let (s, effects) = makeStore()
        let childID = spawn(s, parent: NodeID("root"))
        s.send(.requestStruct(.kill(childID), from: NodeID("root"), replyID: UUID()))

        let r = UUID()
        s.send(.message(from: NodeID("root"), to: childID, text: "hello?", replyID: r))
        XCTAssertTrue(effects().contains { eff in
            if case .deliver(let id, .sendAck(false, let note)) = eff {
                return id == r && note.contains("not reachable")
            }
            return false
        })
    }

    func testMessageToSelfDeadNodeFailsTheReply() {
        // Self-death keeps the node in the tree (terminal status, for display) but its
        // cell is gone — send must fail with "no live cell", not ride a dead route.
        let (s, effects) = makeStore()
        let childID = spawn(s, parent: NodeID("root"))
        s.send(.nodeOnline(childID))
        s.send(.nodeExited(childID, code: 0))               // node stays, status .done

        let r = UUID()
        s.send(.message(from: NodeID("root"), to: childID, text: "hello?", replyID: r))
        XCTAssertTrue(effects().contains { eff in
            if case .deliver(let id, .sendAck(false, let note)) = eff {
                return id == r && note.contains("no live cell")
            }
            return false
        })
        XCTAssertFalse(effects().contains { eff in
            if case .route(let to, _, _, _) = eff { return to == childID }
            return false
        })
    }

    // MARK: tree afterlife (resume grafts the skeleton) + per-node resume

    /// The replayed previous-incarnation tree a resume grafts in (mirrors what
    /// SessionArchive.replay produces: terminal statuses, parent edges, n<k> ids).
    private func archivedSkeleton() -> Tree {
        var t = Tree(root: Node(id: NodeID("root"), role: .manager, status: .killed,
                                title: "old root task"))
        try! t.spawn(parent: NodeID("root"),
                     child: Node(id: NodeID("n1"), role: .manager, status: .done,
                                 title: "old worker A",
                                 endedAt: Date(timeIntervalSince1970: 100)))
        try! t.spawn(parent: NodeID("n1"),
                     child: Node(id: NodeID("n2"), role: .leaf, status: .killed,
                                 title: "old worker B"))
        return t
    }

    func testRestoreSkeletonGraftsDeadNodesAndBumpsIdMint() {
        let (s, effects) = makeStore()
        s.send(.restoreSkeleton(archivedSkeleton()))

        // Skeleton grafted into the tree: terminal statuses as-is, parent/child edges kept; the live root itself is not overwritten (still running).
        XCTAssertEqual(s.tree.count, 3)
        XCTAssertEqual(s.tree.root.status, .running)
        XCTAssertEqual(s.tree[NodeID("n1")]?.status, .done)
        XCTAssertEqual(s.tree[NodeID("n1")]?.parent, NodeID("root"))
        XCTAssertEqual(s.tree[NodeID("n2")]?.parent, NodeID("n1"))
        // The graft produces no world side effects (display-only records, no cell launched).
        XCTAssertTrue(effects().isEmpty)

        // id minting skips n1/n2 — a fresh spawn never collides with a restored id.
        let fresh = spawn(s, parent: NodeID("root"), task: "new job")
        XCTAssertEqual(fresh, NodeID("n3"))
    }

    func testResumeNodeRelaunchesTerminalNodeAndEmitsEffect() {
        let (s, effects) = makeStore()
        s.send(.restoreSkeleton(archivedSkeleton()))

        s.send(.resumeNode(NodeID("n1"), sessionID: "sid-w1"))

        // relaunch clears the terminal freeze: status back to starting, endedAt thawed — the new incarnation's exit can land again.
        XCTAssertEqual(s.tree[NodeID("n1")]?.status, .starting)
        XCTAssertNil(s.tree[NodeID("n1")]?.endedAt)
        XCTAssertTrue(effects().contains { eff in
            if case .resumeCell(let n, let sid) = eff {
                return n.id == NodeID("n1") && sid == "sid-w1"
            }
            return false
        })

        // The new incarnation runs to its terminal status normally (the sticky guard re-applies to the new incarnation).
        s.send(.nodeExited(NodeID("n1"), code: 0))
        XCTAssertEqual(s.tree[NodeID("n1")]?.status, .done)
    }

    func testResumeNodeIgnoresLiveNode() {
        let (s, effects) = makeStore()
        let live = spawn(s, parent: NodeID("root"), task: "still alive")
        let before = effects().count

        s.send(.resumeNode(live, sessionID: "sid-x"))

        XCTAssertEqual(s.tree[live]?.status, .starting)      // untouched
        XCTAssertEqual(effects().count, before, "a live node is not re-hatched, no side effects")
        XCTAssertTrue(s.log.contains { $0.contains("resume ignored") })
    }

    // MARK: the queue must speak up — a task message held behind the human's own typing
    // becomes a card + a .queued status (NOT .waiting — the process is alive, no perm
    // box); the card dies when the hold releases, never via click.

    func testInjectQueuedCreatesCardAndMarksQueued() {
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.nodeOnline(c))

        s.send(.injectQueued(c, pending: 1, epoch: 1))

        XCTAssertEqual(s.notices.count, 1)
        XCTAssertEqual(s.notices[0].kind, .injectQueued)
        XCTAssertEqual(s.notices[0].nodeID, c)
        XCTAssertTrue(s.notices[0].text.contains("1"), "the card text carries the queued count")
        // Independent state: queued ≠ awaiting approval (honesty red line, mirrors .stalled)
        XCTAssertEqual(s.tree[c]?.status, .queued)
    }

    func testInjectQueuedUpsertsOneCardPerNode() {
        // Count refreshes rewrite the card IN PLACE: same id/seq/arrivedAt (stack must
        // not churn; the clock is the FIRST hold moment), only the text moves.
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.injectQueued(c, pending: 1, epoch: 1))
        let first = s.notices[0]

        s.send(.injectQueued(c, pending: 2, epoch: 2))

        XCTAssertEqual(s.notices.count, 1, "one card per node, upsert in place, no card stacking")
        XCTAssertEqual(s.notices[0].id, first.id)
        XCTAssertEqual(s.notices[0].seq, first.seq)
        XCTAssertEqual(s.notices[0].arrivedAt, first.arrivedAt)
        XCTAssertTrue(s.notices[0].text.contains("2"))
    }

    func testInjectSettledRemovesCardAndSettlesToIdle() {
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.injectQueued(c, pending: 1, epoch: 1))
        XCTAssertEqual(s.tree[c]?.status, .queued)

        s.send(.injectSettled(c, epoch: 2))

        XCTAssertTrue(s.notices.isEmpty)
        XCTAssertEqual(s.tree[c]?.status, .idle)             // no open turn → idle
    }

    func testInjectSettledWithOpenTurnReturnsRunning() {
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.turnStarted(c))
        s.send(.injectQueued(c, pending: 1, epoch: 1))

        s.send(.injectSettled(c, epoch: 2))

        XCTAssertEqual(s.tree[c]?.status, .running)          // turn still in flight
    }

    func testInjectSettledLeavesStandingPermCardWaiting() {
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.permRequested(from: c, info: permInfo()))
        s.send(.injectQueued(c, pending: 1, epoch: 1))
        XCTAssertEqual(s.tree[c]?.status, .waiting)          // perm outranks queued

        s.send(.injectSettled(c, epoch: 2))

        XCTAssertEqual(s.notices.count, 1)                   // perm card survives
        XCTAssertEqual(s.notices[0].kind, .permission)
        XCTAssertEqual(s.tree[c]?.status, .waiting)
    }

    func testInjectCardsEmitNoPermTelemetry() {
        // The queue card is not a perm event: its whole lifecycle must leave
        // perm_dogfood.jsonl untouched — including a prompt-time clearNotices sweep.
        let (s, effects) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.injectQueued(c, pending: 1, epoch: 1))
        s.send(.injectSettled(c, epoch: 2))
        s.send(.injectQueued(c, pending: 1, epoch: 3))
        s.send(.clearNotices(c))
        s.send(.injectQueued(c, pending: 1, epoch: 4))
        s.send(.nodeExited(c, code: 0))                      // cascade teardown path

        XCTAssertFalse(effects().contains { if case .permLog = $0 { return true }; return false },
                       "the inject card's whole lifecycle must not pollute perm telemetry")
        XCTAssertTrue(s.notices.isEmpty)
    }

    func testNodeWidePermResolveSparesInjectCard() {
        // PermWatcher's node-wide sweep (box vanished) resolves PERM cards only —
        // the queue card answers to injectSettled, not to permission machinery.
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.permRequested(from: c, info: permInfo()))
        s.send(.injectQueued(c, pending: 1, epoch: 1))

        s.send(.resolveNotice(from: c, match: nil, via: .scrape))

        XCTAssertEqual(s.notices.count, 1)
        XCTAssertEqual(s.notices[0].kind, .injectQueued)
        XCTAssertEqual(s.tree[c]?.status, .queued)           // perm gone, queue card owns it
    }

    func testInjectQueuedOnTerminalNodeIsDropped() {
        // Cell death races the settle callback — a late queued signal must never
        // resurrect a dead record.
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.nodeExited(c, code: 0))

        s.send(.injectQueued(c, pending: 1, epoch: 1))

        XCTAssertTrue(s.notices.isEmpty)
        XCTAssertEqual(s.tree[c]?.status, .done)
    }

    func testNodeDeathDropsInjectCard() {
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.injectQueued(c, pending: 1, epoch: 1))

        s.send(.nodeExited(c, code: 1))

        XCTAssertTrue(s.notices.isEmpty)                     // cascadeTeardown sweeps it
    }

    // MARK: orphan-card race — the load-bearing concurrency regression

    func testStaleQueuedSignalAfterSettleLeavesNoOrphanCard() {
        // The orphan-card race: RealCell's held=true count-refresh is emitted
        // BEFORE the held=false settle but, each crossing its own MainActor hop, can be
        // APPLIED after it. Reproduce that exact reorder at the store boundary — a queued
        // signal whose epoch is OLDER than the last settle must be dropped, or it rebuilds
        // a card the settle just removed (node stuck .queued forever, card never dies).
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.nodeOnline(c))

        s.send(.injectQueued(c, pending: 1, epoch: 1))       // card up
        XCTAssertEqual(s.notices.count, 1)
        s.send(.injectSettled(c, epoch: 3))                  // hold released — card down
        XCTAssertTrue(s.notices.isEmpty)
        s.send(.injectQueued(c, pending: 2, epoch: 2))       // STALE refresh (epoch 2 < 3)

        XCTAssertTrue(s.notices.isEmpty, "a stale-epoch queued signal must not rebuild an orphan card")
        XCTAssertNotEqual(s.tree[c]?.status, .queued, "the node must not get stuck in queued state")
        XCTAssertEqual(s.tree[c]?.status, .idle)             // settled, nothing pending
    }

    // MARK: crossed state — a node can be stalled AND queued at once; the attention
    // deriver's priority (waiting > stalled > queued) resolves it uniquely, and recovery
    // leaves no orphan card and no deadlock, whichever signal arrives first.

    func testStalledThenQueuedResolvesByPriority() {
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.spawnStalled(c))
        XCTAssertEqual(s.tree[c]?.status, .stalled)

        s.send(.injectQueued(c, pending: 1, epoch: 1))
        // stalled outranks queued: the card stands but the node still reads .stalled
        XCTAssertEqual(s.tree[c]?.status, .stalled)
        XCTAssertTrue(s.notices.contains { $0.kind == .injectQueued && $0.nodeID == c })

        s.send(.spawnRecovered(c))
        // stall cleared → the queue card now owns the status
        XCTAssertEqual(s.tree[c]?.status, .queued)

        s.send(.injectSettled(c, epoch: 2))
        XCTAssertTrue(s.notices.isEmpty, "no orphan card")
        XCTAssertEqual(s.tree[c]?.status, .idle)             // nothing left → no deadlock
    }

    func testQueuedThenStalledResolvesByPriority() {
        let (s, _) = makeStore()
        let c = spawn(s, parent: NodeID("root"))
        s.send(.injectQueued(c, pending: 1, epoch: 1))
        XCTAssertEqual(s.tree[c]?.status, .queued)

        s.send(.spawnStalled(c))
        // stalled outranks queued
        XCTAssertEqual(s.tree[c]?.status, .stalled)
        XCTAssertTrue(s.notices.contains { $0.kind == .injectQueued }, "the queue card is still present")

        s.send(.injectSettled(c, epoch: 2))
        // queue card gone, but the stall still needs a human — must NOT settle to resting
        XCTAssertTrue(s.notices.isEmpty)
        XCTAssertEqual(s.tree[c]?.status, .stalled)

        s.send(.spawnRecovered(c))
        XCTAssertEqual(s.tree[c]?.status, .idle)             // last signal cleared
    }
}
