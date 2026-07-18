import SwiftUI
#if os(macOS)
import AppKit
#endif

// Design system — pixel-faithful port of the UI-Design mockup (Vigil - three-tier projects + launcher) CSS tokens.
// The token values below are the authoritative source.
// Two themes (dark/light) × four accents (blue/teal/amber/purple). All views read
// the current `VGTokens` from the SwiftUI environment; switching theme/accent swaps
// the whole token set at once (the CSS `:root` / `[data-theme]` / `[data-accent]`).

enum VGTheme: String, CaseIterable, Hashable { case dark, light }
enum VGAccent: String, CaseIterable, Hashable { case blue, teal, amber, purple }

/// The stored appearance preference (appearance.json `theme`): either a
/// hard pin to one scheme, or "auto" = follow the OS live. Distinct from `VGTheme`, which is
/// always the resolved dark/light a token set is built from — the preference is what the user
/// wrote; the theme is what we render after consulting the system when the preference defers.
/// Default = `.system` (the product decision: a fresh install follows the OS and tracks
/// real-time light⇄dark switches; only an explicit "dark"/"light" pins).
enum VGThemePreference: Equatable, Hashable {
    case system              // "auto" / "system" / missing / unknown — follow the OS, live
    case pinned(VGTheme)     // "dark" / "light" — never follows the OS

    /// Tolerant parse for the loader (a config value can never break the app): only the two
    /// exact scheme names pin; nil / "auto" / "system" / anything unrecognized all resolve to
    /// follow-system — the product default AND the safe degrade for an unknown future value.
    init(configValue: String?) {
        switch configValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "dark":  self = .pinned(.dark)
        case "light": self = .pinned(.light)
        default:      self = .system
        }
    }

    /// The effective token theme. `systemIsDark` (the live OS scheme) is consulted only when
    /// the preference is `.system`; a pin ignores it.
    func resolve(systemIsDark: Bool) -> VGTheme {
        switch self {
        case .pinned(let t): return t
        case .system:        return systemIsDark ? .dark : .light
        }
    }

    /// Whether the effective theme should track the live OS scheme (drives the system-
    /// appearance observer: a pin never re-resolves on a system flip).
    var followsSystem: Bool { if case .system = self { return true } else { return false } }

    /// Native controls inherit the OS appearance in follow-system mode. Only an explicit
    /// appearance.json pin overrides SwiftUI/AppKit's color scheme.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .pinned(.dark): .dark
        case .pinned(.light): .light
        }
    }
}

// MARK: - Color helpers (mirror the CSS rgba()/hex literals exactly)

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue:  Double(hex & 0xFF) / 255.0,
                  opacity: 1.0)
    }
    /// rgba(255,255,255,a)
    static func w(_ a: Double) -> Color { Color(.sRGB, red: 1, green: 1, blue: 1, opacity: a) }
    /// rgba(0,0,0,a)
    static func k(_ a: Double) -> Color { Color(.sRGB, red: 0, green: 0, blue: 0, opacity: a) }
}

#if os(macOS)
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green:   CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue:    CGFloat(hex & 0xFF) / 255.0,
                  alpha: 1.0)
    }
}
#endif

// MARK: - Token set

struct VGTokens {
    let theme: VGTheme
    let accentName: VGAccent

    // backgrounds
    let term: Color            // center area bg          (--term)
    let panelSolid: Color      // left rail / toast bg    (--panel-solid)
    let card: Color            // launcher card           (--card)

    // hairlines / borders
    let hair: Color            // (--hair)
    let hair2: Color           // (--hair-2)

    // text
    let text: Color            // (--text)
    let text2: Color           // (--text-2)
    let text3: Color           // (--text-3)

    // node
    let nodeLine: Color        // tree connector lines (= hair-2)
    let spinring: Color        // subagent spinner base ring (--spinring)

    // semantic
    let green: Color
    let red: Color
    let warn: Color
    let accent: Color

    // shadows (window-level --shadow color; CSS `rgba(0,0,0,.5)`)
    let shadowColor: Color
    // card-level --shadow-sm (`0 6px 18px rgba(0,0,0,.36)`)
    let shadowSmColor: Color
    let shadowSmRadius: CGFloat
    let shadowSmY: CGFloat

    // terminal native colors
    #if os(macOS)
    let termBG: NSColor
    let termFG: NSColor
    let termCaret: NSColor
    #endif

