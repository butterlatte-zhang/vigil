import XCTest
import SwiftUI
import AppKit
import VigilRuntime
import ViewInspector
@testable import VigilApp

// Launcher input box: TextField(axis:.vertical) → NSTextView representable.
// Interaction contract (matches agent TUI convention):
//   · plain Return: submit (onSubmit)
//   · Shift+Return / Cmd+Return / Option+Return: insert a newline
//   · Tab / Shift+Tab: move focus (field-editor semantics)
// The whole Return family is dispatched by returnAction inside PromptNSTextView.keyDown
// (the pure decision logic is separately covered by KeymapTests).
// Performance contract: per-keystroke editing on large text must go through incremental
// layout, not O(full text) on every keystroke.
@MainActor
final class LauncherPromptTests: XCTestCase {

    private func makeBound(_ initial: String = "") -> (PromptNSTextView,
                                                       PromptTextView.Coordinator,
                                                       () -> String) {
        var text = initial
        let binding = Binding(get: { text }, set: { text = $0 })
        let tv = PromptNSTextView.make()
        let coord = PromptTextView.Coordinator(text: binding)
        tv.delegate = coord
        tv.string = initial
        return (tv, coord, { text })
    }

    // MARK: - Return semantics (Enter=submit, Shift/Cmd/Option+Enter=newline)

