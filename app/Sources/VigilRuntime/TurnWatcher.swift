import Foundation
import VigilCore

/// The scrape fallback for the interrupt blind spot (PermWatcher's sibling). A user ESC/deny
/// cancels the whole turn and claude fires no Stop hook (an interrupted turn's transcript has
/// only turn_duration, no stop_hook_summary) — the node would sit `.running` forever. The
/// screen is the only signal: claude's TUI keeps "esc to interrupt" on screen for the whole
/// life of a real turn, and it disappears both on a normal ending and after an ESC interrupt.
///
/// Scope: ONLY nodes the store believes are mid-turn (open turn ∧ still .running) —
/// zero renderScreen work otherwise. Two-phase arming mirrors PermWatcher: absence
/// counts after the anchor was SEEN once for this turn, or the turn is older than
/// `armWindow` (never mis-end a turn whose first frame hasn't painted). A mid-turn
/// permission box pauses the turn WITHOUT the running anchor — its own anchor
/// (PermWatcher.anchors) suppresses the verdict. Absence must hold for two
/// consecutive ticks before `.turnEnded` is emitted (transient redraw tolerance).
///
/// Two hardenings:
///   • Generations — an ESC'd turn never leaves the open set by itself (no Stop hook is
///     the whole premise), so the user's NEXT prompt reuses the node while armed /
///     firstSeen / misses still hold the old turn's leftovers → a stale verdict could
///     kill the new turn mid-run. Every per-node state is therefore keyed to the turn
///     gen the store hands out, reset on change, and the verdict names its gen so the
///     store can drop late ones.
///   • Tail-anchored match — the status line lives at the viewport BOTTOM; matching the
///     whole screen means transcript CONTENT quoting "esc to interrupt" (routine when
///     the agent works on this very repo) keeps an interrupted turn alive forever.
///     The running anchor only counts inside the last few non-empty rows.
///
/// Activity-based liveness (a second form of false idle): the running anchor is not a total
/// guarantee even mid-turn. The anchor can leave the scrape screen for more than one reason —
/// one confirmed case: at a narrow pane (roughly < 64 cols) claude truncates its own running
/// footer to "… · esc to…", dropping "esc to interrupt" off-screen while the turn still runs
/// (a selected node's parser is resized to the live pane width, so this is a selected-node
/// hazard the select-only `attachGrace` cannot cover). Rather than chase every anchor-hiding
/// mechanism, this rule closes them by construction: a running turn's elapsed-time spinner
/// changes the screen every second ("✢ (8s)" → "✳ (10s)" → "✶ (14s)"), so a still-changing
/// anchor-free screen is treated as alive (no miss); only a static anchor-free screen (output
/// stopped after ESC/deny) accrues misses. Interrupt detection is therefore one tick slower
/// after a genuine end, never disabled — the same safe direction as the perm/attach
/// tolerances above.
///
/// Iron-law fit: reading the world is not a state change; the only thing that touches
/// state is the Command emitted into SessionStore — no side channel.
@MainActor
public final class TurnWatcher {
    /// claude's turn-running anchor (the status line trails the whole turn). Lowercased
    /// compare — the footer casing is claude's own.
    public static let runningAnchor = "esc to interrupt"
    /// How long an unarmed open turn may sit with no anchor before absence means
    /// "the turn is long gone" rather than "not painted yet" (slow TUI boot).
    public static let armWindow: TimeInterval = 8
    /// Consecutive anchor-free ticks required before the turn counts as over.
    public static let missesToEnd = 2
    /// The running anchor must sit within this many trailing non-empty rows (footer
    /// zone); anything higher is transcript content, not the status line.
    public static let anchorTailRows = 8
    /// How long after a node is SELECTED (its surface attaches) the watcher tolerates an
    /// anchor-free screen without counting a miss. Selecting a running worker attaches a
    /// surface, which fires a SIGWINCH resize + a full repaint on that one cell; mid-repaint
    /// the scrape grid is non-empty but has not yet redrawn the running footer, and two such
    /// ticks read as an interrupt would falsely `.turnEnded` a live turn while an unviewed
    /// sibling stayed correct. This grace is time-based, not arm-based, on purpose: a poll
    /// tick landing between select and the actual
    /// repaint re-sees the anchor and would re-arm, so re-arming alone leaves the same hole —
    /// the window has to cover the repaint whenever it lands. Generous vs the 2-tick miss
    /// budget; a genuine end merely waits this out before being reaped (harmless — an ESC'd
    /// turn stays ended).
    public static let attachGrace: TimeInterval = 8

