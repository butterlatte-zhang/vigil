import XCTest
import SwiftUI
@testable import VigilApp

// Every Vigil animation
// passes through the single pure gate `VGMotion.gate(_:reduceMotion:)`; when the
// system "Reduce motion" accessibility setting is on, the gate must collapse the
// animation to `nil` (SwiftUI then applies the state change instantly). This pins
// that contract without needing the live accessibility API — the live wiring
// (`VGMotion.reduceMotionEnabled` → NSWorkspace) is a thin, source-injectable seam.
final class ReduceMotionTests: XCTestCase {

    /// Reduce Motion on → the animation is dropped (instant, no motion).
    func testReduceMotionGatesToNil() {
        XCTAssertNil(VGMotion.gate(.easeInOut(duration: 0.18), reduceMotion: true))
        XCTAssertNil(VGMotion.gate(.easeOut(duration: 0.22), reduceMotion: true))
        XCTAssertNil(VGMotion.gate(.spring(response: 0.32, dampingFraction: 0.9), reduceMotion: true))
    }

    /// Reduce Motion off → the base animation passes through unchanged (timings preserved).
    func testMotionAllowedPassesBaseThrough() {
        let ease = Animation.easeInOut(duration: 0.18)
        XCTAssertEqual(VGMotion.gate(ease, reduceMotion: false), ease)
        let spring = Animation.spring(response: 0.32, dampingFraction: 0.9)
        XCTAssertEqual(VGMotion.gate(spring, reduceMotion: false), spring)
    }

    /// A `nil` base stays `nil` on both paths — the gate never invents motion.
    func testNilBaseStaysNil() {
        XCTAssertNil(VGMotion.gate(nil, reduceMotion: false))
        XCTAssertNil(VGMotion.gate(nil, reduceMotion: true))
    }
}
