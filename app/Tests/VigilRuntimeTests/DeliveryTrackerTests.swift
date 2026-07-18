import XCTest
import VigilCore
@testable import VigilRuntime

/// The send-delivery-honesty reconciler, driven deterministically with
/// scripted transcript/status closures (no real cell, no real clock).
@MainActor
final class DeliveryTrackerTests: XCTestCase {

    /// A mutable world the closures read: a per-node transcript string + status.
    final class World {
        var transcript: [NodeID: String] = [:]
        var status: [NodeID: NodeStatus] = [:]
        var reinjected: [(NodeID, String)] = []
        var confirmed: [(NodeID, String)] = []
        var failed: [(target: NodeID, caller: NodeID, text: String, attempts: Int, reason: String)] = []
        var clock = Date(timeIntervalSince1970: 1000)
    }

    private func make(_ w: World, maxAttempts: Int = 3, grace: TimeInterval = 4)
        -> DeliveryTracker {
        DeliveryTracker(
            readSince: { node, _ in w.transcript[node] ?? "" },   // scripted: full transcript is "since"
            fileLength: { node in UInt64((w.transcript[node] ?? "").utf8.count) },
            status: { node in w.status[node] },
            reinject: { node, text in w.reinjected.append((node, text)) },
            onConfirmed: { node, text in w.confirmed.append((node, text)) },
            onFailed: { t, c, text, n, r in w.failed.append((t, c, text, n, r)) },
            maxAttempts: maxAttempts, reinjectGrace: grace, now: { w.clock })
    }

    private func userLine(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":""# + text + #""}}"#
    }

    // Real-shape fixtures (session 48429977, claude 2.1.206).
    private func enqueueLine(_ text: String) -> String {
        #"{"type":"queue-operation","operation":"enqueue","content":""# + text + #""}"#
    }
    private func queuedCommandLine(_ text: String) -> String {   // consumption INTO context
        #"{"attachment":{"type":"queued_command","prompt":""# + text + #""},"type":"attachment"}"#
    }
    private func apiErrorLine() -> String {
        #"{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"API Error: Connection closed mid-response"}]}}"#
    }

    // MARK: three-state delivery confirmation

    func testConfirmsMidTurnQueuedCommandDelivery() {
        // Mid-turn injection only persists queue-operation + queued_command attachment,
        // with no type:"user" line; and at this point the status is misjudged as .idle
        // (not running). A consumed attachment is already in context — it must be
        // confirmed, not treated as unconfirmed (which would reinject repeatedly and
        // falsely report failed).
        let w = World()
        w.status[NodeID("n4")] = .idle
        let msg = "MESSAGE FROM root: rebase onto main"
        w.transcript[NodeID("n4")] = enqueueLine(msg) + "\n" + queuedCommandLine(msg)
        let t = make(w, grace: 0)
        t.register(target: NodeID("n4"), caller: NodeID("root"), text: msg)
        w.clock.addTimeInterval(100)
        t.tick()
        XCTAssertEqual(w.confirmed.count, 1, "consumed queued_command = delivery confirmed")
        XCTAssertTrue(w.reinjected.isEmpty, "already confirmed — never reinject and pollute the context")
        XCTAssertTrue(w.failed.isEmpty, "direction must not flip: a delivered message must not be falsely reported as failed")
        XCTAssertEqual(t.pendingCount, 0)
    }

    func testDoesNotReinjectWhileMessageEnqueuedLive() {
        // mid-turn injection has already entered claude's queue (enqueue) but hasn't been consumed
        // yet; status is misjudged as .idle. The message is still in flight and will be delivered
        // naturally at turn completion — must never jump the gun and reinject. The transcript
        // criterion is immune to status misjudgment.
        let w = World()
        w.status[NodeID("n4")] = .idle
        let msg = "MESSAGE FROM root: rebase onto main"
        w.transcript[NodeID("n4")] = enqueueLine(msg)
        let t = make(w, grace: 4)
        t.register(target: NodeID("n4"), caller: NodeID("root"), text: msg)
        w.clock.addTimeInterval(100); t.tick()
        XCTAssertTrue(w.reinjected.isEmpty, "in flight in the queue — do not reinject")
        XCTAssertTrue(w.failed.isEmpty)
        XCTAssertEqual(t.pendingCount, 1, "still registered, awaiting consumption confirmation")
        // Turn completion consumes it into context → confirmed.
        w.transcript[NodeID("n4")]! += "\n" + queuedCommandLine(msg)
        t.tick()
        XCTAssertEqual(w.confirmed.count, 1)
        XCTAssertEqual(t.pendingCount, 0)
    }

    func testReinjectsWhenEnqueuedButApiErrorDiscardedQueue() {
        // The genuine-loss path must be preserved: after enqueue, the turn is killed by an API
        // error, wiping the queue along with it (no consumption).
        // hasApiError lifts the in-flight exemption → reinject recovers once idle.
        let w = World()
        w.status[NodeID("n7")] = .errored
        let msg = "MESSAGE FROM n5: go"
        w.transcript[NodeID("n7")] = enqueueLine(msg) + "\n" + apiErrorLine()
        let t = make(w, grace: 4)
        t.register(target: NodeID("n7"), caller: NodeID("n5"), text: msg)
        w.clock.addTimeInterval(5); t.tick()
        XCTAssertEqual(w.reinjected.count, 1, "an API error clears the queue = genuine loss, must reinject")
        XCTAssertEqual(t.pendingCount, 1)
    }

