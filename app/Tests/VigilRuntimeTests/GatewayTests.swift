import XCTest
import VigilCore
@testable import VigilRuntime

/// Collects Commands the gateways emit, with an async `first()` the test can await.
actor CommandSink {
    private var cmds: [Command] = []
    private var waiter: CheckedContinuation<Command, Never>?
    func add(_ c: Command) {
        if let w = waiter { waiter = nil; w.resume(returning: c) } else { cmds.append(c) }
    }
    func first() async -> Command {
        if !cmds.isEmpty { return cmds.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }
}

/// Awaitable single-NodeID box (mirror of CommandSink) for onConnect assertions.
actor NodeBox {
    private var node: NodeID?
    private var waiter: CheckedContinuation<NodeID, Never>?
    func set(_ n: NodeID) {
        if let w = waiter { waiter = nil; w.resume(returning: n) } else { node = n }
    }
    func first() async -> NodeID {
        if let n = node { return n }
        return await withCheckedContinuation { waiter = $0 }
    }
}

/// Records onRename fires (node, name) for the #rename dispatch tests — awaitable first
/// value + a count so "empty name / wrong identity fires nothing" is assertable.
actor RenameBox {
    private var calls: [(NodeID, String)] = []
    private var waiter: CheckedContinuation<(NodeID, String), Never>?
    func set(_ n: NodeID, _ name: String) {
        calls.append((n, name))
        if let w = waiter { waiter = nil; w.resume(returning: (n, name)) }
    }
    func first() async -> (NodeID, String)? {
        if let c = calls.first { return c }
        return await withCheckedContinuation { waiter = $0 }
    }
    func count() -> Int { calls.count }
}

final class GatewayTests: XCTestCase {

    // MARK: observation hooks (fire-and-forget, nothing written back)

    /// Order-true sink: records emit CALLS synchronously (lock, no Task hop). The
    /// prompt test asserts turnStarted-before-clearNotices — routing each emit through
    /// an unstructured Task (CommandSink) re-races that order and flakes under load;
    /// the gateway itself emits in order, and THAT is what must be pinned.
    private final class SyncSink: @unchecked Sendable {
        private let lock = NSLock()
        private var cmds: [Command] = []
        func add(_ c: Command) { lock.lock(); cmds.append(c); lock.unlock() }
        var all: [Command] { lock.lock(); defer { lock.unlock() }; return cmds }
    }

    func testHookPromptEventFiresOnPromptAndClearsNotices() async throws {
        // UserPromptSubmit → onPrompt (auto-naming) + .clearNotices (the wait is over).
        let sink = SyncSink()
        let box = NodeBox()
        let gw = HookGateway(emit: { c in sink.add(c) },
                             onPrompt: { node, payload in
            if (payload["transcript_path"] as? String) == "/tmp/t.jsonl" { Task { await box.set(node) } }
        })
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await gw.handle(server) }

        let claude = JSONLine.dump(["prompt": "hi", "transcript_path": "/tmp/t.jsonl"])
        await client.write(JSONLine.dump(["node": "root", "event": "prompt", "payload": claude]))

        let got = await box.first()
        XCTAssertEqual(got, NodeID("root"))
        // observation channel: nothing is ever written back (EOF, not a decision line)
        let line = await client.readLine()
        XCTAssertNil(line)
        await t.value

        // A prompt marks the turn OPEN before the wait is cleared (running, not idle).
        let cmds = sink.all
        XCTAssertEqual(cmds.count, 2)
        guard case .turnStarted(let started) = cmds.first else {
            return XCTFail("expected turnStarted first, got \(cmds)")
        }
        XCTAssertEqual(started, NodeID("root"))
        guard case .clearNotices(let node) = cmds.last else {
            return XCTFail("expected clearNotices second, got \(cmds)")
        }
        XCTAssertEqual(node, NodeID("root"))
    }

    func testHookStopEventEmitsTurnEnded() async throws {
        // Stop (turn ended) → .turnEnded: the idle/running divider. Observation
        // only — nothing written back.
        let sink = CommandSink()
        let gw = HookGateway(emit: { c in Task { await sink.add(c) } })
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await gw.handle(server) }

        let claude = JSONLine.dump(["hook_event_name": "Stop", "stop_hook_active": false])
        await client.write(JSONLine.dump(["node": "n3", "event": "stop", "payload": claude]))

        guard case .turnEnded(let node, gen: nil) = await sink.first() else {
            return XCTFail("expected turnEnded with gen nil (the hook source closes unconditionally)")
        }
        XCTAssertEqual(node, NodeID("n3"))
        let line = await client.readLine()
        XCTAssertNil(line)
        await t.value
    }

    func testHookStopEventFiresOnStopWithPayload() async throws {
        // Stop must also feed the auto-namer — claude's ai-title is written to disk
        // mid-turn; on the first turn it can only be picked up by re-reading after the
        // turn ends.
        let box = NodeBox()
        let gw = HookGateway(emit: { _ in },
                             onStop: { node, payload in
            if (payload["transcript_path"] as? String) == "/tmp/t.jsonl" { Task { await box.set(node) } }
        })
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await gw.handle(server) }

        let claude = JSONLine.dump(["hook_event_name": "Stop",
                                    "transcript_path": "/tmp/t.jsonl"])
        await client.write(JSONLine.dump(["node": "root", "event": "stop", "payload": claude]))

        let got = await box.first()
        XCTAssertEqual(got, NodeID("root"))
        await t.value
    }

    func testHookNotificationEventIsDropped() async throws {
        // The Notification hook is not mounted — claude fires it AND PermissionRequest for
        // the SAME box (a duplicate card). A live agent's stale settings.json may still
        // send the event — the gateway must drop it silently, no command, no reply.
        let sink = SyncSink()
        let gw = HookGateway(emit: { c in sink.add(c) })
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await gw.handle(server) }

        let claude = JSONLine.dump(["hook_event_name": "Notification",
                                    "message": "Claude needs your permission to use Bash"])
        await client.write(JSONLine.dump(["node": "n2", "event": "notification", "payload": claude]))

        // fire-and-forget: no reply line, and the connection closes (handle returns)
        let line = await client.readLine()
        XCTAssertNil(line)
        await t.value
        XCTAssertTrue(sink.all.isEmpty)         // nothing emitted
    }

    func testHookPermRequestEventEmitsPermRequested() async throws {
        // PermissionRequest (payload: prompt_id/tool_name/tool_input, NO tool_use_id) →
        // .permRequested with the canonicalized pairing tuple.
        let sink = CommandSink()
        let gw = HookGateway(emit: { c in Task { await sink.add(c) } })
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await gw.handle(server) }

        let claude = JSONLine.dump(["hook_event_name": "PermissionRequest",
                                    "prompt_id": "p42",
                                    "tool_name": "Bash",
                                    "tool_input": ["command": "git push", "timeout": 5000],
                                    "permission_mode": "default"])
        await client.write(JSONLine.dump(["node": "n3", "event": "perm-request", "payload": claude]))

        guard case .permRequested(let from, let info) = await sink.first() else {
            return XCTFail("expected permRequested")
        }
        XCTAssertEqual(from, NodeID("n3"))
        XCTAssertEqual(info.promptID, "p42")
        XCTAssertEqual(info.toolName, "Bash")
        XCTAssertEqual(info.toolInput, #"{"command":"git push","timeout":5000}"#) // sorted keys
        XCTAssertEqual(info.inputSummary, "git push")
        XCTAssertTrue(info.text.contains("Bash"))
        // observation-only: nothing written back (the native box must be untouched)
        let line = await client.readLine()
        XCTAssertNil(line)
        await t.value
    }

    func testHookPostToolEventEmitsResolveNoticeWithMatchingTuple() async throws {
        // PostToolUse → .resolveNotice(via: .postTool). The tool_input canonicalization
        // MUST equal the perm-request side's for the same dict (key order must not matter).
        let sink = CommandSink()
        let gw = HookGateway(emit: { c in Task { await sink.add(c) } })
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await gw.handle(server) }

        let claude = JSONLine.dump(["hook_event_name": "PostToolUse",
                                    "prompt_id": "p42",
                                    "tool_name": "Bash",
                                    "tool_input": ["timeout": 5000, "command": "git push"],
                                    "tool_use_id": "toolu_7",
                                    "tool_response": ["stdout": "ok"]])
        await client.write(JSONLine.dump(["node": "n3", "event": "post-tool", "payload": claude]))

        guard case .resolveNotice(let from, let match, let via) = await sink.first() else {
            return XCTFail("expected resolveNotice")
        }
        XCTAssertEqual(from, NodeID("n3"))
        XCTAssertEqual(via, .postTool)
        XCTAssertEqual(match?.promptID, "p42")
        XCTAssertEqual(match?.toolName, "Bash")
        XCTAssertEqual(match?.toolInput, #"{"command":"git push","timeout":5000}"#) // same canon
        XCTAssertEqual(match?.toolUseID, "toolu_7")        // log correlation only
        await t.value
    }

    // MARK: MCP server

    func testMCPInitializeAndToolsList() async throws {
        let pending = PendingReplies(); let sink = CommandSink()
        let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending)
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await srv.handle(server) }

        await client.write(JSONLine.dump(["node": "n1"]))                       // handshake
        await client.write(JSONLine.dump(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                          "params": ["protocolVersion": "2025-06-18"]]))
        let initResp = JSONLine.parse(await client.readLine() ?? "")
        let result = initResp?["result"] as? [String: Any]
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "vigil")
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-06-18")     // echoed

        await client.write(JSONLine.dump(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let listResp = JSONLine.parse(await client.readLine() ?? "")
        let tools = (listResp?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        let names = tools.compactMap { $0["name"] as? String }
        // No nodeInfo trim → the full catalog (rename included; the per-identity trim is
        // asserted by the role-scoped surface tests). No ask_human tool.
        XCTAssertEqual(Set(names), ["spawn", "send", "report", "kill", "rename"])
        // spawn does not advertise a human gate
        let spawnDesc = tools.first { ($0["name"] as? String) == "spawn" }?["description"] as? String ?? ""
        XCTAssertFalse(spawnDesc.lowercased().contains("human"))
        XCTAssertTrue(spawnDesc.contains("immediately"))

        await client.close()
        await t.value
    }

    /// The watchdog's stop-clock signal, agent_connected, comes from the {node} handshake
    /// line of the MCP connection — vigil-mcp connects and fires immediately when claude
    /// loads the MCP server (at startup), before any initialize/tool call. The spawn
    /// liveness watchdog's 15s window checks "did the process start", not "was a tool used
    /// for the first time"; harnesses without the vigil-mcp shim need their own
    /// applicability review (pinned by a matching comment on the Orchestrator side).
    func testAgentConnectedFiresOnHandshakeBeforeAnyRpc() async throws {
        let pending = PendingReplies()
        let box = NodeBox()
        let srv = MCPToolServer(emit: { _ in }, pending: pending,
                                onConnect: { node in Task { await box.set(node) } })
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await srv.handle(server) }

        await client.write(JSONLine.dump(["node": "n7"]))   // handshake line, nothing more
        let got = await box.first()
        XCTAssertEqual(got, NodeID("n7"), "onConnect = fires on handshake, no JSON-RPC needed")
        await client.close()
        await t.value
    }

    func testMCPToolSurfaceIsRoleScoped() async throws {
        // Tool trim is HARD, not prompt-level — tools/list shows only the node's
        // surface and tools/call rejects anything outside it. Worker n1 = report only.
        let pending = PendingReplies(); let sink = CommandSink()
        let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending,
                                nodeInfo: { node in
                                    node == NodeID("root") ? (.manager, true, .claude) : (.leaf, false, .claude)
                                })
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await srv.handle(server) }

        await client.write(JSONLine.dump(["node": "n1"]))                        // a worker
        await client.write(JSONLine.dump(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
        let listResp = JSONLine.parse(await client.readLine() ?? "")
        let tools = (listResp?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["report"])

        // calling spawn by name anyway → explicit error result
        await client.write(JSONLine.dump(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                          "params": ["name": "spawn",
                                                     "arguments": ["role": "leaf", "task": "x"]]]))
        let callResp = JSONLine.parse(await client.readLine() ?? "")
        let res = callResp?["result"] as? [String: Any]
        XCTAssertEqual(res?["isError"] as? Bool, true)
        let text = ((res?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("not available"))

        await client.close()
        await t.value
    }

    func testMCPRootToolSurfaceExcludesReport() async throws {
        // Root's report has nowhere to go; every family instead gets the same
        // four root tools, including rename.
        for kind in [AgentCLIKind.claude, .codex, .opencode] {
            let pending = PendingReplies(); let sink = CommandSink()
            let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending,
                                    nodeInfo: { _ in (.manager, true, kind) })
            let (server, client) = PipeLineChannel.pair()
            let t = Task { await srv.handle(server) }

            await client.write(JSONLine.dump(["node": "root"]))
            await client.write(JSONLine.dump(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
            let listResp = JSONLine.parse(await client.readLine() ?? "")
            let tools = (listResp?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
            XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }),
                           ["spawn", "send", "kill", "rename"],
                           "\(kind) root surface excludes report and includes rename")

            await client.close()
            await t.value
        }
    }

    func testMCPAllRootKindsExposeRename() async throws {
        // Every ROOT has the exact spawn/send/kill/rename surface.
        for kind in [AgentCLIKind.claude, .codex, .opencode] {
            let pending = PendingReplies(); let sink = CommandSink()
            let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending,
                                    nodeInfo: { _ in (.manager, true, kind) })
            let (server, client) = PipeLineChannel.pair()
            let t = Task { await srv.handle(server) }

            await client.write(JSONLine.dump(["node": "root"]))
            await client.write(JSONLine.dump(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
            let listResp = JSONLine.parse(await client.readLine() ?? "")
            let tools = (listResp?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
            XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }),
                           ["spawn", "send", "kill", "rename"], "\(kind) root surface")
            XCTAssertEqual(tools.count, 4)

            await client.close()
            await t.value
        }
    }

    func testMCPRenameFiresCallbackAndRejectsEmpty() async throws {
        // A valid name fires onRename with the trimmed value and replies success; an
        // empty/whitespace name is an honest isError with NO callback (never a lying
        // "renamed"). A non-root can't reach it through the hard trim, pinned below.
        let pending = PendingReplies(); let sink = CommandSink()
        let box = RenameBox()
        let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending,
                                onRename: { node, name in Task { await box.set(node, name) } },
                                nodeInfo: { _ in (.manager, true, .codex) })
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await srv.handle(server) }

        await client.write(JSONLine.dump(["node": "root"]))
        // valid name → success + callback with trimmed value
        await client.write(JSONLine.dump(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                          "params": ["name": "rename",
                                                     "arguments": ["name": "  refactor auth module  "]]]))
        let ok = JSONLine.parse(await client.readLine() ?? "")
        let okRes = ok?["result"] as? [String: Any]
        XCTAssertEqual(okRes?["isError"] as? Bool, false)
        let got = await box.first()
        XCTAssertEqual(got?.0, NodeID("root"))
        XCTAssertEqual(got?.1, "refactor auth module", "onRename receives the trimmed name")

        // empty/whitespace name → isError, callback NOT fired again
        await client.write(JSONLine.dump(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                          "params": ["name": "rename",
                                                     "arguments": ["name": "   "]]]))
        let bad = JSONLine.parse(await client.readLine() ?? "")
        let badRes = bad?["result"] as? [String: Any]
        XCTAssertEqual(badRes?["isError"] as? Bool, true)
        let badText = ((badRes?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(badText.contains("empty"))
        let fireCount = await box.count()
        XCTAssertEqual(fireCount, 1, "an empty name must not fire onRename again")

        await client.close()
        await t.value
    }

    func testMCPRenameRejectedForNonRoot() async throws {
        // Rename is root-only — a sub-manager calling it by name hits the hard trim.
        let pending = PendingReplies(); let sink = CommandSink()
        let box = RenameBox()
        let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending,
                                onRename: { node, name in Task { await box.set(node, name) } },
                                nodeInfo: { _ in (.manager, false, .claude) })
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await srv.handle(server) }

        await client.write(JSONLine.dump(["node": "root"]))
        await client.write(JSONLine.dump(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                          "params": ["name": "rename",
                                                     "arguments": ["name": "x"]]]))
        let resp = JSONLine.parse(await client.readLine() ?? "")
        let res = resp?["result"] as? [String: Any]
        XCTAssertEqual(res?["isError"] as? Bool, true)
        let text = ((res?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("not available"))
        let fireCount = await box.count()
        XCTAssertEqual(fireCount, 0, "a non-root rename must not reach onRename")

        await client.close()
        await t.value
    }

    func testMCPSubManagerToolSurfaceIsFourTools() async throws {
        // A sub-manager (role .manager, NOT root) holds the full four-tool surface —
        // spawn/send/report/kill. Root drops report (nowhere to go) and a worker keeps
        // report only.
        let pending = PendingReplies(); let sink = CommandSink()
        let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending,
                                nodeInfo: { _ in (.manager, false, .codex) })
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await srv.handle(server) }

        await client.write(JSONLine.dump(["node": "sm1"]))
        await client.write(JSONLine.dump(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
        let listResp = JSONLine.parse(await client.readLine() ?? "")
        let tools = (listResp?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }),
                       ["spawn", "send", "report", "kill"])
        // exact surface (no more, no fewer) — pin the count too so a future 5th tool trips here
        XCTAssertEqual(tools.count, 4)

        await client.close()
        await t.value
    }

    func testMCPHandshakeFiresOnConnect() async throws {
        // The "agent is online" signal Vigil uses to auto-flip a user-launched session into
        // orchestration mode the moment the user's claude connects to the MCP channel.
        let pending = PendingReplies(); let sink = CommandSink()
        let box = NodeBox()
        let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending,
                                onConnect: { node in Task { await box.set(node) } })
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await srv.handle(server) }

        await client.write(JSONLine.dump(["node": "root"]))                      // handshake only
        let connected = await box.first()
        XCTAssertEqual(connected, NodeID("root"))

        await client.close()
        await t.value
    }

    func testMCPSpawnReturnsChildIdImmediately() async throws {
        let pending = PendingReplies(); let sink = CommandSink()
        let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending)
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await srv.handle(server) }

        await client.write(JSONLine.dump(["node": "root"]))
        await client.write(JSONLine.dump([
            "jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": ["name": "spawn", "arguments": ["role": "leaf", "task": "compute sum 1..10"]],
        ]))

        let cmd = await sink.first()
        guard case .requestStruct(let req, let from, let replyID) = cmd else {
            return XCTFail("expected requestStruct, got \(cmd)")
        }
        XCTAssertEqual(from, NodeID("root"))
        guard case .spawn(let parent, let role, let task, _, _) = req else { return XCTFail() }
        XCTAssertEqual(parent, NodeID("root"))
        XCTAssertEqual(role, .leaf)
        XCTAssertEqual(task, "compute sum 1..10")

        // The store resolves synchronously (no human in the loop) — here the test stands
        // in for the store's immediate applyStruct+deliver; claude receives the child id.
        await pending.deliver(replyID, .structResult(.spawned(NodeID("n5"))))
        let resp = JSONLine.parse(await client.readLine() ?? "")
        XCTAssertEqual(resp?["id"] as? Int, 7)
        let content = (resp?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "n5")
        XCTAssertEqual((resp?["result"] as? [String: Any])?["isError"] as? Bool, false)

        await client.close()
        await t.value
    }

    func testMCPSpawnPassesOptionalModelThrough() async throws {
        // spawn's optional model rides the Command; omitting it stays nil
        // (= inherit the session default).
        let pending = PendingReplies(); let sink = CommandSink()
        let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending)
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await srv.handle(server) }

        await client.write(JSONLine.dump(["node": "root"]))
        await client.write(JSONLine.dump([
            "jsonrpc": "2.0", "id": 11, "method": "tools/call",
            "params": ["name": "spawn",
                       "arguments": ["role": "leaf", "task": "probe", "model": "haiku"]],
        ]))
        guard case .requestStruct(.spawn(_, _, _, let model, _), _, let replyID) = await sink.first() else {
            return XCTFail("expected spawn requestStruct")
        }
        XCTAssertEqual(model, "haiku")
        await pending.deliver(replyID, .structResult(.spawned(NodeID("n7"))))
        _ = await client.readLine()

        await client.write(JSONLine.dump([
            "jsonrpc": "2.0", "id": 12, "method": "tools/call",
            "params": ["name": "spawn", "arguments": ["role": "leaf", "task": "probe"]],
        ]))
        guard case .requestStruct(.spawn(_, _, _, let none, _), _, let replyID2) = await sink.first() else {
            return XCTFail("expected spawn requestStruct")
        }
        XCTAssertNil(none)
        await pending.deliver(replyID2, .structResult(.spawned(NodeID("n8"))))
        _ = await client.readLine()

        // schema mirror: model advertised as OPTIONAL — required stays role+task only
        let spawnSchema = MCPToolServer.toolSchemas.first { ($0["name"] as? String) == "spawn" }
        let input = spawnSchema?["inputSchema"] as? [String: Any]
        XCTAssertNotNil((input?["properties"] as? [String: Any])?["model"])
        XCTAssertEqual(input?["required"] as? [String], ["role", "task"])

        await client.close()
        await t.value
    }

    func testMCPSpawnPassesOptionalNameThrough() async throws {
        // spawn's optional display name rides the Command (blank = nil = task text
        // stays the tree label); schema mirror keeps name OPTIONAL.
        let pending = PendingReplies(); let sink = CommandSink()
        let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending)
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await srv.handle(server) }

        await client.write(JSONLine.dump(["node": "root"]))
        await client.write(JSONLine.dump([
            "jsonrpc": "2.0", "id": 21, "method": "tools/call",
            "params": ["name": "spawn",
                       "arguments": ["role": "leaf", "task": "fix issue #49",
                                     "name": "issue-49 fix"]],
        ]))
        guard case .requestStruct(.spawn(_, _, _, _, let name), _, let replyID)
            = await sink.first() else {
            return XCTFail("expected spawn requestStruct")
        }
        XCTAssertEqual(name, "issue-49 fix")
        await pending.deliver(replyID, .structResult(.spawned(NodeID("n7"))))
        _ = await client.readLine()

        await client.write(JSONLine.dump([
            "jsonrpc": "2.0", "id": 22, "method": "tools/call",
            "params": ["name": "spawn", "arguments": ["role": "leaf", "task": "t", "name": ""]],
        ]))
        guard case .requestStruct(.spawn(_, _, _, _, let blank), _, let replyID2)
            = await sink.first() else {
            return XCTFail("expected spawn requestStruct")
        }
        XCTAssertNil(blank, "an empty-string name = unspecified")
        await pending.deliver(replyID2, .structResult(.spawned(NodeID("n8"))))
        _ = await client.readLine()

        let spawnSchema = MCPToolServer.toolSchemas.first { ($0["name"] as? String) == "spawn" }
        let input = spawnSchema?["inputSchema"] as? [String: Any]
        XCTAssertNotNil((input?["properties"] as? [String: Any])?["name"], "the schema mirror is missing name")
        XCTAssertEqual(input?["required"] as? [String], ["role", "task"])

        await client.close()
        await t.value
    }

    // MARK: spawn(model) misuse guard wiring (the tool-server side: a rejected guard
    // must short-circuit BEFORE the requestStruct emit, so no node is ever created for it).

    func testMCPSpawnModelGuardRejectsAndEmitsNoStructRequest() async throws {
        let pending = PendingReplies(); let sink = CommandSink()
        let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending,
                                spawnModelGuard: { role, model in
                                    model == "codex" ? "\"codex\" looks like an agent name" : nil
                                })
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await srv.handle(server) }

        await client.write(JSONLine.dump(["node": "root"]))
        await client.write(JSONLine.dump([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "spawn",
                       "arguments": ["role": "leaf", "task": "t", "model": "codex"]],
        ]))
        let resp = JSONLine.parse(await client.readLine() ?? "")
        let result = resp?["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.hasPrefix("spawn rejected:"), "got: \(text)")
        XCTAssertTrue(text.contains("agent name"), "got: \(text)")
        XCTAssertEqual(result?["isError"] as? Bool, true)

        // A second, unguarded spawn must proceed normally — proving the rejected call above
        // emitted no requestStruct at all (this is the FIRST command the sink ever sees).
        await client.write(JSONLine.dump([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "spawn", "arguments": ["role": "leaf", "task": "t2"]],
        ]))
        guard case .requestStruct(.spawn(_, _, let task, _, _), _, let replyID)
            = await sink.first() else {
            return XCTFail("expected the SECOND spawn's requestStruct, meaning the first never emitted one")
        }
        XCTAssertEqual(task, "t2")
        await pending.deliver(replyID, .structResult(.spawned(NodeID("n9"))))
        _ = await client.readLine()

        await client.close()
        await t.value
    }

    func testMCPSpawnModelGuardPassingModelStillSpawnsNormally() async throws {
        let pending = PendingReplies(); let sink = CommandSink()
        let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending,
                                spawnModelGuard: { _, _ in nil })   // never rejects
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await srv.handle(server) }

        await client.write(JSONLine.dump(["node": "root"]))
        await client.write(JSONLine.dump([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "spawn",
                       "arguments": ["role": "leaf", "task": "t", "model": "gpt-9-experimental"]],
        ]))
        guard case .requestStruct(.spawn(_, _, _, let model, _), _, let replyID)
            = await sink.first() else {
            return XCTFail("expected requestStruct")
        }
        XCTAssertEqual(model, "gpt-9-experimental")
        await pending.deliver(replyID, .structResult(.spawned(NodeID("n3"))))
        let resp = JSONLine.parse(await client.readLine() ?? "")
        XCTAssertEqual((resp?["result"] as? [String: Any])?["isError"] as? Bool, false)

        await client.close()
        await t.value
    }

    func testMCPSendEmitsRoutedMessageAndReturnsSent() async throws {
        // The manager→worker downlink: send(node, message) → .message Command
        // (LCA-routed injection). send WAITS for the delivery verdict — "sent"
        // only after the route resolves as delivered.
        let pending = PendingReplies(); let sink = CommandSink()
        let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending)
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await srv.handle(server) }

        await client.write(JSONLine.dump(["node": "root"]))
        await client.write(JSONLine.dump([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "send", "arguments": ["node": "n2", "message": "use postgres, not sqlite"]],
        ]))

        let cmd = await sink.first()
        guard case .message(let from, let to, let text, let replyID) = cmd else {
            return XCTFail("expected message, got \(cmd)")
        }
        XCTAssertEqual(from, NodeID("root"))
        XCTAssertEqual(to, NodeID("n2"))
        XCTAssertEqual(text, "MESSAGE FROM root: use postgres, not sqlite")

        // store/runtime stand-in: the route reached a live cell
        let rid = try XCTUnwrap(replyID)
        await pending.deliver(rid, .sendAck(delivered: true, note: "sent"))
        let resp = JSONLine.parse(await client.readLine() ?? "")
        let content = (resp?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "sent")
        XCTAssertEqual((resp?["result"] as? [String: Any])?["isError"] as? Bool, false)

        await client.close()
        await t.value
    }

    func testMCPSendUnreachableNodeReturnsError() async throws {
        // An unroutable target must come back isError=true with a
        // readable reason — not a lying "sent".
        let pending = PendingReplies(); let sink = CommandSink()
        let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending)
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await srv.handle(server) }

        await client.write(JSONLine.dump(["node": "root"]))
        await client.write(JSONLine.dump([
            "jsonrpc": "2.0", "id": 5, "method": "tools/call",
            "params": ["name": "send", "arguments": ["node": "n9", "message": "hello?"]],
        ]))

        guard case .message(_, _, _, let replyID) = await sink.first() else {
            return XCTFail("expected message command")
        }
        let rid = try XCTUnwrap(replyID)
        await pending.deliver(rid, .sendAck(delivered: false,
                                            note: "node n9 not reachable: no live cell"))
        let resp = JSONLine.parse(await client.readLine() ?? "")
        let content = (resp?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "node n9 not reachable: no live cell")
        XCTAssertEqual((resp?["result"] as? [String: Any])?["isError"] as? Bool, true)

        await client.close()
        await t.value
    }

    func testMCPResolutionTextMappingPins() async throws {
        // Pin the Resolution → (text, isError) wire mapping — kill's joined ids, a denied
        // spawn, and a cancelled send must keep their exact reply bytes.
        let pending = PendingReplies(); let sink = CommandSink()
        let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending)
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await srv.handle(server) }
        func reply() async -> (text: String?, isError: Bool?) {
            let resp = JSONLine.parse(await client.readLine() ?? "")
            let result = resp?["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            return (content?.first?["text"] as? String, result?["isError"] as? Bool)
        }

        await client.write(JSONLine.dump(["node": "root"]))

        // kill → comma-joined subtree ids, isError false
        await client.write(JSONLine.dump([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "kill", "arguments": ["node": "n2"]],
        ]))
        guard case .requestStruct(_, _, let killReply) = await sink.first() else {
            return XCTFail("expected kill requestStruct")
        }
        await pending.deliver(killReply, .structResult(.killed([NodeID("n2"), NodeID("n3")])))
        var r = await reply()
        XCTAssertEqual(r.text, "n2,n3"); XCTAssertEqual(r.isError, false)

        // spawn denied → "denied: <reason>", isError true
        await client.write(JSONLine.dump([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "spawn", "arguments": ["role": "leaf", "task": "t"]],
        ]))
        guard case .requestStruct(_, _, let spawnReply) = await sink.first() else {
            return XCTFail("expected spawn requestStruct")
        }
        await pending.deliver(spawnReply, .structResult(.denied(reason: "no such parent")))
        r = await reply()
        XCTAssertEqual(r.text, "denied: no such parent"); XCTAssertEqual(r.isError, true)

        // cancelled send → "cancelled: <reason>", isError true
        await client.write(JSONLine.dump([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "send", "arguments": ["node": "n2", "message": "hi"]],
        ]))
        guard case .message(_, _, _, let sendReply) = await sink.first(),
              let sendReply else { return XCTFail("expected message with replyID") }
        await pending.deliver(sendReply, .cancelled(reason: "node died"))
        r = await reply()
        XCTAssertEqual(r.text, "cancelled: node died"); XCTAssertEqual(r.isError, true)

        await client.close()
        await t.value
    }

    // MARK: cross-kind Resolution = loud failure
    // A tool must never accept a Resolution kind it doesn't own: that only happens on a
    // Core wiring bug, and mapping it "by kind" must never turn the bug into a fake success.
    // Each call site pins: wrong kind → "unexpected: …" + isError=true.

    func testMCPSpawnCrossKindResolutionIsLoudError() async throws {
        let pending = PendingReplies(); let sink = CommandSink()
        let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending)
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await srv.handle(server) }

        await client.write(JSONLine.dump(["node": "root"]))
        await client.write(JSONLine.dump([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "spawn", "arguments": ["role": "leaf", "task": "t"]],
        ]))
        guard case .requestStruct(_, _, let replyID) = await sink.first() else {
            return XCTFail("expected spawn requestStruct")
        }
        // a sendAck can only reach a spawn wait through a Core wiring bug
        await pending.deliver(replyID, .sendAck(delivered: true, note: "sent"))
        let resp = JSONLine.parse(await client.readLine() ?? "")
        let result = resp?["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.hasPrefix("unexpected:"), "got: \(text)")
        XCTAssertEqual(result?["isError"] as? Bool, true)

        await client.close()
        await t.value
    }

    func testMCPSendCrossKindResolutionIsLoudError() async throws {
        let pending = PendingReplies(); let sink = CommandSink()
        let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending)
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await srv.handle(server) }

        await client.write(JSONLine.dump(["node": "root"]))
        await client.write(JSONLine.dump([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "send", "arguments": ["node": "n2", "message": "hi"]],
        ]))
        guard case .message(_, _, _, let replyID) = await sink.first(),
              let replyID else { return XCTFail("expected message with replyID") }
        await pending.deliver(replyID, .structResult(.spawned(NodeID("n9"))))
        let resp = JSONLine.parse(await client.readLine() ?? "")
        let result = resp?["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.hasPrefix("unexpected:"), "got: \(text)")
        XCTAssertEqual(result?["isError"] as? Bool, true)

        await client.close()
        await t.value
    }

    func testMCPReportIsFireAndForget() async throws {
        let pending = PendingReplies(); let sink = CommandSink()
        let srv = MCPToolServer(emit: { c in Task { await sink.add(c) } }, pending: pending)
        let (server, client) = PipeLineChannel.pair()
        let t = Task { await srv.handle(server) }

        await client.write(JSONLine.dump(["node": "n9"]))
        await client.write(JSONLine.dump([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "report", "arguments": ["summary": "sum=55"]],
        ]))
        let cmd = await sink.first()
        guard case .rollup(let from, let summary) = cmd else { return XCTFail("expected rollup") }
        XCTAssertEqual(from, NodeID("n9"))
        XCTAssertEqual(summary, "sum=55")
        let resp = JSONLine.parse(await client.readLine() ?? "")
        XCTAssertEqual((resp?["result"] as? [String: Any])?["isError"] as? Bool, false)

        await client.close()
        await t.value
    }
}
