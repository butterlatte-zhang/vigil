import XCTest
import VigilCore
@testable import VigilRuntime

/// TurnWatcher is the scrape fallback for the interrupt blind spot: ESC/deny cancels the
/// turn and claude fires no Stop hook (an interrupted turn only carries turn_duration, no
/// stop_hook_summary) — the screen is the only signal. "esc to interrupt" stays on screen
/// for the entire turn, and disappears on both a normal finish and after an interrupt.
/// Deterministic tests drive `tick()` directly with injected deps, the same idiom as
/// PermWatcherTests.
@MainActor
final class TurnWatcherTests: XCTestCase {

    private final class World {
        var open: [(node: NodeID, gen: Int)] = []
        var screens: [NodeID: String] = [:]
        var screenReads: [NodeID] = []
        var emitted: [Command] = []
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private func makeWatcher(_ w: World) -> TurnWatcher {
        TurnWatcher(openTurnNodes: { w.open },
                    screen: { id in w.screenReads.append(id); return w.screens[id] },
                    emit: { w.emitted.append($0) },
                    now: { w.now })
    }

    /// Except in the generation test cases, the turn's gen is always 1.
    private func open(_ ids: NodeID...) -> [(node: NodeID, gen: Int)] {
        ids.map { ($0, 1) }
    }

    private let runningScreen =
        "✳ Crunching…\n❯ \n⏸ plan mode on (shift+tab to cycle) · esc to interrupt"
    private let idleScreen =
        "Done.\n❯ \n? for shortcuts"
    private let permBoxScreen =
        "Bash(git push)\n Do you want to proceed? \n ❯ 1. Yes \n 3. No"

    private func endedNodes(_ w: World) -> [NodeID] {
        w.emitted.compactMap { if case .turnEnded(let id, _) = $0 { id } else { nil } }
    }

