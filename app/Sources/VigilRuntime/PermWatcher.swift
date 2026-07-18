import Foundation
import VigilCore

/// Fallback for the deny blind spot: a user deny (esc or "3. No") cancels the whole
/// turn and fires no hook — the screen is the only signal that the box is gone. This
/// watcher polls renderScreen (1s cadence) ONLY while a node has an unresolved
/// permission card, and emits `.resolveNotice(via: .scrape)` when the box text has
/// left the screen.
///
/// Reading the world is not a state change; the only thing that touches state is the
/// Command it emits into SessionStore — no side channel.
///
/// Two-phase arming: absence only counts after the anchor was SEEN once for that card
/// (armed), or the card is older than `armWindow` (the box closed before our first
/// poll). A box that merely hasn't painted yet is never mis-cleared.
@MainActor
public final class PermWatcher {
    /// Claude 2.1.201's permission-box anchor text. The other box lines
    /// ("❯ 1. Yes", "Esc to cancel") also appear in non-permission choice UIs
    /// (trust prompt, plan mode) — this one is the permission box's own.
    public static let anchors = ["Do you want to proceed?"]
    /// How long an unarmed card may sit with no anchor on screen before absence means
    /// "the box is long gone" rather than "not painted yet".
    public static let armWindow: TimeInterval = 5

    private let notices: () -> [AgentNotice]
    private let screen: (NodeID) -> String?
    private let emit: (Command) -> Void
    private let now: () -> Date
    private var armed: Set<UUID> = []
    private var task: Task<Void, Never>?

    public init(notices: @escaping () -> [AgentNotice],
                screen: @escaping (NodeID) -> String?,
                emit: @escaping (Command) -> Void,
                now: @escaping () -> Date = { Date() }) {
        self.notices = notices
        self.screen = screen
        self.emit = emit
        self.now = now
    }

    /// One poll pass — separated from the sleep loop so tests drive it deterministically.
    public func tick() {
        let pending = notices()                            // all cards are perm events
        armed.formIntersection(pending.map(\.id))          // forget store-resolved cards
        guard !pending.isEmpty else { return }             // zero renderScreen work at rest
        for (node, cards) in Dictionary(grouping: pending, by: \.nodeID) {
            guard let s = screen(node) else { continue }
            if Self.anchors.contains(where: s.contains) {
                for c in cards { armed.insert(c.id) }      // box on screen → cards armed
                continue
            }
            let t = now()
            for c in cards where armed.contains(c.id)
                || t.timeIntervalSince(c.arrivedAt) > Self.armWindow {
                // Per-card tuple resolve (FIFO in the store), not node-wide: a fresh
                // unarmed box racing in next to a dying one must keep its card.
                emit(.resolveNotice(from: node,
                                    match: PermResolveMatch(promptID: c.promptID,
                                                            toolName: c.toolName,
                                                            toolInput: c.toolInput,
                                                            toolUseID: nil),
                                    via: .scrape))
            }
        }
    }

    public func start(interval: TimeInterval = 1.0) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(seconds: interval)
                self?.tick()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
