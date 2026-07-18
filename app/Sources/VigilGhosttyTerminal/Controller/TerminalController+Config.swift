//
//  TerminalController+Config.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

/// Keeps a live surface's palette update and its repaint nudge in one ordered operation.
///
/// In a host-driven appearance reload, relying on the app-scoped update alone can leave a
/// running surface's old framebuffer on its previous palette. The new config must reach that
/// surface before its redraw is requested — app-config, then surface-config, then refresh.
@MainActor
enum TerminalSurfaceConfigurationRefresh {
    static func apply(
        to surface: ghostty_surface_t?,
        updateConfiguration: (ghostty_surface_t) -> Void,
        requestRender: () -> Void
    ) {
        guard let surface else { return }
        updateConfiguration(surface)
        requestRender()
    }
}

/// Fans a color-scheme change out to every live surface.
///
/// A color-scheme flip (system appearance toggle, follow-system, pin) must reach surfaces
/// that back a detached/backgrounded cell, not just the one surface currently mounted in an
/// `AppTerminalView` — otherwise ghostty never emits the `CSI ?997;n` notification a TUI
/// subscribed to DEC mode 2031 (claude/opencode) is waiting on. The caller is responsible for
/// snapshotting its live bridge list into `targets` before calling `apply`: a libghostty call
/// can synchronously trigger an action callback that mutates that list, and iterating a
/// snapshot keeps this pass immune to that.
@MainActor
enum TerminalColorSchemeBroadcast {
    struct Target {
        let surface: ghostty_surface_t?
        let requestRender: () -> Void
    }

    static func apply(
        to targets: [Target],
        setColorScheme: (ghostty_surface_t) -> Void
    ) {
        for target in targets {
            TerminalSurfaceConfigurationRefresh.apply(
                to: target.surface,
                updateConfiguration: setColorScheme,
                requestRender: target.requestRender
            )
        }
    }
}

extension TerminalController {
    @discardableResult
    public func updateConfigSource(_ source: ConfigSource) -> Bool {
        guard source != configSource else { return true }

        switch Self.prepareConfig(source: source) {
        case let .success(value):
            applyPreparedConfigToRuntime(value, source: source)
            return true

        case let .failure(issue):
            lastConfigurationIssue = issue.description
            Self.reportConfigurationIssue(issue.description)
            return false
        }
    }

    func applyResolvedConfig(
        _ resolved: (source: ConfigSource, contents: String),
        willChange: (() -> Void)?,
        applyState: () -> Void = {}
    ) -> Bool {
        guard resolved.source != configSource else {
            // ObservableObject subscribers expect will-change semantics.
            willChange?()
            applyState()
            renderedConfigContents = resolved.contents
            return true
        }

        switch Self.prepareConfig(source: resolved.source) {
        case let .success(prepared):
            // Notify after validation succeeds, but before committed state
            // changes become visible through computed TerminalViewState APIs.
            willChange?()
            applyState()
            applyPreparedConfigToRuntime(prepared, source: resolved.source)
            return true

        case let .failure(issue):
            lastConfigurationIssue = issue.description
            Self.reportConfigurationIssue(issue.description)
            return false
        }
    }

    private func applyPreparedConfigToRuntime(_ prepared: PreparedConfig, source: ConfigSource) {
        let previousConfig = config
        let previousManagedConfigURL = managedConfigURL
        let nextConfig = prepared.rawValue

        if let app {
            ghostty_app_update_config(app, nextConfig)
        }

        // Snapshot before invoking libghostty: update_config may synchronously emit an action
        // callback, and callbacks must not mutate the collection currently being traversed.
        // Keep the direct per-surface update even though the app config was updated above —
        // repainting without this soft surface push leaves already-painted rows on the old
        // foreground/palette. Finally nudge a frame explicitly instead of relying solely on
        // CONFIG_CHANGE/RENDER callbacks.
        let bridges = retainedBridges
        for bridge in bridges {
            TerminalSurfaceConfigurationRefresh.apply(
                to: bridge.rawSurface,
                updateConfiguration: { surface in
                    ghostty_surface_update_config(surface, nextConfig)
                },
                requestRender: {
                    bridge.onRenderRequest?()
                }
            )
        }

        applyPreparedConfig(prepared, source: source)

        if let previousConfig {
            ghostty_config_free(previousConfig)
        }

        if let previousManagedConfigURL, previousManagedConfigURL != managedConfigURL {
            try? FileManager.default.removeItem(at: previousManagedConfigURL)
        }
    }

