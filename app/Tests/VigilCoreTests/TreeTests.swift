import XCTest
@testable import VigilCore

final class TreeTests: XCTestCase {

    private func mgr(_ id: String) -> Node { Node(id: NodeID(id), role: .manager, status: .running) }
    private func leaf(_ id: String) -> Node { Node(id: NodeID(id), role: .leaf) }

    func testSpawnAddsLeafUnderManager() throws {
        var t = Tree(root: mgr("root"))
        try t.spawn(parent: NodeID("root"), child: leaf("a"))
        XCTAssertEqual(t.root.children, [NodeID("a")])
        XCTAssertEqual(t[NodeID("a")]?.parent, NodeID("root"))
        XCTAssertEqual(t.count, 2)
    }

    func testLeafCannotSpawn() throws {
        var t = Tree(root: mgr("root"))
        try t.spawn(parent: NodeID("root"), child: leaf("a"))
        XCTAssertThrowsError(try t.spawn(parent: NodeID("a"), child: leaf("b"))) { e in
            XCTAssertEqual(e as? TreeError, .notManager(NodeID("a")))
        }
    }

    // kill seals the WHOLE subtree as dead records — every node STAYS in the tree
    // with its structure intact (dead node = clickable history). Live nodes flip to
    // .killed; the returned list is exactly the LIVE cells (DFS, target first) to reap.
    func testKillSealsSubtreeAsDeadRecords() throws {
        var t = Tree(root: mgr("root"))
        try t.spawn(parent: NodeID("root"), child: mgr("a"))
        try t.spawn(parent: NodeID("a"), child: leaf("b"))
        let reaped = try t.kill(NodeID("a"))
        XCTAssertEqual(reaped, [NodeID("a"), NodeID("b")])     // both were live → both reaped, target first
        XCTAssertEqual(t[NodeID("a")]?.status, .killed)        // a stays with terminal status
        XCTAssertEqual(t[NodeID("a")]?.children, [NodeID("b")])// structure preserved, no orphaning
        XCTAssertEqual(t.root.children, [NodeID("a")])
        XCTAssertEqual(t[NodeID("b")]?.status, .killed)        // descendant STAYS as a dead record
        XCTAssertEqual(t.count, 3)                             // nothing left the tree
    }

    // an already-terminal descendant keeps its OWN terminal status (sticky) and is
    // NOT reaped again — only the live nodes need their cell torn down.
    func testKillPreservesAlreadyDeadDescendantStatus() throws {
        var t = Tree(root: mgr("root"))
        try t.spawn(parent: NodeID("root"), child: mgr("a"))
        try t.spawn(parent: NodeID("a"), child: leaf("b"))
        try t.spawn(parent: NodeID("a"), child: leaf("c"))
        t.setStatus(NodeID("b"), .done)                        // b self-died earlier
        let reaped = try t.kill(NodeID("a"))
        XCTAssertEqual(reaped, [NodeID("a"), NodeID("c")])     // b (terminal) skipped, a+c live
        XCTAssertEqual(t[NodeID("a")]?.status, .killed)
        XCTAssertEqual(t[NodeID("b")]?.status, .done)          // NOT rewritten to .killed
        XCTAssertEqual(t[NodeID("c")]?.status, .killed)
        XCTAssertEqual(t.count, 4)                             // all present
    }

    // seal reaches arbitrarily deep — a whole manager→manager→leaf chain stays.
    func testKillSealsDeepSubtree() throws {
        var t = Tree(root: mgr("root"))
        try t.spawn(parent: NodeID("root"), child: mgr("a"))
        try t.spawn(parent: NodeID("a"), child: mgr("d"))
        try t.spawn(parent: NodeID("d"), child: leaf("e"))
        let reaped = try t.kill(NodeID("a"))
        XCTAssertEqual(reaped, [NodeID("a"), NodeID("d"), NodeID("e")])   // DFS, all live
        for id in ["a", "d", "e"] { XCTAssertEqual(t[NodeID(id)]?.status, .killed) }
        XCTAssertEqual(t[NodeID("d")]?.children, [NodeID("e")])          // structure intact
        XCTAssertEqual(t.count, 4)
    }

    /// First terminal status wins (same sticky rule as SessionStore): killing an
    /// already-dead node must not rewrite done → killed.
    func testKillOnTerminalNodeKeepsFirstTerminalStatus() throws {
        var t = Tree(root: mgr("root"))
        try t.spawn(parent: NodeID("root"), child: leaf("a"))
        t.setStatus(NodeID("a"), .done)
        _ = try t.kill(NodeID("a"))
        XCTAssertEqual(t[NodeID("a")]?.status, .done)
    }

    func testCannotKillRoot() {
        var t = Tree(root: mgr("root"))
        XCTAssertThrowsError(try t.kill(NodeID("root"))) { e in
            XCTAssertEqual(e as? TreeError, .cannotKillRoot)
        }
    }

    // MARK: kill is scoped to the caller's own subtree

