import AppKit
import Observation
import SwiftUI
import XCTest
@testable import VigilApp
@testable import VigilCore
@testable import VigilGhosttyTerminal
@testable import VigilRuntime

/// Regression coverage for the single live appearance source shared by SwiftUI, ghostty, and
/// dark-screen OSC 10/11 replies. Kept separate from ConfigTests because these assertions are
/// about the render transaction, not file-watcher behavior.
@MainActor
final class TerminalAppearanceSyncTests: XCTestCase {
    @Observable
    final class TopBarAppearanceDriver {
        var theme: VGTheme

        init(theme: VGTheme) { self.theme = theme }
    }

    private struct LiveTopBarFixture: View {
        let app: AppModel
        @Bindable var appearance: TopBarAppearanceDriver

        var body: some View {
            let vg = VGTokens.make(appearance.theme, .blue)
            TopBar(app: app)
                .environment(\.vg, vg)
                .background(vg.term)
        }
    }

    private final class FakeAppearanceSource: SystemAppearanceSource {
        var isDark: Bool {
            didSet { if isDark != oldValue { onChange?() } }
        }
        var onChange: (() -> Void)?

        init(isDark: Bool) { self.isDark = isDark }
    }

    private func makeApp(isDark: Bool = true) -> (AppModel, FakeAppearanceSource, String) {
        let appearance = FakeAppearanceSource(isDark: isDark)
        let dir = NSTemporaryDirectory()
            + "vigil-terminal-appearance-\(UUID().uuidString.prefix(8))"
        let app = AppModel(configStore: ConfigStore(dir: dir), appearanceSource: appearance)
        return (app, appearance, dir)
    }

