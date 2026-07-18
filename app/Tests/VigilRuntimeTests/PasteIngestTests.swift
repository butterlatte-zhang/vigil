import XCTest
import AppKit
import VigilGhosttyTerminal
@testable import VigilRuntime

// Paste/drag-drop normalization layer.
// The sole wire format = on-disk path text: files use their original path, images are materialized to a temp file, then shell-escaped before entering the input.
final class PasteIngestTests: XCTestCase {
    private var pb: NSPasteboard!
    private var dir: URL!
    private var store: PasteImageStore!

    override func setUp() {
        super.setUp()
        pb = NSPasteboard(name: .init("vigil-paste-test-\(UUID().uuidString)"))
        pb.clearContents()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vigil-paste-tests-\(UUID().uuidString)")
        store = PasteImageStore(directory: dir)
    }

    override func tearDown() {
        pb.releaseGlobally()
        try? FileManager.default.removeItem(at: dir)
        TerminalClipboardReadHook.transform = nil
        super.tearDown()
    }

    // MARK: - fixtures

    private func pngData() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func tiffData() -> Data {
        NSBitmapImageRep(data: pngData())!.tiffRepresentation!
    }

    @discardableResult
    private func tempFile(_ name: String, _ data: Data = Data("x".utf8)) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vigil-paste-fixture-\(UUID().uuidString)-\(name)")
        try? data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - shell escaping (terminal injection semantics)

    func testShellEscaped_plainUnchanged() {
        XCTAssertEqual(PasteIngest.shellEscaped("abc-123.png"), "abc-123.png")
    }

    func testShellEscaped_fullSpecialSetPinned() {
        // All 22 meta-characters get individually backslash-escaped; non-meta characters pass
        // through unchanged.
        let specials = "\\ ()[]{}<>\"'`!#$&;|*?\t"
        XCTAssertEqual(PasteIngest.shellEscaped(specials),
                       specials.map { "\\\($0)" }.joined())
        XCTAssertEqual(PasteIngest.shellEscaped("中文-路径_0.9~@%^+=,:"),
                       "中文-路径_0.9~@%^+=,:", "non-meta characters (incl. ~ @ % ^ + = , :) are never escaped")
    }

    func testShellEscaped_specialsBackslashed() {
        XCTAssertEqual(PasteIngest.shellEscaped("a b(c)'d"), "a\\ b\\(c\\)\\'d")
    }

    func testShellEscaped_newlineFallsToSingleQuoting() {
        XCTAssertEqual(PasteIngest.shellEscaped("a\nb"), "'a\nb'",
                       "a newline forces whole-string single-quoting (backslash-escaping a newline would split the input across lines)")
        XCTAssertEqual(PasteIngest.shellEscaped("a'\nb"), "'a'\\''\nb'")
    }

    // MARK: - fileURL reading

    func testFileURLs_readAndDeduped() {
        let f = tempFile("a.txt")
        pb.writeObjects([f as NSURL, f as NSURL])
        XCTAssertEqual(PasteIngest.fileURLs(from: pb), [f.standardizedFileURL])
    }

    // MARK: - normalization priority (paste: file > text > raw image)

    func testPaste_fileURLWinsOverString() {
        let f = tempFile("b.png", pngData())
        pb.writeObjects([f as NSURL])
        pb.setString("b.png", forType: .string)   // Finder copy also gives a name string
        XCTAssertEqual(PasteIngest.nonTextIngest(pb, mode: .paste, store: store),
                       .fileURLs([f.standardizedFileURL]))
    }

    func testPaste_plainStringIsNotOurs() {
        pb.setString("hello", forType: .string)
        XCTAssertNil(PasteIngest.nonTextIngest(pb, mode: .paste, store: store),
                     "plain text is handed back to the default paste path")
    }