    func applyInitialConfig(source: ConfigSource) {
        switch Self.prepareConfig(source: source) {
        case let .success(prepared):
            applyPreparedConfig(prepared, source: source)

        case let .failure(issue):
            lastConfigurationIssue = issue.description
            Self.reportConfigurationIssue(issue.description)

            guard source != .none else { return }
            guard case let .success(fallback) = Self.prepareConfig(source: ConfigSource.none) else {
                return
            }
            applyPreparedConfig(fallback, source: .none)
        }
    }

    func createApp() {
        guard let cfg = config else { return }

        let userdata = Unmanaged.passUnretained(self).toOpaque()

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = userdata
        runtimeConfig.supports_selection_clipboard = true
        runtimeConfig.wakeup_cb = terminalControllerWakeupCallback
        runtimeConfig.action_cb = terminalControllerActionCallback
        runtimeConfig.close_surface_cb = terminalControllerCloseSurfaceCallback
        runtimeConfig.write_clipboard_cb = terminalControllerWriteClipboardCallback
        runtimeConfig.read_clipboard_cb = terminalControllerReadClipboardCallback
        runtimeConfig.confirm_read_clipboard_cb = terminalControllerConfirmReadClipboardCallback

        app = ghostty_app_new(&runtimeConfig, cfg)
    }

    private static func prepareConfig(
        source: ConfigSource
    ) -> Result<PreparedConfig, ConfigurationIssue> {
        let resolvedContents: String
        let configPath: String
        let managedConfigURL: URL?

        switch source {
        case .none:
            resolvedContents = defaultRenderedConfig
            switch writeManagedConfig(contents: resolvedContents) {
            case let .success(url):
                managedConfigURL = url
                configPath = url.path
            case let .failure(issue):
                return .failure(issue)
            }

        case let .generated(contents):
            resolvedContents = contents
            switch writeManagedConfig(contents: contents) {
            case let .success(url):
                managedConfigURL = url
                configPath = url.path
            case let .failure(issue):
                return .failure(issue)
            }

        case let .file(path):
            do {
                resolvedContents = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                return .failure(ConfigurationIssue("failed to load ghostty config template: \(error)"))
            }
            managedConfigURL = nil
            configPath = path
        }

        guard let rawValue = ghostty_config_new() else {
            if let managedConfigURL {
                try? FileManager.default.removeItem(at: managedConfigURL)
            }
            return .failure(ConfigurationIssue("ghostty_config_new returned nil"))
        }

        ghostty_config_load_file(rawValue, configPath)
        ghostty_config_finalize(rawValue)

        let diagnostics = configDiagnostics(from: rawValue)
        guard diagnostics.isEmpty else {
            ghostty_config_free(rawValue)
            if let managedConfigURL {
                try? FileManager.default.removeItem(at: managedConfigURL)
            }
            return .failure(
                ConfigurationIssue("ghostty config diagnostics: \(diagnostics.joined(separator: " | "))")
            )
        }

        return .success(
            PreparedConfig(
                rawValue: rawValue,
                managedConfigURL: managedConfigURL,
                renderedContents: resolvedContents
            )
        )
    }

    private static func writeManagedConfig(contents: String) -> Result<URL, ConfigurationIssue> {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-config-\(UUID().uuidString)")
            .appendingPathExtension("conf")

        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return .success(url)
        } catch {
            return .failure(ConfigurationIssue("failed to write generated ghostty config: \(error)"))
        }
    }

    private static func configDiagnostics(from config: ghostty_config_t) -> [String] {
        let count = ghostty_config_diagnostics_count(config)
        guard count > 0 else { return [] }

        return (0 ..< count).compactMap { index in
            let diagnostic = ghostty_config_get_diagnostic(config, index)
            guard let message = diagnostic.message else { return nil }
            return String(cString: message)
        }
    }

    private static func reportConfigurationIssue(_ message: String) {
        NSLog("GhosttyTerminal configuration issue: %@", message)
    }

    private func applyPreparedConfig(_ prepared: PreparedConfig, source: ConfigSource) {
        config = prepared.rawValue
        managedConfigURL = prepared.managedConfigURL
        renderedConfigContents = prepared.renderedContents
        configSource = source
        lastConfigurationIssue = nil
    }
}

