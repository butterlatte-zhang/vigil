import XCTest
import VigilCore
@testable import VigilRuntime
#if canImport(Darwin)
import Darwin
#endif

/// Env hygiene: a CLAUDE_CODE_* prefix sweep would also kill user feature flags
/// (CLAUDE_CODE_EXPERIMENTAL_* etc). A live claude session injects exactly five
/// session-identity markers — strip those and only those (cell env = user env + vigil
/// overlay: add, don't subtract).
final class HarnessEnvHygieneTests: XCTestCase {

    /// The five markers a real claude session injects — the entire justified blacklist
    /// (each is a session-identity marker, not a user setting).
    static let sessionIdentityMarkers = [
        "CLAUDECODE",                  // nested-session flag
        "CLAUDE_CODE_ENTRYPOINT",      // how the PARENT was launched
        "CLAUDE_CODE_SESSION_ID",      // parent's session UUID — wrong attribution if inherited
        "CLAUDE_CODE_CHILD_SESSION",   // marks a spawned child of another claude
        "CLAUDE_CODE_EXECPATH",        // parent's version install dir
    ]

    func testStripsExactlyTheSessionIdentityMarkers() {
        for k in Self.sessionIdentityMarkers { setenv(k, "probe", 1) }
        setenv("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", "1", 1)   // a user feature flag
        defer {
            for k in Self.sessionIdentityMarkers { unsetenv(k) }
            unsetenv("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS")
        }

        let cfg = NSTemporaryDirectory() + "vigil_env_hygiene_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfg) }
        let h = ClaudeCodeHarness(claudeBin: "/c", hookBin: "/h", mcpBin: "/m",
                                  configRoot: cfg, printMode: true)
        let s = h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n1"),
                             role: .leaf, isRoot: false,
                             mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")

        for k in Self.sessionIdentityMarkers {
            XCTAssertNil(s.env[k], "\(k) is parent-session identity — must be stripped")
        }
        // The user's own feature switches pass through untouched.
        XCTAssertEqual(s.env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"], "1",
                       "prefix sweep killed a user feature flag — blacklist, not prefix")
    }

    func testTermStaysForcedWhileGhosttyTerminfoIsUnshipped() {
        // xterm-ghostty terminfo is absent from the system db and
        // NOT bundled in GhosttyKit.xcframework — subprocesses (tput/vim/…) would hit
        // "unknown terminal". Keep forcing xterm-256color until the .app ships terminfo.
        let cfg = NSTemporaryDirectory() + "vigil_env_term_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfg) }
        let h = ClaudeCodeHarness(claudeBin: "/c", hookBin: "/h", mcpBin: "/m",
                                  configRoot: cfg, printMode: true)
        let s = h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n1"),
                             role: .leaf, isRoot: false,
                             mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        XCTAssertEqual(s.env["TERM"], "xterm-256color")
    }
}
