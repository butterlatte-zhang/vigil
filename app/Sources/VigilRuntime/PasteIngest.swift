// Paste/drop normalization layer.
//
// The only wire format = disk path text: files from the clipboard/drop use their original
// path, bare images are written to disk as temp files, and everything enters agent input
// as shell-escaped text — no API attachment, no base64.
// A path fed into the PTY via bracketed paste is recognized by claude as [Image #N],
// without needing to touch the system clipboard.
//
// Three consumers:
//   · Terminal Cmd+V — the vendored readClipboard callback asks here via
//     TerminalClipboardReadHook (installTerminalHook, installed at AppModel startup);
//     plain text returns nil = original path, zero change.
//   · launcher input field — PromptNSTextView paste/drop override takes fileURLs and turns
//     them into attachment chips.
//   · Terminal drop — TerminalHost takes dropPlan and injects (multiple local images fed
//     one at a time in 2s segments; a single real paste only turns one path into one
//     [Image #N] for claude).

#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import VigilGhosttyTerminal

public enum PasteIngestMode { case paste, drop }

public enum PasteIngest {
    /// Normalization result for non-text content; nil = not ours to handle, hand back to
    /// the plain-text default path.
    public enum NonText: Equatable {
        case fileURLs([URL])
        /// The clipboard does hold an image but it's unusable (over limit / failed to write
        /// to disk): swallow the entire paste — for such a clipboard there is no reasonable
        /// fallback to "paste text instead".
        case rejectedImage
    }

    /// Decision order: ① clipboard has files → use paths;
    /// ② in paste mode there is text → let the default path paste the text; ③ bare image
    /// data → write to disk as a file. Drop mode ignores text (files/images dragged in are
    /// meant to be used as files).
    public static func nonTextIngest(_ pb: NSPasteboard, mode: PasteIngestMode,
                                     store: PasteImageStore = .shared) -> NonText? {
        let urls = fileURLs(from: pb)
        if !urls.isEmpty { return .fileURLs(urls) }
        if mode == .paste, let s = pb.string(forType: .string), !s.isEmpty { return nil }
        switch store.materializeImages(from: pb, limit: mode == .paste ? 1 : Int.max) {
        case .saved(let files): return .fileURLs(files)
        case .rejected: return .rejectedImage
        case .none: return nil
        }
    }

    /// The terminal Cmd+V hook body: files/images → escaped path text; everything else nil
    /// (fall back to reading .string, zero behavior change). rejectedImage also returns nil —
    /// such a clipboard has no pasteable text to begin with.
    public static func terminalPasteReplacement(_ pb: NSPasteboard,
                                                store: PasteImageStore = .shared) -> String? {
        switch nonTextIngest(pb, mode: .paste, store: store) {
        case .fileURLs(let urls): return insertedText(forFileURLs: urls)
        case .rejectedImage, nil: return nil
        }
    }

    /// Install the hook into the vendored callback seam. Installed once at app startup
    /// (AppModel.init).
    public static func installTerminalHook(store: PasteImageStore = .shared) {
        TerminalClipboardReadHook.transform = { pb in
            terminalPasteReplacement(pb, store: store)
        }
    }

    // MARK: - Injection plan for terminal drop

    public enum PastePlan: Equatable {
        case insertText(String)
        /// Multiple local images: injected segment by segment, the inter-segment gap gives
        /// claude time to turn the previous path into [Image #N].
        case insertTextSegments([String], interSegmentDelay: TimeInterval)
    }

    /// Terminal drop: files/images → paths (multiple images segmented); otherwise URL/text
    /// fallback. nil = nothing to inject.
    public static func dropPlan(_ pb: NSPasteboard,
                                store: PasteImageStore = .shared) -> PastePlan? {
        switch nonTextIngest(pb, mode: .drop, store: store) {
        case .fileURLs(let urls): return plan(fileURLs: urls)
        case .rejectedImage: return nil
        case nil: break
        }
        if let raw = pb.string(forType: .URL), !raw.isEmpty { return .insertText(shellEscaped(raw)) }
        if let s = pb.string(forType: .string), !s.isEmpty { return .insertText(s) }
        return nil
    }

    static func plan(fileURLs urls: [URL]) -> PastePlan {
        if urls.count > 1, urls.allSatisfy(isLocalImageFile) {
            let segments = urls.map(\.path).map(shellEscaped).enumerated()
                .map { $0.offset == 0 ? $0.element : " " + $0.element }
            return .insertTextSegments(segments, interSegmentDelay: 2.0)
        }
        return .insertText(insertedText(forFileURLs: urls))
    }