    // Hover/selected row washes — the design's --hov5..10
    // family (SPEC §0: text.opacity(.05–.10) suffices). The tiers keep their
    // original values: the 0.05/0.06/0.07/0.09
    // values are distinct (SPEC row generic hov5 / row hov6 / icon button hov7).
    var hoverBGSoft: Color { text.opacity(0.05) }    // hov5 — pinned rows (new chat / search)
    var hoverBG: Color { text.opacity(0.06) }        // hov6 — project/session rows, selector chip
    var hoverBGStrong: Color { text.opacity(0.07) }  // hov7 — icon buttons, tree-panel row hover
    var selectedBG: Color { text.opacity(0.09) }     // hov9 — tree-panel row selected

    // Thin scroller knob (VGThinScroller). Secondary grey at low opacity — no
    // track, right-aligned capsule. Color = the SAME token the sidebar session row paints
    // when selected/focused (`hoverBG`, hov6 = text.opacity(.06) — SessionRow focused pill,
    // SidebarView), NOT a hand-picked grey.
    // Hover bumps to `selectedBG` (hov9) so the widened grab bar reads on the same palette.
    // Both are converted to NSColor for `drawKnob`; the underlying token is single-sourced.
    #if os(macOS)
    var scrollerKnob: NSColor { NSColor(hoverBG) }
    var scrollerKnobHover: NSColor { NSColor(selectedBG) }
    #endif

    static func make(_ theme: VGTheme, _ accent: VGAccent) -> VGTokens {
        // Accent variants (SPEC §0.3): blue/teal/purple split by theme, amber single value.
        let accentHex: UInt32 = {
            switch (theme, accent) {
            case (.dark, .blue):   return 0x0A84FF
            case (.dark, .teal):   return 0x2BC4B0
            case (.dark, .amber):  return 0xFF9F0A
            case (.dark, .purple): return 0xBF5AF2
            case (.light, .blue):  return 0x007AFF
            case (.light, .teal):  return 0x0FA594
            case (.light, .amber): return 0xFF9F0A
            case (.light, .purple):return 0x9D4EDD
            }
        }()

        if theme == .dark {
            return VGTokens(
                theme: .dark, accentName: accent,
                term: Color(hex: 0x161719),
                panelSolid: Color(hex: 0x202126),
                card: Color(hex: 0x26272c),
                hair: .w(0.085), hair2: .w(0.15),
                text: .w(0.93), text2: .w(0.56), text3: .w(0.32),
                nodeLine: .w(0.15),                           // nodeLine = hair-2
                spinring: .w(0.18),
                green: Color(hex: 0x30D158), red: Color(hex: 0xFF453A), warn: Color(hex: 0xFF9F0A),
                accent: Color(hex: accentHex),
                shadowColor: .k(0.5),                                       // rgba(0,0,0,.5)
                shadowSmColor: .k(0.36), shadowSmRadius: 9, shadowSmY: 6,   // 0 6px 18px rgba(0,0,0,.36)
                termBG: NSColor(hex: 0x161719),
                termFG: NSColor(white: 0.93, alpha: 1),       // ≈ text rgba(255,255,255,.93)
                termCaret: NSColor(hex: accentHex)
            )
        } else {
            return VGTokens(
                theme: .light, accentName: accent,
                term: Color(hex: 0xFBFBFD),
                panelSolid: Color(hex: 0xF4F4F6),
                card: Color(hex: 0xFFFFFF),
                hair: .k(0.1), hair2: .k(0.15),
                text: .k(0.88), text2: .k(0.5), text3: .k(0.3),
                nodeLine: .k(0.15),                           // nodeLine = hair-2
                spinring: .k(0.165),
                green: Color(hex: 0x28C840), red: Color(hex: 0xFF3B30), warn: Color(hex: 0xE8890C),
                accent: Color(hex: accentHex),
                shadowColor: .k(0.16),                                      // rgba(0,0,0,.16)
                shadowSmColor: .k(0.1), shadowSmRadius: 8, shadowSmY: 5,    // 0 5px 16px rgba(0,0,0,.1)
                termBG: NSColor(hex: 0xFBFBFD),
                termFG: NSColor(white: 0.12, alpha: 1),       // ≈ text rgba(0,0,0,.88)
                termCaret: NSColor(hex: accentHex)
            )
        }
    }

}