    func testFollowSystemFlipUpdatesSharedTerminalColorSourceExactly() {
        let (app, appearance, dir) = makeApp(isDark: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let unpublished = app.terminalColorSource.snapshot()
        XCTAssertNil(unpublished.fg)
        XCTAssertNil(unpublished.bg)
        app.applyConfig(.defaults)

        var replies: [Data] = []
        let responder = OscColorQueryResponder(
            colorSource: app.terminalColorSource,
            respond: { replies.append($0) })

        var colors = app.terminalColorSource.snapshot()
        XCTAssertEqual(app.terminalColorSource.terminalThemeSnapshot(), "dark")
        XCTAssertEqual(colors.fg, "rgb:eded/eded/eded")
        XCTAssertEqual(colors.bg, "rgb:1616/1717/1919")
        responder.feed(Data("\u{1B}]10;?\u{07}".utf8), surfaceDidReceive: false)
        responder.feed(Data("\u{1B}]11;?\u{07}".utf8), surfaceDidReceive: false)

        appearance.isDark = false

        colors = app.terminalColorSource.snapshot()
        XCTAssertEqual(app.theme, .light)
        XCTAssertEqual(app.terminalColorSource.terminalThemeSnapshot(), "light")
        XCTAssertEqual(colors.fg, "rgb:1f1f/1f1f/1f1f")
        XCTAssertEqual(colors.bg, "rgb:fbfb/fbfb/fdfd")
        responder.feed(Data("\u{1B}]10;?\u{07}".utf8), surfaceDidReceive: false)
        responder.feed(Data("\u{1B}]11;?\u{07}".utf8), surfaceDidReceive: false)

        XCTAssertEqual(replies, [
            Data("\u{1B}]10;rgb:eded/eded/eded\u{07}".utf8),
            Data("\u{1B}]11;rgb:1616/1717/1919\u{07}".utf8),
            Data("\u{1B}]10;rgb:1f1f/1f1f/1f1f\u{07}".utf8),
            Data("\u{1B}]11;rgb:fbfb/fbfb/fdfd\u{07}".utf8),
        ])
    }

    func testTerminalColorOverridesUpdateSurfaceConfigAndSharedSourceTogether() {
        let (app, _, dir) = makeApp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var config = VigilConfig.defaults
        config.themePreference = .pinned(.light)
        config.terminal.foreground = "#123456"
        config.terminal.background = "#ABCDEF"

        app.applyConfig(config)

        let colors = app.terminalColorSource.snapshot()
        XCTAssertEqual(colors.fg, "rgb:1212/3434/5656")
        XCTAssertEqual(colors.bg, "rgb:abab/cdcd/efef")
        XCTAssertTrue(TerminalController.shared.renderedConfig.contains("foreground = #123456"))
        XCTAssertTrue(TerminalController.shared.renderedConfig.contains("background = #abcdef"))
    }

    func testAppModelAutoPolicyForwardsThroughDispatchIntoClaudeSettings() throws {
        XCTAssertEqual(AppModel.agentTerminalTheme, "auto")

        let dir = NSTemporaryDirectory()
            + "vigil-terminal-theme-auto-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let harness = DispatchHarness(
            claudeBin: "/bin/true", codexBin: "/bin/true", opencodeBin: "/bin/true",
            hookBin: "/bin/true", mcpBin: "/bin/true", configRoot: dir,
            terminalTheme: AppModel.agentTerminalTheme)
        let spec = harness.launchSpec(
            task: "test", cwd: "/tmp", nodeID: NodeID("root"), role: .manager,
            isRoot: true, mcpEndpoint: "/tmp/mcp.sock", hookEndpoint: "/tmp/hook.sock",
            idCred: "root")
        let settingsFlag = try XCTUnwrap(spec.args.firstIndex(of: "--settings"))
        let settingsPath = spec.args[settingsFlag + 1]
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["theme"] as? String, "auto")
    }

    func testPinnedThemeIgnoresSystemFlipsForLaterClaudeLaunches() {
        let (app, appearance, dir) = makeApp(isDark: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var config = VigilConfig.defaults
        config.themePreference = .pinned(.light)
        app.applyConfig(config)
        XCTAssertEqual(app.terminalColorSource.terminalThemeSnapshot(), "light")

        appearance.isDark = false
        appearance.isDark = true
        XCTAssertEqual(app.theme, .light)
        XCTAssertEqual(app.terminalColorSource.terminalThemeSnapshot(), "light")
    }

    func testRepeatedFollowSystemFlipsConvergeEveryAppearanceLayer() {
        let (app, appearance, dir) = makeApp(isDark: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        app.applyConfig(.defaults)

        for index in 0..<20 {
            let isDark = !index.isMultiple(of: 2)
            appearance.isDark = isDark

            XCTAssertEqual(app.theme, isDark ? .dark : .light)
            XCTAssertEqual(app.terminalColorSource.terminalThemeSnapshot(),
                           isDark ? "dark" : "light")
            XCTAssertEqual(TerminalController.shared.effectiveColorScheme,
                           isDark ? .dark : .light)
            XCTAssertTrue(TerminalController.shared.renderedConfig.contains(
                isDark ? "background = #161719" : "background = #fbfbfd"))
        }
    }

    func testHexConversionIsExactAndRejectsFullwidthUnicodeDigits() {
        XCTAssertEqual(VGGhosttyTheme.oscColorSpec(hex: "#123456"),
                       "rgb:1212/3434/5656")
        XCTAssertEqual(VGGhosttyTheme.oscColorSpec(hex: "abcdef"),
                       "rgb:abab/cdcd/efef")

        let fullwidth = "#１２３４５６"
        let fallback = NSColor(hex: 0x161719)
        XCTAssertFalse(VGGhosttyTheme.isHexColor(fullwidth))
        XCTAssertEqual(VGGhosttyTheme.effectiveColorHex(fullwidth, fallback: fallback),
                       "#161719")
        XCTAssertEqual(VGGhosttyTheme.oscColorSpec(hex: fullwidth),
                       "rgb:0000/0000/0000")
    }

    func testOnlyPinnedThemeOverridesNativeColorScheme() {
        XCTAssertNil(VGThemePreference.system.preferredColorScheme)
        XCTAssertEqual(VGThemePreference.pinned(.dark).preferredColorScheme, .dark)
        XCTAssertEqual(VGThemePreference.pinned(.light).preferredColorScheme, .light)
    }

    func testTopBarUsesRootAppearanceEnvironmentInsteadOfAStaleModelSnapshot() throws {
        let (app, _, dir) = makeApp(isDark: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        app.applyConfig(.defaults)
        XCTAssertEqual(app.theme, .dark)
        let appearance = TopBarAppearanceDriver(theme: .dark)

        let size = CGSize(width: 320, height: 50)
        let host = NSHostingView(rootView: LiveTopBarFixture(app: app, appearance: appearance))
        host.frame = CGRect(origin: .zero, size: size)
        settle(host)

        let dark = try render(host)
        XCTAssertGreaterThan(contrastingPixelCount(in: dark, expectLight: true), 20)

        appearance.theme = .light
        XCTAssertEqual(app.theme, .dark, "the model stays dark so this only exercises root vg")
        settle(host)

        let light = try render(host)
        XCTAssertGreaterThan(contrastingPixelCount(in: light, expectLight: false), 20,
                             "the already-mounted title must become dark on the light bar")

        appearance.theme = .dark
        settle(host)
        let darkAgain = try render(host)
        XCTAssertGreaterThan(contrastingPixelCount(in: darkAgain, expectLight: true), 20,
                             "the same title must recover after a second appearance flip")
    }

    private func settle(_ view: NSView) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileReadUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func contrastingPixelCount(in rep: NSBitmapImageRep, expectLight: Bool) -> Int {
        // NSHostingView captures at the display backing scale (normally 2×). Restrict the
        // sample to the title's leading/vertical band so neither the background nor the
        // bottom divider can satisfy the contrast assertion.
        let xRange = Int(Double(rep.pixelsWide) * 0.01)..<Int(Double(rep.pixelsWide) * 0.2)
        let yRange = Int(Double(rep.pixelsHigh) * 0.2)..<Int(Double(rep.pixelsHigh) * 0.8)
        return yRange.reduce(into: 0) { total, y in
            for x in xRange {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                if expectLight ? luminance > 0.55 : luminance < 0.45 { total += 1 }
            }
        }
    }
}
