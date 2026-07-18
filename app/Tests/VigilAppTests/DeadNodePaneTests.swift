import XCTest
import SwiftUI
import ViewInspector
@testable import VigilApp
@testable import VigilCore

// The dead-node center pane is Vigil's self-rendered plain-text transcript, with a
// "press Enter to resume" line at the bottom (no resume/open-transcript buttons). T1b: the
// pane takes plain data (node + pointer + frozen frame + preloadedItems test seam), no
// live session needed; the live wiring (killed node selected → pane shows) sits in WiringTests.

@MainActor
final class DeadNodePaneTests: XCTestCase {

    private func deadNode(_ status: NodeStatus = .killed) -> Node {
        Node(id: NodeID("n1"), role: .leaf, status: status, title: "worker A")
    }

    private var liveTranscript: String {
        let p = NSTemporaryDirectory() + "vigil-dead-transcript-\(UUID().uuidString).jsonl"
        try? #"{"type":"user","message":{"content":"fix a bug"}}"#
            .write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    private let sampleItems = [
        TranscriptItem(id: 0, kind: .user, text: "fix a bug"),
        TranscriptItem(id: 1, kind: .assistant, text: "fixed, all tests green"),
    ]

    // MARK: pointer state machine (shared with HistoryPane)

    func testTranscriptPointerStates() {
        let t = liveTranscript
        defer { try? FileManager.default.removeItem(atPath: t) }
        XCTAssertEqual(TranscriptPointer.state(t), .available)
        XCTAssertEqual(TranscriptPointer.state("/tmp/vigil-no-such-transcript.jsonl"), .cleaned)
        XCTAssertEqual(TranscriptPointer.state(nil), .never)
    }

    // MARK: self-rendered body — transcript is read and rendered directly, buttons are gone

    func testPaneRendersTranscriptItemsAndNoLegacyButtons() throws {
        let t = liveTranscript
        defer { try? FileManager.default.removeItem(atPath: t) }
        let pane = DeadNodePane(node: deadNode(), transcriptPath: t,
                                lastFrame: nil, kind: .claude,
                                preloadedItems: sampleItems)
        let v = try pane.inspect()
        XCTAssertNoThrow(try v.find(viewWithAccessibilityIdentifier: "transcript.read"))
        XCTAssertNotNil(try? v.find(text: "fix a bug"))
        XCTAssertNotNil(try? v.find(text: "fixed, all tests green"))
        // Neither legacy button exists.
        XCTAssertThrowsError(try v.find(viewWithAccessibilityIdentifier: "deadnode.transcript"))
        XCTAssertThrowsError(try v.find(viewWithAccessibilityIdentifier: "deadnode.resume"))
        // killed → terminated (the hint line is a long interpolated string, match by contains)
        XCTAssertNoThrow(try v.find(ViewType.Text.self,
                                    where: { try $0.string().contains("Terminated") }))
    }

    /// Invalid pointer → honestly say it was cleaned up, fall back to the frozen frame (never pretend the content is still there).
    func testCleanedPointerFallsBackToFrozenFrame() throws {
        let pane = DeadNodePane(node: deadNode(), transcriptPath: "/tmp/vigil-gone.jsonl",
                                lastFrame: "❯ swift test — 42 passed", kind: .claude)
        let v = try pane.inspect()
        XCTAssertNotNil(try? v.find(text: "❯ swift test — 42 passed"))
        XCTAssertNoThrow(try v.find(ViewType.Text.self,
                                    where: { try $0.string().contains("cleaned up by claude") }))
    }

    func testNeverPointerNoFrameSaysSo() throws {
        let pane = DeadNodePane(node: deadNode(.done), transcriptPath: nil,
                                lastFrame: nil, kind: .claude)
        XCTAssertNotNil(try? pane.inspect()
            .find(text: "No transcript record, and no frozen frame"))
    }

    // MARK: bottom Enter line (replaces the input box)

    func testResumableShowsEnterHint() throws {
        let pane = DeadNodePane(node: deadNode(), transcriptPath: nil,
                                lastFrame: "last", kind: .claude,
                                onResume: {})
        let v = try pane.inspect()
        XCTAssertNoThrow(try v.find(viewWithAccessibilityIdentifier: "deadnode.resumeHint"))
        XCTAssertNoThrow(try v.find(ViewType.Text.self,
                                    where: { try $0.string().contains("Press Enter to resume this agent") }))
    }

    // Each dead node's resume hint is dispatched by its own family — a heterogeneous
    // worker must never show root's claude syntax (claude=`--resume` / codex=`resume` /
    // opencode=`--session`).
    func testResumeHintUsesNodeOwnFamilySyntax() throws {
        func hint(_ kind: AgentCLIKind) throws -> String {
            let pane = DeadNodePane(node: deadNode(), transcriptPath: nil,
                                    lastFrame: "last", kind: kind, onResume: {})
            return try pane.inspect().find(ViewType.Text.self,
                where: { try $0.string().contains("Press Enter to resume this agent") }).string()
        }
        XCTAssertTrue(try hint(.claude).contains("claude --resume"))
        XCTAssertTrue(try hint(.codex).contains("codex resume"))
        XCTAssertTrue(try hint(.opencode).contains("opencode --session"),
                      "opencode dead node must show --session, not a hardcoded --resume")
    }

    func testNonResumableShowsReadOnlyLine() throws {
        let pane = DeadNodePane(node: deadNode(), transcriptPath: nil,
                                lastFrame: "last", kind: .claude, onResume: nil)
        XCTAssertNotNil(try? pane.inspect()
            .find(text: "Read-only — this node has no resume credentials"))
    }

    // MARK: Enter arbitration (shared host shell TranscriptHostView)
    // ViewInspector can't drive onKeyPress, so the arbitration logic lives in
    // handleReturn and is tested directly; DeadNodePane and HistoryPane's Enter semantics
    // share this single implementation.

    func testTranscriptHostReturnKey_resumableFiresAndSwallows() {
        var fired = false
        let host = TranscriptHostView(
            transcriptPath: nil, taskID: "t", axID: "test.host",
            hint: "Press Enter to resume", readOnlyText: "read-only", hintAxID: "test.hint",
            onResume: { fired = true },
            header: { EmptyView() }, content: { _, _ in EmptyView() })
        guard case .handled = host.handleReturn() else {
            return XCTFail("Enter with resume credentials must swallow the event (.handled)")
        }
        XCTAssertTrue(fired, "Enter must fire onResume")
    }

    func testTranscriptHostReturnKey_readOnlyIgnores() {
        let host = TranscriptHostView(
            transcriptPath: nil, taskID: "t", axID: "test.host",
            hint: nil, readOnlyText: "read-only", hintAxID: "test.hint",
            onResume: nil,
            header: { EmptyView() }, content: { _, _ in EmptyView() })
        guard case .ignored = host.handleReturn() else {
            return XCTFail("Enter without credentials must be .ignored (key keeps bubbling, promises nothing)")
        }
    }
}
