import XCTest
@testable import VigilApp
@testable import VigilCore

/// statusText is the user-facing status vocabulary. Spawn takes effect immediately, so a
/// .starting node reads as "booting", never "awaiting approval" — there is no approval
/// step for it to wait on.
final class StatusTextTests: XCTestCase {

    func testStartingMeansBootingNotAwaitingApproval() {
        XCTAssertEqual(statusText(.starting), "Starting")
    }

    func testNoStatusClaimsAnApprovalGate() {
        for d in [DStatus.running, .idle, .waiting, .done, .failed, .killed,
                  .starting, .subagent, .stalled] {
            XCTAssertFalse(statusText(d).lowercased().contains("pending approval"),
                           "\(d): after D13 there is no approval gate, copy must not say 'pending approval'")
        }
    }

    /// Stalled (spawn never connected, the process may not even have been
    /// born) must not masquerade as "awaiting authorization" — that wording belongs to an
    /// actual permission card being present. Honestly reporting a fake-alive state must not
    /// just swap the lie for a different one.
    func testStalledSpawnDoesNotClaimAwaitingApproval() {
        XCTAssertEqual(statusText(.stalled), "spawn didn't connect")
        XCTAssertNotEqual(statusText(.stalled), statusText(.waiting))
        XCTAssertFalse(statusText(.stalled).lowercased().contains("approval"))
        let n = Node(id: NodeID("n1"), role: .leaf, status: .stalled)
        XCTAssertEqual(designStatus(n), .stalled, "NodeStatus.stalled → DStatus.stalled direct mapping")
    }
}
