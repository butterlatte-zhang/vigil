import Foundation
import VigilCore

/// Honest send delivery. A routed `send` reaching the target's PTY (keystrokes
/// typed) is NOT proof it entered the agent's context: if the target is mid-turn claude
/// queues the input, and a later API-error turn death discards that queue — an injection can
/// be acknowledged as sent yet never actually enter the target's context if an API error
/// kills the turn and clears the queue along with it.
///
/// The reliable proof is the target's transcript: the injected text showing up as a REAL
/// user message means it truly landed. This tracker holds every in-flight `send`, confirms
/// it against the transcript, and — when the turn dies unconfirmed — reinjects once the node
/// idles (bounded), then finally reports an honest failure to the caller.
///
/// Design red lines: don't drop (after the turn dies, auto-reinject once the node idles); don't
/// lie (until confirmed, never treat it as delivered — confirmation/failure is settled via
/// orchestration.jsonl + a receipt); make failure visible (reinjects exhausted → a system receipt
/// routes back to the caller). Reinjection reuses the cell's existing inject FIFO (injectTail /
/// hold semantics unchanged). Same iron-law posture as TurnWatcher/PermWatcher:
/// reading the transcript is
/// not a state change; the only state touches are the Commands the closures emit.
@MainActor
public final class DeliveryTracker {
    /// Reinject budget = how many times we re-push an unconfirmed message after its turn
    /// died before giving up and reporting failure to the caller. `nonisolated`: an immutable
    /// Sendable Int, referenced as a default argument from the nonisolated init signature.
    nonisolated public static let defaultMaxAttempts = 3

    struct Delivery {
        let target: NodeID
        let caller: NodeID
        let text: String
        var offset: UInt64      // transcript length at the last (re)inject — confirmation baseline
        var attempts: Int       // reinjects done (the original inject is not counted)
        var lastAttempt: Date
    }

    private var pending: [UUID: Delivery] = [:]

    private let readSince: (NodeID, UInt64) -> String   // transcript content from offset (empty if none)
    private let fileLength: (NodeID) -> UInt64          // current transcript byte length (0 if none)
    private let status: (NodeID) -> NodeStatus?         // live node status (nil = gone from the tree)
    private let reinject: (NodeID, String) -> Void      // re-push via the cell's inject FIFO
    private let onConfirmed: (NodeID, String) -> Void   // forensic log
    private let onFailed: (NodeID, NodeID, String, Int, String) -> Void  // target,caller,text,attempts,reason
    private let now: () -> Date
    private let maxAttempts: Int
    private let reinjectGrace: TimeInterval
    private var task: Task<Void, Never>?

    public init(readSince: @escaping (NodeID, UInt64) -> String,
                fileLength: @escaping (NodeID) -> UInt64,
                status: @escaping (NodeID) -> NodeStatus?,
                reinject: @escaping (NodeID, String) -> Void,
                onConfirmed: @escaping (NodeID, String) -> Void,
                onFailed: @escaping (NodeID, NodeID, String, Int, String) -> Void,
                maxAttempts: Int = defaultMaxAttempts,
                reinjectGrace: TimeInterval = 4,
                now: @escaping () -> Date = { Date() }) {
        self.readSince = readSince; self.fileLength = fileLength; self.status = status
        self.reinject = reinject; self.onConfirmed = onConfirmed; self.onFailed = onFailed
        self.maxAttempts = maxAttempts; self.reinjectGrace = reinjectGrace; self.now = now
    }

    /// Called right after a `send` route injected successfully. Baseline = the transcript's
    /// current length, so confirmation only counts a user message written AFTER this inject
    /// (a prior identical message never false-confirms).
    @discardableResult
    public func register(target: NodeID, caller: NodeID, text: String) -> UUID {
        let id = UUID()
        pending[id] = Delivery(target: target, caller: caller, text: text,
                               offset: fileLength(target), attempts: 0, lastAttempt: now())
        return id
    }

    /// Test seam / observability: how many sends are still unconfirmed.
    public var pendingCount: Int { pending.count }

    /// One reconciliation pass — separated from the sleep loop so tests drive it
    /// deterministically (same posture as TurnWatcher).
    public func tick() {
        for (id, var d) in pending {
            let since = readSince(d.target, d.offset)
            // 1) Confirmed? the injected text entered the target's context — either as a real
            //    user message (idle send) OR, for a MID-TURN send, as a consumed queued_command
            //    attachment (claude 2.1.x writes NO user line for queued input, only
            //    the consumption record). Both = truly landed.
            if TranscriptScan.containsUserMessage(d.text, inJSONL: since)
                || TranscriptScan.containsQueuedCommand(d.text, inJSONL: since) {
                onConfirmed(d.target, d.text); pending[id] = nil; continue
            }
            // 2) Target gone from the tree — nothing to deliver to, drop quietly.
            guard let st = status(d.target) else { pending[id] = nil; continue }
            // 3) Target dead (kill/self-death) — failure is definitive, report it.
            if st.isTerminal {
                onFailed(d.target, d.caller, d.text, d.attempts, "target \(st.rawValue)")
                pending[id] = nil; continue
            }
            // 4) Turn still in flight — the message may yet be queued and delivered on a
            //    normal close; only a DEAD turn (idle/errored) means it was lost.
            //    `.queued` (inject-hold) joins running/starting: an inject the store is
            //    still holding must never be re-pushed on top of itself.
            if st == .running || st == .starting || st == .queued { continue }
            // 4.5) the message is STILL sitting in claude's mid-turn queue
            //    (enqueued, not yet consumed) and the turn has not died on an API error → it is
            //    provably in flight and WILL deliver on turn close; reinjecting only piles a
            //    duplicate into the worker's context. This is transcript-grounded so it holds
            //    even when the node's scraped status is wrong (a reinject could otherwise fire
            //    against a node the store had left non-`.running`). hasApiError releases
            //    the hold so the true-loss path (an API error discarding the queue) still recovers.
            if TranscriptScan.hasEnqueuedCommand(d.text, inJSONL: since)
                && !TranscriptScan.hasApiError(inJSONL: since) { continue }
            guard now().timeIntervalSince(d.lastAttempt) >= reinjectGrace else { continue }
            // 5) Turn ended unconfirmed: reinject if budget remains, else fail visibly.
            if d.attempts >= maxAttempts {
                onFailed(d.target, d.caller, d.text, d.attempts,
                         "\(d.attempts) reinjection(s) still unconfirmed")
                pending[id] = nil; continue
            }
            d.attempts += 1
            d.lastAttempt = now()
            d.offset = fileLength(d.target)   // fresh baseline for this attempt
            pending[id] = d
            reinject(d.target, d.text)
        }
    }

    public func start(interval: TimeInterval = 1.0) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(seconds: interval)
                self?.tick()
            }
        }
    }

    public func stop() { task?.cancel(); task = nil }
}
