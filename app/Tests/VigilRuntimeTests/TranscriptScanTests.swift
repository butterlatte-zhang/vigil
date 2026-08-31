import XCTest
@testable import VigilRuntime

/// Transcript JSONL is the reliable source both for confirming a routed
/// message truly entered a target's context and for spotting an API-error turn
/// death that fires no Stop hook. These pure scans are the shared bedrock.
final class TranscriptScanTests: XCTestCase {

    // MARK: containsUserMessage — delivery confirmation

    func testContainsUserMessageMatchesStringContent() {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"MESSAGE FROM root: use postgres"}}
        """
        XCTAssertTrue(TranscriptScan.containsUserMessage("MESSAGE FROM root: use postgres", inJSONL: jsonl))
    }

    func testContainsUserMessageMatchesTextPartsContent() {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"MESSAGE FROM n1: go"}]}}
        """
        XCTAssertTrue(TranscriptScan.containsUserMessage("MESSAGE FROM n1: go", inJSONL: jsonl))
    }

    func testContainsUserMessageToleratesWhitespaceWrapping() {
        // claude may rewrap the submitted prompt across lines / collapse runs of spaces.
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"MESSAGE FROM root:   use\\n  postgres"}}
        """
        XCTAssertTrue(TranscriptScan.containsUserMessage("MESSAGE FROM root: use postgres", inJSONL: jsonl))
    }

    func testContainsUserMessageIgnoresAssistantAndToolResult() {
        // The payload echoed inside an assistant reply or a tool_result is NOT proof the
        // user turn carried it — only a real user entry counts.
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"MESSAGE FROM root: use postgres"}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"MESSAGE FROM root: use postgres"}]}}
        """
        XCTAssertFalse(TranscriptScan.containsUserMessage("MESSAGE FROM root: use postgres", inJSONL: jsonl))
    }

    func testContainsUserMessageAbsentWhenNotPresent() {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"something else entirely"}}
        """
        XCTAssertFalse(TranscriptScan.containsUserMessage("MESSAGE FROM root: go", inJSONL: jsonl))
    }

    // MARK: containsQueuedCommand — mid-turn delivery confirmation

    func testContainsQueuedCommandMatchesConsumedAttachment() {
        // claude 2.1.x consumes a mid-turn injection as a queued_command attachment (real
        // live-captured shape, session 48429977 line ~300) — NO type:"user" line ever appears.
        let jsonl = """
        {"parentUuid":"a","isSidechain":false,"attachment":{"type":"queued_command","prompt":"MESSAGE FROM root: rebase onto main","commandMode":"prompt","origin":{"kind":"human"},"timestamp":"2026-07-10T02:25:46.317Z"},"type":"attachment","uuid":"b"}
        """
        XCTAssertTrue(TranscriptScan.containsQueuedCommand("MESSAGE FROM root: rebase onto main", inJSONL: jsonl))
    }

    func testContainsQueuedCommandToleratesWhitespaceWrapping() {
        let jsonl = """
        {"attachment":{"type":"queued_command","prompt":"MESSAGE FROM root:   rebase\\n  onto main"},"type":"attachment"}
        """
        XCTAssertTrue(TranscriptScan.containsQueuedCommand("MESSAGE FROM root: rebase onto main", inJSONL: jsonl))
    }

    func testContainsQueuedCommandIgnoresBareEnqueue() {
        // A bare enqueue (not yet consumed) is NOT confirmation — the queue can still be
        // discarded by an API-error turn death. Only the attachment counts.
        let jsonl = """
        {"type":"queue-operation","operation":"enqueue","content":"MESSAGE FROM root: rebase onto main"}
        """
        XCTAssertFalse(TranscriptScan.containsQueuedCommand("MESSAGE FROM root: rebase onto main", inJSONL: jsonl))
    }

    func testContainsQueuedCommandAbsentWhenNotPresent() {
        let jsonl = """
        {"attachment":{"type":"task_reminder","content":[]},"type":"attachment"}
        """
        XCTAssertFalse(TranscriptScan.containsQueuedCommand("MESSAGE FROM root: go", inJSONL: jsonl))
    }

    // MARK: hasEnqueuedCommand — in-flight (live-queue) liveness proxy

    func testHasEnqueuedCommandMatchesLiveEnqueue() {
        let jsonl = """
        {"type":"queue-operation","operation":"enqueue","timestamp":"2026-07-10T02:25:14.069Z","content":"MESSAGE FROM root: rebase onto main"}
        """
        XCTAssertTrue(TranscriptScan.hasEnqueuedCommand("MESSAGE FROM root: rebase onto main", inJSONL: jsonl))
    }

    func testHasEnqueuedCommandIgnoresRemoveOp() {
        // Only `enqueue` means still-in-flight; a `remove` is the queue draining at consumption.
        let jsonl = """
        {"type":"queue-operation","operation":"remove","content":"MESSAGE FROM root: rebase onto main"}
        """
        XCTAssertFalse(TranscriptScan.hasEnqueuedCommand("MESSAGE FROM root: rebase onto main", inJSONL: jsonl))
    }

    func testHasEnqueuedCommandAbsentOnUnrelatedTranscript() {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        """
        XCTAssertFalse(TranscriptScan.hasEnqueuedCommand("MESSAGE FROM root: go", inJSONL: jsonl))
    }

    // MARK: hasApiError — abnormal-turn-death anchor

    func testHasApiErrorViaFlag() {
        // The reliable claude anchor: an assistant entry flagged isApiErrorMessage.
        let jsonl = """
        {"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"API Error: Connection closed mid-response"}]}}
        """
        XCTAssertTrue(TranscriptScan.hasApiError(inJSONL: jsonl))
    }

    func testHasApiErrorViaText() {
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"API Error: Overloaded"}]}}
        """
        XCTAssertTrue(TranscriptScan.hasApiError(inJSONL: jsonl))
    }

    func testNoApiErrorOnNormalTranscript() {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"all good, done"}]}}
        """
        XCTAssertFalse(TranscriptScan.hasApiError(inJSONL: jsonl))
    }

    func testMalformedLinesAreSkipped() {
        let jsonl = """
        not json at all
        {"type":"user","message":{"role":"user","content":"MESSAGE FROM root: go"}}
        {broken
        """
        XCTAssertTrue(TranscriptScan.containsUserMessage("MESSAGE FROM root: go", inJSONL: jsonl))
        XCTAssertFalse(TranscriptScan.hasApiError(inJSONL: jsonl))
    }

    // MARK: apiErrorSnippet — turn_errored's forensic reason

    func testApiErrorSnippetPrefersBodyText() {
        let jsonl = """
        {"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"API Error: Connection closed mid-response"}]}}
        """
        XCTAssertEqual(TranscriptScan.apiErrorSnippet(inJSONL: jsonl),
                       "API Error: Connection closed mid-response")
    }

    func testApiErrorSnippetNilOnNormalTranscript() {
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"all good, done"}]}}
        """
        XCTAssertNil(TranscriptScan.apiErrorSnippet(inJSONL: jsonl))
    }

    // MARK: pendingBackgroundAgents — the report-watchdog's background-agent exemption

    func testPendingBackgroundAgentsLastLineWins() {
        let jsonl = """
        {"type":"system","subtype":"turn_duration","pendingBackgroundAgentCount":3}
        {"type":"system","subtype":"turn_duration","pendingBackgroundAgentCount":0}
        """
        XCTAssertEqual(TranscriptScan.pendingBackgroundAgents(inJSONL: jsonl), 0)
    }

    func testPendingBackgroundAgentsNilWhenAbsent() {
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
        """
        XCTAssertNil(TranscriptScan.pendingBackgroundAgents(inJSONL: jsonl))
    }

    func testPendingBackgroundAgentsSkipsMalformedLines() {
        let jsonl = """
        not json at all
        {broken
        {"type":"system","subtype":"turn_duration","pendingBackgroundAgentCount":2}
        """
        XCTAssertEqual(TranscriptScan.pendingBackgroundAgents(inJSONL: jsonl), 2)
    }
}