    func testPaste_rawImageMaterializesToOwnedPNGFile() throws {
        let png = pngData()
        pb.setData(png, forType: .png)
        guard case .fileURLs(let files)? =
                PasteIngest.nonTextIngest(pb, mode: .paste, store: store) else {
            return XCTFail("a raw image must be materialized to a file")
        }
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(file.pathExtension, "png")
        XCTAssertTrue(file.lastPathComponent.hasPrefix("clipboard-"))
        XCTAssertEqual(try Data(contentsOf: file), png)
        XCTAssertTrue(store.isOwned(file))
    }

    func testPaste_tiffNormalizedToPNG() throws {
        pb.setData(tiffData(), forType: .tiff)   // macOS screenshot/copy often gives TIFF
        guard case .fileURLs(let files)? =
                PasteIngest.nonTextIngest(pb, mode: .paste, store: store) else {
            return XCTFail("TIFF must be normalized to a PNG on disk")
        }
        let data = try Data(contentsOf: try XCTUnwrap(files.first))
        XCTAssertEqual(files.first?.pathExtension, "png")
        XCTAssertEqual([UInt8](data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "PNG magic")
    }

    func testPaste_oversizeImageRejectedNotTruncated() {
        pb.setData(Data(count: PasteImageStore.maxImageBytes + 1), forType: .png)
        XCTAssertEqual(PasteIngest.nonTextIngest(pb, mode: .paste, store: store),
                       .rejectedImage, ">10MB is explicitly rejected — no silent truncation, no fallback to text")
    }

    func testPaste_materializesOnlyFirstImage_dropTakesAll() {
        let one = NSPasteboardItem(); one.setData(pngData(), forType: .png)
        let two = NSPasteboardItem(); two.setData(pngData(), forType: .png)
        pb.writeObjects([one, two])
        guard case .fileURLs(let pasted)? =
                PasteIngest.nonTextIngest(pb, mode: .paste, store: store) else {
            return XCTFail()
        }
        XCTAssertEqual(pasted.count, 1, "paste takes only the first image (cmux prefix(1) semantics)")

        let pb2 = NSPasteboard(name: .init("vigil-paste-test-\(UUID().uuidString)"))
        defer { pb2.releaseGlobally() }
        pb2.clearContents()
        let a = NSPasteboardItem(); a.setData(pngData(), forType: .png)
        let b = NSPasteboardItem(); b.setData(pngData(), forType: .png)
        pb2.writeObjects([a, b])
        guard case .fileURLs(let dropped)? =
                PasteIngest.nonTextIngest(pb2, mode: .drop, store: store) else {
            return XCTFail()
        }
        XCTAssertEqual(dropped.count, 2, "drop materializes all of them")
    }

    // MARK: - owned registration and cleanup

    func testCleanup_removesOwnedOnly() throws {
        pb.setData(pngData(), forType: .png)
        guard case .fileURLs(let files)? =
                PasteIngest.nonTextIngest(pb, mode: .paste, store: store) else {
            return XCTFail()
        }
        let foreign = dir.appendingPathComponent("not-ours.png")
        try Data("keep".utf8).write(to: foreign)

        store.cleanup([foreign])
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path),
                      "a non-owned file must never be deleted (same-family rule as the 0703 incident-grade red line)")
        store.cleanupAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    // MARK: - injected text and multi-image segmentation plan

    func testInsertedText_escapedAndSpaceJoined() {
        let urls = [URL(fileURLWithPath: "/tmp/a b.png"), URL(fileURLWithPath: "/tmp/c.txt")]
        XCTAssertEqual(PasteIngest.insertedText(forFileURLs: urls), "/tmp/a\\ b.png /tmp/c.txt")
    }

    func testDropPlan_multipleLocalImages_segmentedWith2sGap() throws {
        // claude turns "one path from a single real paste" into one [Image #N] — multiple images must be fed one at a time
        let i1 = tempFile("1.png", pngData()), i2 = tempFile("2.png", pngData())
        pb.writeObjects([i1 as NSURL, i2 as NSURL])
        let plan = try XCTUnwrap(PasteIngest.dropPlan(pb, store: store))
        guard case .insertTextSegments(let segs, let delay) = plan else {
            return XCTFail("dropping multiple local images must inject in segments, got \(plan)")
        }
        XCTAssertEqual(delay, 2.0)
        XCTAssertEqual(segs, [PasteIngest.shellEscaped(i1.standardizedFileURL.path),
                              " " + PasteIngest.shellEscaped(i2.standardizedFileURL.path)])
    }

