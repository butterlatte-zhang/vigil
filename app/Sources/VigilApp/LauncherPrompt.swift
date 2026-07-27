import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VigilRuntime

// Launcher task input field: an NSTextView-backed representable.
//
// Why not TextField(axis:.vertical): SwiftUI's auto-growing multiline TextField does an
// O(n) intrinsic layout recompute over the entire text on every keystroke/paste, and the
// launcher is exactly the "paste a large task brief" scenario — large text is bound to lag.
// NSTextView's TextKit-1 layout invalidates
// incrementally by paragraph, so per-keystroke cost depends only on the paragraph the edit
// point is in, not the full text length (consistent with the repo's vendored NSView
// terminal approach).
//
// Interaction contract (matches each agent TUI):
//   · plain Return: submit (onSubmit)
//   · ⇧Return / ⌘Return / ⌥Return: insert a newline — all three newline, zero muscle-memory
//     switching cost
//   · Tab / ⇧Tab: move focus (field-editor semantics, unchanged)
// The Return family is all dispatched in keyDown by returnAction (⇧ can't be distinguished
// from plain Return inside doCommandBy, and ⌘Return being a key equivalent produces no
// doCommand at all — only keyDown gets the complete modifier keys). The submit button does
// not carry a ⌘Enter keyboardShortcut — that would steal ⌘Enter for submitting,
// conflicting with "⌘Enter=newline" (see CenterView2.submitButton).

/// Launcher input state: text is split out of LauncherView into a reference model —
/// a keystroke only re-evaluates the LauncherPromptField that reads it; the title and the 5
/// menu chips aren't rebuilt per keystroke (LauncherView's body doesn't read text,
/// and the read inside the submit closure establishes no observation dependency).
@MainActor @Observable
final class LauncherPromptModel {
    var text: String
    /// The expansion outlet for attachment chips. Pasted/dropped files and
    /// images are chips in the input field (U+FFFC attachment char), only expanded into
    /// escaped paths at submit — CenterView2.submit reads here, not text. No host (no chip /
    /// pure logic test) = text itself.
    @ObservationIgnored weak var host: PromptNSTextView?
    /// Attachment URLs to splice back into `text`'s U+FFFC placeholders (one per
    /// placeholder, left-to-right) — set only when this model seeds from a cached launcher
    /// draft (AppModel.launcherDraft). Chips live only inside a live NSTextView's
    /// NSTextStorage (see PromptAttachment below), never in a plain string, so restoring
    /// them needs this side channel alongside `text`.
    @ObservationIgnored private var draftAttachments: [URL]
    @ObservationIgnored private var draftConsumed = false
    var submissionText: String { host?.expandedText() ?? text }

    init(text: String = "", draftAttachments: [URL] = []) {
        self.text = text
        self.draftAttachments = draftAttachments
    }

    /// One-shot: PromptTextView.makeNSView consumes the pending draft attachments the
    /// first time it mounts a host, nil afterwards (and whenever there is nothing to
    /// restore) — a later plain reassignment of `text` (e.g. clear-on-submit) must not
    /// re-run chip reconstruction.
    func consumeDraftAttachments() -> [URL]? {
        guard !draftConsumed, !draftAttachments.isEmpty else { return nil }
        draftConsumed = true
        return draftAttachments
    }
}

/// The launcher's multiline task input area: representable + placeholder + AX container.
/// Visually equivalent to the old TextField: transparent background, ui(14), line spacing
/// 0.35em, minH 64, placeholder text-3.
struct LauncherPromptField: View {
    @Bindable var model: LauncherPromptModel
    let vg: VGTokens
    /// Plain Return = submit (launcher). LauncherView passes in its submit
    /// closure; newlines (⇧/⌘/⌥+Return) are handled inside PromptNSTextView, not here.
    var onSubmit: () -> Void = {}

    var body: some View {
        // The placeholder is a ZStack sibling rather than an overlay: the representable is a
        // traversal blocker for ViewInspector, so content hung on its overlay is untouchable
        // in tests; visually the two are equivalent (the text view is transparent).
        ZStack(alignment: .topLeading) {
            if model.text.isEmpty {
                Text("Type anything…").font(VGFont.ui(14)).foregroundStyle(vg.text3)
                    .allowsHitTesting(false)
            }
            PromptTextView(text: $model.text,
                           textColor: NSColor(vg.text),
                           knobColor: vg.scrollerKnob,
                           knobColorHover: vg.scrollerKnobHover,
                           minHeight: 64,
                           model: model,
                           onSubmit: onSubmit)
        }
        // XCUITest/axdriver needs a real AX element to carry the id — hung bare on an
        // NSViewRepresentable it isn't exposed, so wrap it as an AX container the way
        // center.terminal does (ACCESSIBILITY_IDS.md).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("launcher.prompt")
    }
}

