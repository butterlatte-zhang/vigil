import XCTest
import AppKit
import SwiftUI
@testable import VigilApp

// Thin Codex-style scroller: the knob is a right-aligned rounded capsule (2pt, 3.5pt on
// hover), no track. VGScrollerGeom holds the pure geometry so the width/corner-radius/rect
// math is pinned without needing a live NSScroller.
final class ScrollerGeomTests: XCTestCase {

    func testRestingAndHoverWidth() {
        XCTAssertEqual(VGScrollerGeom.width(hovering: false), 2, accuracy: 0.001)
        XCTAssertEqual(VGScrollerGeom.width(hovering: true), 3.5, accuracy: 0.001)
        XCTAssertGreaterThan(VGScrollerGeom.width(hovering: true),
                             VGScrollerGeom.width(hovering: false),
                             "hover must widen the knob for an easier grab")
    }

    func testCornerRadiusIsFullCapsule() {
        // radius = width/2 → the ends are perfect semicircles (a capsule, not a rounded rect).
        XCTAssertEqual(VGScrollerGeom.cornerRadius(hovering: false),
                       VGScrollerGeom.width(hovering: false) / 2, accuracy: 0.001)
        XCTAssertEqual(VGScrollerGeom.cornerRadius(hovering: true),
                       VGScrollerGeom.width(hovering: true) / 2, accuracy: 0.001)
    }

    func testKnobRectIsRightAlignedAndThin() {
        let bounds = CGRect(x: 0, y: 0, width: 15, height: 400)   // a natural-width scroller
        let appleKnob = CGRect(x: 0, y: 100, width: 15, height: 120) // AppKit's proportional knob
        let r = VGScrollerGeom.thinKnobRect(from: appleKnob, in: bounds, hovering: false)

        XCTAssertEqual(r.width, 2, accuracy: 0.001, "resting knob is a 2pt hairline (2/3 of the old 3pt)")
        // right-aligned: sits rightMargin (3) in from the right edge.
        XCTAssertEqual(r.maxX, bounds.maxX - VGScrollerGeom.rightMargin, accuracy: 0.001)
        // vertical position/length inherited from AppKit, trimmed by vInset top+bottom.
        XCTAssertEqual(r.minY, appleKnob.minY + VGScrollerGeom.vInset, accuracy: 0.001)
        XCTAssertEqual(r.height, appleKnob.height - VGScrollerGeom.vInset * 2, accuracy: 0.001)
    }

    func testHoverKnobIsWiderStillRightAligned() {
        let bounds = CGRect(x: 0, y: 0, width: 15, height: 400)
        let appleKnob = CGRect(x: 0, y: 0, width: 15, height: 200)
        let r = VGScrollerGeom.thinKnobRect(from: appleKnob, in: bounds, hovering: true)
        XCTAssertEqual(r.width, 3.5, accuracy: 0.001)
        XCTAssertEqual(r.maxX, bounds.maxX - VGScrollerGeom.rightMargin, accuracy: 0.001,
                       "widening on hover grows leftward — the right edge stays pinned")
    }

    func testKnobNeverShorterThanADot() {
        // A tiny AppKit knob (nearly zero after inset) must still be at least width tall so it
        // renders as a dot rather than collapsing to nothing.
        let bounds = CGRect(x: 0, y: 0, width: 15, height: 400)
        let tinyKnob = CGRect(x: 0, y: 50, width: 15, height: 1)
        let r = VGScrollerGeom.thinKnobRect(from: tinyKnob, in: bounds, hovering: false)
        XCTAssertGreaterThanOrEqual(r.height, VGScrollerGeom.width(hovering: false))
    }

    func testKnobColorsTrackTheme() {
        // Light theme: black at low opacity; dark theme: white at low opacity (SPEC ranges).
        let light = VGTokens.make(.light, .blue)
        let dark = VGTokens.make(.dark, .blue)
        var lw: CGFloat = 0, lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0
        light.scrollerKnob.usingColorSpace(.sRGB)?.getRed(&lr, green: &lg, blue: &lb, alpha: &lw)
        XCTAssertEqual(lr, 0, accuracy: 0.01); XCTAssertLessThan(lw, 0.5)
        var dw: CGFloat = 0, dr: CGFloat = 0, dg: CGFloat = 0, db: CGFloat = 0
        dark.scrollerKnob.usingColorSpace(.sRGB)?.getRed(&dr, green: &dg, blue: &db, alpha: &dw)
        XCTAssertEqual(dr, 1, accuracy: 0.01); XCTAssertLessThan(dw, 0.5)
        // hover is more prominent than resting, in both themes.
        XCTAssertGreaterThan(dark.scrollerKnobHover.alphaComponent, dark.scrollerKnob.alphaComponent)
        XCTAssertGreaterThan(light.scrollerKnobHover.alphaComponent, light.scrollerKnob.alphaComponent)
    }

