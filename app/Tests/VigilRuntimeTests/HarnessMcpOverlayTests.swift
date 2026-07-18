import XCTest
import VigilCore
@testable import VigilRuntime
#if canImport(Darwin)
import Darwin
#endif

/// `--mcp-config` WITHOUT `--strict-mcp-config` is a pure overlay — user-level +
/// project-level + injected servers all connect, and a name collision resolves
/// silently in --mcp-config's favor (the user's same-named server is never spawned),
/// so the vigil channel cannot be hijacked. The product path therefore must NOT pass
/// strict (a cell must never be weaker than a bare terminal); vigil-smoke / Tier-2
/// keep strict for determinism via explicit opt-in.
final class HarnessMcpOverlayTests: XCTestCase {

    private func spec(strictMCP: Bool?, cfg: String) -> LaunchSpec {
        let h: ClaudeCodeHarness
        if let strictMCP = strictMCP {
            h = ClaudeCodeHarness(claudeBin: "/c", hookBin: "/h", mcpBin: "/m",
                                  configRoot: cfg, printMode: true, strictMCP: strictMCP)
        } else {  // product call shape: strict never mentioned
            h = ClaudeCodeHarness(claudeBin: "/c", hookBin: "/h", mcpBin: "/m",
                                  configRoot: cfg, printMode: true)
        }
        return h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n1"),
                            role: .leaf, isRoot: false,
                            mcpEndpoint: "/s/mcp.sock", hookEndpoint: nil, idCred: "n1")
    }

    func testProductPathOverlaysUserMcpServers() {
        // Default (= AppModel's call): vigil is ADDED to the user's servers, not
        // swapped in for them — --mcp-config stays, --strict-mcp-config goes.
        let cfg = NSTemporaryDirectory() + "vigil_mcp_overlay_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfg) }
        let s = spec(strictMCP: nil, cfg: cfg)
        let i = s.args.firstIndex(of: "--mcp-config")
        XCTAssertNotNil(i, "vigil server must still be injected")
        XCTAssertEqual(s.args[i! + 1], cfg + "/n1/mcp.json")
        XCTAssertFalse(s.args.contains("--strict-mcp-config"),
                       "#11: strict blocks every user/project MCP server — lab constraint, not product")
    }

    func testSmokeOptInKeepsStrictDeterminism() {
        // Tier-2 (vigil-smoke) opts in explicitly: same launch surface + strict.
        let cfg = NSTemporaryDirectory() + "vigil_mcp_strict_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfg) }
        let s = spec(strictMCP: true, cfg: cfg)
        XCTAssertTrue(s.args.contains("--mcp-config"))
        XCTAssertTrue(s.args.contains("--strict-mcp-config"))
    }

    func testNoMcpEndpointMeansNoMcpFlagsAtAll() {
        // Without a vigil socket there is nothing to inject — and strict must not
        // appear on its own (a bare --strict-mcp-config would nuke user servers).
        let cfg = NSTemporaryDirectory() + "vigil_mcp_none_\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: cfg) }
        let h = ClaudeCodeHarness(claudeBin: "/c", hookBin: "/h", mcpBin: "/m",
                                  configRoot: cfg, printMode: true)
        let s = h.launchSpec(task: "t", cwd: "/w", nodeID: NodeID("n1"),
                             role: .leaf, isRoot: false,
                             mcpEndpoint: nil, hookEndpoint: nil, idCred: "n1")
        XCTAssertFalse(s.args.contains("--mcp-config"))
        XCTAssertFalse(s.args.contains("--strict-mcp-config"))
    }
}
