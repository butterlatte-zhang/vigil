import Foundation
import AppKit
import VigilGhosttyTerminal

// VG tokens → ghostty terminal theme.
// The ghostty config is app-level (one TerminalController.shared for every cell), so the
// mapping lives here as a diff-guarded singleton apply: TerminalHost calls apply(vg) on
// every SwiftUI update, and only an actual token change reaches ghostty — re-applying
// the same theme causes a visible flicker.

/// appearance.json `terminal` block: user-tunable, purely render-side knobs for the
/// ghostty surface. Every field is optional — nil / invalid values fall back to the
/// built-in defaults (the config-can't-break-the-app contract); validation lives in
/// VGGhosttyTheme's `effective*` helpers (T1a-tested).
struct VGTerminalPrefs: Equatable {
    var fontFamily: [String] = []       // ordered fallback chain; [] = built-in chain
    var fontSize: Double? = nil         // points; accepted 6...72
    var cursorStyle: String? = nil      // block | bar | underline | block_hollow
    var padding: Int? = nil             // window-padding-x/y in px; accepted 0...64
    var paletteDark: [String]? = nil    // exactly 16 "#rrggbb" entries; nil = "auto" (theme built-in)
    var paletteLight: [String]? = nil
    // Base terminal colors. Each is "auto" / nil / invalid = follow the app theme's
    // built-in token (the current default behavior made explicit), or a "#rrggbb" string
    // to override.
    var background: String? = nil       // "auto" | "#rrggbb"
    var foreground: String? = nil       // "auto" | "#rrggbb"
    var cursorColor: String? = nil      // "auto" | "#rrggbb" (distinct from cursorStyle)

    static let defaults = VGTerminalPrefs()
}

@MainActor
enum VGGhosttyTheme {
    private static var appliedKey: String?
    private static var appliedPrefs: VGTerminalPrefs?

    /// Pure diff-guard: given the last-applied identity and the incoming one, should the
    /// terminal theme actually be re-pushed to ghostty? Re-applying the SAME (theme, accent,
    /// prefs) causes a visible flicker — so identical ⇒ false. A follow-system light⇄dark
    /// flip changes `vg.theme`, hence the key, hence returns true and rides this ONE writer
    /// (no bypass write-point). Extracted so the guard is unit-testable without the ghostty
    /// controller.
    static func shouldApply(prevKey: String?, prevPrefs: VGTerminalPrefs?,
                            key: String, prefs: VGTerminalPrefs) -> Bool {
        key != prevKey || prefs != prevPrefs
    }

    /// Applies the resolved Vigil appearance to ghostty and reports whether the shared
    /// controller is now at that exact target. A cache hit is success: another AppModel may
    /// still need to publish the same already-applied colors into its own TerminalColorSource.
    /// Failed validation/application never poisons the diff cache, so the next SwiftUI update
    /// can retry the same identity.
    @discardableResult
    static func apply(_ vg: VGTokens, prefs: VGTerminalPrefs = .defaults) -> Bool {
        let key = "\(vg.theme)-\(vg.accentName)"
        let cfg = configuration(for: vg, prefs: prefs)
        // Both slots carry the SAME resolved VG config: VG's own theme toggle decides
        // dark/light (tokens are pre-resolved), so a system-appearance adopt() cannot
        // fight the app theme — whichever scheme ghostty picks, it renders VG's colors.
        let theme = TerminalTheme(light: cfg, dark: cfg)
        let controller = TerminalController.shared
        let colorScheme: TerminalColorScheme = vg.theme == .dark ? .dark : .light
        let identityChanged = shouldApply(prevKey: appliedKey, prevPrefs: appliedPrefs,
                                          key: key, prefs: prefs)
        if !identityChanged,
           controller.theme == theme,
           controller.effectiveColorScheme == colorScheme { return true }

        // A cache hit with controller drift is not a no-op: AppTerminalView lifecycle can
        // independently adopt a scheme, so drive it back to the resolved app target.
        controller.setTheme(theme)
        controller.setColorScheme(colorScheme)

        guard controller.theme == theme,
              controller.effectiveColorScheme == colorScheme else { return false }
        appliedKey = key
        appliedPrefs = prefs
        return true
    }

