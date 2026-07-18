import XCTest
import Foundation
import VigilRuntime

/// The one "find the shim executables next to argv[0]" derivation shared by
/// vigil-smoke and AppModel.VigilBins.
final class SiblingBinsTests: XCTestCase {
    func testLocateDerivesSiblingsOfArgv0() {
        // Pin the exact derivation: argv[0], symlinks resolved,
        // parent dir, "/vigil-hook" and "/vigil-mcp" appended.
        let expectedDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent().path
        XCTAssertEqual(SiblingBins.binDir, expectedDir)
        let bins = SiblingBins.locate()
        XCTAssertEqual(bins.hook, expectedDir + "/vigil-hook")
        XCTAssertEqual(bins.mcp, expectedDir + "/vigil-mcp")
    }
}
