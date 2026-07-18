import Foundation
import VigilCore

// settings-v2 startup prober: which agent CLIs live on this machine, probed by VIGIL —
// never delegated to an agent, for three reasons (PLAN):
//   1. chicken-and-egg — no CLI, no settings agent to ask;
//   2. GUI PATH — a Dock-launched app never sees the shell PATH (~/.local/bin is
//      invisible), so we scan a candidate-dir table + the process PATH;
//   3. shell-function trap — the user's `claude` may be a shell function that smuggles in
//      --dangerously-skip-permissions; probing FILES sidesteps functions entirely.
// The result is written to <config>/detected.json every app start (fact, not setting —
// the settings agent reads it instead of running its own probes) and seeds the first
// agents.json / launcher.json on install (ConfigStore.ensureInstalled).

/// One probe hit. `kind` doubles as the registry key the installer seeds.
struct DetectedCLI: Equatable, Codable {
    let kind: String
    let bin: String
}

enum CLIProber {
    /// The product-decided probe order: the FIRST hit becomes the default agent (launcher.json).
    static let order: [AgentCLIKind] = [.claude, .codex, .opencode]

    /// Candidate dirs, most-specific first; the process PATH is appended so terminal
    /// launches (swift run) still see everything the shell does. VIGIL_PROBE_DIRS
    /// (colon-separated) replaces the whole table — the deterministic test seam.
    /// `home` is a seam too (tests point it at a throwaway HOME to exercise the nvm glob).
    ///
    /// The tool-manager dir table (nvm/bun/deno/volta/npm-global, nvm GLOBBED) lives
    /// in VigilCore.ToolchainPaths — shared with GhosttyBackend.ensuredPATH so a CLI this
    /// probe detects is guaranteed resolvable by the forked child too. Don't hand-copy the
    /// table back here: a separate copy drifts out of sync and lets nvm-only machines detect
    /// codex without being able to exec it.
    static func candidateDirs(
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> [String] {
        if let s = env["VIGIL_PROBE_DIRS"] {
            return s.split(separator: ":").map(String.init)
        }
        var dirs = ToolchainPaths.candidateDirs(home: home)
        dirs += (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Scan in `order`; per CLI the first dir hit wins. Only a real executable file
    /// counts (symlinks resolved) — a directory or a dangling link is not a CLI.
    static func probe(dirs: [String]? = nil) -> [DetectedCLI] {
        let ds = dirs ?? candidateDirs()
        let fm = FileManager.default
        return order.compactMap { kind in
            for d in ds {
                let p = (d as NSString).appendingPathComponent(kind.rawValue)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue,
                      fm.isExecutableFile(atPath: p) else { continue }
                return DetectedCLI(kind: kind.rawValue, bin: p)
            }
            return nil
        }
    }

    /// Rewrite <dir>/detected.json (every start; overwrite BY DESIGN — it is probe
    /// fact, the README tells users and agents that hand-edits don't stick).
    static func writeDetected(_ found: [DetectedCLI], dir: String) {
        let notFound = order.map(\.rawValue).filter { k in !found.contains { $0.kind == k } }
        let obj: [String: Any] = [
            "probedAt": ISO8601DateFormatter().string(from: Date()),
            "found": found.map { ["kind": $0.kind, "bin": $0.bin] },
            "notFound": notFound,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath:
            (dir as NSString).appendingPathComponent("detected.json")))
    }
}
