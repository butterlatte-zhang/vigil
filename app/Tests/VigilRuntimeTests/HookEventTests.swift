import XCTest
@testable import VigilRuntime

// HookEvent is the single source of truth for the wire literals used on both the mount
// side (ClaudeCodeHarness writing settings.json's `--event <name>`) and the dispatch side
// (the HookGateway switch) — a typo in either place would silently sever the channel. This
// test pins the wire literals down — renaming a case must not change the bytes on the wire
// (the literal assertions in HarnessTests/GatewayTests pin the same contract from both
// ends).

final class HookEventTests: XCTestCase {

    func testRawValuesPinTheWireLiterals() {
        XCTAssertEqual(HookEvent.prompt.rawValue, "prompt")
        XCTAssertEqual(HookEvent.permRequest.rawValue, "perm-request")
        XCTAssertEqual(HookEvent.postTool.rawValue, "post-tool")
        XCTAssertEqual(HookEvent.stop.rawValue, "stop")
    }

    /// Event names outside the enum must stay OUT of it: "notification" arriving from a
    /// stale settings.json parses to nil = the gateway's silent drop.
    func testUnknownEventsParseToNil() {
        XCTAssertNil(HookEvent(rawValue: "notification"))
        XCTAssertNil(HookEvent(rawValue: "perm-review"))   // not a recognized event
        XCTAssertNil(HookEvent(rawValue: ""))
        XCTAssertNil(HookEvent(rawValue: "Stop"))     // case-sensitive, wire is lowercase
    }
}
