import XCTest
@testable import VigilApp
@testable import VigilCore

/// The tree panel's runtime column is a PURE render of the model's
/// startedAt/endedAt stamps (SessionStore's injected clock); the panel holds no clock
/// state of its own, so rebuilds (panel toggling/switching sessions) can never reset or cross-wire it.
final class TreePanelRuntimeTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func node(_ status: NodeStatus, startedAt: Date? = nil,
                      endedAt: Date? = nil) -> Node {
        Node(id: NodeID("n1"), role: .leaf, status: status, title: "task",
             startedAt: startedAt, endedAt: endedAt)
    }

    func testLiveNodeCountsFromModelStartedAt() {
        XCTAssertEqual(nodeRuntimeText(node(.running, startedAt: t0),
                                       now: t0.addingTimeInterval(125)), "2m 05s")
        XCTAssertEqual(nodeRuntimeText(node(.idle, startedAt: t0),
                                       now: t0.addingTimeInterval(59)), "59s")
        XCTAssertEqual(nodeRuntimeText(node(.waiting, startedAt: t0),
                                       now: t0.addingTimeInterval(3_900)), "1h 05m")
    }

    func testTerminalNodeFreezesAtEndedAt() {
        let n = node(.done, startedAt: t0, endedAt: t0.addingTimeInterval(61))
        // Long after death the display must NOT keep counting.
        XCTAssertEqual(nodeRuntimeText(n, now: t0.addingTimeInterval(99_999)), "1m 01s")
    }

    func testGhostAndUnstampedShowDash() {
        // starting = ghost (not yet approved/online) — dash even though spawn stamped it.
        XCTAssertEqual(nodeRuntimeText(node(.starting, startedAt: t0),
                                       now: t0.addingTimeInterval(5)), "—")
        // No stamp at all (defensive: a node that never passed through the store).
        XCTAssertEqual(nodeRuntimeText(node(.running), now: t0), "—")
    }

    // MARK: "Hide finished": flatten skips terminal nodes and recomputes connectors

    /// root ├─ a(running) ├─ b(done) └─ c(killed): hiding the finished ones must drop
    /// b and c AND recompute a's lineage (a becomes the LAST visible child → └).
    private func deadMixTree() -> VigilCore.Tree {
        var t = VigilCore.Tree(root: Node(id: NodeID("root"), role: .manager, status: .running))
        try? t.spawn(parent: NodeID("root"), child: Node(id: NodeID("a"), role: .leaf, status: .running))
        try? t.spawn(parent: NodeID("root"), child: Node(id: NodeID("b"), role: .leaf, status: .done))
        try? t.spawn(parent: NodeID("root"), child: Node(id: NodeID("c"), role: .leaf, status: .killed))
        return t
    }

    func testFlattenDefaultKeepsTerminalNodes() {
        let rows = flattenTree(deadMixTree())
        XCTAssertEqual(rows.map(\.node.id.raw), ["root", "a", "b", "c"])
    }

    func testFlattenHideFinishedSkipsTerminalAndFixesLineage() {
        let rows = flattenTree(deadMixTree(), hideFinished: true)
        XCTAssertEqual(rows.map(\.node.id.raw), ["root", "a"])
        XCTAssertEqual(rows[1].lineage, [true])   // a is now the last VISIBLE child (└)
    }

    func testFlattenHideFinishedKeepsTerminalRoot() {
        // The root is the record anchor — it must survive the filter even when terminal.
        let t = VigilCore.Tree(root: Node(id: NodeID("root"), role: .manager, status: .done))
        let rows = flattenTree(t, hideFinished: true)
        XCTAssertEqual(rows.map(\.node.id.raw), ["root"])
    }

    // MARK: auto-focus — the tree card scrolls the SELECTED row into view (follows selection changes)

    /// The scroll target for a selection is that node's id — but ONLY when it has a
    /// visible row. Every path that moves selection (sidebar row / ⌘⇧[] / ⌘⇧U / notification card)
    /// funnels through `selectedID`, so pinning target = selectedID pins them all.
    func testScrollTargetIsSelectedWhenVisible() {
        let rows = flattenTree(deadMixTree())          // root, a, b, c all visible
        XCTAssertEqual(treeScrollTarget(rows: rows, selected: NodeID("c")), NodeID("c"))
        XCTAssertEqual(treeScrollTarget(rows: rows, selected: NodeID("root")), NodeID("root"))
    }

    /// A selection hidden by "Hide finished" has no row to reach — no scroll (nil), never a
    /// scroll to an off-list id that would silently jump nowhere.
    func testScrollTargetNilWhenSelectionHidden() {
        let rows = flattenTree(deadMixTree(), hideFinished: true)   // only root, a
        XCTAssertNil(treeScrollTarget(rows: rows, selected: NodeID("b")))
        XCTAssertEqual(treeScrollTarget(rows: rows, selected: NodeID("a")), NodeID("a"))
    }
}
