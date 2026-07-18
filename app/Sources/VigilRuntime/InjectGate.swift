import Foundation

/// The injection-window keystroke gate (gate + replay).
///
/// PROBLEM (inject merging with a half-typed line):
/// `RealCell.probeInputLine` guards the STANDING content before an inject (probe → hold).
/// But between the probe passing and the CR actually landing (`send(body)` + 150ms settle +
/// `send("\r")` ≈ 200ms) the human can start typing, and those NEW keystrokes splice into
/// the injected line. This gate closes that ~200ms window.
///
/// WHERE IT SITS: the host-side choke point — `GhosttyViewBackend`'s `write:` closure, the
/// ONE place three byte streams merge with no origin tag:
///   ① Vigil injection   ② direct hardware keys (sendInput)   ③ surface keys + protocol
///   replies (DA/DSR, receiveBufferCallback). ② and ③ share seams with ① and each other, so
///   they cannot be told apart at the seam. Instead: Vigil injection is routed AROUND the gate
///   (`injectDirect`, never buffered), and everything arriving through the gated `write:`
///   closure during an open window is user/protocol bytes → buffered and replayed AFTER the
///   injected CR, so the human's keystrokes land on claude's NEXT (empty) input line intact.
///
/// RED LINES:
///   ① Only buffers RAW bytes and only DELAYS them — never rewrites, since Vigil never takes
///     over user input.
///   ② The window is bounded by begin()/end() = the actual inject sequence; the hold poll runs
///     BEFORE begin() (probe said userTyping → wait), so the gate is closed then and the human
///     types straight through — RealCell only opens the window once it commits to inject.
///   ③ Orthogonal to RealCell's FIFO (`injectTail`) and hold epoch (`holdSeq`): this is the
///     backend write layer, it touches neither.
///
/// Headless & unit-testable: zero surface/AppKit, `toPTY` is the only outward edge (a stand-in
/// for `hostPTY.write` in prod, a recorder in tests). Thread-safe via a lock even though in
/// prod every call funnels through the main thread (sendInput/receiveBufferCallback fire on
/// main, begin/end/injectDirect hop to main) — the lock keeps ordering correct regardless.
public final class InjectGate: @unchecked Sendable {
    private let lock = NSLock()
    private let toPTY: (Data) -> Void
    private var injecting = false
    private var buffer: [Data] = []

    public init(toPTY: @escaping (Data) -> Void) { self.toPTY = toPTY }

    /// The gated entry point — user/protocol bytes arriving at the `write:` choke point.
    /// Window closed → straight through; window open → buffered in arrival order (raw, unchanged).
    public func ingest(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if injecting { buffer.append(data) } else { toPTY(data) }
    }

    /// Vigil injection bytes — ALWAYS written immediately, never buffered (bypasses the gate).
    /// `hostPTY.write` is surface-independent host-direct output, so this is byte-equivalent to
    /// the old `session.sendInput` path; echo still comes back via the child PTY → surface.
    public func injectDirect(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        toPTY(data)
    }

    /// Open the injection window. Idempotent: begin() while already open is a no-op.
    public func begin() {
        lock.lock(); defer { lock.unlock() }
        injecting = true
    }

    /// Close the window: flush the buffered user/protocol bytes to the PTY IN ARRIVAL ORDER
    /// (landing AFTER the injected CR that preceded end()), then clear. Idempotent: end()
    /// without a matching begin() flushes an empty buffer and leaves the window closed.
    /// The flush runs under `lock` so a concurrent ingest cannot splice between buffered writes.
    public func end() {
        lock.lock(); defer { lock.unlock() }
        let pending = buffer
        buffer.removeAll()
        injecting = false
        for d in pending { toPTY(d) }
    }
}
