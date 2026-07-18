import XCTest
@testable import VigilGhosttyTerminal

@MainActor
final class TerminalSurfaceConfigurationRefreshTests: XCTestCase {
    func testLiveSurfaceUpdatesConfigurationBeforeRequestingRender() throws {
        let surface = try XCTUnwrap(UnsafeMutableRawPointer(bitPattern: 0x3851))
        var events: [String] = []

        TerminalSurfaceConfigurationRefresh.apply(
            to: surface,
            updateConfiguration: { received in
                XCTAssertEqual(received, surface)
                events.append("surface-config")
            },
            requestRender: {
                events.append("render")
            }
        )

        XCTAssertEqual(events, ["surface-config", "render"])
    }

    func testMissingSurfaceDoesNotRequestRender() {
        var events: [String] = []

        TerminalSurfaceConfigurationRefresh.apply(
            to: nil,
            updateConfiguration: { _ in events.append("surface-config") },
            requestRender: { events.append("render") }
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testRepeatedReloadsAlwaysPushConfigurationBeforeRepaint() throws {
        let surface = try XCTUnwrap(UnsafeMutableRawPointer(bitPattern: 0x3852))
        var events: [String] = []

        for generation in 0..<100 {
            TerminalSurfaceConfigurationRefresh.apply(
                to: surface,
                updateConfiguration: { _ in events.append("config-\(generation)") },
                requestRender: { events.append("render-\(generation)") }
            )
        }

        XCTAssertEqual(events.count, 200)
        for generation in 0..<100 {
            XCTAssertEqual(events[generation * 2], "config-\(generation)")
            XCTAssertEqual(events[generation * 2 + 1], "render-\(generation)")
        }
    }
}
