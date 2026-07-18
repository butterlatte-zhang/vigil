import XCTest
import AppKit
@testable import VigilApp

/// Pins down the "real entry point" E2E for launcher paste/drag — not going through the
/// handleIngestPaste seam, but tv.paste() (the real NSPasteboard.general, restored after
/// the test) and draggingEntered/performDragOperation (a stub NSDraggingInfo). This guards
/// against the GUI surface silently detaching from the seam-based tests if a
/// view-structure change (e.g. scroll wrapping) breaks the real entry point.
@MainActor
final class LauncherPasteEntryTests: XCTestCase {

    private func withGeneralPasteboard(_ body: (NSPasteboard) -> Void) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        } ?? []
        defer {
            pb.clearContents()
            let items = saved.map { dict -> NSPasteboardItem in
                let it = NSPasteboardItem()
                for (t, d) in dict { it.setData(d, forType: t) }
                return it
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        body(pb)
    }

    func testRealPasteEntry_fileURL_becomesChip() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("vigil-paste-probe-\(UUID().uuidString.prefix(6)).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let scroll = PromptNSTextView.makeScrollable()
        let tv = try XCTUnwrap(scroll.documentView as? PromptNSTextView)
        withGeneralPasteboard { pb in
            pb.clearContents()
            pb.writeObjects([file as NSURL])
            tv.paste(nil)
        }
        XCTAssertTrue(tv.string.contains("\u{FFFC}"), "file paste must become a chip (U+FFFC)")
        XCTAssertTrue(tv.expandedText().contains(file.lastPathComponent),
                      "expandedText must expand the escaped path, got: \(tv.expandedText())")
    }

    /// Drag entry point: draggingEntered decides .copy, performDragOperation lands the
    /// chip (drop uses a private pasteboard, never touches .general).
    func testRealDropEntry_fileURL_becomesChip() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("vigil-drop-probe-\(UUID().uuidString.prefix(6)).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let pb = NSPasteboard(name: NSPasteboard.Name("vigil-drop-probe-\(getpid())"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([file as NSURL])

        let scroll = PromptNSTextView.makeScrollable()
        let tv = try XCTUnwrap(scroll.documentView as? PromptNSTextView)
        let info = DragInfoStub(pasteboard: pb)
        XCTAssertEqual(tv.draggingEntered(info), .copy, "file drag must show the copy cursor")
        XCTAssertTrue(tv.performDragOperation(info), "drop must be consumed by the ingest layer")
        XCTAssertTrue(tv.string.contains("\u{FFFC}"), "file drop must become a chip (U+FFFC)")
    }

    /// Minimal NSDraggingInfo stub: the ingest chain only reads draggingPasteboard.
    private final class DragInfoStub: NSObject, NSDraggingInfo {
        let pb: NSPasteboard
        init(pasteboard: NSPasteboard) { self.pb = pasteboard }
        var draggingPasteboard: NSPasteboard { pb }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 0 }
        var draggingFormation: NSDraggingFormation { get { .default } set {} }
        var animatesToDestination: Bool { get { false } set {} }
        var numberOfValidItemsForDrop: Int { get { 1 } set {} }
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions,
                                    for view: NSView?, classes: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                    using block: (NSDraggingItem, Int,
                                                  UnsafeMutablePointer<ObjCBool>) -> Void) {}
        func resetSpringLoading() {}
    }

    // MARK: paste:'s menu-validation layer
    //
    // Cmd+V doesn't go straight into keyDown — it's the key equivalent of the main menu's
    // Edit>Paste, and before dispatching, AppKit first asks the firstResponder's
    // validateUserInterfaceItem. A plain-text NSTextView's readablePasteboardTypes doesn't
    // include image types → an image-only clipboard disables the Paste item → the
    // paste(_:) override never gets called at all (observed as "paste does nothing").
    // The three E2E tests above call tv.paste() directly, which bypasses this layer
    // entirely, so they pass even when this validation layer is broken.

    private func pasteMenuItem() -> NSMenuItem {
        NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    }

    /// Image-only clipboard: the normalization layer can consume it (materializes to a
    /// chip on disk), so the Paste menu item must be enabled.
    func testPasteMenuValidation_imageOnlyClipboard() throws {
        let img = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let tiff = try XCTUnwrap(img.tiffRepresentation)

        let scroll = PromptNSTextView.makeScrollable()
        let tv = try XCTUnwrap(scroll.documentView as? PromptNSTextView)
        withGeneralPasteboard { pb in
            pb.clearContents()
            pb.setData(tiff, forType: .tiff)
            XCTAssertTrue(tv.validateUserInterfaceItem(pasteMenuItem()),
                          "image-only clipboard must allow Paste — otherwise ⌘V is swallowed by menu validation, " +
                          "and the paste(_:) override never runs")
        }
    }

    /// File-only clipboard (the modern shape of a Finder Cmd+C may carry only a fileURL):
    /// must likewise be allowed through.
    func testPasteMenuValidation_fileURLClipboard() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("vigil-validate-probe-\(UUID().uuidString.prefix(6)).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let scroll = PromptNSTextView.makeScrollable()
        let tv = try XCTUnwrap(scroll.documentView as? PromptNSTextView)
        withGeneralPasteboard { pb in
            pb.clearContents()
            pb.setData(Data(file.absoluteString.utf8), forType: .fileURL)
            XCTAssertTrue(tv.validateUserInterfaceItem(pasteMenuItem()),
                          "file-only clipboard must allow Paste")
        }
    }

    /// Empty clipboard: the normalization layer has nothing to consume, so validation
    /// falls back to the default path (disabled) — it must not blindly allow everything.
    func testPasteMenuValidation_emptyClipboardStaysDisabled() throws {
        let scroll = PromptNSTextView.makeScrollable()
        let tv = try XCTUnwrap(scroll.documentView as? PromptNSTextView)
        withGeneralPasteboard { pb in
            pb.clearContents()
            XCTAssertFalse(tv.validateUserInterfaceItem(pasteMenuItem()),
                           "empty clipboard: Paste must stay disabled (default validation semantics unchanged)")
        }
    }

    func testRealPasteEntry_rawImage_becomesChip() throws {
        let img = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let tiff = try XCTUnwrap(img.tiffRepresentation)

        let scroll = PromptNSTextView.makeScrollable()
        let tv = try XCTUnwrap(scroll.documentView as? PromptNSTextView)
        withGeneralPasteboard { pb in
            pb.clearContents()
            pb.setData(tiff, forType: .tiff)
            tv.paste(nil)
        }
        XCTAssertTrue(tv.string.contains("\u{FFFC}"), "raw image paste must be written to disk and become a chip (U+FFFC)")
        XCTAssertTrue(tv.expandedText().contains("clipboard-"),
                      "expandedText must expand the on-disk path, got: \(tv.expandedText())")
    }
}
