import XCTest
import VigilCore
@testable import VigilRuntime

/// PermWatcher = the scrape fallback for the deny blind spot (a user deny
/// cancels the turn and fires NO hook — the screen is the only signal). Deterministic
/// tests drive `tick()` directly with injected deps; the 1s polling loop is just a
/// tick scheduler. Two-phase arming: an anchor must have been SEEN once (armed) — or
/// the notice must be older than the arm window — before its absence counts as
/// "resolved", so a box that hasn't painted yet is never mis-cleared.
@MainActor
final class PermWatcherTests: XCTestCase {

    private final class World {
        var notices: [AgentNotice] = []
        var screens: [NodeID: String] = [:]
        var screenReads: [NodeID] = []
        var emitted: [Command] = []
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private func makeWatcher(_ w: World) -> PermWatcher {
        PermWatcher(notices: { w.notices },
                    screen: { id in w.screenReads.append(id); return w.screens[id] },
                    emit: { w.emitted.append($0) },
                    now: { w.now })
    }

    private func permNotice(_ node: String, promptID: String? = "p1",
                            toolInput: String? = #"{"command":"git push"}"#,
                            seq: UInt64 = 1, arrivedAt: Date) -> AgentNotice {
        AgentNotice(seq: seq, nodeID: NodeID(node), kind: .permission, text: "perm",
                    promptID: promptID, toolName: "Bash", toolInput: toolInput,
                    arrivedAt: arrivedAt)
    }

    private let boxScreen = "╭─╮\n Bash(git push) \n Do you want to proceed? \n ❯ 1. Yes \n 3. No"

    func testNoPermissionCardsMeansNoScreenReads() {
        // Polling runs ONLY while an unresolved permission card exists — zero cards
        // must cost zero renderScreen work (a card is always a permission event).
        let w = World()
        let pw = makeWatcher(w)
        pw.tick()
        XCTAssertTrue(w.screenReads.isEmpty)
        XCTAssertTrue(w.emitted.isEmpty)
    }

    func testAnchorPresentArmsAndDoesNotResolve() {
        let w = World()
        w.notices = [permNotice("n1", arrivedAt: w.now)]
        w.screens[NodeID("n1")] = boxScreen
        let pw = makeWatcher(w)
        pw.tick()
        XCTAssertEqual(w.screenReads, [NodeID("n1")])
        XCTAssertTrue(w.emitted.isEmpty)
    }

    func testArmedThenAnchorGoneEmitsScrapeResolveWithTheCardsTuple() {
        let w = World()
        w.notices = [permNotice("n1", arrivedAt: w.now)]
        w.screens[NodeID("n1")] = boxScreen
        let pw = makeWatcher(w)
        pw.tick()                                          // sees the box → armed
        w.screens[NodeID("n1")] = "❯ ready\n"              // box gone (deny / esc)
        pw.tick()

        XCTAssertEqual(w.emitted.count, 1)
        guard case .resolveNotice(let from, let match, let via) = w.emitted[0] else {
            return XCTFail("expected resolveNotice, got \(w.emitted)")
        }
        XCTAssertEqual(from, NodeID("n1"))
        XCTAssertEqual(via, .scrape)
        // per-card tuple resolve (FIFO in the store) — a fresh box racing in next to a
        // dying one keeps its card
        XCTAssertEqual(match?.promptID, "p1")
        XCTAssertEqual(match?.toolName, "Bash")
        XCTAssertEqual(match?.toolInput, #"{"command":"git push"}"#)
        XCTAssertNil(match?.toolUseID)                     // scrape never invents one
    }

    func testYoungUnarmedNoticeIsNotResolvedByAbsence() {
        // The box may simply not have painted yet — absence before arming (and inside
        // the arm window) must NOT resolve, or every card would die at first tick.
        let w = World()
        w.notices = [permNotice("n1", arrivedAt: w.now)]
        w.screens[NodeID("n1")] = "still drawing…"
        let pw = makeWatcher(w)
        pw.tick()
        XCTAssertTrue(w.emitted.isEmpty)
    }

    func testStaleUnarmedNoticeResolvesAfterArmWindow() {
        // Never saw the box and it's been > armWindow — the box is long gone (e.g. it
        // closed between the hook firing and our first poll). Clear the card.
        let w = World()
        w.notices = [permNotice("n1", arrivedAt: w.now.addingTimeInterval(-PermWatcher.armWindow - 1))]
        w.screens[NodeID("n1")] = "❯ ready\n"
        let pw = makeWatcher(w)
        pw.tick()
        XCTAssertEqual(w.emitted.count, 1)
        guard case .resolveNotice(_, _, .scrape) = w.emitted[0] else {
            return XCTFail("expected scrape resolve")
        }
    }

    func testEachDeadCardGetsItsOwnResolve() {
        // Two same-turn cards (shared prompt_id), box gone → one tuple resolve per
        // card; identical tuples still drain fully via the store's FIFO.
        let w = World()
        w.notices = [permNotice("n1", seq: 1, arrivedAt: w.now),
                     permNotice("n1", toolInput: #"{"command":"npm test"}"#,
                                seq: 2, arrivedAt: w.now)]
        w.screens[NodeID("n1")] = boxScreen
        let pw = makeWatcher(w)
        pw.tick()                                          // armed (both)
        w.screens[NodeID("n1")] = ""
        pw.tick()

        XCTAssertEqual(w.emitted.count, 2)
        let inputs = w.emitted.compactMap { cmd -> String? in
            guard case .resolveNotice(_, let m, .scrape) = cmd else { return nil }
            return m?.toolInput
        }
        XCTAssertEqual(Set(inputs), [#"{"command":"git push"}"#, #"{"command":"npm test"}"#])
    }

    func testResolvedNoticeIsForgotten() {
        // After the store removed a card (PostToolUse won the race), a later tick must
        // not re-emit for it.
        let w = World()
        w.notices = [permNotice("n1", arrivedAt: w.now)]
        w.screens[NodeID("n1")] = boxScreen
        let pw = makeWatcher(w)
        pw.tick()                                          // armed
        w.notices = []                                     // store resolved it
        w.screens[NodeID("n1")] = ""
        pw.tick()
        XCTAssertTrue(w.emitted.isEmpty)
    }
}
