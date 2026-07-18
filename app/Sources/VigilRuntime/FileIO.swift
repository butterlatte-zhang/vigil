import Foundation

/// The one JSON→disk helper, shared by ClaudeCodeHarness (per-node
/// settings/mcp configs), SessionArchive (meta.json), and Orchestrator (jsonl trails),
/// so none of them need their own inline copy of "serialize, then write".
///
/// The writes REPORT failure. Each method
/// returns a Bool (true = written) and, when given a `report` sink, hands it the failing
/// op so a swallowed config/launch write doesn't manifest as "the whole orchestration
/// vanishes, with zero logs the entire time" (disk full / permission error → the cell
/// starts up with no hook / no MCP, undiagnosable). `report` defaults to nil
/// so best-effort telemetry callers stay silent; launch-critical sites pass a sink.
enum FileIO {
    /// Reports one failed IO op: (operation, path, error description).
    typealias ErrorSink = (_ op: String, _ path: String, _ error: String) -> Void

    /// Create a directory (with intermediates). Returns success + reports failure.
    @discardableResult
    static func createDirectory(_ path: String, report: ErrorSink? = nil) -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return true
        } catch {
            report?("createDirectory", path, "\(error)")
            return false
        }
    }

    /// Whole-file write of a JSON object (dictionary form).
    @discardableResult
    static func writeJSON(_ obj: [String: Any], to path: String,
                          options: JSONSerialization.WritingOptions = [],
                          report: ErrorSink? = nil) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: options) else {
            report?("serialize", path, "JSONSerialization failed")
            return false
        }
        return write(data, to: path, report: report)
    }

    /// Whole-file write of an Encodable with a caller-configured encoder
    /// (date strategy / output formatting stay the call site's decision).
    @discardableResult
    static func writeJSON<T: Encodable>(_ value: T, to path: String, encoder: JSONEncoder,
                                        report: ErrorSink? = nil) -> Bool {
        guard let data = try? encoder.encode(value) else {
            report?("encode", path, "JSONEncoder failed")
            return false
        }
        return write(data, to: path, report: report)
    }

    /// Append one compact, newline-terminated JSONL line; first write creates the file.
    @discardableResult
    static func appendJSONLine(_ obj: [String: Any], to path: String,
                               report: ErrorSink? = nil) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else {
            report?("serialize", path, "JSONSerialization failed")
            return false
        }
        let line = Data((json + "\n").utf8)
        if let fh = FileHandle(forWritingAtPath: path) {
            defer { try? fh.close() }
            do {
                _ = try fh.seekToEnd()
                try fh.write(contentsOf: line)
                return true
            } catch {
                report?("append", path, "\(error)")
                return false
            }
        }
        do {
            try line.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            report?("create", path, "\(error)")
            return false
        }
    }

    private static func write(_ data: Data, to path: String, report: ErrorSink?) -> Bool {
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            report?("write", path, "\(error)")
            return false
        }
    }
}