    func testDoesNotReinjectWhileQueuedStatus() {
        // .queued (local inject FIFO pending) is also in the exemption set: a local injection
        // attempt is still in progress, must not stack an additional reinject.
        let w = World()
        w.status[NodeID("n7")] = .queued
        let t = make(w, grace: 0)
        t.register(target: NodeID("n7"), caller: NodeID("n5"), text: "MESSAGE FROM n5: go")
        w.clock.addTimeInterval(100); t.tick()
        XCTAssertTrue(w.reinjected.isEmpty)
        XCTAssertEqual(t.pendingCount, 1)
    }

    func testConfirmsWhenUserMessageAppears() {
        let w = World()
        w.status[NodeID("n7")] = .running
        let t = make(w)
        t.register(target: NodeID("n7"), caller: NodeID("n5"), text: "MESSAGE FROM n5: go")

        t.tick()   // not in transcript yet
        XCTAssertEqual(t.pendingCount, 1)

        w.transcript[NodeID("n7")] = userLine("MESSAGE FROM n5: go")
        t.tick()
        XCTAssertEqual(t.pendingCount, 0)
        XCTAssertEqual(w.confirmed.count, 1)
        XCTAssertTrue(w.reinjected.isEmpty, "already confirmed — never reinject")
    }

    func testDoesNotReinjectWhileTurnRunning() {
        // Turn is running: the message may still be queued inside claude; wait for the turn to
        // finish naturally, don't jump the gun and reinject.
        let w = World()
        w.status[NodeID("n7")] = .running
        let t = make(w, grace: 0)
        t.register(target: NodeID("n7"), caller: NodeID("n5"), text: "MESSAGE FROM n5: go")
        w.clock.addTimeInterval(100)
        t.tick()
        XCTAssertTrue(w.reinjected.isEmpty)
        XCTAssertEqual(t.pendingCount, 1)
    }

    func testReinjectsAfterTurnDeathUnconfirmed() {
        // Turn is dead (idle/errored) and unconfirmed → reinject once idle (via the existing inject
        // FIFO).
        let w = World()
        w.status[NodeID("n7")] = .errored          // API-dead turn
        let t = make(w, grace: 4)
        t.register(target: NodeID("n7"), caller: NodeID("n5"), text: "MESSAGE FROM n5: go")

        t.tick()                                    // grace period hasn't elapsed
        XCTAssertTrue(w.reinjected.isEmpty)

        w.clock.addTimeInterval(5)                  // grace period elapsed
        t.tick()
        XCTAssertEqual(w.reinjected.count, 1)
        XCTAssertEqual(w.reinjected.first?.0, NodeID("n7"))
        XCTAssertEqual(t.pendingCount, 1, "still registered after reinject, awaiting confirmation")
    }

    func testReinjectRespectsGraceBetweenAttempts() {
        let w = World()
        w.status[NodeID("n7")] = .idle
        let t = make(w, grace: 4)
        t.register(target: NodeID("n7"), caller: NodeID("n5"), text: "MESSAGE FROM n5: go")
        w.clock.addTimeInterval(5); t.tick()        // attempt 1
        XCTAssertEqual(w.reinjected.count, 1)
        w.clock.addTimeInterval(1); t.tick()        // hasn't reached grace yet, don't reinject
        XCTAssertEqual(w.reinjected.count, 1)
        w.clock.addTimeInterval(4); t.tick()        // attempt 2
        XCTAssertEqual(w.reinjected.count, 2)
    }

    func testFailsAfterMaxAttemptsWithVisibleReceipt() {
        // Exhausted reinjects still unconfirmed → failure is visible to the caller (onFailed
        // triggers a system receipt).
        let w = World()
        w.status[NodeID("n7")] = .idle
        let t = make(w, maxAttempts: 2, grace: 4)
        t.register(target: NodeID("n7"), caller: NodeID("n5"), text: "MESSAGE FROM n5: go")
        for _ in 0..<4 { w.clock.addTimeInterval(5); t.tick() }
        XCTAssertEqual(w.reinjected.count, 2, "reinject cap = 2")
        XCTAssertEqual(w.failed.count, 1)
        XCTAssertEqual(w.failed.first?.caller, NodeID("n5"), "the failure receipt goes back to the caller")
        XCTAssertEqual(w.failed.first?.attempts, 2)
        XCTAssertEqual(t.pendingCount, 0)
    }

    func testTargetDeathFailsImmediately() {
        let w = World()
        w.status[NodeID("n7")] = .killed
        let t = make(w)
        t.register(target: NodeID("n7"), caller: NodeID("n5"), text: "MESSAGE FROM n5: go")
        t.tick()
        XCTAssertEqual(w.failed.count, 1)
        XCTAssertTrue(w.failed.first?.reason.contains("killed") ?? false)
        XCTAssertEqual(t.pendingCount, 0)
    }

    func testConfirmationBeatsReinjectRace() {
        // Turn is dead but the message has actually already entered the transcript (normal
        // completion wrote to disk a beat late) → confirmation wins the race over reinject.
        let w = World()
        w.status[NodeID("n7")] = .idle
        w.transcript[NodeID("n7")] = userLine("MESSAGE FROM n5: go")
        let t = make(w, grace: 0)
        t.register(target: NodeID("n7"), caller: NodeID("n5"), text: "MESSAGE FROM n5: go")
        w.clock.addTimeInterval(10)
        t.tick()
        XCTAssertEqual(w.confirmed.count, 1)
        XCTAssertTrue(w.reinjected.isEmpty)
        XCTAssertTrue(w.failed.isEmpty)
    }
}
