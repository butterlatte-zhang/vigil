import Foundation

/// Codex-home cache prune. The per-node CODEX_HOME exists to isolate CONFIG
/// (config.toml/hooks.json, per-node MCP+hook sockets) and ROLLOUT ATTRIBUTION
/// (sessions/ scan = sid + transcript pointer; intra-home pollution needs filtering
/// too) — but codex also treats its home as a CACHE root: every cold start downloads
/// tens of megabytes of node-agnostic bytes (curated plugin templates, remote catalog
/// caches, logs sqlite) that the isolation then multiplies per worker.
///
/// The prune deletes EXACTLY that re-downloadable set from homes whose session is dead;
/// everything resume/afterlife reads survives byte-identical: sessions/ (the resume
/// credential), config.toml, hooks.json, the auth.json symlink (never followed — the
/// user's real credential is behind it), state/memories sqlite, history.jsonl. A pruned
/// home that later resumes just re-downloads its caches on first launch — cold-start
/// cost, zero correctness cost.
///
/// Two callers: `Orchestrator.stop()` (session death: rest harvest / close / app quit,
/// after the cells have terminated) and the AppModel startup sweep beside OrphanReaper
/// (sessions a hard-killed Vigil never stopped cleanly + pre-fix history). A session
/// held by a LIVE instance is never touched (same live.lock guard as the reaper).
public enum CodexHomePrune {

    /// The delete set, nothing else: the two cache dirs codex re-downloads wholesale,
    /// plus its rotating debug logs (`logs_<n>.sqlite` + sqlite wal/shm sidecars).
    static let cacheDirNames = ["plugins", "cache"]
    static func isLogsFile(_ name: String) -> Bool {
        name.hasPrefix("logs_") && name.contains(".sqlite")
    }

    /// Prune one codex-home. Returns bytes freed (0 = nothing there / no such home).
    @discardableResult
    public static func pruneNodeHome(_ home: String) -> Int64 {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: home) else { return 0 }
        var freed: Int64 = 0
        for name in entries where cacheDirNames.contains(name) || isLogsFile(name) {
            let path = (home as NSString).appendingPathComponent(name)
            freed += size(of: path)
            try? fm.removeItem(atPath: path)
        }
        return freed
    }

    /// Prune every per-node codex-home under `<sessionDir>/config/`. Node dirs of the
    /// other families (claude settings.json, opencode oc-plugin.js) have no codex-home
    /// and are untouched by construction.
    @discardableResult
    public static func pruneSession(dir: String) -> Int64 {
        let configRoot = (dir as NSString).appendingPathComponent("config")
        guard let nodes = try? FileManager.default.contentsOfDirectory(atPath: configRoot)
        else { return 0 }
        return nodes.reduce(Int64(0)) { sum, node in
            let home = (configRoot as NSString)
                .appendingPathComponent(node) + "/codex-home"
            return sum + pruneNodeHome(home)
        }
    }

    /// Startup sweep: prune every DEAD session under the archive root. Mirrors the
    /// OrphanReaper's guards — only dirs that are sessions (orchestration.jsonl exists),
    /// never one held by a live instance (`isLive`, injectable for tests). Runs AFTER
    /// the reap so a stray codex child is dead before its caches go.
    @discardableResult
    public static func pruneAllDead(
        root: String, now: Date = Date(),
        isLive: (String) -> Bool = { SessionLock.isLive(dir: $0) }
    ) -> Int64 {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return 0 }
        return names.map { root + "/" + $0 }
            .filter { fm.fileExists(atPath: $0 + "/orchestration.jsonl") && !isLive($0) }
            .reduce(Int64(0)) { $0 + pruneSession(dir: $1) }
    }

    /// Regular-file bytes under `path` (itself or recursive). lstat semantics: a symlink
    /// counts as 0 and is never followed — sizing must not walk out of the home.
    private static func size(of path: String) -> Int64 {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let type = attrs[.type] as? FileAttributeType else { return 0 }
        switch type {
        case .typeRegular: return (attrs[.size] as? Int64) ?? 0
        case .typeDirectory:
            guard let e = fm.enumerator(atPath: path) else { return 0 }
            var total: Int64 = 0
            while let rel = e.nextObject() as? String {
                if let a = try? fm.attributesOfItem(atPath: path + "/" + rel),
                   (a[.type] as? FileAttributeType) == .typeRegular {
                    total += (a[.size] as? Int64) ?? 0
                }
            }
            return total
        default: return 0   // symlink / fifo / device — never sized, never followed
        }
    }
}
