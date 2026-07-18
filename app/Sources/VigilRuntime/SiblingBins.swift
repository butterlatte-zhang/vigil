import Foundation

/// Locates the vigil shim executables sitting next to the running binary — the app and
/// vigil-smoke are built into the same products dir as vigil-hook/vigil-mcp.
public enum SiblingBins {
    /// Directory of the running executable (argv[0], symlinks resolved).
    public static let binDir: String = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath().deletingLastPathComponent().path

    /// The two shim paths next to the running executable.
    public static func locate() -> (hook: String, mcp: String) {
        (binDir + "/vigil-hook", binDir + "/vigil-mcp")
    }
}