// MARK: - Layout

enum VGLayout {
    /// The top-right overlay column's one width (tree panel / history tree / notif
    /// cards / the column itself — SPEC §1 top-right overlay column 322pt).
    static let overlayWidth: CGFloat = 322
}

extension View {
    /// The 322pt top-right overlay card chrome (SPEC §1): inner padding →
    /// fixed width (→ optional minHeight) → card bg r16 → hair stroke → shadow-sm.
    /// Shared by TreePanel and HistoryTreePanel; AX identity stays at the call sites.
    func vgOverlayCard(_ vg: VGTokens, minHeight: CGFloat? = nil) -> some View {
        padding(EdgeInsets(top: 12, leading: 12, bottom: 8, trailing: 12))
            .frame(width: VGLayout.overlayWidth)
            .frame(minHeight: minHeight, alignment: .top)
            .background(vg.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(vg.hair, lineWidth: 1))
            .shadow(color: vg.shadowSmColor, radius: vg.shadowSmRadius, y: vg.shadowSmY)
    }
}

// MARK: - Thin overlay scrollers

extension View {
    /// Install Vigil's thin scroller on the enclosing SwiftUI `ScrollView`'s
    /// backing `NSScrollView`: a ~3pt rounded capsule knob pinned to the right edge, **no
    /// track**, secondary-grey at low opacity, that fades in on scroll + auto-hides when idle
    /// and widens slightly on hover for easier dragging.
    ///
    /// Why not just `.scrollIndicators`: that modifier is only advisory, and even AppKit's own
    /// `.overlay` scroller style still paints the *system* knob — visibly
    /// fatter and darker than the target design. So we walk up
    /// to the `NSScrollView` (SwiftUI-Introspect technique, inlined, zero dependency), force
    /// `.overlay` style (overrides the "Always show scroll bars" pref → still auto-fades), and
    /// swap in `VGThinScroller`, which draws the thin capsule and suppresses the track.
    /// Pair with `.scrollIndicators(.automatic)` so the indicator is allowed to show on scroll.
    func vgNativeOverlayScrollers() -> some View {
        #if os(macOS)
        background(NativeOverlayScrollers())
        #else
        self
        #endif
    }
}

#if os(macOS)
/// Pure geometry for the thin knob — no AppKit state, unit-tested (ScrollerGeomTests).
enum VGScrollerGeom {
    static let knobWidth: CGFloat = 2          // resting capsule width
    static let knobWidthHover: CGFloat = 3.5   // widen on hover for an easier grab
    static let rightMargin: CGFloat = 3        // gap from the scroll view's right edge
    static let vInset: CGFloat = 2             // trim top/bottom so the capsule isn't edge-to-edge

    static func width(hovering: Bool) -> CGFloat { hovering ? knobWidthHover : knobWidth }
    /// Full capsule: corner radius = half the width.
    static func cornerRadius(hovering: Bool) -> CGFloat { width(hovering: hovering) / 2 }

    /// Given AppKit's proportional knob rect (its position/length within the track) and the
    /// scroller bounds, return the thin right-aligned capsule we actually paint. We keep
    /// AppKit's vertical position/length and override only x/width so the knob stays a hairline.
    static func thinKnobRect(from knobRect: CGRect, in bounds: CGRect, hovering: Bool) -> CGRect {
        let w = width(hovering: hovering)
        let x = bounds.maxX - w - rightMargin
        let y = knobRect.minY + vInset
        let h = max(knobRect.height - vInset * 2, w)   // never shorter than a dot
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// `NSScroller` that paints the thin capsule and suppresses the track. The enclosing
/// `NSScrollView` still owns fade-in/auto-hide (overlay style) — we only override drawing +
/// a hover flag. We deliberately do NOT shrink `scrollerWidth`: keeping the scroller view its
/// natural width preserves a generous drag/hit zone, while `drawKnob` makes
/// the *visible* bar a hairline.
final class VGThinScroller: NSScroller {
    private var hovering = false
    private(set) var knobColor: NSColor = NSColor(white: 1, alpha: 0.06)
    private(set) var knobColorHover: NSColor = NSColor(white: 1, alpha: 0.09)

    func setColors(_ knob: NSColor, _ hover: NSColor) {
        guard knob != knobColor || hover != knobColorHover else { return }
        knobColor = knob; knobColorHover = hover
        needsDisplay = true
    }

    // No track — only the bare knob shows (kills the slot/expanded-track background).
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let r = VGScrollerGeom.thinKnobRect(from: rect(for: .knob), in: bounds, hovering: hovering)
        guard r.width > 0, r.height > 0 else { return }
        let radius = VGScrollerGeom.cornerRadius(hovering: hovering)
        (hovering ? knobColorHover : knobColor).setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
}

/// Zero-size probe placed in a ScrollView's background; on mount/layout/theme-change it walks
/// up to the first enclosing `NSScrollView` and installs the thin overlay scroller.
private struct NativeOverlayScrollers: NSViewRepresentable {
    @Environment(\.vg) private var vg
    func makeNSView(context: Context) -> NSView { ScrollerStyleProbe() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScrollerStyleProbe)?.apply(knob: vg.scrollerKnob, hover: vg.scrollerKnobHover)
    }
}

private final class ScrollerStyleProbe: NSView {
    private var knob = NSColor(white: 1, alpha: 0.06)
    private var hover = NSColor(white: 1, alpha: 0.09)
    private weak var styled: NSScrollView?          // the scroll view we currently own
    private var scrollerObs: NSObjectProtocol?      // fires if SwiftUI swaps the scroller back

