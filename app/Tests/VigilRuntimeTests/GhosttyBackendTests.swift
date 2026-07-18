import XCTest
import AppKit
import VigilGhosttyTerminal
@testable import VigilRuntime

// T1a logic tests for the host-managed GhosttyViewBackend.
//
// XCTest boundary (same as GhosttyViewBackend.startOnMain's guard): no ghostty surface
// ever exists in a unit-test process, and the backend does not fork a real agent under
// XCTest either (the headless HostPTY path is exercised directly by
// HostScrapeIntegrationTests). So T1 pins the surface-less / process-less half: view
// lifecycle on kill vs natural exit, and that a pre-start send is a safe no-op. The live
// attach → render / host injection is Tier-2 (vigil-smoke / manual).
//
// Host injection (session.sendInput → HostPTY.write) is surface-independent, so there is
// nothing to queue and no attach-time flush to pin. See GhosttyViewBackend.sendOnMain.
@MainActor
final class GhosttyBackendTests: XCTestCase {

    // MARK: kill path must unparent the view

    /// kill: the node leaves the tree, the view is unreachable — keeping it parented
    /// anywhere is a pure NSView + CAMetalLayer leak.
    func testTerminateRemovesViewFromSuperview() {
        let backend = GhosttyViewBackend()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        host.addSubview(backend.view)
        backend.terminate()
        XCTAssertNil(backend.view.superview,
                     "killed cell's view must leave its superview (issue #3)")
    }

    /// Natural exit boundary: the node stays in the tree and the user can select it to
    /// inspect the final screen — the view must stay parented. The surface's child-exited
    /// delegate is inert (HostPTY owns exit now), so firing it must not touch the view.
    func testNaturalExitKeepsViewParented() {
        let backend = GhosttyViewBackend()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        host.addSubview(backend.view)
        (backend.view.delegate as? any TerminalSurfaceChildExitedDelegate)?
            .terminalChildDidExit(exitCode: 0, runtimeMs: 1)
        XCTAssertNotNil(backend.view.superview,
                        "surface child-exit must not unparent the view")
    }

    // NB: host-managed decouples the child spawn from any renderer, so there is no
    // failed-surface-build to heal and nothing to disarm here. The STALL truth chain is
    // untouched and lives in Orchestrator/SessionStore (OrchestratorTests / SessionStoreTests
    // cover it).

    // MARK: host injection — pre-start send is a safe no-op

    /// send() before start() (or under the XCTest spawn guard) has no session/parser —
    /// it must drop honestly, not crash and not accumulate any hidden queue. renderScreen
    /// with no parser is the empty string.
    func testSendBeforeStartIsSafeNoOp() {
        let backend = GhosttyViewBackend()
        backend.send("hello")
        backend.send("world\r")
        XCTAssertEqual(backend.renderScreen(), "",
                       "no parser before start → scrape is empty, no crash")
    }

    // MARK: fork winsize seeded from the canonical pane size authority

    /// The WIRING assertion for the background-spawn garble fix: a cell must derive its fork
    /// winsize from the shared CanonicalPaneSize so an off-screen worker is born at the real
    /// width, not 24×80. The actual forkpty seeding is proven headless by
    /// HostPTYTests.testResizeBeforeStartSeedsForkSize; here we pin that GhosttyViewBackend
    /// READS canonical on start (recorded via the test seam even under the no-fork guard).
    func testStartDerivesForkSeedFromCanonical() {
        let canonical = CanonicalPaneSize()
        canonical.update(cols: 196, rows: 70, widthPx: 1600, heightPx: 1100)
        let backend = GhosttyViewBackend(cols: 120, rows: 32)
        backend.canonical = canonical
        backend.start(executable: "/bin/echo", args: [], env: [:], cwd: "/tmp") { _ in }
        XCTAssertEqual(backend.lastForkSeedForTest,
                       CanonicalGrid(cols: 196, rows: 70, widthPx: 1600, heightPx: 1100),
                       "background cell must fork at the canonical grid, not the 24×80 default")
    }

    /// No canonical (vigil-parity / winrepro / standalone) → no seed → the pre-existing
    /// default-fork path is untouched. Pins that the fix is strictly additive.
    func testStartWithoutCanonicalKeepsDefaultForkPath() {
        let backend = GhosttyViewBackend(cols: 120, rows: 32)
        backend.start(executable: "/bin/echo", args: [], env: [:], cwd: "/tmp") { _ in }
        XCTAssertNil(backend.lastForkSeedForTest,
                     "no canonical → no seed → HostPTY falls back to its 24×80 default")
    }

    // MARK: ensuredPATH must resolve everything CLIProber can detect

    /// CLIProber's candidateDirs globs ~/.nvm/versions/node/<v>/bin; ensuredPATH must carry
    /// the same tool-manager dirs (nvm GLOBBED, bun, deno, volta, npm-global) as detection,
    /// or a Dock-launched app would detect codex, then fork it into a PATH that can't
    /// resolve its `#!/usr/bin/env node` shebang.
    func testEnsuredPATHIncludesNvmGlobAndBunDir() {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "vigil-ensuredpath-\(UUID().uuidString.prefix(8))"
        for v in ["v18.20.0", "v20.19.6"] {
            try? fm.createDirectory(atPath: home + "/.nvm/versions/node/\(v)/bin",
                                    withIntermediateDirectories: true)
        }
        addTeardownBlock { try? fm.removeItem(atPath: home) }
        let path = GhosttyViewBackend.ensuredPATH(nil, home: home)
        let dirs = path.split(separator: ":").map(String.init)
        XCTAssertTrue(dirs.contains(home + "/.nvm/versions/node/v18.20.0/bin"),
                     "nvm node version bins must be globbed into the execution PATH")
        XCTAssertTrue(dirs.contains(home + "/.nvm/versions/node/v20.19.6/bin"))
        XCTAssertTrue(dirs.contains(home + "/.bun/bin"), "bun-compiled CLIs must resolve")
        XCTAssertTrue(dirs.contains(home + "/.deno/bin"))
        XCTAssertTrue(dirs.contains(home + "/.volta/bin"))
        XCTAssertTrue(dirs.contains(home + "/.npm-global/bin"))
    }

    /// The inherited PATH (e.g. a `swift run` dev launch's full shell PATH) must survive
    /// untouched — ensuredPATH only ADDS, never replaces.
    func testEnsuredPATHPreservesInheritedEntries() {
        let path = GhosttyViewBackend.ensuredPATH("/custom/bin:/usr/bin", home: "/tmp/vigil-nohome")
        let dirs = path.split(separator: ":").map(String.init)
        XCTAssertEqual(dirs.first, "/custom/bin", "inherited entries keep priority order")
        XCTAssertEqual(dirs.filter { $0 == "/usr/bin" }.count, 1, "no duplicate entries")
    }
}
