import XCTest
import Foundation
@testable import VigilRuntime

/// The one JSON→disk helper shared by ClaudeCodeHarness.writeJSON / SessionArchive.writeMeta /
/// Orchestrator.appendJSONL. Behavior contract pinned here matches each call site's prior
/// behavior byte for byte, including try? silent error swallowing on the write path (not
/// upgraded here — the broader error-swallowing chain is out of scope).
final class FileIOTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "vigil_fileio_\(getpid())_\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    func testWriteJSONObjectPrettyPrintedRoundTrips() throws {
        // ClaudeCodeHarness.writeJSON semantics: whole-file, .prettyPrinted.
        let p = dir + "/settings.json"
        FileIO.writeJSON(["hooks": ["Stop": ["cmd"]]], to: p, options: [.prettyPrinted])
        let data = try XCTUnwrap(FileManager.default.contents(atPath: p))
        // pretty-printed = multi-line output (the original's only formatting trait)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\n"))
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(back["hooks"] as? [String: Any])
        XCTAssertEqual(hooks["Stop"] as? [String], ["cmd"])
    }

    func testWriteJSONObjectReturnsFalseAndReportsOnUnwritablePath() {
        // A failed write leaves no file, throws nothing, and never crashes — but does
        // return false and hand the failure to the report sink.
        var reported: [(op: String, path: String)] = []
        let ok = FileIO.writeJSON(["k": "v"], to: dir + "/no/such/dir/x.json",
                                  report: { op, p, _ in reported.append((op, p)) })
        XCTAssertFalse(ok, "a disk-write failure must return false")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/no/such/dir/x.json"))
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.op, "write")
    }

    func testWriteJSONSucceedsSilentlyWhenNoSink() {
        // Default report=nil: the success path returns true, quietly.
        XCTAssertTrue(FileIO.writeJSON(["k": "v"], to: dir + "/ok.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/ok.json"))
    }

    func testCreateDirectoryReturnsFalseAndReportsWhenBlocked() {
        // An ordinary file blocking the target directory's position → createDirectory
        // must fail, returning false + report.
        let blocked = dir + "/blocker"
        FileManager.default.createFile(atPath: blocked, contents: Data("x".utf8))
        var reported = 0
        let ok = FileIO.createDirectory(blocked + "/child", report: { _, _, _ in reported += 1 })
        XCTAssertFalse(ok)
        XCTAssertEqual(reported, 1)
        XCTAssertTrue(FileIO.createDirectory(dir + "/fresh"))   // the normal path still returns true
    }

    func testWriteEncodableHonorsEncoderConfig() throws {
        // SessionArchive.writeMeta semantics: caller-configured JSONEncoder
        // (iso8601 + prettyPrinted + sortedKeys) writes whole-file.
        struct M: Codable, Equatable { var b: String; var a: Date }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let p = dir + "/meta.json"
        let m = M(b: "x", a: Date(timeIntervalSince1970: 1_700_000_000))
        FileIO.writeJSON(m, to: p, encoder: enc)
        let s = try String(contentsOfFile: p, encoding: .utf8)
        XCTAssertTrue(s.contains("2023-11-14T22:13:20Z"), "iso8601 date encoding must apply")
        let keyA = try XCTUnwrap(s.range(of: "\"a\""))
        let keyB = try XCTUnwrap(s.range(of: "\"b\""))
        XCTAssertLessThan(keyA.lowerBound, keyB.lowerBound, "sortedKeys must apply")
    }

    func testAppendJSONLineCreatesThenAppends() throws {
        // Orchestrator.appendJSONL semantics: compact one-line JSON + "\n", create on
        // first write, append thereafter.
        let p = dir + "/orchestration.jsonl"
        FileIO.appendJSONLine(["event": "a"], to: p)
        FileIO.appendJSONLine(["event": "b"], to: p)
        let lines = try String(contentsOfFile: p, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines[0].contains(" "), "jsonl line is compact, not pretty")
        let objs = lines.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
        XCTAssertEqual(objs.map { $0["event"] as? String }, ["a", "b"])
    }
}