#if DEBUG
extension TerminalController {
    /// Test-only headless config validation.
    ///
    /// Parses a raw ghostty config string through the exact prepareConfig parser path
    /// (`ghostty_config_new` → `load_file` → `finalize`) and returns its diagnostics — no
    /// app, no surface, so it runs inside a unit-test process (the surface is what XCTest
    /// can't spawn; the config parser is pure). Empty array = ghostty accepted every line.
    ///
    /// KeymapTests uses it to pin that every `vigilUnbinds` trigger string is a legal
    /// ghostty key name. This matters because `prepareConfig` rejects the WHOLE generated
    /// config on the first diagnostic (see the guard above) and falls back to defaults —
    /// so one bad key name silently drops all 21 unbinds and every ⌘ shortcut stays
    /// swallowed by the focused terminal.
    public static func diagnosticsForConfigString(_ contents: String) -> [String] {
        initializeRuntimeIfNeeded()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vigil-keymap-diag-\(UUID().uuidString)")
            .appendingPathExtension("conf")
        guard (try? contents.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            return ["failed to write temp config file"]
        }
        defer { try? FileManager.default.removeItem(at: url) }

        guard let raw = ghostty_config_new() else { return ["ghostty_config_new returned nil"] }
        defer { ghostty_config_free(raw) }
        ghostty_config_load_file(raw, url.path)
        ghostty_config_finalize(raw)
        return configDiagnostics(from: raw)
    }

    /// Test-only ground-truth probe: ask ghostty which trigger it binds to a
    /// given action, in a config built from `configContents` (empty = ghostty defaults).
    /// This is stronger than diagnostics — it reveals the ACTUAL default binding form
    /// (physical key + mods) that a `keybind = …=unbind` line must match to neutralise, and
    /// (after loading an unbind) whether the action became unbound. Returns a stable string
    /// like "physical BRACKET_LEFT super+shift" / "unicode U+0031 super" / "catch_all/none".
    public static func triggerForAction(_ action: String, configContents: String = "") -> String {
        initializeRuntimeIfNeeded()

        var url: URL?
        if !configContents.isEmpty {
            let u = FileManager.default.temporaryDirectory
                .appendingPathComponent("vigil-trig-\(UUID().uuidString)")
                .appendingPathExtension("conf")
            if (try? configContents.write(to: u, atomically: true, encoding: .utf8)) != nil { url = u }
        }
        defer { if let url { try? FileManager.default.removeItem(at: url) } }

        guard let raw = ghostty_config_new() else { return "nil-config" }
        defer { ghostty_config_free(raw) }
        if let url { ghostty_config_load_file(raw, url.path) }
        ghostty_config_finalize(raw)

        let t = action.withCString { ghostty_config_trigger(raw, $0, UInt(strlen($0))) }
        return describeTrigger(t)
    }

    private static func describeTrigger(_ t: ghostty_input_trigger_s) -> String {
        var mods: [String] = []
        let m = t.mods.rawValue
        if m & GHOSTTY_MODS_CTRL.rawValue != 0 { mods.append("ctrl") }
        if m & GHOSTTY_MODS_SUPER.rawValue != 0 { mods.append("super") }
        if m & GHOSTTY_MODS_SHIFT.rawValue != 0 { mods.append("shift") }
        if m & GHOSTTY_MODS_ALT.rawValue != 0 { mods.append("alt") }
        let modStr = mods.isEmpty ? "-" : mods.joined(separator: "+")
        switch t.tag {
        case GHOSTTY_TRIGGER_PHYSICAL:
            return "physical key=\(t.key.physical.rawValue) \(modStr)"
        case GHOSTTY_TRIGGER_UNICODE:
            return "unicode U+\(String(format: "%04X", t.key.unicode)) \(modStr)"
        case GHOSTTY_TRIGGER_CATCH_ALL:
            return "catch_all \(modStr)"
        default:
            return "none/unbound (tag=\(t.tag.rawValue)) \(modStr)"
        }
    }
}
#endif
