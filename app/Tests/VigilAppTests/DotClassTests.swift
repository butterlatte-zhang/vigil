import XCTest
@testable import VigilApp
@testable import VigilCore

/// Status-dot unification. Both the sidebar session
/// row and the top-right node tree classify a state into ONE of four dot buckets via a
/// single classifier `dotClass(status, unseen)`:
///   spinner — running / starting (working);
///   blue    — a run finished and you haven't looked (idle / done, one-time, view-to-clear);
///   yellow  — anything that needs a glance (waiting / stalled / queued always; errored /
///             failed until you view the node);
///   plain   — default (sidebar: nothing; tree: hollow ring) — killed, or a seen completion/error.
@MainActor
final class DotClassTests: XCTestCase {

    // MARK: the full mapping table — every NodeStatus × {unseen, seen}

    func testSpinnerStates() {
        // starting → pure spinner (stalled covers a genuine failed-to-connect spawn in yellow).
        XCTAssertEqual(dotClass(.starting, unseen: true), .spinner)
        XCTAssertEqual(dotClass(.starting, unseen: false), .spinner)
        XCTAssertEqual(dotClass(.running, unseen: true), .spinner)
        XCTAssertEqual(dotClass(.running, unseen: false), .spinner)
    }

    /// Live-condition attention: yellow regardless of "seen" — these clear when the
    /// CONDITION resolves (perm answered / hold released / spawn connects), not by viewing.
    func testLiveConditionAlwaysYellow() {
        for s in [NodeStatus.waiting, .stalled, .queued] {
            XCTAssertEqual(dotClass(s, unseen: true), .yellow, "\(s) unseen")
            XCTAssertEqual(dotClass(s, unseen: false), .yellow, "\(s) seen")
        }
    }

    /// Event attention: errored/failed are yellow until the user views the node, then
    /// fall back to default (failed joins errored's view-to-clear behavior — neither state
    /// stays yellow forever with no clear path). Honesty: yellow WHILE unseen, never swallowed.
    func testErroredFailedViewToClear() {
        XCTAssertEqual(dotClass(.errored, unseen: true), .yellow)
        XCTAssertEqual(dotClass(.errored, unseen: false), .plain)
        XCTAssertEqual(dotClass(.failed, unseen: true), .yellow)
        XCTAssertEqual(dotClass(.failed, unseen: false), .plain)
    }

    /// Completion: idle (turn ended, alive) and done (terminal) light blue until viewed
    /// (every running→idle is a "it finished something, look" beat), then default.
    func testCompletionBlueThenPlain() {
        XCTAssertEqual(dotClass(.idle, unseen: true), .blue)
        XCTAssertEqual(dotClass(.idle, unseen: false), .plain)
        XCTAssertEqual(dotClass(.done, unseen: true), .blue)
        XCTAssertEqual(dotClass(.done, unseen: false), .plain)
    }

    /// killed = a deliberate termination — never attention; default in both seen states
    /// (the "Terminated" fact rides the status text + the row dimming, not a dot).
    func testKilledAlwaysPlain() {
        XCTAssertEqual(dotClass(.killed, unseen: true), .plain)
        XCTAssertEqual(dotClass(.killed, unseen: false), .plain)
    }

    // MARK: per-node unseen transition rule (pure — the reconcile glue is thin over this)

    func testUnseenMutationRule() {
        // running→idle behind your back = a completion you haven't seen → mark.
        XCTAssertEqual(unseenMutation(prev: .running, now: .idle, watching: false), .mark)
        // …but if you're looking right at it as it lands, it's already seen → don't light.
        XCTAssertEqual(unseenMutation(prev: .running, now: .idle, watching: true), .clear)
        // errored / failed / done are all "look-at-me" transitions.
        XCTAssertEqual(unseenMutation(prev: .running, now: .errored, watching: false), .mark)
        XCTAssertEqual(unseenMutation(prev: .running, now: .failed, watching: false), .mark)
        XCTAssertEqual(unseenMutation(prev: .running, now: .done, watching: false), .mark)
        // live conditions are NOT view-to-clear — they never enter the unseen set.
        XCTAssertEqual(unseenMutation(prev: .running, now: .waiting, watching: false), .none)
        XCTAssertEqual(unseenMutation(prev: .idle, now: .queued, watching: false), .none)
        XCTAssertEqual(unseenMutation(prev: .running, now: .stalled, watching: false), .none)
        // resuming work / starting / being killed clears any stale unseen mark.
        XCTAssertEqual(unseenMutation(prev: .idle, now: .running, watching: false), .clear)
        XCTAssertEqual(unseenMutation(prev: .idle, now: .killed, watching: false), .clear)
        // no status change = no mutation (idempotent — a re-derivation to the same state
        // must not re-light a dot the user already cleared).
        XCTAssertEqual(unseenMutation(prev: .errored, now: .errored, watching: false), .none)
        XCTAssertEqual(unseenMutation(prev: .idle, now: .idle, watching: false), .none)
    }

    // MARK: session rollup goes through the SAME classifier (single source)

    private func tree(root: NodeStatus, children: [NodeStatus] = []) -> Tree {
        var t = Tree(root: Node(id: NodeID("root"), role: .manager, status: root))
        for (i, s) in children.enumerated() {
            try! t.spawn(parent: NodeID("root"),
                         child: Node(id: NodeID("n\(i + 1)"), role: .leaf, status: s))
        }
        return t
    }

