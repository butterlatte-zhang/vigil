import AppKit

// App icon: a 1024x1024 png, bundled as a
// SwiftPM resource. Installed at runtime onto NSApplication so BOTH entry shells get it
// (`swift run Vigil` and the Xcode thin shell) — a SwiftPM executable has no .app
// bundle to carry an asset-catalog icon. Finder/.app-bundle iconography belongs to the
// packaging pipeline (SPEC §3).
enum AppIcon {
    /// Lookup order is load-bearing (getting it backwards crashes a packaged .app): Bundle.main FIRST —
    /// the release .app carries the png in Contents/Resources — and Bundle.module only as
    /// the bare-`swift run` fallback. `swift build`'s generated Bundle.module accessor
    /// probes just the .app ROOT (which must stay sealed for codesign) plus the dev
    /// machine's absolute .build path, so on any other machine merely EVALUATING
    /// Bundle.module fatalErrors; it must stay unevaluated whenever main can serve.
    static func iconURL(main: Bundle = .main) -> URL? {
        main.url(forResource: "vigil-app-icon", withExtension: "png")
            ?? Bundle.module.url(forResource: "vigil-app-icon", withExtension: "png")
    }

    static func install() {
        guard let url = iconURL(), let img = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = img
    }
}
