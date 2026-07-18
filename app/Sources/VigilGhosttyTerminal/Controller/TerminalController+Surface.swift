//
//  TerminalController+Surface.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

extension TerminalController {
    /// Creates a new Ghostty surface with the given configuration.
    ///
    /// The `platformSetup` closure lets the caller fill in
    /// platform-specific fields (`platform_tag`, `platform`, `scale_factor`)
    /// on the raw surface config struct before the surface is created.
    func createSurface(
        bridge: TerminalCallbackBridge,
        configuration: TerminalSurfaceOptions,
        platformSetup: (inout ghostty_surface_config_s) -> Void
    ) -> ghostty_surface_t? {
        guard let app else { return nil }

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.userdata = Unmanaged.passUnretained(bridge).toOpaque()
        surfaceConfig.context = configuration.context.ghosttyValue
        configureBackend(&surfaceConfig, from: configuration)

        if let fontSize = configuration.fontSize {
            surfaceConfig.font_size = fontSize
        }

        return finalizeSurface(
            app: app,
            bridge: bridge,
            configuration: configuration,
            config: &surfaceConfig,
            workingDirectory: configuration.workingDirectory,
            platformSetup: platformSetup
        )
    }

    func retain(_ bridge: TerminalCallbackBridge) {
        retainedBridges.append(bridge)
    }

    func remove(_ bridge: TerminalCallbackBridge) {
        retainedBridges.removeAll { $0 === bridge }
    }

    var retainedBridgeCount: Int {
        retainedBridges.count
    }

    private func configureBackend(
        _ config: inout ghostty_surface_config_s,
        from options: TerminalSurfaceOptions
    ) {
        guard case let .inMemory(session) = options.backend else {
            config.backend = GHOSTTY_SURFACE_IO_BACKEND_EXEC
            return
        }

        config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        config.receive_userdata = Unmanaged.passUnretained(session).toOpaque()
        config.receive_buffer = InMemoryTerminalSession.receiveBufferCallback
        config.receive_resize = InMemoryTerminalSession.receiveResizeCallback
    }

    private func finalizeSurface(
        app: ghostty_app_t,
        bridge: TerminalCallbackBridge,
        configuration: TerminalSurfaceOptions,
        config: inout ghostty_surface_config_s,
        workingDirectory: String?,
        platformSetup: (inout ghostty_surface_config_s) -> Void
    ) -> ghostty_surface_t? {
        guard let workingDirectory else {
            return buildSurface(
                app: app,
                bridge: bridge,
                configuration: configuration,
                config: &config,
                platformSetup: platformSetup
            )
        }

        return workingDirectory.withCString { ptr in
            config.working_directory = ptr
            return buildSurface(
                app: app,
                bridge: bridge,
                configuration: configuration,
                config: &config,
                platformSetup: platformSetup
            )
        }
    }

    private func buildSurface(
        app: ghostty_app_t,
        bridge: TerminalCallbackBridge,
        configuration: TerminalSurfaceOptions,
        config: inout ghostty_surface_config_s,
        platformSetup: (inout ghostty_surface_config_s) -> Void
    ) -> ghostty_surface_t? {
        platformSetup(&config)

        // VIGIL: per-surface command + env vars. ghostty copies the config's
        // strings during surface_new, so strdup'd buffers can be freed right
        // after the call (same lifetime contract the upstream macOS app uses).
        var ownedCStrings: [UnsafeMutablePointer<CChar>] = []
        defer { ownedCStrings.forEach { free($0) } }
        func owned(_ s: String) -> UnsafePointer<CChar>? {
            guard let dup = strdup(s) else { return nil }
            ownedCStrings.append(dup)
            return UnsafePointer(dup)
        }
        if let command = configuration.command {
            config.command = owned(command)
        }
        var envArray: [ghostty_env_var_s] = configuration.envVars.map {
            ghostty_env_var_s(key: owned($0.key), value: owned($0.value))
        }
        let surface: ghostty_surface_t? = envArray.withUnsafeMutableBufferPointer { buf in
            if !buf.isEmpty {
                config.env_vars = buf.baseAddress
                config.env_var_count = buf.count
            }
            return ghostty_surface_new(app, &config)
        }
        guard let surface else {
            return nil
        }

        retain(bridge)

        if case let .inMemory(session) = configuration.backend {
            session.setSurface(surface)
        }

        return surface
    }
}
