import XCTest
@testable import VigilApp
@testable import VigilCore

/// The sidebar session-row indicator is a PURE derivation of node statuses (+ unread
/// badge); a session has no lifecycle state of its own. Display semantics:
///   spinner (live)   — ONLY running/starting somewhere in the tree (actually doing work);
///   yellow (attention) — a node waits for the human (waiting) or unread notices exist;
///   static (rest)    — everything else: idle, or the whole tree terminal (done/failed).
@MainActor
final class SessionIndicatorTests: XCTestCase {

    /// root(manager) with the given status, plus leaf children n1... with the given statuses.
    private func tree(root: NodeStatus, children: [NodeStatus] = []) -> Tree {
        var t = Tree(root: Node(id: NodeID("root"), role: .manager, status: root))
        for (i, s) in children.enumerated() {
            try! t.spawn(parent: NodeID("root"),
                         child: Node(id: NodeID("n\(i + 1)"), role: .leaf, status: s))
        }
        return t
    }

    func testRunningRootIsLive() {
        XCTAssertEqual(sessionIndicator(badge: 0, tree: tree(root: .running)), .live)
    }

    func testStartingWorkerIsLive() {
        XCTAssertEqual(sessionIndicator(badge: 0, tree: tree(root: .idle, children: [.starting])),
                       .live)
    }

    /// The decree's core case: an agent idle waiting on human input must STOP the spinner
    /// and show the static attention dot instead — even while another node still runs
    /// (to alert the human to come look).
    func testWaitingIsAttentionNotLive() {
        XCTAssertEqual(sessionIndicator(badge: 0, tree: tree(root: .idle, children: [.waiting])),
                       .attention)
        XCTAssertEqual(sessionIndicator(badge: 0, tree: tree(root: .running, children: [.waiting])),
                       .attention)
    }

    func testUnreadBadgeIsAttention() {
        XCTAssertEqual(sessionIndicator(badge: 1, tree: tree(root: .running)), .attention)
    }

    /// Stalled (spawn never connected) is in the same attention tier as waiting —
    /// the human should come take a look — but at the copy layer it is NOT "waiting for
    /// authorization" (pinned by StatusTextTests); the indicator-light layer's yellow-dot
    /// treatment is consistent across both.
    func testStalledIsAttentionNotLive() {
        XCTAssertEqual(sessionIndicator(badge: 0, tree: tree(root: .idle, children: [.stalled])),
                       .attention)
        XCTAssertEqual(sessionIndicator(badge: 0, tree: tree(root: .running, children: [.stalled])),
                       .attention)
    }

    func testIdleTreeRests() {
        XCTAssertEqual(sessionIndicator(badge: 0, tree: tree(root: .idle, children: [.idle])),
                       .rest)
    }

    /// done / killed = rest (a stopped session never updates again). failed, however,
    /// warrants a glance (an abnormal exit is a look-at-me event) → attention, not rest.
    func testTerminalRollup() {
        XCTAssertEqual(sessionIndicator(badge: 0, tree: tree(root: .done)), .rest)
        XCTAssertEqual(sessionIndicator(badge: 0, tree: tree(root: .done, children: [.killed])),
                       .rest)
        XCTAssertEqual(sessionIndicator(badge: 0, tree: tree(root: .done, children: [.failed])),
                       .attention)
        XCTAssertEqual(sessionIndicator(badge: 0, tree: tree(root: .failed)), .attention)
    }

    func testRunningBesideTerminalIsStillLive() {
        XCTAssertEqual(sessionIndicator(badge: 0, tree: tree(root: .running, children: [.done])),
                       .live)
    }
}
