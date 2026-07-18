import XCTest
@testable import VigilApp

// appearance.json `terminal` knobs. The `effective*` helpers are the validation boundary —
// every invalid value must degrade to the built-in default without dragging its sibling
// fields down (config can't break the app), and valid values must pass through verbatim.

@MainActor
final class TerminalPrefsTests: XCTestCase {

    func testDefaultsMatchTheBuiltinLook() {
        let p = VGTerminalPrefs.defaults
        XCTAssertEqual(VGGhosttyTheme.effectiveFontChain(p),
                       ["SF Mono", "Menlo", "PingFang SC"])
        XCTAssertEqual(VGGhosttyTheme.effectiveFontSize(p), 12.5)
        XCTAssertEqual(VGGhosttyTheme.effectiveCursorStyle(p), "block")
        XCTAssertEqual(VGGhosttyTheme.effectivePadding(p), 0)
        XCTAssertEqual(VGGhosttyTheme.effectivePalette(p, theme: .dark),
                       VGGhosttyTheme.builtinPaletteDark)
        XCTAssertEqual(VGGhosttyTheme.effectivePalette(p, theme: .light),
                       VGGhosttyTheme.builtinPaletteLight)
    }

    func testValidValuesPassThrough() {
        var p = VGTerminalPrefs()
        p.fontFamily = ["JetBrains Mono", " Menlo "]
        p.fontSize = 14
        p.cursorStyle = "Bar"                       // case-insensitive
        p.padding = 12
        p.paletteDark = (0..<16).map { String(format: "#%06x", $0 * 1000) }
        XCTAssertEqual(VGGhosttyTheme.effectiveFontChain(p), ["JetBrains Mono", "Menlo"],
                       "families are trimmed, order preserved")
        XCTAssertEqual(VGGhosttyTheme.effectiveFontSize(p), 14)
        XCTAssertEqual(VGGhosttyTheme.effectiveCursorStyle(p), "bar")
        XCTAssertEqual(VGGhosttyTheme.effectivePadding(p), 12)
        XCTAssertEqual(VGGhosttyTheme.effectivePalette(p, theme: .dark), p.paletteDark)
        XCTAssertEqual(VGGhosttyTheme.effectivePalette(p, theme: .light),
                       VGGhosttyTheme.builtinPaletteLight,
                       "a dark-only override must not leak into light")
    }

    func testInvalidValuesDegradeToBuiltins() {
        var p = VGTerminalPrefs()
        p.fontFamily = ["", "   ", ".AppleSystemUIFontMonospaced"]   // private dot font banned
        p.fontSize = 300                                             // out of 6...72
        p.cursorStyle = "beam"                                       // not a ghostty style
        p.padding = -3                                               // out of 0...64
        p.paletteDark = ["#123456"]                                  // not 16 entries
        p.paletteLight = Array(repeating: "red", count: 16)          // not #rrggbb
        XCTAssertEqual(VGGhosttyTheme.effectiveFontChain(p),
                       ["SF Mono", "Menlo", "PingFang SC"])
        XCTAssertEqual(VGGhosttyTheme.effectiveFontSize(p), 12.5)
        XCTAssertEqual(VGGhosttyTheme.effectiveCursorStyle(p), "block")
        XCTAssertEqual(VGGhosttyTheme.effectivePadding(p), 0)
        XCTAssertEqual(VGGhosttyTheme.effectivePalette(p, theme: .dark),
                       VGGhosttyTheme.builtinPaletteDark)
        XCTAssertEqual(VGGhosttyTheme.effectivePalette(p, theme: .light),
                       VGGhosttyTheme.builtinPaletteLight)
    }

    func testHexColorValidator() {
        XCTAssertTrue(VGGhosttyTheme.isHexColor("#a1B2c3"))
        XCTAssertFalse(VGGhosttyTheme.isHexColor("a1B2c3"))     // missing #
        XCTAssertFalse(VGGhosttyTheme.isHexColor("#a1B2c"))     // short
        XCTAssertFalse(VGGhosttyTheme.isHexColor("#a1B2c3d4")) // long
        XCTAssertFalse(VGGhosttyTheme.isHexColor("#a1B2cg"))    // non-hex digit
    }

    // Base terminal colors support "auto" (the default): "auto" / nil / invalid resolve to
    // the theme's built-in token; a valid hex overrides.
    func testBaseColorsDefaultToAuto() {
        let fallback = NSColor(hex: 0x161719)
        // nil (the default) and the literal "auto" both fall back to the theme token.
        XCTAssertEqual(VGGhosttyTheme.effectiveColorHex(nil, fallback: fallback), "#161719")
        XCTAssertEqual(VGGhosttyTheme.effectiveColorHex("auto", fallback: fallback), "#161719")
        XCTAssertEqual(VGGhosttyTheme.effectiveColorHex("  AUTO  ", fallback: fallback), "#161719",
                       "auto is trimmed but is not a hex → still the fallback")
        // Invalid shapes degrade to the fallback (config can't break the surface).
        XCTAssertEqual(VGGhosttyTheme.effectiveColorHex("161719", fallback: fallback), "#161719")
        XCTAssertEqual(VGGhosttyTheme.effectiveColorHex("#12345", fallback: fallback), "#161719")
    }

    func testBaseColorsValidHexOverrides() {
        let fallback = NSColor(hex: 0x161719)
        XCTAssertEqual(VGGhosttyTheme.effectiveColorHex("#ABCDEF", fallback: fallback), "#abcdef",
                       "a valid override wins and is normalized to lowercase")
        // The default prefs (all-auto) render the theme tokens verbatim.
        let cfg = VGGhosttyTheme.configuration(for: VGTokens.make(.dark, .blue),
                                               prefs: .defaults)
        XCTAssertNotNil(cfg, "configuration builds with all-auto colors")
    }

    // The orchestration toast is opt-in — default OFF surfaces nothing, ON surfaces the
    // last spawn/kill line.
    func testOrchestrationToast_defaultOffShowsNothing() {
        let lines = ["spawned n1 (leaf) under root", "killed n2"]
        XCTAssertNil(TerminalPane.orchestrationToastLine(in: lines[...], enabled: false),
                     "default off must surface no toast, even with matching log lines")
    }

    func testOrchestrationToast_enabledSurfacesLastMatch() {
        let lines = ["injected note", "spawned n1 (leaf) under root",
                     "some other note", "killed n2"]
        XCTAssertEqual(TerminalPane.orchestrationToastLine(in: lines[...], enabled: true),
                       "killed n2", "last matching line wins")
        XCTAssertNil(TerminalPane.orchestrationToastLine(in: ["idle", "note"][...], enabled: true),
                     "no spawn/kill line → nothing even when enabled")
    }
}
