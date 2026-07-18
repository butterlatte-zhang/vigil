import XCTest

// The app must present as "Vigil" — not "vigil-app" — in the macOS App
// menu (About/Hide/Quit), which for a BARE SwiftPM executable (no .app bundle) is derived
// from the executable FILENAME, with the embedded Info.plist's CFBundleName driving only the
// bold menu-bar title. So the invariant has two pillars, BOTH pinned here so a rename or a
// plist edit that reintroduces "vigil-app" fails deterministically at `swift test`:
//   1. the app executable target/product is named `Vigil` (→ filename `Vigil` → "About Vigil")
//   2. the embedded Info.plist declares CFBundleName/CFBundleDisplayName == "Vigil"
// The rendered menu itself needs a window server, so its visual check is a manual step
// (STATUS / report); this guards the source-of-truth that feeds it.
final class AppDisplayNameTests: XCTestCase {

    /// Package root = <repo>/app, three levels up from this file
    /// (app/Tests/VigilAppTests/AppDisplayNameTests.swift).
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VigilAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
    }

    func testEmbeddedInfoPlistDeclaresVigilName() throws {
        let plistURL = packageRoot.appendingPathComponent("Vigil-Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            "Vigil-Info.plist must be a valid plist dictionary")

        XCTAssertEqual(plist["CFBundleName"] as? String, "Vigil",
                       "App menu bold title comes from CFBundleName")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Vigil")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "dev.vigil.Vigil")
    }

    func testPackageWiresVigilExecutableAndEmbedsThePlist() throws {
        let pkgURL = packageRoot.appendingPathComponent("Package.swift")
        let pkg = try String(contentsOf: pkgURL, encoding: .utf8)

        // Pillar 1: the executable is named `Vigil` (filename → About/Hide/Quit text) and
        // lives at Sources/Vigil. A regression to `vigil-app` would break the App menu.
        XCTAssertTrue(pkg.contains(#"name: "Vigil""#),
                      "app executable target must be named Vigil (bare-binary App menu = filename)")
        XCTAssertTrue(pkg.contains(#"path: "Sources/Vigil""#),
                      "Vigil target path")
        XCTAssertFalse(pkg.contains(#"name: "vigil-app""#),
                       "the app executable must not revert to vigil-app")

        // Pillar 2: the Info.plist is embedded into __TEXT,__info_plist for the bold title.
        XCTAssertTrue(pkg.contains("__info_plist"), "Info.plist must be embedded via sectcreate")
        XCTAssertTrue(pkg.contains(#""Vigil-Info.plist""#), "embed the Vigil-Info.plist file")
    }
}
