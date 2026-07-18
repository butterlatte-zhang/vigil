import XCTest
@testable import VigilApp

// History self-rendering — a pure-function parser from transcript jsonl to read-only
// blocks. The format is claude's internal one (real-capture samples aligned to 2.1.204):
// user content comes in string / parts forms; slash commands are XML-wrapped;
// tool_result/thinking/meta never render; consecutive tool calls fold into one line.

final class TranscriptRenderTests: XCTestCase {

    // MARK: basic forms

    func testUserStringAndAssistantText() {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"test what environment is this now"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"this is a description of the test environment"}]}}
        """
        let items = TranscriptRender.parse(jsonl)
        XCTAssertEqual(items.map(\.kind), [.user, .assistant])
        XCTAssertEqual(items[0].text, "test what environment is this now")
        XCTAssertEqual(items[1].text, "this is a description of the test environment")
    }

    func testUserPartsFormAndToolResultSkipped() {
        let jsonl = """
        {"type":"user","message":{"content":[{"type":"text","text":"help me fix a bug"}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","content":"file contents..."}]}}
        """
        let items = TranscriptRender.parse(jsonl)
        XCTAssertEqual(items.count, 1, "a user line with only tool_result does not render")
        XCTAssertEqual(items[0].text, "help me fix a bug")
    }

    func testToolUseRunCollapsesIntoOneLine() {
        let jsonl = """
        {"type":"user","message":{"content":"run the tests"}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"all green"}]}}
        """
        let items = TranscriptRender.parse(jsonl)
        XCTAssertEqual(items.map(\.kind), [.user, .tools, .assistant])
        XCTAssertTrue(items[1].text.contains("×3"), "total count: \(items[1].text)")
        XCTAssertTrue(items[1].text.contains("Bash ×2"))
        XCTAssertTrue(items[1].text.contains("Read"))
    }

    func testMetaThinkingAndSidecarLinesNeverRender() {
        let jsonl = """
        {"type":"ai-title","aiTitle":"check current environment test"}
        {"type":"file-history-snapshot"}
        {"type":"system","content":"irrelevant"}
        {"type":"user","isMeta":true,"message":{"content":"Caveat: injected"}}
        {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"}]}}
        not json at all
        """
        XCTAssertEqual(TranscriptRender.parse(jsonl), [])
    }

    // MARK: slash commands and local-command echo

    func testSlashCommandRendersAsCommandLine() {
        let jsonl = #"{"type":"user","message":{"content":"<command-name>/model</command-name><command-message>model</command-message><command-args>opus</command-args>"}}"#
        let items = TranscriptRender.parse(jsonl)
        XCTAssertEqual(items.map(\.text), ["/model opus"])
    }

    func testLocalCommandStdoutSkipped() {
        let jsonl = #"{"type":"user","message":{"content":"<local-command-stdout>Set model to opus</local-command-stdout>"}}"#
        XCTAssertEqual(TranscriptRender.parse(jsonl), [])
    }

    func testInterruptMarkerRendersDimNotAsUserPrompt() {
        // The interrupt marker claude injects isn't something the human typed — render it
        // dim like the claude TUI does, not as a user prompt line.
        let jsonl = #"{"type":"user","message":{"content":"[Request interrupted by user for tool use]"}}"#
        let items = TranscriptRender.parse(jsonl)
        XCTAssertEqual(items.map(\.kind), [.notice])
    }

    // MARK: honest truncation notice

    func testTruncatedHeadGetsNotice() {
        let jsonl = #"{"type":"user","message":{"content":"hi"}}"#
        let items = TranscriptRender.parse(jsonl, truncatedHead: true)
        XCTAssertEqual(items.first?.kind, .notice)
        XCTAssertTrue(items.first!.text.contains("Earlier content omitted"))
    }

    func testItemCapKeepsTailAndAddsNotice() {
        let lines = (0..<450).map {
            #"{"type":"user","message":{"content":"m\#($0)"}}"#
        }.joined(separator: "\n")
        let items = TranscriptRender.parse(lines)
        XCTAssertEqual(items.count, TranscriptRender.maxItems + 1)
        XCTAssertEqual(items.first?.kind, .notice)
        XCTAssertEqual(items.last?.text, "m449", "the cap keeps the tail, not the head — the latest conversation is what review needs")
    }

    // MARK: load (tail read + missing file)

    func testLoadMissingFileReturnsNil() {
        XCTAssertNil(TranscriptRender.load(path: "/tmp/vigil-no-such-transcript.jsonl"))
        XCTAssertNil(TranscriptRender.load(path: nil))
    }

    // MARK: stats (/status·/usage same-source info, full-file scan)

    private func assistantLine(req: String, model: String, ts: String,
                               input: Int, output: Int,
                               cacheRead: Int = 0, cacheWrite: Int = 0) -> String {
        #"{"type":"assistant","requestId":"\#(req)","timestamp":"\#(ts)","version":"2.1.204","sessionId":"sid-1","message":{"model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheWrite)},"content":[{"type":"text","text":"x"}]}}"#
    }

    func testStatsAggregatesUsageDedupedByRequestId() throws {
        let p = NSTemporaryDirectory() + "vigil-stats-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: p) }
        // The same requestId is split across 3 lines (real-capture form: one API response,
        // multiple jsonl lines) → counted only once; the second requestId is a different
        // model → its own line, in first-seen order.
        let lines = [
            assistantLine(req: "req_1", model: "claude-fable-5",
                          ts: "2026-07-07T07:00:00.000Z", input: 1000, output: 200,
                          cacheRead: 5000, cacheWrite: 300),
            assistantLine(req: "req_1", model: "claude-fable-5",
                          ts: "2026-07-07T07:00:05.000Z", input: 1000, output: 200,
                          cacheRead: 5000, cacheWrite: 300),
            assistantLine(req: "req_1", model: "claude-fable-5",
                          ts: "2026-07-07T07:00:06.000Z", input: 1000, output: 200,
                          cacheRead: 5000, cacheWrite: 300),
            assistantLine(req: "req_2", model: "claude-haiku-4-5",
                          ts: "2026-07-07T07:19:24.000Z", input: 629, output: 23),
        ]
        try lines.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8)

        let s = try XCTUnwrap(TranscriptRender.stats(path: p))
        XCTAssertEqual(s.version, "2.1.204")
        XCTAssertEqual(s.sessionId, "sid-1")
        XCTAssertEqual(s.wallSeconds, 19 * 60 + 24, "wall clock = time delta between the first and last line")
        XCTAssertEqual(s.models.map(\.model), ["claude-fable-5", "claude-haiku-4-5"])
        XCTAssertEqual(s.models[0].input, 1000, "duplicate lines with the same requestId count only once")
        XCTAssertEqual(s.models[0].output, 200)
        XCTAssertEqual(s.models[0].cacheRead, 5000)
        XCTAssertEqual(s.models[0].cacheWrite, 300)
        XCTAssertEqual(s.models[1].input, 629)
    }

    func testStatsLinesWithoutStableIdAreSkippedNotMultiplied() throws {
        // Omit rather than overstate: when both requestId/message.id are missing (field
        // drift), a per-line fallback id would be unique per line — one response split
        // across 4 lines would get counted 4 times. Drifted lines must be skipped, not
        // counted; lines with a stable id still aggregate normally.
        let p = NSTemporaryDirectory() + "vigil-stats-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: p) }
        let driftLine = #"{"type":"assistant","uuid":"\#(UUID().uuidString)","message":{"model":"claude-fable-5","usage":{"input_tokens":1000,"output_tokens":200}}}"#
        let lines = [
            driftLine, driftLine,                       // same response split into two lines, both missing an id
            assistantLine(req: "req_1", model: "claude-haiku-4-5",
                          ts: "2026-07-07T07:00:00.000Z", input: 629, output: 23),
        ]
        try lines.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8)

        let s = try XCTUnwrap(TranscriptRender.stats(path: p))
        XCTAssertEqual(s.models.map(\.model), ["claude-haiku-4-5"],
                       "lines without a stable id are not counted (never overstate by a multiple)")
        XCTAssertEqual(s.models[0].input, 629)
    }

    func testStatsMissingFileReturnsNil() {
        XCTAssertNil(TranscriptRender.stats(path: "/tmp/vigil-no-such.jsonl"))
        XCTAssertNil(TranscriptRender.stats(path: nil))
    }

    func testTokenAndWallFormatting() {
        XCTAssertEqual(TranscriptRender.fmtTokens(629), "629")
        XCTAssertEqual(TranscriptRender.fmtTokens(4_800), "4.8k")
        XCTAssertEqual(TranscriptRender.fmtTokens(38_100), "38.1k")
        XCTAssertEqual(TranscriptRender.fmtTokens(133_600), "133.6k")
        XCTAssertEqual(TranscriptRender.fmtTokens(4_500_000), "4.5m")
        XCTAssertEqual(TranscriptRender.fmtTokens(1_000), "1k")
        // wall-clock formatting → VGDuration.wall, pinned in VGDurationTests;
        // the stats card's call site keeps the same bytes:
        XCTAssertEqual(VGDuration.wall(seconds: 45), "45s")
        XCTAssertEqual(VGDuration.wall(seconds: 19 * 60 + 24), "19m 24s")
        XCTAssertEqual(VGDuration.wall(seconds: 2 * 3600 + 300), "2h 5m")
    }

    // MARK: codex rollout jsonl (event_msg form, entirely different from claude JSONL)

    /// codex rollout's render source = event_msg: user_message / agent_message each pull
    /// from their own payload.message; env-context noise only shows up in response_item,
    /// never in user_message.
    func testCodexUserAndAgentMessages() {
        let jsonl = """
        {"type":"session_meta","payload":{"session_id":"abc","cwd":"/p"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>noise</environment_context>"}]}}
        {"type":"event_msg","payload":{"type":"user_message","message":"What is 2+2?"}}
        {"type":"event_msg","payload":{"type":"agent_message","message":"Four","phase":"final_answer"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{}}}
        """
        let items = TranscriptRender.parseCodex(jsonl)
        XCTAssertEqual(items.map(\.kind), [.user, .assistant], "response_item/session_meta/token_count do not render")
        XCTAssertEqual(items[0].text, "What is 2+2?")
        XCTAssertEqual(items[1].text, "Four")
    }

    func testCodexToolEventsFoldIntoOneLine() {
        let jsonl = """
        {"type":"event_msg","payload":{"type":"user_message","message":"run tests"}}
        {"type":"event_msg","payload":{"type":"exec_command_begin","command":["swift","test"]}}
        {"type":"event_msg","payload":{"type":"exec_command_begin","command":["ls"]}}
        {"type":"event_msg","payload":{"type":"mcp_tool_call_begin","tool":"report"}}
        {"type":"event_msg","payload":{"type":"agent_message","message":"green","phase":"final_answer"}}
        """
        let items = TranscriptRender.parseCodex(jsonl)
        XCTAssertEqual(items.map(\.kind), [.user, .tools, .assistant])
        XCTAssertTrue(items[1].text.contains("×3"), "tool count: \(items[1].text)")
        XCTAssertTrue(items[1].text.contains("shell ×2"))
        XCTAssertTrue(items[1].text.contains("report"))
    }

    func testCodexEmptyMessagesAndUnknownEventsSkipped() {
        let jsonl = """
        {"type":"event_msg","payload":{"type":"user_message","message":"   "}}
        {"type":"event_msg","payload":{"type":"agent_reasoning","text":"internal"}}
        {"type":"world_state","payload":{}}
        not json
        {"type":"event_msg","payload":{"type":"agent_message","message":"real answer"}}
        """
        let items = TranscriptRender.parseCodex(jsonl)
        XCTAssertEqual(items.map(\.kind), [.assistant], "empty user_message / reasoning / world_state are all skipped")
        XCTAssertEqual(items[0].text, "real answer")
    }

    /// load dispatches by filename shape: `rollout-…jsonl` goes through parseCodex,
    /// `<sid>.jsonl` goes through claude parse.
    func testLoadRoutesCodexByFilename() throws {
        XCTAssertTrue(TranscriptRender.isCodexRollout("/x/rollout-2026-07-10T16-28-05-abc.jsonl"))
        XCTAssertFalse(TranscriptRender.isCodexRollout("/x/019f4b24-1b04.jsonl"))

        let dir = NSTemporaryDirectory() + "vigil-codex-load-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = dir + "/rollout-2026-07-10T16-28-05-019f4b24-1b04-7ce0-9059-7da727c56bf3.jsonl"
        let jsonl = """
        {"type":"session_meta","payload":{"session_id":"s"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"hello"}}
        {"type":"event_msg","payload":{"type":"agent_message","message":"world"}}
        """
        try jsonl.write(toFile: p, atomically: true, encoding: .utf8)
        let items = try XCTUnwrap(TranscriptRender.load(path: p))
        XCTAssertEqual(items.map(\.kind), [.user, .assistant])
        XCTAssertEqual(items.map(\.text), ["hello", "world"])
    }

    /// codex stats: session_meta supplies sid + version, token_count accumulates usage;
    /// $ cost is never fabricated.
    func testCodexStatsFromRollout() {
        let jsonl = """
        {"timestamp":"2026-07-10T08:28:05.000Z","type":"session_meta","payload":{"session_id":"sid-9","cli_version":"0.144.1"}}
        {"timestamp":"2026-07-10T08:28:05.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"timestamp":"2026-07-10T08:28:20.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":12284,"output_tokens":5,"cached_input_tokens":9600}}}}
        """
        let s = TranscriptRender.codexStats(jsonl)
        XCTAssertEqual(s.sessionId, "sid-9")
        XCTAssertEqual(s.version, "0.144.1")
        XCTAssertEqual(s.wallSeconds, 15)
        XCTAssertEqual(s.models.first?.model, "gpt-5.5")
        XCTAssertEqual(s.models.first?.input, 12284)
        XCTAssertEqual(s.models.first?.output, 5)
        XCTAssertEqual(s.models.first?.cacheRead, 9600)
        XCTAssertFalse(s.isEmpty)
    }

    /// Real-machine regression guard: parses an actual codex 0.144.1 rollout
    /// (base_instructions trimmed, everything else verbatim). Two rounds of Q&A on
    /// Paris/Tokyo — rendering emits only user/assistant, task_started/token_count/
    /// session_meta are all skipped; stats reads sid + usage off the real sample. If a
    /// synthetic fixture drifts from the real shape, this test goes red first.
    func testParsesRealCodexRolloutFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "rollout-codex-0.144.1-sample", withExtension: "jsonl"))
        let items = try XCTUnwrap(TranscriptRender.load(path: url.path))
        XCTAssertEqual(items.map(\.kind), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(items.map(\.text),
                       ["What is the capital of France? One word.", "Paris",
                        "And of Japan? One word.", "Tokyo"])
        let s = try XCTUnwrap(TranscriptRender.stats(path: url.path))
        XCTAssertFalse(s.isEmpty)
        XCTAssertEqual(s.sessionId?.isEmpty, false, "the real sample reads out session_id")
        XCTAssertNotNil(s.models.first?.input, "token_count reads out usage")
    }

    // MARK: opencode export JSON (playback data source)

    /// opencode export = ONE JSON object (info + messages): parts.text → body text,
    /// tool → folded ⚒, patch → apply_patch, reasoning/step-* → skipped. user/assistant
    /// is split by message.info.role.
    func testOpenCodeUserAssistantAndToolFolding() {
        let json = """
        {"info":{"id":"ses_x","title":"T"},"messages":[
          {"info":{"role":"user"},"parts":[{"type":"text","text":"run the tests and report back"}]},
          {"info":{"role":"assistant"},"parts":[
            {"type":"step-start"},
            {"type":"reasoning","text":"internal"},
            {"type":"tool","tool":"bash"},
            {"type":"tool","tool":"bash"},
            {"type":"patch","hash":"h"},
            {"type":"text","text":"green, reported"},
            {"type":"step-finish"}]}
        ]}
        """
        let items = TranscriptRender.parseOpenCode(json)
        XCTAssertEqual(items.map(\.kind), [.user, .tools, .assistant],
                       "reasoning/step-* do not render; tool/patch fold before text")
        XCTAssertEqual(items[0].text, "run the tests and report back")
        XCTAssertTrue(items[1].text.contains("bash ×2"), "tool tally: \(items[1].text)")
        XCTAssertTrue(items[1].text.contains("apply_patch"))
        XCTAssertEqual(items[2].text, "green, reported")
    }

    func testOpenCodeEmptyTextAndMalformedSkipped() {
        XCTAssertEqual(TranscriptRender.parseOpenCode("not json"), [])
        XCTAssertEqual(TranscriptRender.parseOpenCode("""
        {"info":{},"messages":[{"info":{"role":"user"},"parts":[{"type":"text","text":"   "}]}]}
        """), [], "blank text does not render")
    }

    /// load dispatches by filename shape: `opencode-…json` goes through parseOpenCode
    /// (a whole JSON document, not tail-read JSONL).
    func testLoadRoutesOpenCodeByFilename() throws {
        XCTAssertTrue(TranscriptRender.isOpenCodeExport("/x/opencode-n1.json"))
        XCTAssertFalse(TranscriptRender.isOpenCodeExport("/x/rollout-abc.jsonl"))
        XCTAssertFalse(TranscriptRender.isOpenCodeExport("/x/019f4b24.jsonl"))

        let dir = NSTemporaryDirectory() + "vigil-oc-load-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = dir + "/opencode-root.json"
        try #"{"info":{"id":"s"},"messages":[{"info":{"role":"user"},"parts":[{"type":"text","text":"hello"}]},{"info":{"role":"assistant"},"parts":[{"type":"text","text":"world"}]}]}"#
            .write(toFile: p, atomically: true, encoding: .utf8)
        let items = try XCTUnwrap(TranscriptRender.load(path: p))
        XCTAssertEqual(items.map(\.kind), [.user, .assistant])
        XCTAssertEqual(items.map(\.text), ["hello", "world"])
    }

    /// opencode stats: info.id=sid, version, model=providerID/id, tokens, time→wall.
    /// $ cost is factual, never fabricated.
    func testOpenCodeStatsFromInfo() {
        let json = """
        {"info":{"id":"ses_9","version":"1.17.18","model":{"id":"big-pickle","providerID":"opencode"},
        "tokens":{"input":13652,"output":241,"cache":{"read":27392,"write":0}},
        "time":{"created":1783679172211,"updated":1783679185249}},"messages":[]}
        """
        let s = TranscriptRender.opencodeStats(json)
        XCTAssertEqual(s.sessionId, "ses_9")
        XCTAssertEqual(s.version, "1.17.18")
        XCTAssertEqual(s.models.first?.model, "opencode/big-pickle")
        XCTAssertEqual(s.models.first?.input, 13652)
        XCTAssertEqual(s.models.first?.output, 241)
        XCTAssertEqual(s.models.first?.cacheRead, 27392)
        XCTAssertEqual(s.wallSeconds, 13)
        XCTAssertFalse(s.isEmpty)
    }

    /// Real-machine regression guard: parses an actual opencode 1.17.18 export
    /// (tool state/reasoning trimmed, shape otherwise verbatim). Rendering emits only
    /// user/assistant plus folded tools; stats reads sid/model/usage off the real sample.
    /// If a synthetic fixture drifts, this test goes red first.
    func testParsesRealOpenCodeExportFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "opencode-1.17.18-export-sample", withExtension: "json"))
        let items = try XCTUnwrap(TranscriptRender.load(path: url.path))
        XCTAssertEqual(items.map(\.kind), [.user, .tools, .assistant, .tools, .assistant],
                       "real sample: user→bash→assistant→(report+patch)→assistant")
        XCTAssertTrue(items[1].text.contains("bash"))
        XCTAssertTrue(items[3].text.contains("vigil_report"))
        let s = try XCTUnwrap(TranscriptRender.stats(path: url.path))
        XCTAssertEqual(s.sessionId, "ses_0b46fc18cffeSopROVmNUAK1RB")
        XCTAssertEqual(s.models.first?.model, "opencode/big-pickle")
        XCTAssertEqual(s.version, "1.17.18")
        XCTAssertFalse(s.isEmpty)
    }

    func testLoadTailDropsPartialFirstLineAndMarksTruncation() throws {
        let p = NSTemporaryDirectory() + "vigil-transcript-tail-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: p) }
        let filler = String(repeating: "x", count: 200)
        let lines = (0..<40).map {
            #"{"type":"user","message":{"content":"msg\#($0) \#(filler)"}}"#
        }
        try lines.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8)
        // Cap far below the file size → tail read, first (partial) line dropped.
        let items = try XCTUnwrap(TranscriptRender.load(path: p, maxBytes: 2048))
        XCTAssertEqual(items.first?.kind, .notice)
        XCTAssertTrue(items.last!.text.hasPrefix("msg39"))
        // Every survivor is a complete, valid line (a torn head would have vanished).
        XCTAssertTrue(items.dropFirst().allSatisfy { $0.kind == .user })
    }
}
