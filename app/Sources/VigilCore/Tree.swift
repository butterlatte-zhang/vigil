import Foundation

public enum TreeError: Error, Equatable {
    case noSuchNode(NodeID)
    case notManager(NodeID)        // only managers may spawn (§3.1)
    case duplicate(NodeID)
    case cannotKillRoot
    case notInSubtree(NodeID, caller: NodeID)   // kill is scoped to the caller's subtree
}

/// The node tree with its invariants — single-root / single-parent / acyclic
/// (§3.1). All mutations go through these methods so the invariants can
/// never be violated. (Phase 1 uses spawn/kill + parent↔child path; lca/subtree
/// are cheap and kept for the eventual LCA routing — DOCTRINE §10.0.)
public struct Tree: Sendable, Equatable {
    public private(set) var nodes: [NodeID: Node]
    public let rootID: NodeID

    public init(root: Node) {
        precondition(root.parent == nil, "root must have no parent")
        self.rootID = root.id
        self.nodes = [root.id: root]
    }

    public subscript(_ id: NodeID) -> Node? { nodes[id] }
    public var root: Node { nodes[rootID]! }
    public var count: Int { nodes.count }

    // MARK: structural mutations (the only two)

    public mutating func spawn(parent: NodeID, child: Node) throws {
        guard var p = nodes[parent] else { throw TreeError.noSuchNode(parent) }
        guard p.role == .manager else { throw TreeError.notManager(parent) }
        guard nodes[child.id] == nil else { throw TreeError.duplicate(child.id) }
        var c = child; c.parent = parent
        nodes[child.id] = c
        p.children.append(child.id)
        nodes[parent] = p
    }

    /// Kill seals the whole subtree: the killed node AND every descendant STAY in
    /// the tree as dead records (for display/history — a dead node is a clickable
    /// afterlife). Structure is preserved — no node leaves the tree. Live nodes flip
    /// to `.killed`; already-terminal nodes keep their own status (sticky, the same
    /// rule SessionStore applies to exit echoes). Returns the ids that were LIVE at
    /// kill time (DFS, `id` first) — exactly the cells that still need tearing down.
    /// `caller` = the node the request came from: the target must sit inside the
    /// caller's own subtree — a sub-manager cannot kill siblings or ancestors. nil =
    /// no caller context (the app itself), unrestricted.
    @discardableResult
    public mutating func kill(_ id: NodeID, by caller: NodeID? = nil) throws -> [NodeID] {
        guard nodes[id] != nil else { throw TreeError.noSuchNode(id) }
        guard id != rootID else { throw TreeError.cannotKillRoot }
        if let caller, !pathToRoot(id).contains(caller) {
            throw TreeError.notInSubtree(id, caller: caller)
        }
        return sealSubtree(id)
    }

    /// Seal the subtree rooted at `id` as dead records: every node STAYS with its
    /// structure intact; each LIVE node flips to `.killed`, already-terminal nodes keep
    /// their status (sticky). Returns the ids that were live at seal time (DFS, `id`
    /// first) — the cells still needing teardown. The clock-freeze / notice-drop /
    /// killCells effects are the store's job. (Self-death sets the target's own terminal
    /// status FIRST, so the target is already terminal here and the seal skips it.)
    @discardableResult
    public mutating func sealSubtree(_ id: NodeID) -> [NodeID] {
        var live: [NodeID] = []
        for nid in subtree(of: id) where nodes[nid]?.status.isTerminal == false {
            live.append(nid)
            setStatus(nid, .killed)
        }
        return live
    }

    public mutating func setStatus(_ id: NodeID, _ s: NodeStatus) {
        guard var n = nodes[id] else { return }
        n.status = s; nodes[id] = n
    }

    /// Freeze the runtime clock. Stamped once — a later echo (teardown exit
    /// report) must not move a dead node's frozen time.
    public mutating func setEnded(_ id: NodeID, _ d: Date) {
        guard var n = nodes[id], n.endedAt == nil else { return }
        n.endedAt = d; nodes[id] = n
    }

    /// Re-incarnation on resume: the same node id launched again in the same
    /// session dir. Clears the previous lifetime's frozen terminal state — status,
    /// endedAt (re-arming setEnded's once-only guard), startedAt — so the new
    /// lifetime's events stamp fresh; structure (parent/children) is untouched.
    public mutating func relaunch(_ id: NodeID, status: NodeStatus, startedAt: Date?) {
        guard var n = nodes[id] else { return }
        n.status = status
        n.endedAt = nil
        if let startedAt { n.startedAt = startedAt }
        nodes[id] = n
    }

    public mutating func setRollup(_ id: NodeID, _ summary: String) {
        guard var n = nodes[id] else { return }
        n.lastRollup = summary; nodes[id] = n
    }

    // MARK: queries

    public func children(of id: NodeID) -> [NodeID] { nodes[id]?.children ?? [] }

    /// All ids in the subtree rooted at `id`, including `id` (DFS, deterministic order).
    public func subtree(of id: NodeID) -> [NodeID] {
        guard nodes[id] != nil else { return [] }
        var out: [NodeID] = []
        var stack = [id]
        while let cur = stack.popLast() {
            out.append(cur)
            // push children in reverse so output is parent-then-children left-to-right
            stack.append(contentsOf: (nodes[cur]?.children ?? []).reversed())
        }
        return out
    }

    /// `id` then each ancestor up to and including root.
    public func pathToRoot(_ id: NodeID) -> [NodeID] {
        var out: [NodeID] = []
        var cur: NodeID? = id
        while let c = cur, nodes[c] != nil { out.append(c); cur = nodes[c]?.parent }
        return out
    }

    /// Lowest common ancestor — the relay point for cross-subtree messages.
    public func lca(_ a: NodeID, _ b: NodeID) -> NodeID? {
        let aSet = Set(pathToRoot(a))
        for n in pathToRoot(b) where aSet.contains(n) { return n }
        return nil
    }

    /// The unique tree path a ↑ LCA ↓ b (§3.4: no mesh, route via edges).
    public func path(from a: NodeID, to b: NodeID) -> [NodeID] {
        guard nodes[a] != nil, nodes[b] != nil, let l = lca(a, b) else { return [] }
        var up: [NodeID] = []
        var cur: NodeID? = a
        while let c = cur { up.append(c); if c == l { break }; cur = nodes[c]?.parent }
        var down: [NodeID] = []
        cur = b
        while let c = cur, c != l { down.append(c); cur = nodes[c]?.parent }
        return up + down.reversed()
    }
}