    // MARK: effective values (pure validation — invalid input falls back to built-ins)

    /// Built-in ANSI 16 per VG theme — claude's colored output must stay readable on
    /// both grounds.
    static let builtinPaletteDark = ["#32323e", "#e06c75", "#98c379", "#e5c07b",
                                     "#61afef", "#c678dd", "#56b6c2", "#d8d8e0",
                                     "#5a5a6a", "#e8828b", "#a8d389", "#f0cb8b",
                                     "#7bbcf5", "#d38ee8", "#6cc6d2", "#ffffff"]
    static let builtinPaletteLight = ["#2a2a32", "#ca1243", "#50a14f", "#c18401",
                                      "#4078f2", "#a626a4", "#0184bc", "#a0a0a8",
                                      "#6a6a74", "#e04563", "#63b463", "#d69a24",
                                      "#5a8ff5", "#bc44ba", "#1a9cd4", "#2a2a32"]
    /// mac-native terminal font stack: in light mode ghostty's bundled JetBrains Mono
    /// plus the heavy CJK black face CoreText picks as fallback looks ugly and muddy.
    /// Repeated font-family = the fallback chain: SF Mono
    /// (resolvable by name only if the user installed Apple's official font pack;
    /// when absent ghostty's by-family discovery skips it) → Menlo (preinstalled on
    /// every Mac, Terminal.app's factory default) → PingFang SC (Chinese). The
    /// system-internal .AppleSystemUIFontMonospaced is a dot-prefixed private font —
    /// never put it in the config (private API, breaks across versions).
    static let builtinFontChain = ["SF Mono", "Menlo", "PingFang SC"]