    private let openTurnNodes: () -> [(node: NodeID, gen: Int)]
    private let screen: (NodeID) -> String?
    private let emit: (Command) -> Void
    private let now: () -> Date
    private var gens: [NodeID: Int] = [:]
    private var armed: Set<NodeID> = []
    private var firstSeen: [NodeID: Date] = [:]
    private var misses: [NodeID: Int] = [:]
    /// Per-node deadline until which an anchor-free screen is treated as a post-attach
    /// repaint transient, not a turn end (see `attachGrace`). Set by `noteAttention`.
    private var attachGraceUntil: [NodeID: Date] = [:]
    /// Previous tick's rendered screen per node — the width-robust liveness signal.
    /// At a narrow pane claude truncates its running footer ("… · esc to…"), so the running
    /// anchor is genuinely off-screen even mid-turn; but the live elapsed-time spinner keeps
    /// changing the screen every second. A still-changing anchor-free screen = the turn is
    /// alive; only a static anchor-free screen (output stopped after ESC/deny) is a real end.
    private var lastScreen: [NodeID: String] = [:]
    private var task: Task<Void, Never>?

    public init(openTurnNodes: @escaping () -> [(node: NodeID, gen: Int)],
                screen: @escaping (NodeID) -> String?,
                emit: @escaping (Command) -> Void,
                now: @escaping () -> Date = { Date() }) {
        self.openTurnNodes = openTurnNodes
        self.screen = screen
        self.emit = emit
        self.now = now
    }

    /// A view just attached to this node's surface (the node was selected). Opens the
    /// `attachGrace` window so the SIGWINCH resize + repaint the attach triggers cannot be
    /// misread as an interrupt. Recorded even for a node not currently mid-turn — a stale
    /// entry is dropped by tick's live filter, and it costs nothing.
    public func noteAttention(_ node: NodeID) {
        attachGraceUntil[node] = now().addingTimeInterval(Self.attachGrace)
    }

    /// One poll pass — separated from the sleep loop so tests drive it deterministically.
    public func tick() {
        let open = openTurnNodes()
        let live = Set(open.map(\.node))
        armed.formIntersection(live)                       // a turn whose Stop arrived normally drops out on its own
        gens = gens.filter { live.contains($0.key) }
        firstSeen = firstSeen.filter { live.contains($0.key) }
        misses = misses.filter { live.contains($0.key) }
        attachGraceUntil = attachGraceUntil.filter { live.contains($0.key) }
        lastScreen = lastScreen.filter { live.contains($0.key) }
        for (node, gen) in open {
            if gens[node] != gen {                         // gen change: any leftovers from the old turn are all invalidated
                gens[node] = gen
                armed.remove(node)
                firstSeen[node] = nil
                misses[node] = 0
                lastScreen[node] = nil
            }
            guard let raw = screen(node), !raw.isEmpty else { continue }
            let prevScreen = lastScreen[node]              // width-robust liveness: prior tick's frame
            lastScreen[node] = raw
            let s = raw.lowercased()
            let t = now()
            let seen = firstSeen[node] ?? t
            firstSeen[node] = seen
            if Self.footer(of: s).contains(Self.runningAnchor) {
                armed.insert(node)
                misses[node] = 0                           // the turn is still running
                continue
            }
            if PermWatcher.anchors.contains(where: { s.contains($0.lowercased()) }) {
                misses[node] = 0                           // a suspended permission box ≠ turn ended
                continue
            }
            if let until = attachGraceUntil[node], t < until {
                misses[node] = 0                           // post-attach repaint blank ≠ turn ended
                continue
            }
            guard armed.contains(node)
                || t.timeIntervalSince(seen) > Self.armWindow else { continue }
            // Activity-based liveness (a second false-idle form): the anchor can leave the
            // screen mid-turn for more than one reason (one confirmed case: claude truncates
            // its own footer to "… · esc to…" at a narrow pane). Rather than enumerate every
            // anchor-hiding mechanism, treat a still-changing anchor-free screen as alive: a
            // live turn's elapsed-time spinner ticks every second ("✢ (8s)" → "✳ (10s)" →
            // "✶ (14s)"), so if the screen changed since last tick the turn is working — do
            // not count a miss. Only a static anchor-free screen accrues misses: interrupt
            // detection just gets one tick slower (after ESC/deny the output freezes), never
            // disabled.
            if let prevScreen, prevScreen != raw {
                misses[node] = 0
                continue
            }
            let m = (misses[node] ?? 0) + 1
            misses[node] = m
            if m >= Self.missesToEnd {
                misses[node] = 0
                armed.remove(node)
                emit(.turnEnded(node, gen: gen))           // an interrupted/denied turn is reaped here
            }
        }
    }

    /// The trailing non-empty rows of a rendered screen — the TUI footer zone. Perm
    /// anchors deliberately stay full-screen: their false-positive direction merely
    /// DELAYS a verdict (safe), while a missed box would mis-end a paused turn.
    static func footer(of screen: String) -> String {
        screen.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(anchorTailRows)
            .joined(separator: "\n")
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
