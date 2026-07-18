//
//  TerminalSurfaceOptions.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import GhosttyKit

public struct TerminalSurfaceOptions: Sendable {
    public var backend: TerminalSessionBackend
    public var fontSize: Float?
    public var workingDirectory: String?
    public var context: TerminalSurfaceContext
    /// VIGIL: per-surface child command (surface_config.command). nil = user shell.
    public var command: String?
    /// VIGIL: extra environment for the child (surface_config.env_vars).
    public var envVars: [String: String]
    /// ticket 7: the session-wide canonical size authority (fork seed + attach bootstrap). The
    /// coordinator's per-surface `TerminalSizePipeline` reads it to converge a freshly-built
    /// surface. Deliberately NOT part of `isEquivalent` — it is a stable shared reference, so
    /// injecting it must never look like a configuration change that rebuilds the surface.
    public var canonicalPaneSize: CanonicalPaneSize?

    public init(
        backend: TerminalSessionBackend = .exec,
        fontSize: Float? = nil,
        workingDirectory: String? = nil,
        context: TerminalSurfaceContext = .window,
        command: String? = nil,
        envVars: [String: String] = [:],
        canonicalPaneSize: CanonicalPaneSize? = nil
    ) {
        self.backend = backend
        self.fontSize = fontSize
        self.workingDirectory = workingDirectory
        self.context = context
        self.command = command
        self.envVars = envVars
        self.canonicalPaneSize = canonicalPaneSize
    }

    func isEquivalent(to other: TerminalSurfaceOptions) -> Bool {
        fontSize == other.fontSize
            && workingDirectory == other.workingDirectory
            && context == other.context
            && backend.isEquivalent(to: other.backend)
            && command == other.command
            && envVars == other.envVars
    }

    var inMemorySession: InMemoryTerminalSession? {
        guard case let .inMemory(session) = backend else { return nil }
        return session
    }
}
