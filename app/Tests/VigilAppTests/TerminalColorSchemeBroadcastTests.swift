import XCTest
@testable import VigilGhosttyTerminal

@MainActor
final class TerminalColorSchemeBroadcastTests: XCTestCase {
    func testEachLiveSurfaceGetsOneSetSchemeAndOneRenderNudge() throws {
        let surfaceA = try XCTUnwrap(UnsafeMutableRawPointer(bitPattern: 0x2031))
        let surfaceB = try XCTUnwrap(UnsafeMutableRawPointer(bitPattern: 0x997))
        var schemeCalls: [UnsafeMutableRawPointer] = []
        var renderCalls: [Int] = []

        TerminalColorSchemeBroadcast.apply(
            to: [
                .init(surface: surfaceA, requestRender: { renderCalls.append(0) }),
                .init(surface: surfaceB, requestRender: { renderCalls.append(1) }),
            ],
            setColorScheme: { schemeCalls.append($0) }
        )

        XCTAssertEqual(schemeCalls, [surfaceA, surfaceB])
        XCTAssertEqual(renderCalls, [0, 1])
    }

    func testNilSurfacesAreSkippedWithoutSchemeOrRenderCalls() {
        var schemeCalls = 0
        var renderCalls = 0

        TerminalColorSchemeBroadcast.apply(
            to: [
                .init(surface: nil, requestRender: { renderCalls += 1 }),
            ],
            setColorScheme: { _ in schemeCalls += 1 }
        )

        XCTAssertEqual(schemeCalls, 0)
        XCTAssertEqual(renderCalls, 0)
    }

    func testMixedNilAndLiveSurfacesOnlyBroadcastToLiveOnes() throws {
        let surface = try XCTUnwrap(UnsafeMutableRawPointer(bitPattern: 0xBEEF))
        var schemeCalls: [UnsafeMutableRawPointer] = []
        var renderCalls = 0

        TerminalColorSchemeBroadcast.apply(
            to: [
                .init(surface: nil, requestRender: { renderCalls += 1 }),
                .init(surface: surface, requestRender: { renderCalls += 1 }),
                .init(surface: nil, requestRender: { renderCalls += 1 }),
            ],
            setColorScheme: { schemeCalls.append($0) }
        )

        XCTAssertEqual(schemeCalls, [surface])
        XCTAssertEqual(renderCalls, 1)
    }

    /// A libghostty call can synchronously trigger an action callback that
    /// mutates the live bridge list. The broadcast must operate on a snapshot handed to it —
    /// mutating the caller's source collection mid-broadcast must not change what this call
    /// visits.
    func testBroadcastIsImmuneToSourceMutationDuringIteration() throws {
        let surfaceA = try XCTUnwrap(UnsafeMutableRawPointer(bitPattern: 0xA))
        let surfaceB = try XCTUnwrap(UnsafeMutableRawPointer(bitPattern: 0xB))
        var liveBridges: [UnsafeMutableRawPointer?] = [surfaceA]
        var visited: [UnsafeMutableRawPointer] = []

        let snapshot = liveBridges
        TerminalColorSchemeBroadcast.apply(
            to: snapshot.map { surface in
                TerminalColorSchemeBroadcast.Target(
                    surface: surface,
                    requestRender: {
                        if let surface { visited.append(surface) }
                        // Simulate a synchronous action callback that grows the live list.
                        liveBridges.append(surfaceB)
                    }
                )
            },
            setColorScheme: { _ in }
        )

        XCTAssertEqual(visited, [surfaceA])
        XCTAssertEqual(liveBridges, [surfaceA, surfaceB])
    }
}
