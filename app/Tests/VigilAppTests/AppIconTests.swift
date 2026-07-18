import XCTest
@testable import VigilApp

// Packaged-.app icon lookup: `swift build`'s generated Bundle.module accessor probes ONLY
// (a) Bundle.main.bundleURL root — which for a .app is Vigil.app/ itself, NOT
// Contents/Resources, and the bundle root must stay sealed (codesign forbids extra
// entries) — and (b) an ABSOLUTE dev-machine .build path baked in at compile time. So a
// distributed .app fatalErrors inside the accessor on any machine without that path, while
// the dev box false-passes by hitting its own .build. The fix: icon lookup goes Bundle.main
// FIRST (packaging drops the png into Contents/Resources), and only falls back to
// Bundle.module for bare `swift run`. Bundle.module must never be evaluated when main has
// the resource — its static-let initializer is the thing that crashes.
final class AppIconTests: XCTestCase {

    /// A throwaway directory posing as a bundle, optionally carrying the icon resource.
    private func makeBundle(withIcon: Bool) throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppIconTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        if withIcon {
            try Data("png-bytes".utf8)
                .write(to: dir.appendingPathComponent("vigil-app-icon.png"))
        }
        return try XCTUnwrap(Bundle(path: dir.path))
    }

    func testMainBundleWinsWhenItCarriesTheIcon() throws {
        let main = try makeBundle(withIcon: true)
        let url = try XCTUnwrap(AppIcon.iconURL(main: main))
        XCTAssertTrue(url.path.hasPrefix(main.bundlePath),
                      "packaged .app must resolve the icon from Bundle.main " +
                      "(Contents/Resources), never touching Bundle.module — got \(url.path)")
    }

    func testFallsBackToModuleBundleForBareExecutable() throws {
        let main = try makeBundle(withIcon: false)
        let url = try XCTUnwrap(AppIcon.iconURL(main: main),
                                "bare `swift run` (no icon next to Bundle.main) must still " +
                                "find the SwiftPM resource via Bundle.module")
        XCTAssertTrue(url.path.contains("Vigil_VigilApp.bundle"),
                      "fallback should hit the SwiftPM resource bundle — got \(url.path)")
    }
}