    func testKnobReusesSidebarSelectedToken() {
        // The knob must be the EXACT sidebar session selected-state wash (hoverBG = hov6),
        // not a hand-picked grey, and hover = selectedBG (hov9). Pin the reuse so a future
        // token tweak can't silently drift the scroller off the sidebar.
        for theme in [VGTheme.dark, .light] {
            let t = VGTokens.make(theme, .blue)
            assertSameColor(t.scrollerKnob, NSColor(t.hoverBG),
                            "resting knob must equal the sidebar session selected wash (hoverBG)")
            assertSameColor(t.scrollerKnobHover, NSColor(t.selectedBG),
                            "hover knob must equal selectedBG (hov9)")
        }
    }

    // MARK: - ScrollViewLocator (nested tree/history card)
    //
    // The AppKit hierarchy SwiftUI builds for the nested tree/history card: the card's inner
    // ScrollView (+ its `.background` probe) live INSIDE the OverlayColumn's outer ScrollView.
    // `.background(probe)` hosts the probe as a SIBLING of the scroll view it belongs to. An
    // ancestor-first walk from the inner probe would hit the OUTER scroll view first (a genuine
    // ancestor) and leave the inner one unstyled. The locator must return the probe's SIBLING
    // scroll view, not the outer ancestor.

    func testLocatorPrefersSiblingOverAncestorWhenNested() {
        // outerScroll ▸ outerDoc ▸ innerContainer ▸ { innerScroll, probe }
        let outerScroll = NSScrollView()
        let outerDoc = NSView()
        let innerContainer = NSView()
        let innerScroll = NSScrollView()
        let probe = NSView()
        outerScroll.documentView = outerDoc
        outerDoc.addSubview(innerContainer)
        innerContainer.addSubview(innerScroll)   // the card's own bar — what we MUST style
        innerContainer.addSubview(probe)          // `.background` sibling of innerScroll

        let found = ScrollViewLocator.backgroundScrollView(from: probe)
        XCTAssertTrue(found === innerScroll,
                      "nested probe must style its SIBLING inner scroll view, not the outer ancestor")
        XCTAssertFalse(found === outerScroll,
                       "the outer OverlayColumn scroll view is an ancestor and must NOT be grabbed")
    }

    func testOuterProbeStillGrabsOuterNotNestedInner() {
        // The OverlayColumn's OWN probe is a sibling of the outer scroll view, which itself
        // contains the inner card scroll view. It must style the OUTER (shallower) one — the
        // check-before-recurse order guarantees a direct-child scroll view wins over a deeper one.
        let container = NSView()
        let outerScroll = NSScrollView()
        let outerProbe = NSView()
        let outerDoc = NSView()
        let innerScroll = NSScrollView()
        container.addSubview(outerScroll)
        container.addSubview(outerProbe)
        outerScroll.documentView = outerDoc
        outerDoc.addSubview(innerScroll)
        XCTAssertTrue(ScrollViewLocator.backgroundScrollView(from: outerProbe) === outerScroll,
                      "outer probe must style the outer bar, not the nested inner one")
    }

    func testLocatorFindsSiblingInSimpleCase() {
        // The non-nested case (sidebar / transcript / center): container ▸ { scroll, probe }.
        let container = NSView()
        let scroll = NSScrollView()
        let probe = NSView()
        container.addSubview(scroll)
        container.addSubview(probe)
        XCTAssertTrue(ScrollViewLocator.backgroundScrollView(from: probe) === scroll)
    }

    func testLocatorWalksUpWhenProbeIsNestedDeeper() {
        // SwiftUI sometimes wraps the probe in an extra layout container; the scroll view is then
        // a sibling one level up. The locator must ascend until a level's subtree contains it.
        let container = NSView()
        let scroll = NSScrollView()
        let wrapper = NSView()
        let probe = NSView()
        container.addSubview(scroll)
        container.addSubview(wrapper)
        wrapper.addSubview(probe)
        XCTAssertTrue(ScrollViewLocator.backgroundScrollView(from: probe) === scroll)
    }

    func testLocatorReturnsNilWhenNoScrollView() {
        let container = NSView(); let probe = NSView(); container.addSubview(probe)
        XCTAssertNil(ScrollViewLocator.backgroundScrollView(from: probe))
    }

    private func assertSameColor(_ a: NSColor, _ b: NSColor, _ msg: String) {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.usingColorSpace(.sRGB)?.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.usingColorSpace(.sRGB)?.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        XCTAssertEqual(ar, br, accuracy: 0.001, msg)
        XCTAssertEqual(ag, bg, accuracy: 0.001, msg)
        XCTAssertEqual(ab, bb, accuracy: 0.001, msg)
        XCTAssertEqual(aa, ba, accuracy: 0.001, msg)
    }
}