/// NSTextView wrapper (hosted in NSScrollView). Width fills the proposal, height = full-text
/// layout height (incrementally recomputed) clamped within [minHeight, maxHeight]: short text
/// grows automatically (old TextField behavior), long text (a pasted task brief) is clamped
/// at maxHeight and scrolls internally beyond that — the box size stays fixed, keeping the
/// card layout stable.
struct PromptTextView: NSViewRepresentable {
    @Binding var text: String
    let textColor: NSColor
    /// The shared thin-scroller knob colors (VGTokens.scrollerKnob/Hover = the sidebar session
    /// selected-state wash). Threaded from the call site so this field's internal scroller uses
    /// the exact same token as every app-wide bar — no separate textColor-derived tint.
    var knobColor: NSColor = NSColor(white: 1, alpha: 0.06)
    var knobColorHover: NSColor = NSColor(white: 1, alpha: 0.09)
    let minHeight: CGFloat
    var maxHeight: CGFloat = PromptTextView.defaultMaxHeight
    var model: LauncherPromptModel? = nil   // mount point for the chip expansion outlet
    var onSubmit: () -> Void = {}            // plain Return = submit

    static let fontSize: CGFloat = 14   // = VGFont.ui(14) + lineSpacing 0.35em (old value carried over)
    /// Auto-grow ceiling ≈ 10 lines (14pt + 0.35em line spacing ≈ 21.9pt/line): longer than
    /// that switches to internal scrolling.
    static let defaultMaxHeight: CGFloat = 220

    /// Height clamp (pure function, pinned by LauncherPromptTests): short keeps min, medium
    /// grows, long clamps at max.
    static func fittedHeight(measured: CGFloat, min minH: CGFloat, max maxH: CGFloat) -> CGFloat {
        min(max(measured, minH), maxH)
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PromptNSTextView.makeScrollable()
        let tv = scroll.documentView as! PromptNSTextView
        tv.delegate = context.coordinator
        tv.onSubmit = onSubmit
        model?.host = tv
        applyStyle(tv)
        Self.styleScroller(scroll, knob: knobColor, hover: knobColorHover)
        if let attachments = model?.consumeDraftAttachments() {
            tv.restoreDraft(text: text, attachments: attachments)
        } else {
            Self.sync(tv, to: text)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? PromptNSTextView else { return }
        context.coordinator.text = $text
        tv.onSubmit = onSubmit                             // closure refreshed as body rebuilds (captures latest selection)
        model?.host = tv
        if tv.string != text { Self.sync(tv, to: text) }   // external assignments like prefill / clear-on-submit
        applyStyle(tv)                                        // theme hot-reload follows the environment
        Self.styleScroller(scroll, knob: knobColor, hover: knobColorHover)   // scroller knob tracks the theme too
    }

    /// Paint the thin overlay scroller with the shared knob tokens (VGTokens.scrollerKnob/Hover
    /// = the sidebar session selected-state wash), so the launcher field matches every other bar.
    private static func styleScroller(_ scroll: NSScrollView, knob: NSColor, hover: NSColor) {
        (scroll.verticalScroller as? VGThinScroller)?.setColors(knob, hover)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView,
                      context: Context) -> CGSize? {
        guard let tv = scroll.documentView as? PromptNSTextView else { return nil }
        let w: CGFloat = {
            guard let pw = proposal.width, pw.isFinite, pw > 0 else {
                return max(scroll.bounds.width, 200)   // probe round (unspecified/∞): give a stable answer
            }
            return pw
        }()
        return CGSize(width: w,
                      height: Self.fittedHeight(measured: Self.measuredHeight(tv, width: w),
                                                min: minHeight, max: maxHeight))
    }

    /// Programmatic assignment (prefill, clear-on-submit): write the full text and place the
    /// cursor at the end — typing after a prefill appends. After height clamping, a long
    /// prefill may exceed one screen: scroll to the cursor to keep the "position where typing
    /// continues" visible.
    static func sync(_ tv: NSTextView, to text: String) {
        tv.string = text
        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
    }

    /// The layout height of the full text at a given width. TextKit-1 directly reuses the
    /// cache for un-invalidated paragraphs, so a per-keystroke call only re-lays-out the
    /// paragraph the edit point is in (performance acceptance line, pinned by
    /// LauncherPromptTests).
    static func measuredHeight(_ tv: NSTextView, width: CGFloat) -> CGFloat {
        guard let container = tv.textContainer, let lm = tv.layoutManager else { return 0 }
        if abs(container.size.width - width) > 0.5 {
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        lm.ensureLayout(for: container)
        // the height of an empty document / trailing empty line lives in extraLineFragment,
        // usedRect doesn't include it
        let h = max(lm.usedRect(for: container).height, lm.extraLineFragmentRect.height)
        return ceil(h)
    }

    private func applyStyle(_ tv: PromptNSTextView) {
        let font = NSFont.systemFont(ofSize: Self.fontSize)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = Self.fontSize * 0.35
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor, .paragraphStyle: para,
        ]
        tv.font = font
        tv.defaultParagraphStyle = para
        tv.typingAttributes = attrs
        tv.insertionPointColor = textColor
        if tv.textColor != textColor {
            tv.textColor = textColor
            if let storage = tv.textStorage, storage.length > 0 {
                storage.addAttributes(attrs, range: NSRange(location: 0, length: storage.length))
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }

        // The Return family (submit/newline) is fully dispatched in PromptNSTextView.keyDown
        // (see the interaction contract in the file header) rather than via doCommandBy — here
        // we only handle Tab/⇧Tab focus movement.
        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                tv.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                tv.window?.selectPreviousKeyView(nil)
                return true
            default:
                return false
            }
        }
    }
}