    private func loadFixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "raw") else {
            throw XCTSkip("missing fixture \(name).raw")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testNoOpenTurnsMeansNoScreenReads() {
        let w = World()
        w.screens[NodeID("n1")] = idleScreen
        let tw = makeWatcher(w)
        tw.tick()
        XCTAssertTrue(w.screenReads.isEmpty, "no open turn = zero screen-scrape cost")
        XCTAssertTrue(w.emitted.isEmpty)
    }

    func testAnchorPresentArmsAndDoesNotEnd() {
        let w = World()
        w.open = open(NodeID("root"))
        w.screens[NodeID("root")] = runningScreen
        let tw = makeWatcher(w)
        tw.tick(); tw.tick(); tw.tick()
        XCTAssertTrue(w.emitted.isEmpty, "anchor on screen = turn is running")
    }

    func testArmedThenAnchorGoneTwoTicksEmitsTurnEnded() {
        // Main path: running (armed) → user hits ESC → anchor absent on a STATIC screen for two
        // ticks → turnEnded, fired only once. The first anchor-free tick is the running→idle
        // transition (the screen CHANGED), which the width-robust liveness rule treats as still
        // alive; the miss counter only advances once the screen goes static.
        let w = World()
        w.open = open(NodeID("root"))
        w.screens[NodeID("root")] = runningScreen
        let tw = makeWatcher(w)
        tw.tick()                                          // armed
        w.screens[NodeID("root")] = idleScreen
        tw.tick()                                          // transition (changed) → alive, no miss
        tw.tick()
        XCTAssertTrue(w.emitted.isEmpty, "a single static absent tick does not count (tolerates a transient repaint)")
        tw.tick()
        XCTAssertEqual(endedNodes(w), [NodeID("root")])
    }

    func testPermissionBoxSuppressesTheVerdict() {
        // A pending permission box = the turn is paused, not ended: the box has no running anchor, but it has its own anchor.
        let w = World()
        w.open = open(NodeID("root"))
        w.screens[NodeID("root")] = runningScreen
        let tw = makeWatcher(w)
        tw.tick()                                          // armed
        w.screens[NodeID("root")] = permBoxScreen
        tw.tick(); tw.tick(); tw.tick()
        XCTAssertTrue(w.emitted.isEmpty, "a permission box on screen never falsely reaps the turn")
        // User approves → turn resumes → interrupted again → reaped normally. The running→idle
        // transition is one activity tick; the miss counter advances only once the screen freezes.
        w.screens[NodeID("root")] = runningScreen
        tw.tick()
        w.screens[NodeID("root")] = idleScreen
        tw.tick(); tw.tick(); tw.tick()
        XCTAssertEqual(endedNodes(w), [NodeID("root")])
    }

    func testYoungUnarmedTurnIsNotEndedByAbsence() {
        // A new turn whose first frame hasn't been drawn yet (slow TUI startup) must never be misjudged — the other half of the two-tick arming.
        let w = World()
        w.open = open(NodeID("root"))
        w.screens[NodeID("root")] = idleScreen
        let tw = makeWatcher(w)
        tw.tick(); tw.tick(); tw.tick()
        XCTAssertTrue(w.emitted.isEmpty)
    }

    func testStaleUnarmedTurnEndsAfterArmWindow() {
        // Anchor never seen + turn already past armWindow (e.g. interrupted within a second, faster than the first tick) → absence means ended immediately.
        let w = World()
        w.open = open(NodeID("root"))
        w.screens[NodeID("root")] = idleScreen
        let tw = makeWatcher(w)
        tw.tick()                                          // firstSeen recorded
        w.now = w.now.addingTimeInterval(TurnWatcher.armWindow + 1)
        tw.tick(); tw.tick()
        XCTAssertEqual(endedNodes(w), [NodeID("root")])
    }

    func testAnchorReturnResetsTheMissCounter() {
        let w = World()
        w.open = open(NodeID("root"))
        w.screens[NodeID("root")] = runningScreen
        let tw = makeWatcher(w)
        tw.tick()                                          // armed
        w.screens[NodeID("root")] = idleScreen
        tw.tick()                                          // transition (changed) → alive
        w.screens[NodeID("root")] = runningScreen
        tw.tick()                                          // anchor returns → reset to zero
        w.screens[NodeID("root")] = idleScreen
        tw.tick()                                          // transition (changed) → alive
        tw.tick()                                          // static → miss 1
        XCTAssertTrue(w.emitted.isEmpty, "intermittent absence does not accumulate (only a static screen counts as a miss)")
        tw.tick()                                          // static → miss 2 → ended
        XCTAssertEqual(endedNodes(w), [NodeID("root")])
    }

    func testClosedTurnLeavesTheWatchList() {
        // Stop arrives normally (store receives the turn, node exits the open set) → watcher state is cleared accordingly.
        let w = World()
        w.open = open(NodeID("root"))
        w.screens[NodeID("root")] = runningScreen
        let tw = makeWatcher(w)
        tw.tick()
        w.open = []                                        // Stop hook closed the turn
        tw.tick(); tw.tick(); tw.tick()
        XCTAssertTrue(w.emitted.isEmpty)
        XCTAssertEqual(w.screenReads.count, 1, "zero screen-scrapes after leaving the watch list")
    }

    // MARK: turn generation + tail-row anchor

    func testNewTurnGenerationResetsStaleState() {
        // A turn interrupted by ESC does not leave the open set on its own (no Stop hook is this
        // watcher's whole premise); the user immediately submitting a new prompt = the same node
        // advancing its generation in place. The old generation's armed/miss/firstSeen must not
        // be allowed to kill a new turn whose first frame hasn't drawn an anchor yet.
        let w = World()
        w.open = [(NodeID("root"), 1)]
        w.screens[NodeID("root")] = runningScreen
        let tw = makeWatcher(w)
        tw.tick()                                          // gen1 armed
        w.screens[NodeID("root")] = idleScreen
        tw.tick()                                          // gen1 miss=1
        w.open = [(NodeID("root"), 2)]                     // new prompt, node hasn't exited the open set
        tw.tick(); tw.tick(); tw.tick()                    // the new turn's first frame never draws an anchor
        XCTAssertTrue(w.emitted.isEmpty, "a new generation resets the old one; within armWindow a new turn is never falsely reaped")
        // New turn draws an anchor, then is interrupted → reaped normally; the verdict must name the current generation.
        w.screens[NodeID("root")] = runningScreen
        tw.tick()
        w.screens[NodeID("root")] = idleScreen
        tw.tick(); tw.tick(); tw.tick()                    // transition (alive) + two static → ended
        guard case .turnEnded(NodeID("root"), gen: 2) = w.emitted.first else {
            return XCTFail("expected turnEnded(root, gen: 2), got \(w.emitted)")
        }
        XCTAssertEqual(w.emitted.count, 1)
    }

    func testAnchorInTranscriptContentDoesNotKeepTheTurnAlive() {
        // During dogfooding in this repo, transcript content containing "esc to interrupt" is
        // common (the agent has read TurnWatcher's code/docs). The anchor only recognizes the
        // footer's tail row — the same text appearing in the content must not resurrect an
        // already-interrupted turn into running forever.
        let contentScreen = "the footer keeps esc to interrupt on screen for the turn\n"
            + (1...TurnWatcher.anchorTailRows).map { "plain output line \($0)" }
                .joined(separator: "\n")
            + "\n❯ \n? for shortcuts"
        let w = World()
        w.open = open(NodeID("root"))
        w.screens[NodeID("root")] = runningScreen          // real anchor in the tail row → armed
        let tw = makeWatcher(w)
        tw.tick()
        w.screens[NodeID("root")] = contentScreen          // after ESC: only a content reference to the anchor remains
        tw.tick(); tw.tick(); tw.tick()                    // transition (alive) + two static → reaped
        XCTAssertEqual(endedNodes(w), [NodeID("root")], "an anchor in content does not count; two static ticks reap it as usual")
    }

    // MARK: attach repaint race — a VIEWED running worker collapsed to idle

    /// Selecting a running worker attaches a surface, which fires a SIGWINCH resize + full
    /// repaint on THAT cell only. Mid-repaint the scrape grid is non-empty but the running
    /// anchor has not been redrawn yet — two such ticks could otherwise be read as an
    /// interrupt and falsely end a LIVE turn. `noteAttention` opens a grace window so a
    /// post-attach repaint blank is never mistaken for a turn end.
    func testAttachRepaintDoesNotFalselyEndRunningTurn() {
        let n = NodeID("n40")
        let w = World()
        w.open = open(n)
        w.screens[n] = runningScreen
        let tw = makeWatcher(w)
        tw.tick()                                          // armed, running
        tw.noteAttention(n)                                // user selects n40 → attach grace opens
        // SIGWINCH → claude clears and repaints; the anchor is gone while the top redraws.
        w.screens[n] = "Claude Code v2.1\nrepainting the interface…"
        w.now = w.now.addingTimeInterval(1); tw.tick()
        w.now = w.now.addingTimeInterval(1); tw.tick()
        XCTAssertTrue(w.emitted.isEmpty, "a transient attach-repaint anchor gap must never falsely reap a running turn")
        // Repaint completes, the anchor is back → the turn stays running, never ended.
        w.screens[n] = runningScreen
        w.now = w.now.addingTimeInterval(1); tw.tick()
        XCTAssertTrue(w.emitted.isEmpty, "repaint done, anchor back, turn still running")
    }

    // MARK: activity-based liveness (mechanism-agnostic)

    /// The core invariant, with the anchor-hiding MECHANISM abstracted away: whatever hides
    /// the running anchor mid-turn, as long as the screen keeps CHANGING (a live turn's
    /// spinner or scrolling output), the turn must never be reaped. No footer, no anchor
    /// anywhere, wide screen, fresh content every tick.
    func testAnchorAbsentButScreenStillChangingIsNeverEnded() {
        let w = World()
        w.open = open(NodeID("n43"))
        w.screens[NodeID("n43")] = runningScreen           // arm while the anchor is visible
        let tw = makeWatcher(w)
        tw.tick()                                          // armed
        // 20 ticks of a running turn whose anchor is gone (unspecified reason) but whose screen
        // never stops moving. A plain 2-miss reaper would have fired ~19 times; the invariant holds.
        for i in 1...20 {
            w.screens[NodeID("n43")] =
                "analyzing app/Sources/File\(i).swift …\noutput line \(i) cumulative bytes \(i * 4096)\n(no footer at all)"
            w.now = w.now.addingTimeInterval(1)
            tw.tick()
        }
        XCTAssertTrue(w.emitted.isEmpty,
                      "the screen keeps changing = the turn is running; whatever hid the anchor, it must never be reaped (this is exactly the n43 invariant)")
    }

    // MARK: narrow-pane truncated footer (one proven anchor-hiding form, not the only one)

    /// One proven anchor-hiding form: a selected node's parser resized to a narrow live
    /// pane, where claude TRUNCATES its own footer to "… · esc to…" at narrow widths. The
    /// turn is alive: claude's elapsed-time spinner changes the screen every second, so a
    /// still-changing anchor-free screen must NOT be reaped. Uses a REAL scraped 58-col
    /// frame as the anchor-free base and mutates only the spinner (as real claude does tick
    /// to tick).
    func testNarrowTruncatedFooterWhileStreamingIsNotEnded() throws {
        let raw = try loadFixture("claude-2.1.209-narrow58-truncated-footer")
        XCTAssertFalse(raw.lowercased().contains(TurnWatcher.runningAnchor),
                       "fixture precondition: the truncated footer has NO running anchor")
        let w = World()
        w.open = open(NodeID("n43"))
        w.screens[NodeID("n43")] = runningScreen           // first frame arms while the anchor is visible
        let tw = makeWatcher(w)
        tw.tick()                                          // armed
        // Now the pane is narrow: the footer is truncated (anchor gone) but the spinner ticks —
        // emulate 12 seconds of a live turn by advancing only the elapsed counter each tick.
        for sec in stride(from: 8, through: 30, by: 2) {
            w.screens[NodeID("n43")] = raw.replacingOccurrences(of: "(8s ·", with: "(\(sec)s ·")
            w.now = w.now.addingTimeInterval(1)
            tw.tick()
        }
        XCTAssertTrue(w.emitted.isEmpty,
                      "claude truncated the anchor in a narrow pane, but the screen keeps changing = the turn is running; never falsely reap (n43)")
    }

    /// The counterpart: once a narrow-pane turn is genuinely interrupted, output stops and the
    /// screen FREEZES — a static anchor-free frame still gets reaped (detection only slower, never
    /// disabled). Proves the liveness rule does not mute the interrupt path at narrow widths.
    func testNarrowTruncatedFooterThatFreezesIsEnded() throws {
        let raw = try loadFixture("claude-2.1.209-narrow58-truncated-footer")
        let w = World()
        w.open = open(NodeID("n43"))
        w.screens[NodeID("n43")] = runningScreen
        let tw = makeWatcher(w)
        tw.tick()                                          // armed
        // Interrupt: the last frame lingers (anchor absent), and the screen no longer changes.
        w.screens[NodeID("n43")] = raw
        w.now = w.now.addingTimeInterval(1); tw.tick()     // running→raw transition (changed) → alive
        w.now = w.now.addingTimeInterval(1); tw.tick()     // first static anchor-free tick (miss 1)
        XCTAssertTrue(w.emitted.isEmpty, "a single static absent tick does not count")
        w.now = w.now.addingTimeInterval(1); tw.tick()     // second static (miss 2 → ended)
        XCTAssertEqual(endedNodes(w), [NodeID("n43")], "a static anchor-free narrow pane is reaped as usual")
    }

    /// The grace is a bounded window, not a mute button: a turn that genuinely ended right
    /// after the node was selected still gets reaped once the window elapses (an ESC'd turn
    /// stays ended forever, so a few extra seconds of delay costs nothing).
    func testGenuineEndStillFiresAfterAttachGrace() {
        let n = NodeID("n40")
        let w = World()
        w.open = open(n)
        w.screens[n] = runningScreen
        let tw = makeWatcher(w)
        tw.tick()                                          // armed
        tw.noteAttention(n)                                // selected
        w.screens[n] = idleScreen                          // the turn truly ended (ESC / normal)
        // Inside the grace: no verdict yet.
        w.now = w.now.addingTimeInterval(1); tw.tick()
        w.now = w.now.addingTimeInterval(1); tw.tick()
        XCTAssertTrue(w.emitted.isEmpty, "no verdict inside the grace window")
        // Past the grace: the anchor is still gone → two ticks reap it normally.
        w.now = w.now.addingTimeInterval(TurnWatcher.attachGrace + 1); tw.tick()
        tw.tick()
        XCTAssertEqual(endedNodes(w), [n], "past the grace window, a genuine end is reaped as usual")
    }
}