    // Reapply on every hierarchy move: the enclosing NSScrollView often isn't installed yet
    // when the probe first mounts, so a single walk misses it and the fat legacy system scroller
    // sticks. Retry until attached. A full
    // SwiftUI subtree rebuild recreates this probe, so these callbacks also re-attach after a
    // rebuild or a host-window change; the KVO guard below catches a scroller swap on the SAME
    // scroll view. Together they cover late-appearance + rebuild + re-host without polling.
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleReapply() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleReapply() }
    func apply(knob: NSColor, hover: NSColor) { self.knob = knob; self.hover = hover; scheduleReapply() }

    /// Try to attach now; if the scroll view isn't in the tree yet, retry next runloop
    /// (bounded — the hierarchy settles within a few passes) so no instance is ever left
    /// on the system scroller. Colors are cheap to re-set, so a successful pass also refreshes
    /// them on theme change.
    private func scheduleReapply(_ attempt: Int = 0) {
        if reapply() || attempt >= 10 { return }
        DispatchQueue.main.async { [weak self] in self?.scheduleReapply(attempt + 1) }
    }

    @discardableResult
    private func reapply() -> Bool {
        guard let scroll = ScrollViewLocator.backgroundScrollView(from: self) else { return false }
        install(on: scroll)
        if scroll !== styled { observe(scroll) }   // (re)arm the rebuild guard on a new target
        return true
    }

    /// Idempotent: force overlay style + our thin scroller + current theme colors. Safe to call
    /// repeatedly (it only builds a new VGThinScroller when the current one isn't ours).
    private func install(on scroll: NSScrollView) {
        scroll.scrollerStyle = .overlay        // auto-fading knob, overrides "Always" pref
        scroll.autohidesScrollers = true       // fade out when idle
        scroll.hasHorizontalScroller = false   // vertical-only
        scroll.hasVerticalScroller = true
        if !(scroll.verticalScroller is VGThinScroller) {
            let s = VGThinScroller()
            s.scrollerStyle = .overlay
            scroll.verticalScroller = s
        }
        (scroll.verticalScroller as? VGThinScroller)?.setColors(knob, hover)
    }

    /// Rebuild immunity for the case a full-subtree rebuild does NOT cover: SwiftUI reconfiguring
    /// the SAME NSScrollView and resetting `verticalScroller` to a system scroller. ObjC KVO on
    /// the property (event-driven, no polling) re-installs our thin scroller when that happens.
    private func observe(_ scroll: NSScrollView) {
        if let old = scrollerObs { NotificationCenter.default.removeObserver(old) }
        scrollerObs = nil
        styled?.removeObserver(self, forKeyPath: "verticalScroller")
        styled = scroll
        scroll.addObserver(self, forKeyPath: "verticalScroller", options: [.new], context: nil)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard keyPath == "verticalScroller", let scroll = object as? NSScrollView else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        if !(scroll.verticalScroller is VGThinScroller) { install(on: scroll) }
    }

    deinit { styled?.removeObserver(self, forKeyPath: "verticalScroller") }
}