/// Customized NSTextView: explicit TextKit-1 stack (incremental layout is the entire point,
/// guarding against the measurement ambiguity of a lazy TextKit-2 fallback) + auto
/// grab focus on first entry into a window (snapshot
/// off-screen rendering has no window, so it naturally doesn't trigger).
final class PromptNSTextView: NSTextView {
    private var wantsInitialFocus = true

    /// The submit closure triggered by plain Return (= launcher.submit).
    var onSubmit: (() -> Void)?

    /// The dispatch decision for the Return family (pure function, T1a-assertable, no need to
    /// build an NSEvent):
    ///   Enter = submit; ⇧/⌘/⌥ + Enter = newline; any other key = pass through to the default
    ///   input path.
    enum ReturnAction: Equatable { case submit, newline, passthrough }

    static func returnAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> ReturnAction {
        guard keyCode == 36 || keyCode == 76 else { return .passthrough }  // 36=Return 76=keypad Enter
        let m = modifiers.intersection(.deviceIndependentFlagsMask)
        if m.contains(.shift) || m.contains(.command) || m.contains(.option) { return .newline }
        return .submit
    }

    override func keyDown(with event: NSEvent) {
        switch effectiveReturnAction(keyCode: event.keyCode, modifiers: event.modifierFlags) {
        case .submit:      onSubmit?()
        case .newline:     insertNewlineIgnoringFieldEditor(self)
        case .passthrough: super.keyDown(with: event)
        }
    }