    static func effectiveFontChain(_ prefs: VGTerminalPrefs) -> [String] {
        let cleaned = prefs.fontFamily
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(".") }   // dot-prefix = private fonts
        return cleaned.isEmpty ? builtinFontChain : cleaned
    }

    static func effectiveFontSize(_ prefs: VGTerminalPrefs) -> Double {
        guard let s = prefs.fontSize, (6.0...72.0).contains(s) else { return 12.5 }
        return s
    }

    static func effectiveCursorStyle(_ prefs: VGTerminalPrefs) -> String {
        let allowed = ["block", "bar", "underline", "block_hollow"]
        guard let c = prefs.cursorStyle?.trimmingCharacters(in: .whitespaces).lowercased(),
              allowed.contains(c) else { return "block" }
        return c
    }

    static func effectivePadding(_ prefs: VGTerminalPrefs) -> Int {
        guard let p = prefs.padding, (0...64).contains(p) else { return 0 }
        return p
    }

    static func effectivePalette(_ prefs: VGTerminalPrefs, theme: VGTheme) -> [String] {
        let user = theme == .dark ? prefs.paletteDark : prefs.paletteLight
        if let user, user.count == 16, user.allSatisfy(isHexColor) { return user }
        return theme == .dark ? builtinPaletteDark : builtinPaletteLight
    }

    static func isHexColor(_ s: String) -> Bool {
        let bytes = s.utf8
        guard bytes.count == 7, bytes.first == 0x23 else { return false }
        return bytes.dropFirst().allSatisfy { byte in
            (0x30 ... 0x39).contains(byte)
                || (0x41 ... 0x46).contains(byte)
                || (0x61 ... 0x66).contains(byte)
        }
    }

    /// Base color resolution: a valid "#rrggbb" override wins; "auto" / nil / anything
    /// invalid falls back to the theme's built-in token (rendered to hex). This makes
    /// "auto" the explicit default — the current behavior — without a special case.
    static func effectiveColorHex(_ raw: String?, fallback: NSColor) -> String {
        if let raw = raw?.trimmingCharacters(in: .whitespaces), isHexColor(raw) {
            return raw.lowercased()
        }
        return hexString(fallback)
    }

    /// "#rrggbb" → the xterm OSC 10/11 reply color spec (`rgb:rrrr/gggg/bbbb`) — each 8-bit
    /// channel doubled into a 16-bit component, the standard xterm reply convention (`0xNN`
    /// scales to `0xNNNN` via `NN` repeated, not `NN00`). This is the ONE place an
    /// NSColor-derived value crosses into VigilRuntime (which cannot `import AppKit`) — the
    /// two resulting strings are passed down as opaque, already-formatted wire values;
    /// VigilRuntime never touches a color, only concatenates these into the OSC reply frame.
    static func oscColorSpec(hex: String) -> String {
        let normalized = hex.hasPrefix("#") ? hex : "#" + hex
        guard isHexColor(normalized) else { return "rgb:0000/0000/0000" }
        let digits = String(normalized.dropFirst())
        let r = digits.prefix(2), g = digits.dropFirst(2).prefix(2), b = digits.suffix(2)
        return "rgb:\(r)\(r)/\(g)\(g)/\(b)\(b)"
    }

    static func configuration(for vg: VGTokens,
                              prefs: VGTerminalPrefs = .defaults) -> TerminalConfiguration {
        let palette = effectivePalette(prefs, theme: vg.theme)
        return TerminalConfiguration { b in
            b.withBackground(effectiveColorHex(prefs.background, fallback: vg.termBG))
            b.withForeground(effectiveColorHex(prefs.foreground, fallback: vg.termFG))
            b.withCursorColor(effectiveColorHex(prefs.cursorColor, fallback: vg.termCaret))
            for (i, c) in palette.enumerated() { b.withPalette(i, color: c) }
            for family in effectiveFontChain(prefs) { b.withFontFamily(family) }
            b.withFontSize(Float(effectiveFontSize(prefs)))
            b.withCustom("cursor-style", effectiveCursorStyle(prefs))
            let pad = String(effectivePadding(prefs))
            b.withCustom("window-padding-x", pad)
            b.withCustom("window-padding-y", pad)
            // Red line: Vigil's global ⌘ shortcuts must be able to pass through a
            // focused terminal and reach the menu. keyIsBinding runs first inside
            // performKeyEquivalent — if ghostty treats some ⌘ combo as its own binding it
            // swallows the key before the menu. Here we unbind ghostty's colliding defaults
            // one by one, handing the combos back to Vigil's menu (VigilKeymap).
            //
            // CRITICAL: as of libghostty 1.2.8, ghostty's defaults are keyed by the LITERAL
            // character (unicode), NOT the W3C key name — so `super+comma`/`super+bracket_left`
            // are silent no-ops that DON'T free ⌘,/⌘⇧[ (the "pressed but nothing happens"
            // bug). We must write the literal char: `super+,`, `super+shift+[`.
            // Digits are DOUBLE-bound (goto_tab:N on both unicode `super+N` and translated
            // `super+digit_N`) and a real ⌘1 event carries both a codepoint and a keycode, so
            // both forms must be unbound to actually free ⌘1–9. Unbinding an unbound entry is a
            // safe no-op; a syntax error only logs one diagnostic. ⌘C/⌘V aren't in the table,
            // so copy/paste is unaffected.
            for combo in Self.vigilUnbinds { b.withCustom("keybind", "\(combo)=unbind") }
            // Keyboard scroll GUARANTEE: pin the scrollback-viewport scroll keys as
            // app-owned bindings instead of leaning on ghostty's compiled-in defaults, since
            // a libghostty bump can silently move a default. A ghostty scroll binding
            // CONSUMES the key — it never emits PTY bytes (⌘-combos produce zero stdin), so
            // scrolling can't corrupt a TUI. Bare Page/Home/End stay UNBOUND on purpose →
            // they pass through to the focused full-screen app (bare PageUp sends `\e[5~`
            // to the PTY), which is the alt-screen terminal convention. See vigilScrollBinds
            // for the map.
            for (trigger, action) in Self.vigilScrollBinds {
                b.withCustom("keybind", "\(trigger)=\(action)")
            }
        }
    }

    /// ghostty trigger strings that neutralise every ghostty default colliding with a Vigil ⌘
    /// shortcut — App.swift's VigilKeymap nav bindings + the ⌘,/⌘T/⌘O menu homes + ⌘1–9 (super=⌘).
    /// Forms are LITERAL characters (`super+,`, `super+shift+[`) because that is how ghostty keys
    /// its defaults; digits carry both `super+N` (unicode) and `super+digit_N` (translated). Change
    /// a shortcut = change it here too (mirror law); pinned by KeymapTests
    /// (`testGhosttyUnbinds_*` + `testUnbinds_neutralizeGhosttyDefaultCollisions`).
    static let vigilUnbinds: [String] = [
        // menu homes: ⌘, (open_config) / ⌘T (new_tab) / ⌘O (no ghostty default; kept for cover)
        "super+,", "super+t", "super+o",
        // ⌘1–9 (goto_tab / last_tab) — double-bound: unicode + translated digit key
        "super+1", "super+2", "super+3", "super+4", "super+5",
        "super+6", "super+7", "super+8", "super+9",
        "super+digit_1", "super+digit_2", "super+digit_3", "super+digit_4", "super+digit_5",
        "super+digit_6", "super+digit_7", "super+digit_8", "super+digit_9",
        // VigilKeymap nav bindings (mirror law). ⌘J = toggleBottomTerminal, ⌘B = sidebar —
        // neither is a ghostty default, so these are safe no-ops kept for the mirror.
        "super+j", "super+b",
        "super+shift+u", "super+shift+r", "super+shift+w",
        "super+shift+[", "super+shift+]",
        "ctrl+super+[", "ctrl+super+]",
    ]

    /// The guaranteed scrollback-viewport scroll map (trigger → ghostty action). App-owned
    /// so it survives a libghostty default reshuffle. Two conventions:
    ///
    ///   • mac (⌘): ⌘↑/⌘↓ = top/bottom, ⌘Home/⌘End = top/bottom, ⌘PageUp/Down = page.
    ///     ⌘Home/End/PageUp/Down MATCH ghostty's current defaults — re-declared here to PIN
    ///     them. ⌘↑/⌘↓ OVERRIDE ghostty's default (jump_to_prompt), which is dead weight in
    ///     Vigil: agents emit no OSC-133 prompt marks, so jump_to_prompt is a no-op.
    ///   • terminal (⇧): ⇧PageUp/⇧PageDown = page. ghostty leaves these unbound, so
    ///     otherwise they send `\e[5;2~`/`\e[6;2~` to the PTY instead of scrolling.
    ///
    /// Deliberately NOT bound: bare PageUp/PageDown/Home/End — they must pass through to the
    /// focused TUI (alt-screen convention). Every scroll action consumes the key (no PTY
    /// bytes), so none of these can corrupt a full-screen app. ghostty key names verified to
    /// parse with zero diagnostics + to take effect via KeymapTests (`testScrollBinds_*`).
    /// Collision-free against vigilUnbinds / VigilKeymap / menu homes (no arrow/page/home/end
    /// combo is claimed elsewhere) — pinned by `testScrollBinds_noCollisionWithClaimedCombos`.
    static let vigilScrollBinds: [(trigger: String, action: String)] = [
        ("super+up", "scroll_to_top"),
        ("super+down", "scroll_to_bottom"),
        ("super+home", "scroll_to_top"),
        ("super+end", "scroll_to_bottom"),
        ("super+page_up", "scroll_page_up"),
        ("super+page_down", "scroll_page_down"),
        ("shift+page_up", "scroll_page_up"),
        ("shift+page_down", "scroll_page_down"),
    ]

    private static func hexString(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
