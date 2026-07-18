import Foundation

// Detection (VigilApp/CLIProber.candidateDirs) and execution (VigilRuntime/
// GhosttyBackend.ensuredPATH) must share one tool-dir list — if they drift, a
// Dock-launched app can detect a CLI under nvm/bun/etc. yet fail to EXEC it, because
// the child-process PATH never gets the same entries. For example, if CLIProber finds
// codex under ~/.nvm/versions/node/<v>/bin but ensuredPATH's table doesn't have that
// glob, the forked child's `#!/usr/bin/env node` shebang resolves to nothing and codex
// dies instantly with "node: No such file or directory". One shared table in VigilCore
// (the lowest layer both VigilApp and VigilRuntime depend on — see Package.swift's
// layering comment) makes that drift structurally impossible instead of a thing to
// remember to keep in sync.
public enum ToolchainPaths {
    /// Tool-manager bin dirs common on macOS dev machines, most-specific first. nvm's
    /// node versions are GLOBBED — never hardcode a version or a home path here.
    public static func candidateDirs(home: String, fm: FileManager = .default) -> [String] {
        var dirs = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                    home + "/.npm-global/bin", home + "/.bun/bin", home + "/bin",
                    home + "/.deno/bin", home + "/.volta/bin"]
        dirs += nvmBinDirs(home: home, fm: fm)
        return dirs
    }

    /// ~/.nvm/versions/node/<version>/bin for EVERY installed version — dynamically
    /// enumerated, never hardcoded.
    public static func nvmBinDirs(home: String, fm: FileManager = .default) -> [String] {
        let base = home + "/.nvm/versions/node"
        guard let versions = try? fm.contentsOfDirectory(atPath: base) else { return [] }
        return versions.sorted().map { base + "/" + $0 + "/bin" }
    }
}