/// Locates the `NSScrollView` that a SwiftUI `.background`-hosted probe belongs to. Pulled out of
/// the probe (and made internal) so the traversal is unit-testable without a live window.
enum ScrollViewLocator {
    /// SwiftUI hosts `content.background(probe)` with the scroll view and the probe as **siblings**
    /// under a shared container. So at each level we search that level's subtree DOWNWARD for the
    /// nearest scroll view BEFORE ascending. A naive ancestor-first walk breaks the nested case:
    /// when this scroll view lives inside another ScrollView (OverlayColumn → tree/history card),
    /// the OUTER scroll view is a genuine ANCESTOR of the probe, so ancestor-first grabs it and
    /// styles the outer bar twice while the card's own inner bar keeps the fat legacy scroller.
    /// Sibling-first (downward-at-each-level) always returns the innermost owning scroll view; an
    /// ancestor is only reached as a last resort when nothing sits below any level.
    static func backgroundScrollView(from probe: NSView) -> NSScrollView? {
        var node: NSView? = probe
        while let cur = node {
            if let parent = cur.superview,
               let s = firstScrollView(under: parent, excluding: probe) { return s }
            node = cur.superview
        }
        return nil
    }

    /// Depth-first, checking a subview as a scroll view BEFORE recursing into it — so a shallower
    /// (outer) scroll view is returned before any deeper one nested inside it.
    static func firstScrollView(under view: NSView, excluding: NSView) -> NSScrollView? {
        for sub in view.subviews {
            if sub === excluding { continue }
            if let s = sub as? NSScrollView { return s }
            if let s = firstScrollView(under: sub, excluding: excluding) { return s }
        }
        return nil
    }
}
#endif

// MARK: - Motion (quantized frame-by-frame from a screen recording)

enum VGMotion {
    /// Live system Reduce-Motion flag (System Settings ▸ Accessibility ▸ Display ▸
    /// "Reduce motion"). Read fresh at every call so toggling the setting takes effect
    /// immediately — no app restart (the value is re-evaluated each time an animation
    /// is about to run).
    static var reduceMotionEnabled: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        false
        #endif
    }

    /// The single gate every Vigil animation passes through. Pure and source-injectable
    /// so it is unit-testable without the accessibility API (Keymap/Motion tests):
    /// Reduce Motion → `nil` (SwiftUI applies the state change with no animation),
    /// otherwise the base animation passes through unchanged. Collecting one gate is
    /// what keeps the respect uniform — no per-site opt-in to forget.
    static func gate(_ base: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : base
    }

    /// Live convenience over `gate(_:reduceMotion:)` — reads the current system flag.
    /// Wrap every ad-hoc `.animation(...)` / `withAnimation(...)` literal in this.
    static func gated(_ base: Animation?) -> Animation? {
        gate(base, reduceMotion: reduceMotionEnabled)
    }

    /// Sidebar collapse/expand: whole rail translates + content follows; measured ~310ms, quick out with a long soft tail, no overshoot. Gated.
    static var sidebar: Animation? { gated(.spring(response: 0.32, dampingFraction: 0.9)) }
    /// Top-right card (node-tree panel) open/close: fade in + 14px slide from the right, ~220ms (= design mock vg-card). Gated.
    static var panel: Animation? { gated(.easeOut(duration: 0.22)) }
}

/// vg-card transition: opacity 0→1 + translateX(14→0) (SwiftUI version of dc.html's @keyframes vg-card).
struct VGCardTransition: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
        content.opacity(hidden ? 0 : 1).offset(x: hidden ? 14 : 0)
    }
}

extension AnyTransition {
    static let vgCard = AnyTransition.modifier(
        active: VGCardTransition(hidden: true),
        identity: VGCardTransition(hidden: false))
}

// MARK: - Fonts

enum VGFont {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        #if os(macOS)
        Font(NSFont.monospacedSystemFont(ofSize: size, weight: weight.nsFontWeight))
        #else
        .system(size: size, weight: weight, design: .monospaced)
        #endif
    }
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

#if os(macOS)
private extension Font.Weight {
    var nsFontWeight: NSFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}
#endif

// MARK: - Environment

private struct VGTokensKey: EnvironmentKey {
    static let defaultValue = VGTokens.make(.dark, .blue)
}
extension EnvironmentValues {
    var vg: VGTokens {
        get { self[VGTokensKey.self] }
        set { self[VGTokensKey.self] = newValue }
    }
}
