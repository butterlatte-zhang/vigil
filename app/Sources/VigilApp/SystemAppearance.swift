import Foundation
#if os(macOS)
import AppKit
#endif

// System appearance source: the OS's current dark/light plus a change hook.
// Abstracted behind a protocol so the follow-system theme path (VGThemePreference.system) is
// deterministic in tests — a fake drives isDark instead of the whole suite depending on the
// test machine's System Settings › Appearance. Production reads NSApp.effectiveAppearance and
// observes it via KVO. RootView sets preferredColorScheme only for an explicit pin; follow-system
// leaves it nil, so the application's effective appearance remains the system input and KVO fires
// when the user flips light⇄dark (including the auto day/night schedule).

@MainActor
protocol SystemAppearanceSource: AnyObject {
    /// The OS's effective scheme right now.
    var isDark: Bool { get }
    /// Fired (on the main actor) whenever the effective scheme changes.
    var onChange: (() -> Void)? { get set }
}

#if os(macOS)
/// Static dark/light for an NSAppearance — the SAME bestMatch idiom the terminal view uses
/// (AppTerminalView+Lifecycle) so the whole app reads the OS scheme one way.
func appearanceIsDark(_ appearance: NSAppearance) -> Bool {
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
}

@MainActor
final class NSAppAppearanceSource: SystemAppearanceSource {
    var onChange: (() -> Void)?
    private var observation: NSKeyValueObservation?

    init() {
        // KVO on the shared application's effectiveAppearance: fires on every OS appearance
        // change. The handler can arrive off the main thread and with the value not yet
        // settled, so we hop to the main actor via a Task and re-read isDark there (the
        // async hop also dodges the "KVO reports the old value" timing gotcha).
        observation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.onChange?() }
        }
    }

    var isDark: Bool { appearanceIsDark(NSApplication.shared.effectiveAppearance) }

    deinit { observation?.invalidate() }
}
#else
/// Non-macOS builds have no NSApp appearance to follow — default to dark, never change.
@MainActor
final class StubAppearanceSource: SystemAppearanceSource {
    var isDark: Bool { true }
    var onChange: (() -> Void)?
}
#endif
