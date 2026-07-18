import XCTest
@testable import VigilCore

/// The agent picker's honesty red line — the launcher only lights up kinds
/// that are actually verified working. `custom`-kind entries are grayed out in the UI,
/// backed by `AgentEntry.usable`.
final class AgentEntryTests: XCTestCase {

    func testCustomKindIsNotUsable() {
        // Honesty red line: custom = an unwired escape hatch, must be usable=false (grayed out, unselectable in the launcher).
        let custom = AgentEntry(key: "mystery", bin: "/opt/mystery", kind: .custom)
        XCTAssertFalse(custom.usable, "custom-kind entries must not be usable (grayed out in the agent selector)")
    }

    func testWiredKindsAreUsable() {
        // The three wired families (each with its own Harness + real-machine walkthrough): claude / codex / opencode are all usable.
        for kind in [AgentCLIKind.claude, .codex, .opencode] {
            let e = AgentEntry(key: kind.rawValue, bin: "/bin/\(kind.rawValue)", kind: kind)
            XCTAssertTrue(e.usable, "\(kind.rawValue) is wired, must be usable")
        }
    }
}