    /// sessionDotClass = the sidebar's dot, derived from the session rollup + the
    /// session-level completedUnseen (which keeps its own granularity, unchanged).
    func testSessionDotClass() {
        // attention rollup → yellow.
        XCTAssertEqual(sessionDotClass(badge: 0, tree: tree(root: .running, children: [.waiting]),
                                       completedUnseen: false), .yellow)
        // working rollup → spinner.
        XCTAssertEqual(sessionDotClass(badge: 0, tree: tree(root: .running),
                                       completedUnseen: false), .spinner)
        // rest + completedUnseen → blue; rest + seen → plain.
        XCTAssertEqual(sessionDotClass(badge: 0, tree: tree(root: .idle),
                                       completedUnseen: true), .blue)
        XCTAssertEqual(sessionDotClass(badge: 0, tree: tree(root: .idle),
                                       completedUnseen: false), .plain)
        // a working node outranks a stale unseen-done flag — spinner wins.
        XCTAssertEqual(sessionDotClass(badge: 0, tree: tree(root: .running),
                                       completedUnseen: true), .spinner)
    }

    // MARK: per-node unseen lifecycle on a real SessionVM (view-to-clear end to end)

    /// Exercised through the real store: a turn that ends / errors behind
    /// your back lights the node (blue / yellow); selecting the node row = viewed = it
    /// falls back to default. Driven synchronously (send + reconcile) so no async pump.
    func testNodeUnseenLifecycle() {
        let vm = SessionVM(id: "s1", name: "t", rootCwd: NSTemporaryDirectory(), initialTask: "x")
        let root = vm.store.tree.rootID
        // Seeded at init — a fresh running root is not spuriously "unseen".
        XCTAssertFalse(vm.isNodeUnseen(root))

        // running → idle (turn done) while unfocused → blue-worthy unseen.
        vm.store.send(.turnEnded(root, gen: nil))
        XCTAssertEqual(vm.store.tree[root]?.status, .idle)
        vm.reconcileUnseen()
        XCTAssertTrue(vm.isNodeUnseen(root))
        XCTAssertEqual(dotClass(vm.store.tree[root]!.status, unseen: vm.isNodeUnseen(root)), .blue)

        // selecting the node = viewed → cleared → default.
        vm.select(root)
        XCTAssertFalse(vm.isNodeUnseen(root))
        XCTAssertEqual(dotClass(vm.store.tree[root]!.status, unseen: vm.isNodeUnseen(root)), .plain)

        // new turn clears any stale mark; an API-error turn death re-lights (yellow) until viewed.
        vm.store.send(.turnStarted(root))
        vm.reconcileUnseen()
        XCTAssertFalse(vm.isNodeUnseen(root))
        vm.store.send(.turnErrored(root))
        XCTAssertEqual(vm.store.tree[root]?.status, .errored)
        vm.reconcileUnseen()
        XCTAssertTrue(vm.isNodeUnseen(root))
        XCTAssertEqual(dotClass(vm.store.tree[root]!.status, unseen: vm.isNodeUnseen(root)), .yellow)
        vm.select(root)
        XCTAssertFalse(vm.isNodeUnseen(root))   // the errored dot has a clear path now
        XCTAssertEqual(dotClass(vm.store.tree[root]!.status, unseen: vm.isNodeUnseen(root)), .plain)
    }

    /// Watching a node as its turn lands = already seen: it must NOT light behind glass.
    func testWatchedNodeNotMarked() {
        let vm = SessionVM(id: "s2", name: "t", rootCwd: NSTemporaryDirectory(), initialTask: "x")
        let root = vm.store.tree.rootID
        vm.isFocused = { true }          // session focused …
        vm.select(root)                  // … and this node is the one on screen
        vm.store.send(.turnEnded(root, gen: nil))
        vm.reconcileUnseen()
        XCTAssertFalse(vm.isNodeUnseen(root))
    }

    /// A node goes blue while you're away, then you switch INTO its session from the
    /// sidebar. markCompletionSeen (the focus-arrival hook) must clear the tree dot of the
    /// node you land on — no second click in the tree.
    func testFocusArrivalClearsViewedNodeDot() {
        let vm = SessionVM(id: "s3", name: "t", rootCwd: NSTemporaryDirectory(), initialTask: "x")
        let root = vm.store.tree.rootID
        vm.store.send(.turnEnded(root, gen: nil))
        vm.reconcileUnseen()                 // unfocused turn-end → root lit blue
        XCTAssertTrue(vm.isNodeUnseen(root))
        vm.markCompletionSeen()              // sidebar switch lands focus on this session
        XCTAssertFalse(vm.isNodeUnseen(root))  // the viewed node's dot is cleared in the same beat
    }

    /// The reconcile invariant guard: once you are watching a node, a later reconcile pass
    /// (fired by any node's status change) can never leave the viewed node blue, even if it
    /// was marked earlier while unfocused.
    func testReconcileNeverLeavesViewedNodeBlue() {
        let vm = SessionVM(id: "s4", name: "t", rootCwd: NSTemporaryDirectory(), initialTask: "x")
        let root = vm.store.tree.rootID
        vm.store.send(.turnEnded(root, gen: nil))
        vm.reconcileUnseen()                 // marked blue while unfocused
        XCTAssertTrue(vm.isNodeUnseen(root))
        vm.isFocused = { true }              // you are now viewing this node …
        vm.select(root)
        vm.reconcileUnseen()                 // … a subsequent reconcile keeps it clear
        XCTAssertFalse(vm.isNodeUnseen(root))
    }
}