    private static func isLocalImageFile(_ url: URL) -> Bool {
        let u = url.standardizedFileURL
        guard u.isFileURL,
              (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let type = UTType(filenameExtension: u.pathExtension),
              type.conforms(to: .image) else { return false }
        return true
    }

    // MARK: - pasteboard file reading

    /// Read uniformly from three sources (modern NSURL, legacy filenames, bare fileURL
    /// string), deduplicated by path.
    public static func fileURLs(from pb: NSPasteboard) -> [URL] {
        var found: [URL] = []
        let objects = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) ?? []
        for case let url as URL in objects where url.isFileURL {
            found.append(url.standardizedFileURL)
        }
        let legacy = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pb.propertyList(forType: legacy) as? [String] {
            found += paths.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0).standardizedFileURL }
        }
        if let raw = pb.string(forType: .fileURL), let url = URL(string: raw), url.isFileURL {
            found.append(url.standardizedFileURL)
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.path).inserted }
    }

    // MARK: - Injected text

    public static func insertedText(forFileURLs urls: [URL]) -> String {
        urls.map(\.path).map(shellEscaped).joined(separator: " ")
    }

    /// Escaping applied to a path before injecting it into the terminal as shell input. A
    /// newline can't be expressed with a backslash (the line editor treats it as a submit
    /// key and splits the input into two pieces), so any value containing a newline goes
    /// through POSIX single quotes as a whole; other values get a backslash per shell
    /// metacharacter (the path body stays visually readable).
    public static func shellEscaped(_ value: String) -> String {
        guard !value.contains("\n"), !value.contains("\r") else {
            return posixSingleQuoted(value)
        }
        var out = String()
        out.reserveCapacity(value.count)
        for ch in value {
            if isShellSpecial(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private static func posixSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Shell metacharacter test, grouped by semantics (POSIX sh + the extension surface of
    /// common interactive shells).
    private static func isShellSpecial(_ ch: Character) -> Bool {
        switch ch {
        case " ", "\t":                                    return true  // word splitting
        case "'", "\"", "`", "\\":                         return true  // quoting and escaping
        case "$", "!", "#", "&", ";", "|":                 return true  // expansion/history/comment/control
        case "(", ")", "{", "}", "[", "]", "<", ">":       return true  // grouping/brace expansion/glob/redirection
        case "*", "?":                                     return true  // path globbing
        default:                                           return false
        }
    }
}

// MARK: - Image-to-disk service

/// Clipboard image → temp file: decode order is per-item direct read → RTFD attachment →
/// NSImage fallback, TIFF is always normalized to PNG, a 10MB limit is explicitly rejected;
/// files written to disk are registered as owned, and cleanup only touches files we wrote
/// ourselves.
/// Process singleton (PasteIngest's entry points default to .shared); tests inject a
/// scratch directory.
public final class PasteImageStore: @unchecked Sendable {
    public static let shared = PasteImageStore()
    public static let maxImageBytes = 10 * 1024 * 1024

    public let directory: URL
    private let lock = NSLock()
    private var owned: Set<String> = []

    public init(directory: URL = FileManager.default.temporaryDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public enum Materialization: Equatable {
        case saved([URL])
        case rejected      // a real image exists but is unusable (over limit / write failed)
        case none          // no decodable image on the clipboard
    }

    public func materializeImages(from pb: NSPasteboard, limit: Int = .max) -> Materialization {
        let reps = Array(imageRepresentations(in: pb).prefix(limit))
        guard !reps.isEmpty else { return .none }
        var files: [URL] = []
        for rep in reps {
            guard rep.data.count <= Self.maxImageBytes, let url = persist(rep) else {
                cleanup(files)             // batch atomicity: if one fails, reclaim all already written
                return .rejected
            }
            files.append(url)
        }
        return .saved(files)
    }

    /// Write a single image to disk + register as owned; on write failure clean up the
    /// half-finished file and return nil.
    private func persist(_ rep: (data: Data, ext: String)) -> URL? {
        let url = newFileURL(ext: rep.ext)
        do {
            try rep.data.write(to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        register(url)
        return url
    }

    // MARK: owned registration and cleanup

    public func isOwned(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        return owned.contains(path)
    }

    /// Only delete files we wrote to disk and still own (consumes ownership).
    public func cleanup(_ urls: [URL]) {
        for url in urls {
            let u = url.standardizedFileURL
            guard u.isFileURL, consume(u) else { continue }
            try? FileManager.default.removeItem(at: u)
        }
    }

    public func cleanupAll() {
        lock.lock()
        let paths = owned
        owned.removeAll()
        lock.unlock()
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
    }

    private func register(_ url: URL) {
        let path = url.standardizedFileURL.path
        lock.lock(); owned.insert(path); lock.unlock()
    }

    private func consume(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        return owned.remove(path) != nil
    }

    // MARK: Decode (direct read → RTFD attachment → NSImage fallback; TIFF→PNG)

    func imageRepresentations(in pb: NSPasteboard) -> [(data: Data, ext: String)] {
        let perItem = (pb.pasteboardItems ?? []).compactMap { item in
            directRepresentation(types: item.types, data: { item.data(forType: $0) })
        }
        if !perItem.isEmpty { return perItem }
        if let direct = directRepresentation(types: pb.types ?? [],
                                             data: { pb.data(forType: $0) }) {
            return [direct]
        }
        let rtfd = rtfdAttachmentRepresentations(pb.data(forType: .rtfd))
        if !rtfd.isEmpty { return rtfd }
        if let fallback = nsImageFallback(pb) { return [fallback] }
        return []
    }

    private func directRepresentation(
        types: [NSPasteboard.PasteboardType],
        data: (NSPasteboard.PasteboardType) -> Data?
    ) -> (data: Data, ext: String)? {
        if types.contains(.png), let d = data(.png) { return (d, "png") }
        for type in types where type != .png {
            guard let ut = UTType(type.rawValue), ut.conforms(to: .image),
                  let d = data(type) else { continue }
            if ut.conforms(to: .tiff) { return pngNormalized(d) }
            guard let ext = ut.preferredFilenameExtension, !ext.isEmpty else { continue }
            return (d, ext)
        }
        return nil
    }

    /// Images in rich text (copied from Notes/browser) are hidden inside RTFD as
    /// NSTextAttachment.
    private func rtfdAttachmentRepresentations(_ data: Data?) -> [(data: Data, ext: String)] {
        guard let data,
              let attr = try? NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                documentAttributes: nil) else { return [] }
        var out: [(data: Data, ext: String)] = []
        attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length)) {
            value, _, _ in
            guard let att = value as? NSTextAttachment,
                  let wrapper = att.fileWrapper,
                  let d = wrapper.regularFileContents,
                  let rep = self.attachmentRepresentation(d, filename: wrapper.preferredFilename)
            else { return }
            out.append(rep)
        }
        return out
    }

    private func attachmentRepresentation(_ data: Data,
                                          filename: String?) -> (data: Data, ext: String)? {
        let ext = ((filename ?? "") as NSString).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            if type.conforms(to: .tiff) { return pngNormalized(data) }
            return (data, type.preferredFilenameExtension ?? ext)
        }
        // filename not trustworthy → let CGImageSource sniff the real type
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let id = CGImageSourceGetType(source) as String?,
              let type = UTType(id), type.conforms(to: .image),
              let sniffed = type.preferredFilenameExtension else { return nil }
        if type.conforms(to: .tiff) { return pngNormalized(data) }
        return (data, sniffed)
    }

    private func nsImageFallback(_ pb: NSPasteboard) -> (data: Data, ext: String)? {
        guard NSImage.canInit(with: pb),
              let tiff = NSImage(pasteboard: pb)?.tiffRepresentation else { return nil }
        return pngNormalized(tiff)
    }

    /// Uniformly convert bitmaps to PNG. Before transcoding, read the pixel dimensions
    /// without decoding (CGImageSource only parses the header) to set a budget — a
    /// decompression-bomb TIFF is rejected before paying the cost of a full decode +
    /// re-encode (a multi-second main-thread stall + memory spike). The normal path
    /// (≤ budget) is unchanged.
    private func pngNormalized(_ data: Data) -> (data: Data, ext: String)? {
        guard pixelCount(of: data) <= Self.maxPixels,
              let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, "png")
    }

    /// Pixel budget: ~50MP (8K class). A full 5K screen capture ≈15MP, ample margin.
    static let maxPixels = 50_000_000

    /// Read pixel dimensions by parsing the header, never triggering a full decode; if the
    /// dimensions can't be read, treat as over-limit (better to reject than blindly decode).
    private func pixelCount(of data: Data) -> Int {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return .max }
        return w * h
    }

    // MARK: Naming

    /// On-disk name = fixed prefix + second-granularity timestamp + 8-char random segment +
    /// whitelisted extension: readable to the agent, unique under concurrency, and carrying
    /// no original string from the clipboard.
    private func newFileURL(ext: String) -> URL {
        let stamp = UInt64(Date().timeIntervalSince1970)
        let nonce = UUID().uuidString.prefix(8).lowercased()
        return directory.appendingPathComponent("clipboard-\(stamp)-\(nonce).\(sanitizedExt(ext))")
    }

    private static let knownImageExts: Set<String> =
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp"]

    /// The extension is only accepted from the whitelist — it is spliced into the filename,
    /// and the source (clipboard/RTFD filename) is untrustworthy; TIFF has already been
    /// normalized to PNG upstream, so it's not on the list.
    private func sanitizedExt(_ raw: String) -> String {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.knownImageExts.contains(candidate) ? candidate : "png"
    }
}
#endif
