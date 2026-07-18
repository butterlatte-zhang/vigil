import Foundation
import VigilCore

// L3 transport plumbing (DOCTRINE §4/§5.4), written as pure logic over an abstract
// newline-delimited duplex `LineChannel` so the protocol handlers are deterministically
// unit-testable: tests use an in-memory PipeLineChannel; production uses a
// UDS-backed SocketLineChannel. The accept loop is thin glue, exercised by vigil-smoke.

/// A bidirectional newline-delimited message channel. `readLine()` returns nil on EOF.
public protocol LineChannel: AnyObject, Sendable {
    func readLine() async -> String?
    func write(_ line: String) async
    func close() async
}

// MARK: - In-memory channel (tests)

/// An async FIFO of lines with EOF — the backbone of the in-memory pipe.
public actor AsyncLineQueue {
    private var buffer: [String] = []
    private var waiters: [CheckedContinuation<String?, Never>] = []
    private var closed = false

    public init() {}

    public func put(_ s: String) {
        if !waiters.isEmpty { waiters.removeFirst().resume(returning: s) }
        else { buffer.append(s) }
    }
    public func take() async -> String? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }
    public func close() {
        closed = true
        for w in waiters { w.resume(returning: nil) }
        waiters.removeAll()
    }
}

/// An in-memory LineChannel endpoint. `pair()` returns the two ends of one pipe:
/// what one end writes, the other reads.
public final class PipeLineChannel: LineChannel, @unchecked Sendable {
    private let inQ: AsyncLineQueue
    private let outQ: AsyncLineQueue
    init(inQ: AsyncLineQueue, outQ: AsyncLineQueue) { self.inQ = inQ; self.outQ = outQ }

    public func readLine() async -> String? { await inQ.take() }
    public func write(_ line: String) async { await outQ.put(line) }
    public func close() async { await outQ.close() }

    public static func pair() -> (PipeLineChannel, PipeLineChannel) {
        let q1 = AsyncLineQueue(); let q2 = AsyncLineQueue()
        return (PipeLineChannel(inQ: q1, outQ: q2), PipeLineChannel(inQ: q2, outQ: q1))
    }
}

// MARK: - Pending replies (the blocking-request registry, DOCTRINE §6.1)

/// Each blocking MCP/hook call awaits its `replyID` here; `deliver(...)` (driven by the
/// human's decision through the store's Effect) resolves it. Buffers a resolution that
/// arrives before the waiter registers (gate auto-resolve / fast paths), and enforces
/// deliver-once (§6.4) as a second line of defense alongside SessionStore.
public actor PendingReplies {
    private enum State { case waiting(CheckedContinuation<Resolution, Never>); case delivered(Resolution) }
    private var map: [UUID: State] = [:]

    public init() {}

    public func wait(_ id: UUID) async -> Resolution {
        if case .delivered(let r)? = map[id] { map[id] = nil; return r }
        return await withCheckedContinuation { c in map[id] = .waiting(c) }
    }
    public func deliver(_ id: UUID, _ r: Resolution) {
        switch map[id] {
        case .waiting(let c): map[id] = nil; c.resume(returning: r)
        case .delivered: break                       // once
        case nil: map[id] = .delivered(r)            // arrived before the waiter
        }
    }
}

// MARK: - JSON helpers (Foundation, dynamic — MCP/hook payloads are loosely typed)

/// The jsonl single-line codec: every "one line → dict" parse in the repo goes
/// through here — gateways, SessionArchive.replay, and the app-side transcript
/// readers (AutoNamer / TranscriptRender). Public so VigilApp can share it
/// instead of inlining a duplicate copy.
public enum JSONLine {
    /// Parse one line into a dictionary, or nil if it isn't a JSON object.
    public static func parse(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }
    /// Serialize a dictionary to a single compact line (no embedded newlines).
    static func dump(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s.replacingOccurrences(of: "\n", with: " ")
    }
}