    func testKillByCallerInsideOwnSubtreeSucceeds() throws {
        var t = Tree(root: mgr("root"))
        try t.spawn(parent: NodeID("root"), child: mgr("a"))
        try t.spawn(parent: NodeID("a"), child: leaf("b"))
        let reaped = try t.kill(NodeID("b"), by: NodeID("a"))  // own child: ok
        XCTAssertEqual(reaped, [NodeID("b")])
        XCTAssertEqual(t[NodeID("b")]?.status, .killed)          // stays as dead record
    }

    func testKillSiblingByCallerThrowsNotInSubtree() throws {
        var t = Tree(root: mgr("root"))
        try t.spawn(parent: NodeID("root"), child: mgr("a"))
        try t.spawn(parent: NodeID("root"), child: leaf("c"))
        XCTAssertThrowsError(try t.kill(NodeID("c"), by: NodeID("a"))) { e in
            XCTAssertEqual(e as? TreeError, .notInSubtree(NodeID("c"), caller: NodeID("a")))
        }
        XCTAssertNotNil(t[NodeID("c")])                          // untouched
    }

    func testKillParentByCallerThrowsNotInSubtree() throws {
        var t = Tree(root: mgr("root"))
        try t.spawn(parent: NodeID("root"), child: mgr("a"))
        try t.spawn(parent: NodeID("a"), child: mgr("b"))
        XCTAssertThrowsError(try t.kill(NodeID("a"), by: NodeID("b"))) { e in
            XCTAssertEqual(e as? TreeError, .notInSubtree(NodeID("a"), caller: NodeID("b")))
        }
        XCTAssertNotNil(t[NodeID("a")])
    }

    // MARK: re-incarnation (resume respawns the same node into the same session dir)

    func testRelaunchClearsFrozenTerminalState() throws {
        var t = Tree(root: mgr("root"))
        try t.spawn(parent: NodeID("root"), child: leaf("a"))
        t.setStatus(NodeID("a"), .done)
        t.setEnded(NodeID("a"), Date(timeIntervalSince1970: 100))

        t.relaunch(NodeID("a"), status: .killed, startedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(t[NodeID("a")]?.status, .killed)
        XCTAssertNil(t[NodeID("a")]?.endedAt)              // the frozen clock thaws
        XCTAssertEqual(t[NodeID("a")]?.startedAt, Date(timeIntervalSince1970: 200))

        // In the new lifetime, setEnded's one-shot guard is active again (endedAt==nil guard).
        t.setEnded(NodeID("a"), Date(timeIntervalSince1970: 300))
        XCTAssertEqual(t[NodeID("a")]?.endedAt, Date(timeIntervalSince1970: 300))
    }

    // sealSubtree flips every LIVE node in the subtree to .killed, keeps
    // already-terminal ones sticky, and removes NOTHING (structure preserved).
    func testSealSubtreeKeepsStructureAndSkipsTerminal() throws {
        var t = Tree(root: mgr("root"))
        try t.spawn(parent: NodeID("root"), child: mgr("a"))
        try t.spawn(parent: NodeID("a"), child: leaf("b"))
        try t.spawn(parent: NodeID("a"), child: leaf("c"))
        t.setStatus(NodeID("c"), .failed)                     // c already dead
        let live = t.sealSubtree(NodeID("a"))
        XCTAssertEqual(live, [NodeID("a"), NodeID("b")])      // c (terminal) skipped
        XCTAssertEqual(t[NodeID("a")]?.status, .killed)
        XCTAssertEqual(t[NodeID("b")]?.status, .killed)
        XCTAssertEqual(t[NodeID("c")]?.status, .failed)       // sticky, untouched
        XCTAssertEqual(t[NodeID("a")]?.children, [NodeID("b"), NodeID("c")])  // nothing removed
        XCTAssertEqual(t.count, 4)
    }

    func testLCAandPath() throws {
        var t = Tree(root: mgr("root"))
        try t.spawn(parent: NodeID("root"), child: mgr("a"))
        try t.spawn(parent: NodeID("a"), child: leaf("b"))
        try t.spawn(parent: NodeID("root"), child: leaf("c"))
        XCTAssertEqual(t.lca(NodeID("b"), NodeID("c")), NodeID("root"))
        // b ↑ root ↓ c
        XCTAssertEqual(t.path(from: NodeID("b"), to: NodeID("c")),
                       [NodeID("b"), NodeID("a"), NodeID("root"), NodeID("c")])
        XCTAssertEqual(t.path(from: NodeID("b"), to: NodeID("a")),
                       [NodeID("b"), NodeID("a")])
    }

    func testSubtreeIsParentFirst() throws {
        var t = Tree(root: mgr("root"))
        try t.spawn(parent: NodeID("root"), child: mgr("a"))
        try t.spawn(parent: NodeID("a"), child: leaf("b"))
        try t.spawn(parent: NodeID("root"), child: leaf("c"))
        XCTAssertEqual(t.subtree(of: NodeID("root")),
                       [NodeID("root"), NodeID("a"), NodeID("b"), NodeID("c")])
    }
}