    func testDropPlan_singleFileOrNonImages_onePaste() throws {
        let i1 = tempFile("1.png", pngData())
        pb.writeObjects([i1 as NSURL])
        XCTAssertEqual(try XCTUnwrap(PasteIngest.dropPlan(pb, store: store)),
                       .insertText(PasteIngest.shellEscaped(i1.standardizedFileURL.path)))

        let pb2 = NSPasteboard(name: .init("vigil-paste-test-\(UUID().uuidString)"))
        defer { pb2.releaseGlobally() }
        pb2.clearContents()
        let t1 = tempFile("a.txt"), t2 = tempFile("b.txt")
        pb2.writeObjects([t1 as NSURL, t2 as NSURL])
        XCTAssertEqual(try XCTUnwrap(PasteIngest.dropPlan(pb2, store: store)),
                       .insertText(PasteIngest.insertedText(
                        forFileURLs: [t1.standardizedFileURL, t2.standardizedFileURL])),
                       "a non-image-only combination injects in one shot (segmentation exists only to serve [Image #N])")
    }

    func testDropPlan_plainTextFallsThrough() {
        pb.setString("dropped text", forType: .string)
        XCTAssertEqual(PasteIngest.dropPlan(pb, store: store), .insertText("dropped text"))
    }

    // MARK: - terminal readClipboard hook (vendored seam + host transform)

    func testTerminalPasteReplacement_threeBranches() throws {
        let f = tempFile("x y.png", pngData())
        pb.writeObjects([f as NSURL])
        XCTAssertEqual(PasteIngest.terminalPasteReplacement(pb, store: store),
                       PasteIngest.shellEscaped(f.standardizedFileURL.path))

        let pbText = NSPasteboard(name: .init("vigil-paste-test-\(UUID().uuidString)"))
        defer { pbText.releaseGlobally() }
        pbText.clearContents()
        pbText.setString("plain", forType: .string)
        XCTAssertNil(PasteIngest.terminalPasteReplacement(pbText, store: store),
                     "plain text returns nil → the callback uses the default .string read, behavior unchanged")

        let pbImg = NSPasteboard(name: .init("vigil-paste-test-\(UUID().uuidString)"))
        defer { pbImg.releaseGlobally() }
        pbImg.clearContents()
        pbImg.setData(pngData(), forType: .png)
        let text = try XCTUnwrap(PasteIngest.terminalPasteReplacement(pbImg, store: store))
        XCTAssertTrue(text.hasSuffix(".png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: text.replacingOccurrences(of: "\\", with: "")))
    }

    func testReadHook_transformWinsNilFallsBack() {
        pb.setString("fallback", forType: .string)
        XCTAssertNil(TerminalClipboardReadHook.transform, "the seam defaults to empty")
        XCTAssertEqual(TerminalClipboardReadHook.resolvePasteText(pb), "fallback")

        TerminalClipboardReadHook.transform = { _ in "transformed" }
        XCTAssertEqual(TerminalClipboardReadHook.resolvePasteText(pb), "transformed")

        TerminalClipboardReadHook.transform = { _ in nil }
        XCTAssertEqual(TerminalClipboardReadHook.resolvePasteText(pb), "fallback",
                       "transform returning nil must fall back to the default .string read")
    }

    func testInstallTerminalHook_routesImagePasteboardToPathText() throws {
        PasteIngest.installTerminalHook(store: store)
        pb.setData(pngData(), forType: .png)
        let text = try XCTUnwrap(TerminalClipboardReadHook.resolvePasteText(pb))
        XCTAssertTrue(text.contains("clipboard-") && text.hasSuffix(".png"),
                      "terminal Cmd+V image paste = on-disk path text into the PTY")
    }
}
