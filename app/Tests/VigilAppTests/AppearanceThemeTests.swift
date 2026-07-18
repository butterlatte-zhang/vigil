import XCTest
@testable import VigilApp

// Pure T1 for the follow-system appearance model: preference parse, effective
// theme derivation, and the terminal diff-guard. No AppModel / NSApp here — the live-switch
// integration lives in ConfigTests.testFollowSystem_liveSwitchAndPin.
@MainActor
final class AppearanceThemeTests: XCTestCase {

    // 1) preference parse — tolerant parse of appearance.json `theme`.
    func testPreferenceParse() {
        XCTAssertEqual(VGThemePreference(configValue: "dark"), .pinned(.dark))
        XCTAssertEqual(VGThemePreference(configValue: "light"), .pinned(.light))
        // "auto" / "system" / absent / unknown all mean follow-system (the product default).
        XCTAssertEqual(VGThemePreference(configValue: "auto"), .system)
        XCTAssertEqual(VGThemePreference(configValue: "system"), .system)
        XCTAssertEqual(VGThemePreference(configValue: nil), .system)
        XCTAssertEqual(VGThemePreference(configValue: "solarized"), .system)
        XCTAssertEqual(VGThemePreference(configValue: ""), .system)
        // Whitespace + case tolerance (config-can't-break-the-app).
        XCTAssertEqual(VGThemePreference(configValue: "  Dark "), .pinned(.dark))
        XCTAssertEqual(VGThemePreference(configValue: "LIGHT"), .pinned(.light))
    }

    // 2) effective theme resolution — resolve against the live OS scheme.
    func testResolveAndFollowsSystem() {
        XCTAssertEqual(VGThemePreference.pinned(.dark).resolve(systemIsDark: false), .dark,
                       "a pin ignores the system")
        XCTAssertEqual(VGThemePreference.pinned(.light).resolve(systemIsDark: true), .light)
        XCTAssertEqual(VGThemePreference.system.resolve(systemIsDark: true), .dark)
        XCTAssertEqual(VGThemePreference.system.resolve(systemIsDark: false), .light)

        XCTAssertTrue(VGThemePreference.system.followsSystem)
        XCTAssertFalse(VGThemePreference.pinned(.dark).followsSystem)
        XCTAssertFalse(VGThemePreference.pinned(.light).followsSystem)
    }

    // 3) diff guard avoids redundant apply — the terminal only re-applies on a REAL identity change.
    func testGhosttyDiffGuard() {
        let d = VGTerminalPrefs.defaults
        // First apply (no prior state) always goes through.
        XCTAssertTrue(VGGhosttyTheme.shouldApply(prevKey: nil, prevPrefs: nil,
                                                 key: "dark-blue", prefs: d))
        // Identical (theme, accent, prefs) ⇒ guarded (avoids a redundant re-apply that would flicker).
        XCTAssertFalse(VGGhosttyTheme.shouldApply(prevKey: "dark-blue", prevPrefs: d,
                                                  key: "dark-blue", prefs: d))
        // A follow-system light⇄dark flip changes the theme half of the key ⇒ applies.
        XCTAssertTrue(VGGhosttyTheme.shouldApply(prevKey: "dark-blue", prevPrefs: d,
                                                 key: "light-blue", prefs: d))
        // Accent change ⇒ applies.
        XCTAssertTrue(VGGhosttyTheme.shouldApply(prevKey: "dark-blue", prevPrefs: d,
                                                 key: "dark-teal", prefs: d))
        // Same theme/accent but a prefs change (e.g. font size) ⇒ applies.
        var p = VGTerminalPrefs.defaults; p.fontSize = 15
        XCTAssertTrue(VGGhosttyTheme.shouldApply(prevKey: "dark-blue", prevPrefs: d,
                                                 key: "dark-blue", prefs: p))
    }
}
