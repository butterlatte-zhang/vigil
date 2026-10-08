import Foundation

/// codex-home inheritance, matching claude's config posture. claude nodes overlay their
/// per-node config via CLI flags (`--settings` MERGES onto the user's own ~/.claude), so
/// the user's real defaults stay live under Vigil. codex has no such flags — its only
/// config surface is $CODEX_HOME — so the per-node home must be built by inheriting the
/// user's config rather than from zero; building from zero silently drops everything the
/// user configured in ~/.codex/config.toml (e.g. a codex subManager falling back to the
/// codex builtin default model because the user's own `model = …` never reached the
/// per-node home, with their [mcp_servers.*] and profiles lost the same way).
///
/// Fix = inherit-then-override: per-node config.toml = the user's config with ONLY the
/// Vigil-owned parts replaced. Vigil owns exactly:
///   - `approval_policy` / `sandbox_mode` — the role's permission tier. Stripped from
///     the user config WHEREVER they appear (a [profiles.*] copy would outrank a top-level
///     tier in codex's precedence), then written once, top-level, by the harness.
///   - `[projects."<cwd>"]` — the turn-zero trust pre-seed. The user's own entry for
///     the SAME cwd is dropped (it may say untrusted → trust box blocks the initial prompt);
///     every other project entry survives.
///   - `[mcp_servers.vigil]` — the per-node identity wiring; a stale user copy is dropped.
///     The user's own MCP servers survive: a node sees the same tool ecosystem the user's
///     own codex does (native-codex parity).
///
/// Deliberately NOT a TOML parser: a line-based section filter with just enough syntax
/// awareness (multi-line-string opacity, quoted header keys). It only ever REMOVES whole
/// lines/sections, never rewrites one — a config it would mis-read is one codex itself
/// rejects, and the untouched lines reach codex byte-identical.
enum CodexConfigInherit {

    /// Key names whose value Vigil owns — stripped from the user config wherever they appear.
    static let ownedKeys: Set<String> = ["approval_policy", "sandbox_mode", "check_for_update_on_startup"]

    /// Compose the per-node config.toml: Vigil's top-level keys first (they must precede any
    /// table header or they would join it), then the filtered user config, then Vigil's tables.
    static func merged(user: String?, vigilTopLevel: String, vigilTables: String,
                       projectCwd: String?) -> String {
        var out = vigilTopLevel
        if let user {
            let kept = filtered(user, projectCwd: projectCwd)
            if !kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out += "\n" + kept
                if !out.hasSuffix("\n") { out += "\n" }
            }
        }
        return out + vigilTables
    }

    /// The user's config minus the Vigil-owned lines/sections.
    static func filtered(_ toml: String, projectCwd: String?) -> String {
        var kept: [String] = []
        var openString: String?    // "\"\"\"" or "'''" while inside a multi-line string
        var keepStringBody = true  // did we keep the line that OPENED the string?
        var dropSection = false
        for sub in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(sub)
            if openString != nil {                       // string body is opaque, not structure
                if keepStringBody { kept.append(line) }
                scanStrings(line, open: &openString)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), let path = headerPath(trimmed) {
                dropSection = isOwnedTable(path, projectCwd: projectCwd)
                if !dropSection { kept.append(line) }
                continue
            }
            let keep = !dropSection && !isOwnedKeyLine(trimmed)
            if keep { kept.append(line) }
            keepStringBody = keep
            scanStrings(line, open: &openString)
        }
        return kept.joined(separator: "\n")
    }

    /// `[a.b."quoted key".'literal']` (also `[[array.of.tables]]`) → decoded path segments.
    /// nil = not a well-formed header; the caller keeps the line verbatim and drops nothing.
    static func headerPath(_ header: String) -> [String]? {
        var inner = header.dropFirst().dropLast()
        if inner.hasPrefix("["), inner.hasSuffix("]") { inner = inner.dropFirst().dropLast() }
        var segs: [String] = []
        var i = inner.startIndex
        func skipWS() {
            while i < inner.endIndex, inner[i] == " " || inner[i] == "\t" {
                i = inner.index(after: i)
            }
        }
        while true {
            skipWS()
            guard i < inner.endIndex else { return nil }        // empty header / trailing dot
            var seg = ""
            switch inner[i] {
            case "\"":                                          // basic string: \\ and \" decode
                i = inner.index(after: i)
                var closed = false
                while i < inner.endIndex {
                    let ch = inner[i]
                    if ch == "\\" {
                        let n = inner.index(after: i)
                        guard n < inner.endIndex else { return nil }
                        seg.append(inner[n]); i = inner.index(after: n)
                    } else if ch == "\"" {
                        closed = true; i = inner.index(after: i); break
                    } else {
                        seg.append(ch); i = inner.index(after: i)
                    }
                }
                guard closed else { return nil }
            case "'":                                           // literal string: verbatim
                i = inner.index(after: i)
                guard let close = inner[i...].firstIndex(of: "'") else { return nil }
                seg = String(inner[i..<close]); i = inner.index(after: close)
            default:                                            // bare key
                while i < inner.endIndex, inner[i] != ".", inner[i] != " ", inner[i] != "\t" {
                    seg.append(inner[i]); i = inner.index(after: i)
                }
                guard !seg.isEmpty else { return nil }
            }
            segs.append(seg)
            skipWS()
            if i >= inner.endIndex { return segs }
            guard inner[i] == "." else { return nil }
            i = inner.index(after: i)
        }
    }

    /// A table Vigil owns: `[mcp_servers.vigil]` (and subtables) or `[projects."<cwd>"]`
    /// (and subtables) for the node's own cwd — matched by DECODED key, not quoting style.
    static func isOwnedTable(_ path: [String], projectCwd: String?) -> Bool {
        guard path.count >= 2 else { return false }
        if path[0] == "mcp_servers", path[1] == "vigil" { return true }
        if let cwd = projectCwd, path[0] == "projects", path[1] == cwd { return true }
        return false
    }

    /// A top-of-line `owned_key = …` assignment (any section — see ownedKeys).
    static func isOwnedKeyLine(_ trimmed: String) -> Bool {
        guard let eq = trimmed.firstIndex(of: "=") else { return false }
        return ownedKeys.contains(trimmed[..<eq].trimmingCharacters(in: .whitespaces))
    }

    /// Advance the multi-line-string state across one line: TOML multi-line strings open and
    /// close with `"""` or `'''`; a delimiter can open and close on the same line.
    private static func scanStrings(_ line: String, open: inout String?) {
        var idx = line.startIndex
        while idx < line.endIndex {
            if let delim = open {
                guard let r = line.range(of: delim, range: idx..<line.endIndex) else { return }
                open = nil; idx = r.upperBound
            } else {
                let next = ["\"\"\"", "'''"]
                    .compactMap { d in line.range(of: d, range: idx..<line.endIndex).map { (d, $0) } }
                    .min { $0.1.lowerBound < $1.1.lowerBound }
                guard let (d, r) = next else { return }
                open = d; idx = r.upperBound
            }
        }
    }
}
