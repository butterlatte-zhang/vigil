import Foundation

/// The host-side VT parser that makes `renderScreen()` work even
/// when there is NO live surface (deep display sleep + lock refuses the Metal renderer).
/// The dark-screen scrape blind spot (PLAN §1.1) is closed HERE: every byte the
/// host PTY reads is fed into this parser, which owns the scrape screen state
/// independently of any surface. `renderScreen()` reads THIS, not `surface.readViewportText()`.
///
/// The parser is a libghostty-vt `VtScreen` that also backs `HeadlessBackend` and every §12
/// scrape measurement — so the view backend and the headless backend scrape from one engine
/// (PLAN invariant ⑦: a single scrape source, same libghostty family as the visible surface).
/// It also owns the screen STATE that surface attach reads: when a surface attaches late
/// (screen woke), `synthesize()` regenerates a clean VT stream from the current
/// grid+scrollback and replays it so the display catches up. State synthesis is
/// volume-independent and cannot truncate, unlike a bounded byte ring whose head-truncation
/// would lose a long-lived cell's early frame.
///
/// Zero surface / zero Metal / zero AppKit — a plain `VtScreen` fed on a private serial
/// queue, so `swift test` can drive it against real forkpty'd bytes (see
/// HostScrapeIntegrationTests). The `VtScreen` is confined to `queue`; every access
/// (feed / render / mode read / resize / snapshot) hops through it. Terminal responses
/// (DA/DSR/DECRQM …) are inert: `VtScreen` registers no effects, so this shadow parser never
/// answers the child (the ghostty SURFACE owns replies to the PTY; double replies would corrupt).
final class HostScreenParser: @unchecked Sendable {

    /// Serial queue the emulator is confined to — feed/render/resize/mode-read all hop
    /// here, so the non-Sendable `VtScreen` is never touched concurrently. FIFO ordering
    /// means a `renderScreen()` after a `feed()` always observes that feed.
    private let queue = DispatchQueue(label: "vigil.hostpty.parse")
    private let terminal: VtScreen

    init(cols: Int, rows: Int) {
        terminal = VtScreen(cols: cols, rows: rows)
    }

    /// Feed one chunk of PTY output into the scrape parser. Called from the host PTY read
    /// queue (serial) — the async hop preserves order.
    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            terminal.feed([UInt8](data))
        }
    }

    /// The visible grid as text — the ONE scrape source (§12.3 semantics via renderGrid).
    func renderScreen() -> String {
        queue.sync { terminal.renderScreen() }
    }

    /// The visible grid WITH per-cell dim (SGR 2) — same queue.sync discipline
    /// (never mid-mutation), same §12.3 text, index-aligned dim mask. The input-line
    /// probe reads this to distinguish claude's dim placeholder from real user typing. dim is
    /// live here because the scrape source is the libghostty-vt `VtScreen` whose per-cell
    /// `GhosttyStyle.faint` is a first-class field.
    func renderAttributed() -> AttributedScreen {
        queue.sync { terminal.renderAttributed() }
    }

    /// The DEC mode truth for bracketed-paste injection, read on the feed queue so
    /// it is never sampled mid-mutation (same rule as HeadlessBackend.send).
    var bracketedPasteMode: Bool {
        queue.sync { terminal.bracketedPasteMode }
    }

    /// mode-2031 dark-cell notification: the DEC mode 2031 truth (agent subscribed to
    /// unsolicited color-scheme reports), read on the feed queue with the same discipline
    /// as `bracketedPasteMode`. Read-only — this never touches parse semantics.
    var colorSchemeReportMode: Bool {
        queue.sync { terminal.colorSchemeReportMode }
    }

    /// Keep the shadow grid the same size as the real PTY (driven off the surface's
    /// resize, mirrored to HostPTY) so wrapping/footer detection matches what the child
    /// actually drew.
    func resize(cols: Int, rows: Int) {
        queue.async { [self] in terminal.resize(cols: max(1, cols), rows: max(1, rows)) }
    }

    // MARK: - Attach synthesis (the surface-attach display source)

    /// Snapshot the parser screen STATE for `AttachScreenSynthesizer`. `queue.sync` so the
    /// `VtScreen` is never touched off its serial queue (same discipline as `renderScreen`).
    func snapshot() -> ScreenSnapshot {
        queue.sync { terminal.snapshot() }
    }

    /// Synthesize a clean attach VT stream (clear → scrollback → active grid → cursor) from
    /// screen STATE — the surface-attach display source. Volume-independent, so it can never
    /// head-truncate: a long-lived cell's early frame and scrollback survive regardless of how
    /// much output scrolled past. Called at the attach cut point on the PTY read queue;
    /// `queue.sync` drains all feeds enqueued before it, so the snapshot captures exactly the
    /// bytes fed up to that instant (INV3).
    func synthesize() -> Data {
        queue.sync { AttachScreenSynthesizer.serialize(terminal.snapshot()) }
    }

    /// Run `block` after every feed enqueued so far has been parsed. Used at child exit
    /// to flush in-flight bytes into the grid before the final screen is observed
    /// (HostPTY.onExit can outrun the tail of the read queue).
    func afterPending(_ block: @escaping () -> Void) {
        queue.async { block() }
    }
}