    private func typeReturn(_ tv: PromptNSTextView, _ mods: NSEvent.ModifierFlags) {
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                 timestamp: 1, windowNumber: 0, context: nil,
                                 characters: "\r", charactersIgnoringModifiers: "\r",
                                 isARepeat: false, keyCode: 36)!
        tv.keyDown(with: e)
    }

    func testPlainReturn_submits_noNewline() {
        let (tv, _, _) = makeBound("abc")
        var fired = false
        tv.onSubmit = { fired = true }
        typeReturn(tv, [])
        XCTAssertTrue(fired, "plain Return = submit (onSubmit)")
        XCTAssertEqual(tv.string, "abc", "submit inserts no newline — text unchanged")
    }

    func testShiftReturn_insertsNewline_noSubmit() {
        let (tv, _, _) = makeBound("abc")
        var fired = false
        tv.onSubmit = { fired = true }
        typeReturn(tv, .shift)
        XCTAssertFalse(fired, "⇧Return does not submit")
        XCTAssertEqual(tv.string, "abc\n", "⇧Return = newline")
    }

    func testCommandReturn_insertsNewline_noSubmit() {
        let (tv, _, _) = makeBound("abc")
        var fired = false
        tv.onSubmit = { fired = true }
        typeReturn(tv, .command)
        XCTAssertFalse(fired, "⌘Return does not submit (folded into newline, opposite the old contract)")
        XCTAssertEqual(tv.string, "abc\n", "⌘Return = newline")
    }

    func testOptionReturn_insertsNewline() {
        let (tv, _, _) = makeBound("abc")
        typeReturn(tv, .option)
        XCTAssertEqual(tv.string, "abc\n", "⌥Return = newline (unchanged)")
    }

    // MARK: - IME composition: typing English under a Chinese input method leaves marked
    // pre-edit text; the Return that confirms the composition must NOT submit — only the
    // next Return, after composition ends, submits.

    /// Put the text view into an active composition (marked pre-edit text) the way an input
    /// method does. hasMarkedText() is true from here until unmarkText / a commit.
    private func beginComposition(_ tv: PromptNSTextView, _ preedit: String = "nihao") {
        tv.setMarkedText(preedit,
                         selectedRange: NSRange(location: 0, length: (preedit as NSString).length),
                         replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func testComposing_returnDecisionIsPassthrough_notSubmit() {
        // Assert the dispatch decision keyDown actually makes (not just the action body):
        // while composing, Return is passthrough (→ input context confirms), never submit.
        let (tv, _, _) = makeBound("")
        beginComposition(tv)
        XCTAssertTrue(tv.hasMarkedText(), "precondition: setMarkedText really put it into composition")
        XCTAssertEqual(tv.effectiveReturnAction(keyCode: 36, modifiers: []),
                       PromptNSTextView.ReturnAction.passthrough,
                       "while composing, Return goes to the IME to confirm the composition, never submit")
        XCTAssertEqual(tv.effectiveReturnAction(keyCode: 76, modifiers: []),
                       PromptNSTextView.ReturnAction.passthrough,
                       "while composing, keypad Enter also does not submit")
    }

    func testAfterComposition_returnDecisionSubmitsAgain() {
        let (tv, _, _) = makeBound("")
        beginComposition(tv)
        tv.unmarkText()   // IME committed / composition ended
        XCTAssertFalse(tv.hasMarkedText(), "precondition: composition ended, marked text cleared")
        XCTAssertEqual(tv.effectiveReturnAction(keyCode: 36, modifiers: []),
                       PromptNSTextView.ReturnAction.submit,
                       "the next Return after composition ends restores submit semantics")
    }

    func testComposing_keyDownReturn_doesNotSubmit() {
        // End-to-end through the real dispatch path (keyDown with a real NSEvent): Enter to
        // confirm English letters under a Chinese IME must not submit.
        let (tv, _, _) = makeBound("")
        var fired = false
        tv.onSubmit = { fired = true }
        beginComposition(tv)
        typeReturn(tv, [])
        XCTAssertFalse(fired, "Enter confirms the composition — the launcher never fires a submit")
    }

    func testComposing_thenCommit_nextReturnSubmits_keyDownPath() {
        let (tv, _, _) = makeBound("")
        var fired = false
        tv.onSubmit = { fired = true }
        beginComposition(tv)
        typeReturn(tv, [])            // confirms composition, no submit
        XCTAssertFalse(fired)
        tv.unmarkText()               // composition ends
        typeReturn(tv, [])            // now a real submit
        XCTAssertTrue(fired, "only the Enter after composition ends submits")
    }

    func testComposing_shiftReturnStillNoNewlineSideEffect() {
        // During composition even ⇧Return must defer to the IME (passthrough), not force our
        // newline branch — the input method owns the keyboard while marked text is present.
        let (tv, _, _) = makeBound("")
        beginComposition(tv)
        XCTAssertEqual(tv.effectiveReturnAction(keyCode: 36, modifiers: .shift),
                       PromptNSTextView.ReturnAction.passthrough,
                       "while composing, ⇧Return also goes to the IME, not our newline branch")
    }

    func testTab_movesFocusInsteadOfInsertingTab() {
        let (tv, coord, _) = makeBound("abc")
        XCTAssertTrue(coord.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:))),
                      "Tab moves focus (field-editor semantics), does not insert \\t")
        XCTAssertEqual(tv.string, "abc")
    }

    // MARK: - binding sync

    func testTyping_syncsBinding() {
        let (tv, _, read) = makeBound("")
        tv.insertText("large task brief", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(read(), "large task brief", "typing must write back to the binding via textDidChange")
    }

    func testProgrammaticSet_viaModel_reachesTextView() throws {
        // Prefill path (launcherPrefill): an external assignment to model.text →
        // updateNSView writes it into the NSTextView. ViewInspector doesn't spawn an
        // NSView, so this drives the representable's update semantics directly.
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })
        let tv = PromptNSTextView.make()
        let coord = PromptTextView.Coordinator(text: binding)
        tv.delegate = coord
        text = AppModel.configOnboardingPrompt
        PromptTextView.sync(tv, to: text)
        XCTAssertEqual(tv.string, AppModel.configOnboardingPrompt)
        // Sync should place the cursor at the end of the text (so typing after a prefill
        // doesn't overwrite it)
        XCTAssertEqual(tv.selectedRange().location, (text as NSString).length)
    }

    // MARK: - auto-grow height (preserving TextField(axis:.vertical)'s height behavior)

    func testMeasuredHeight_growsWithLines() {
        let tv = PromptNSTextView.make()
        tv.string = "one line"
        let h1 = PromptTextView.measuredHeight(tv, width: 500)
        tv.string = Array(repeating: "line", count: 12).joined(separator: "\n")
        let h12 = PromptTextView.measuredHeight(tv, width: 500)
        XCTAssertGreaterThan(h1, 0)
        XCTAssertGreaterThan(h12, h1 * 8, "12 lines must be significantly taller than 1 line (auto-grow)")
    }

    func testMeasuredHeight_emptyTextStillOneLine() {
        let tv = PromptNSTextView.make()
        tv.string = ""
        XCTAssertGreaterThan(PromptTextView.measuredHeight(tv, width: 500), 0,
                             "empty text must still keep one line of height (cursor visible, area clickable)")
    }

    // MARK: - long-text height clamp + internal scroll: pasting a long task brief keeps
    // the box size fixed and scrolls the text

    func testFittedHeight_clampsBetweenMinAndMax() {
        XCTAssertEqual(PromptTextView.fittedHeight(measured: 30, min: 64, max: 220), 64,
                       "short text keeps minHeight (old behavior unchanged)")
        XCTAssertEqual(PromptTextView.fittedHeight(measured: 100, min: 64, max: 220), 100,
                       "medium text auto-grows (old behavior unchanged)")
        XCTAssertEqual(PromptTextView.fittedHeight(measured: 5000, min: 64, max: 220), 220,
                       "long text clamps at maxHeight — the box no longer grows unbounded")
    }

    func testMakeScrollable_wrapsTextViewForInternalScroll() throws {
        let scroll = PromptNSTextView.makeScrollable()
        let tv = try XCTUnwrap(scroll.documentView as? PromptNSTextView,
                               "documentView must be a PromptNSTextView (chip/keyDown semantics live on it)")
        XCTAssertIdentical(tv.enclosingScrollView, scroll,
                           "the text view must have an enclosingScrollView — so it can scroll internally when overflowing")
        XCTAssertTrue(scroll.hasVerticalScroller && scroll.autohidesScrollers,
                      "scrollers appear on demand (short text looks identical to the old version)")
        XCTAssertFalse(scroll.drawsBackground, "transparent background: the card background shows through, visuals unchanged")
        XCTAssertFalse(scroll.hasHorizontalScroller, "vertical scroll only (widthTracksTextView wraps)")
    }

    func testScrollableDocumentCoversViewport_dropAndClickSurface() throws {
        // The drag/drop and click target is entirely on PromptNSTextView
        // (registerForDraggedTypes/draggingEntered/paste override). After wrapping in
        // NSScrollView, documentView's height only follows the text layout (empty text
        // ≈22pt for one line) and doesn't fill a ≥64pt viewport → drops in the lower part
        // of the box hit clipView and get dropped by the whole chain, clicking blank
        // space doesn't focus (and once focus is lost, Cmd+V does nothing either).
        // Contract: under any viewport geometry, tv's height ≥ the viewport's height.
        let scroll = PromptNSTextView.makeScrollable()
        let tv = try XCTUnwrap(scroll.documentView as? PromptNSTextView)
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 64)
        scroll.tile()   // in real AppKit runtime tile() fires on every geometry change; drive the same entry point explicitly here
        XCTAssertGreaterThanOrEqual(tv.frame.height, 64,
                                    "with empty text tv must fill the viewport — it is the only drag/drop/click surface")
        // when the viewport grows taller (multi-line auto-grow up to the 220 clamp tier), tv must keep up too
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 220)
        scroll.tile()
        XCTAssertGreaterThanOrEqual(tv.frame.height, 220, "after the viewport grows taller, tv's bottom edge must still hug the box bottom")
    }

    func testLongText_measuredHeightExceedsMax_soClampEngages() {
        // The clamp isn't decorative: for a full-page paste (dozens of lines), the
        // measured height must actually exceed the cap.
        let tv = PromptNSTextView.make()
        tv.string = Array(repeating: "paste a very long task brief text", count: 60).joined(separator: "\n")
        XCTAssertGreaterThan(PromptTextView.measuredHeight(tv, width: 592),
                             PromptTextView.defaultMaxHeight)
    }

    // MARK: - performance acceptance line: incremental layout for per-keystroke editing on large text

    func testLargeText_perKeystrokeLayoutIsIncremental() {
        // ~300k characters, segmented to resemble a real task brief (~40 chars per line).
        // A naive TextField-style implementation would do an O(n) intrinsic recalculation
        // on the full text for every keystroke — at this scale that's perceptible lag per
        // keystroke. NSTextView's layout must invalidate incrementally per paragraph, so
        // 100 rounds of "keystroke + height remeasure (= one sizeThatFits per key)" must
        // be far faster than O(n)×100.
        let line = String(repeating: "paste a very long task brief text, ", count: 3) + "\n"
        let tv = PromptNSTextView.make()
        tv.string = String(repeating: line, count: 7500)          // ≈ 300k characters
        _ = PromptTextView.measuredHeight(tv, width: 592)         // first full layout pass after the paste
        let storage = try! XCTUnwrap(tv.textStorage)

        let t0 = Date()
        for _ in 0..<100 {
            tv.insertText("a", replacementRange: NSRange(location: storage.length, length: 0))
            _ = PromptTextView.measuredHeight(tv, width: 592)
        }
        let dt = Date().timeIntervalSince(t0)
        XCTAssertLessThan(dt, 1.5,
            "100 keystrokes + height remeasure on 300k-char text took \(dt)s — incremental layout broke (back to per-key O(n))")
    }

    // MARK: - view wiring (AX id contract + placeholder)

    func testPromptField_carriesLauncherPromptID() throws {
        let model = LauncherPromptModel(text: "")
        let field = LauncherPromptField(model: model, vg: VGTokens.make(.dark, .blue))
        XCTAssertNoThrow(
            try field.inspect().find(viewWithAccessibilityIdentifier: "launcher.prompt"),
            "launcher.prompt id contract (ACCESSIBILITY_IDS.md) must not break")
    }

    func testPlaceholder_showsOnlyWhenEmpty() throws {
        let vg = VGTokens.make(.dark, .blue)
        let empty = LauncherPromptField(model: LauncherPromptModel(text: ""), vg: vg)
        XCTAssertNoThrow(try empty.inspect().find(text: "Type anything…"))
        let filled = LauncherPromptField(model: LauncherPromptModel(text: "has content"), vg: vg)
        XCTAssertThrowsError(try filled.inspect().find(text: "Type anything…"))
    }

    // MARK: - attachment chips (pasting/dragging images and files)

    private func freshPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("vigil-launcher-test-\(UUID().uuidString)"))
        pb.clearContents()
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }

    private func pngData() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testAttachChips_expandedTextSubstitutesEscapedPaths() {
        let (tv, _, read) = makeBound("look at this: ")
        tv.setSelectedRange(NSRange(location: ("look at this: " as NSString).length, length: 0))
        tv.attachChips(for: [URL(fileURLWithPath: "/tmp/a b.png")])
        XCTAssertEqual(tv.expandedText(), "look at this: /tmp/a\\ b.png ",
                       "chip expands to an escaped path + separator space on submit")
        XCTAssertTrue(read().contains("\u{FFFC}"),
                      "the binding holds the attachment placeholder char — the path only appears when expanded at submit")
        XCTAssertEqual(tv.selectedRange().location, tv.textStorage!.length,
                       "after chip insertion the cursor sits after it, so continued typing appends")
    }

    func testExpandedText_plainTextEqualsString() {
        let (tv, _, _) = makeBound("plain text task")
        XCTAssertEqual(tv.expandedText(), "plain text task")
    }

    func testChipDeletion_removesFromExpansion() {
        let (tv, _, _) = makeBound("")
        tv.attachChips(for: [URL(fileURLWithPath: "/tmp/z.png")])
        XCTAssertTrue(tv.expandedText().contains("/tmp/z.png"))
        tv.textStorage!.deleteCharacters(in: NSRange(location: 0, length: tv.textStorage!.length))
        XCTAssertEqual(tv.expandedText(), "", "deleting the chip (one character) = it's absent from the submission")
    }

    func testIngestPaste_fileURLBecomesChip_plainTextFallsThrough() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("vigil-launcher-fixture-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let pb = freshPasteboard()
        pb.writeObjects([file as NSURL])
        pb.setString(file.lastPathComponent, forType: .string)   // Finder copies also carry a name string

        let (tv, _, _) = makeBound("")
        XCTAssertTrue(tv.handleIngestPaste(pb, mode: .paste), "a file paste must be consumed by the chip layer")
        XCTAssertEqual(tv.expandedText(),
                       PasteIngest.shellEscaped(file.standardizedFileURL.path) + " ")

        let pbText = freshPasteboard()
        pbText.setString("plain", forType: .string)
        XCTAssertFalse(tv.handleIngestPaste(pbText, mode: .paste),
                       "plain text passes through to NSTextView's default paste (zero behavior change)")
    }

    func testIngestPaste_rawImageMaterializesToChip() throws {
        let pb = freshPasteboard()
        pb.setData(pngData(), forType: .png)
        let (tv, _, _) = makeBound("")
        XCTAssertTrue(tv.handleIngestPaste(pb, mode: .paste), "a screenshot paste must be materialized to disk as a chip")
        let path = tv.expandedText().trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(path.contains("clipboard-") && path.hasSuffix(".png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "behind the chip is a real on-disk file (claude will Read it later)")
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
    }

    func testAttachChips_undoRestoresReplacedText() {
        // shouldChangeText's replacementString must be the actual inserted string. Passing
        // nil = "attribute-only change" — undo gets registered as an attribute rollback
        // while the document length has already changed, so Cmd+Z can't undo the chip,
        // and in the replace-selection case the original text doesn't come back either.
        // undoManager goes through the responder chain, so it only exists once attached
        // to a window.
        let (tv, _, _) = makeBound("abc")
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = tv
        tv.setSelectedRange(NSRange(location: 1, length: 1))     // select "b"; chip replaces the selection
        tv.attachChips(for: [URL(fileURLWithPath: "/tmp/u.png")])
        XCTAssertTrue(tv.string.contains("\u{FFFC}"))
        let undo = try! XCTUnwrap(tv.undoManager, "inside a window there must be an undoManager")
        XCTAssertTrue(undo.canUndo, "chip insertion must register a character-level undo")
        undo.undo()
        XCTAssertEqual(tv.string, "abc", "Cmd+Z fully restores (including the replaced selection text)")
    }

    // MARK: - draft round-trip (launcher input cache across a session switch)

    func testCurrentAttachmentURLs_walksChipsInOrder() {
        let (tv, _, _) = makeBound("look: ")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.attachChips(for: [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")])
        XCTAssertEqual(tv.currentAttachmentURLs(),
                       [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")],
                       "the snapshot must walk chips left-to-right, matching insertion order")
    }

    func testCurrentAttachmentURLs_emptyWhenNoChips() {
        let (tv, _, _) = makeBound("plain text, no chips")
        XCTAssertEqual(tv.currentAttachmentURLs(), [])
    }

    func testRestoreDraft_rebuildsChipsFromCachedURLs() {
        // The counterpart to attachChips: given the plain text (with its U+FFFC
        // placeholders) and the URL list captured by currentAttachmentURLs, restoreDraft
        // must reconstruct real chips — not leave bare placeholder characters behind —
        // so expandedText() still substitutes the escaped path at submit.
        let (tv, _, _) = makeBound("")
        tv.attachChips(for: [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")])
        let text = tv.string
        let urls = tv.currentAttachmentURLs()

        let (fresh, _, _) = makeBound("")
        fresh.restoreDraft(text: text, attachments: urls)

        XCTAssertEqual(fresh.string, text, "restored plain string matches the cached draft")
        XCTAssertEqual(fresh.currentAttachmentURLs(), urls, "restored chips carry the same URLs, in order")
        XCTAssertEqual(fresh.expandedText(), tv.expandedText(),
                       "a restored chip must expand to the escaped path at submit, exactly like a freshly-pasted one")
    }

    func testRestoreDraft_plainTextOnly_noAttachments() {
        let (tv, _, _) = makeBound("")
        tv.restoreDraft(text: "just some text", attachments: [])
        XCTAssertEqual(tv.string, "just some text")
        XCTAssertEqual(tv.expandedText(), "just some text")
    }

    func testModel_consumeDraftAttachments_isOneShot() {
        let model = LauncherPromptModel(text: "\u{FFFC}", draftAttachments: [URL(fileURLWithPath: "/tmp/a.png")])
        XCTAssertEqual(model.consumeDraftAttachments(), [URL(fileURLWithPath: "/tmp/a.png")])
        XCTAssertNil(model.consumeDraftAttachments(), "a second call must not re-run reconstruction")
    }

    func testModel_consumeDraftAttachments_nilWhenNoneCached() {
        let model = LauncherPromptModel(text: "plain")
        XCTAssertNil(model.consumeDraftAttachments())
    }

    func testModel_submissionTextPrefersHostExpansion() {
        let (tv, _, _) = makeBound("")
        tv.attachChips(for: [URL(fileURLWithPath: "/tmp/q.png")])
        let model = LauncherPromptModel(text: tv.string)
        model.host = tv
        XCTAssertEqual(model.submissionText, "/tmp/q.png ",
                       "the submission path (CenterView2.submit) reads submissionText, not text")
        model.host = nil
        XCTAssertEqual(model.submissionText, tv.string, "no host (no chip / tests) falls back to text")
    }
}