    /// The Return dispatch as it actually fires in keyDown, folding in live IME state on top of
    /// the pure keyCode/modifier decision.
    ///
    /// Typing English letters under a Chinese input
    /// method leaves marked (pre-edit) text; the Return that *confirms* that composition must
    /// go to confirming it, never to launcher submit/newline. hasMarkedText() stays true from
    /// the first composing keystroke until the IME commits, so that confirming Return lands
    /// here as `.passthrough` → super.keyDown routes it to the input context, which consumes it
    /// to commit the composition (insertNewline: never fires). Only the *next* Return, after
    /// composition has ended and marked text is gone, submits. During composition every key is
    /// passthrough anyway, so guarding all of them (not just Return) is both correct and the
    /// simplest honest statement of "the IME owns the keyboard while composing".
    ///
    /// Separated from the pure `returnAction` so this IME-aware branch is unit-testable against
    /// real marked-text state (assert the dispatch decision, not just the action
    /// body).
    func effectiveReturnAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> ReturnAction {
        if hasMarkedText() { return .passthrough }
        return Self.returnAction(keyCode: keyCode, modifiers: modifiers)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsInitialFocus, window != nil else { return }
        wantsInitialFocus = false
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    // MARK: files/images → attachment chips

    override func paste(_ sender: Any?) {
        if handleIngestPaste(.general, mode: .paste) { return }
        super.paste(sender)
    }

    /// ⌘V is the key equivalent for the main-menu Edit>Paste, and before
    /// dispatch AppKit first passes through this validation here — a plain-text NSTextView's
    /// readablePasteboardTypes doesn't include image types, so an image-only clipboard
    /// disables the Paste item and the paste(_:) override above is never called at all
    /// (observed = "paste does nothing"). Any content the normalization layer can consume
    /// (file/image, same decision as drag) must have Paste enabled; everything else is handed
    /// back to default validation, and an empty clipboard is disabled as before.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)), wantsIngest(.general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    /// true = consumed by this layer (files/images become chips, or an over-limit image is
    /// rejected); false = plain text takes the default path. The decision order is the same
    /// normalization layer as the terminal side (PasteIngest: files > text > bare image).
    func handleIngestPaste(_ pb: NSPasteboard, mode: PasteIngestMode) -> Bool {
        switch PasteIngest.nonTextIngest(pb, mode: mode) {
        case .fileURLs(let urls): attachChips(for: urls); return true
        case .rejectedImage: NSSound.beep(); return true
        case nil: return false
        }
    }

    /// Insert a chip at the cursor (one U+FFFC attachment char + a separating space):
    /// delete/select/cursor semantics come for free, and at submit expandedText expands it
    /// into an escaped path.
    func attachChips(for urls: [URL]) {
        guard let storage = textStorage else { return }
        let insertion = NSMutableAttributedString()
        for url in urls {
            insertion.append(NSAttributedString(attachment: PromptAttachment(fileURL: url)))
            insertion.append(NSAttributedString(string: " ", attributes: typingAttributes))
        }
        let range = selectedRange()
        // replacementString must be the actual inserted string: nil = "attribute-only
        // change", and undo would be registered as an attribute rollback while the document
        // length has already changed — Cmd+Z can't undo the chip and the undo stack is
        // misaligned from then on.
        guard shouldChangeText(in: range, replacementString: insertion.string) else { return }
        storage.replaceCharacters(in: range, with: insertion)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + insertion.length, length: 0))
    }

    /// The full text used for submission: chip → submissionText (escaped path), everything
    /// else verbatim.
    func expandedText() -> String {
        guard let storage = textStorage, storage.length > 0 else { return string }
        var out = ""
        let ns = storage.string as NSString
        storage.enumerateAttribute(.attachment,
                                   in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            if let chip = value as? PromptAttachment {
                out += chip.submissionText
            } else {
                out += ns.substring(with: range)
            }
        }
        return out
    }

    /// Rebuild chips from a cached draft: `text` carries one U+FFFC placeholder per chip
    /// (left-to-right), `attachments` supplies the matching URLs in the same order — the
    /// reconstruction a restored launcher draft needs, since chips exist only in this
    /// view's NSTextStorage, never in a plain string (see `currentAttachmentURLs` below,
    /// its snapshot-side counterpart).
    func restoreDraft(text: String, attachments: [URL]) {
        guard let storage = textStorage else { return }
        let result = NSMutableAttributedString()
        var pending = attachments[...]
        for scalar in text.unicodeScalars {
            if scalar == Unicode.Scalar(0xFFFC), let url = pending.first {
                pending = pending.dropFirst()
                result.append(NSAttributedString(attachment: PromptAttachment(fileURL: url)))
            } else {
                result.append(NSAttributedString(string: String(scalar), attributes: typingAttributes))
            }
        }
        storage.setAttributedString(result)
        didChangeText()
        let end = NSRange(location: (string as NSString).length, length: 0)
        setSelectedRange(end)
        scrollRangeToVisible(end)
    }

    /// Ordered attachment URLs walking this document's chips left-to-right — read before
    /// this view is torn down (LauncherView.onDisappear) to snapshot a launcher draft,
    /// since chips exist only here. Paired with `restoreDraft` above.
    func currentAttachmentURLs() -> [URL] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        var urls: [URL] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) {
            value, _, _ in
            if let chip = value as? PromptAttachment { urls.append(chip.localURL) }
        }
        return urls
    }

    // Drag uses the same normalization: files/images → chips; everything else passes through
    // to default text drag-drop.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        wantsIngest(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        wantsIngest(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if handleIngestPaste(sender.draggingPasteboard, mode: .drop) { return true }
        return super.performDragOperation(sender)
    }

    /// The normalization layer's consumability test (file/image), shared by the drag cursor
    /// and the paste-menu validation as one criterion.
    private func wantsIngest(_ pb: NSPasteboard) -> Bool {
        if !PasteIngest.fileURLs(from: pb).isEmpty { return true }
        return (pb.types ?? []).contains {
            UTType($0.rawValue)?.conforms(to: .image) == true
        }
    }

    static func make() -> PromptNSTextView {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let container = NSTextContainer(size: NSSize(width: 0,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0          // text origin = view origin, aligned with the old TextField
        lm.addTextContainer(container)

        let tv = PromptNSTextView(frame: .zero, textContainer: container)
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 0)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.allowsUndo = true
        // task briefs often contain code/paths: plain-text paste + turn off all automatic
        // substitutions (consistent with the old field editor)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.usesFontPanel = false
        tv.usesFindBar = false
        // A plain-text NSTextView doesn't accept file/image drags by default —
        // register additionally (append, don't override the default text types; paste doesn't
        // go through here, it goes through the paste override).
        tv.registerForDraggedTypes(tv.registeredDraggedTypes + [.fileURL, .png, .tiff])
        return tv
    }

    /// The internal-scroll host for long text. A bare NSTextView with no
    /// enclosingScrollView can only blow out the card when it grows too tall; wrapped in a
    /// transparent NSScrollView (overlay scroller appears on demand, no border), the
    /// representable clamps the height at maxHeight, the overflow scrolls internally, and
    /// NSTextView's built-in "scroll to follow the cursor on keystroke" takes effect for free.
    static func makeScrollable() -> NSScrollView {
        let tv = make()
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .automatic
        scroll.scrollerStyle = .overlay            // thin overlay scroller, unified app-wide
        let thin = VGThinScroller()
        thin.scrollerStyle = .overlay
        scroll.verticalScroller = thin
        scroll.documentView = tv
        return scroll
    }
}

