import XCTest
import AppKit
import VigilRuntime
@testable import VigilApp

// Terminal drag-drop → path paste injection.
// File/image normalization is owned by PasteIngest.dropPlan (pinned by PasteIngestTests);
// this file pins TerminalHost's execution semantics: a single segment injects immediately,
// multiple segments (multiple local images) are fed one at a time spaced by the delay —
// a single real claude paste only turns one path into one [Image #N].
@MainActor
final class TerminalDropTests: XCTestCase {

    func testExecute_singleText_sendsImmediately() {
        var sent: [String] = []
        TerminalHost.execute(.insertText("/tmp/a.png"),
                             send: { sent.append($0) },
                             scheduleAfter: { _, _ in XCTFail("single segment must not be scheduled") })
        XCTAssertEqual(sent, ["/tmp/a.png"])
    }

    func testExecute_segments_firstImmediate_restSpacedByDelay() {
        var sent: [String] = []
        var scheduled: [(TimeInterval, () -> Void)] = []
        TerminalHost.execute(
            .insertTextSegments(["a", " b", " c"], interSegmentDelay: 2.0),
            send: { sent.append($0) },
            scheduleAfter: { delay, work in scheduled.append((delay, work)) })

        XCTAssertEqual(sent, ["a"], "first segment injects immediately")
        XCTAssertEqual(scheduled.map(\.0), [2.0], "later segments scheduled one at a time by the delay (next only after the previous is fed)")
        scheduled.removeFirst().1()
        XCTAssertEqual(sent, ["a", " b"])
        XCTAssertEqual(scheduled.map(\.0), [2.0])
        scheduled.removeFirst().1()
        XCTAssertEqual(sent, ["a", " b", " c"])
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testWantsDrop_fileImageOrText() throws {
        let pb = NSPasteboard(name: .init("vigil-drop-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        XCTAssertFalse(TerminalHost.wantsDrop(pb), "empty drag is not accepted")

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("vigil-drop-fixture-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        pb.writeObjects([file as NSURL])
        XCTAssertTrue(TerminalHost.wantsDrop(pb))

        pb.clearContents()
        pb.setString("text drop", forType: .string)
        XCTAssertTrue(TerminalHost.wantsDrop(pb), "text drag = paste text")
    }
}