/// The attachment chip in the input field. One chip = one attachment char
/// (U+FFFC) — delete, select, and cursor semantics all come for free; display = an
/// icon+filename capsule (appearance-adaptive, the drawingHandler paints on the spot per the
/// current appearance); submit = submissionText (the shell-escaped original path / on-disk
/// path).
final class PromptAttachment: NSTextAttachment {
    let localURL: URL
    let submissionText: String

    init(fileURL: URL) {
        let url = fileURL.standardizedFileURL
        self.localURL = url
        self.submissionText = PasteIngest.shellEscaped(url.path)
        super.init(data: nil, ofType: nil)
        let chip = Self.chipImage(for: url)
        image = chip
        // lower the baseline so the capsule is vertically centered with the 14pt body text
        bounds = NSRect(x: 0, y: -5, width: chip.size.width, height: chip.size.height)
    }

    required init?(coder: NSCoder) { nil }

    static func chipImage(for url: URL) -> NSImage {
        let name: String = {
            let full = url.lastPathComponent
            return full.count > 28 ? String(full.prefix(27)) + "…" : full
        }()
        let font = NSFont.systemFont(ofSize: 12)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let iconSide: CGFloat = 14, padX: CGFloat = 6, gap: CGFloat = 4, height: CGFloat = 20
        let nameWidth = ceil((name as NSString).size(withAttributes: [.font: font]).width)
        let size = NSSize(width: padX + iconSide + gap + nameWidth + padX, height: height)

        return NSImage(size: size, flipped: false) { rect in
            let capsule = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                       xRadius: rect.height / 2, yRadius: rect.height / 2)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            capsule.fill()
            NSColor.labelColor.withAlphaComponent(0.16).setStroke()
            capsule.lineWidth = 1
            capsule.stroke()

            icon.draw(in: NSRect(x: padX, y: (height - iconSide) / 2,
                                 width: iconSide, height: iconSide))
            let baseline = (height - font.capHeight) / 2 - abs(font.descender) / 2
            (name as NSString).draw(
                at: NSPoint(x: padX + iconSide + gap, y: max(baseline, 3)),
                withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
            return true
        }
    }
}
