// vigil-smoke — the real-claude end-to-end smoke (Tier-2, MANUAL; never run by `swift
// test`). Stands the whole product stack up against a REAL claude and reproduces the
// core loop with no human approval step:
//   • a root MANAGER cell (RealCell + ClaudeCodeHarness) is told to delegate
//   • it calls the Vigil MCP `spawn` tool → applied IMMEDIATELY → a child cell launches
//     (MCP transport + sync spine resolve without a human)
//   • the child runs `echo > result.txt` — permission level is claude-native;
//     the smoke uses --permission-mode bypassPermissions so no native dialog blocks it
//   • the child reads it back and calls `report` → rollup routes to the parent
// Disk ground truth (result.txt) is cross-checked.
//
// Run:  cd app && swift run vigil-smoke   (needs CLAUDE_BIN, or claude on PATH)

import Foundation
import VigilCore
import VigilRuntime

setvbuf(stdout, nil, _IOLBF, 0)

func hr(_ s: String) { print(String(repeating: "=", count: 72)); print(s); print(String(repeating: "=", count: 72)) }

let claudeBin = ProcessInfo.processInfo.environment["CLAUDE_BIN"] ?? "claude"
guard FileManager.default.isExecutableFile(atPath: claudeBin) else {
    print("SKIP: claude binary not found/executable at \(claudeBin). Set CLAUDE_BIN."); exit(2)
}

// Resolve sibling shim executables (same .build dir as this binary) via SiblingBins.
let (hookBin, mcpBin) = SiblingBins.locate()
for b in [hookBin, mcpBin] where !FileManager.default.isExecutableFile(atPath: b) {
    print("FAIL: shim missing: \(b) (run `swift build` first)"); exit(1)
}

let sessionDir = NSTemporaryDirectory() + "vigil_smoke_\(getpid())"

let CHILD_TASK = "Run exactly this one shell command and nothing else: "
    + "echo VIGIL_PROOF_$(date +%s) > result.txt ; "
    + "then read result.txt back and call the `report` tool with its exact contents as the summary."
let MANAGER_TASK = "You are a manager and you are FORBIDDEN to do the subtask yourself. "
    + "Call the `spawn` tool EXACTLY ONCE with role=\"leaf\" and task set to EXACTLY this string: "
    + "\"\(CHILD_TASK)\"  — emit the real tool call, do not describe it. "
    + "After spawn returns the child node id, briefly state the id; you are done."

hr("VIGIL SMOKE — real claude through the product stack (RealCell + hooks + MCP, D13)")
print("  claude :", claudeBin)
print("  shims  :", hookBin, "|", mcpBin)
print("  session:", sessionDir)

@MainActor
func runSmoke() async -> Int32 {
    let root = Node(id: NodeID("root"), role: .manager, status: .running, title: "manager")
    // Interactive (not -p): the manager must stay alive while the child works — a -p
    // manager would exit right after spawn returns and its self-death would cascade-kill
    // the child (§6.4). Interactive also matches the real product (root = live terminal).
    // bypassPermissions: the smoke is headless — no human at the child's terminal to click
    // claude's native approval dialog (permission level = claude-native mechanism).
    // strictMCP: Tier-2 determinism — the smoke must see ONLY the vigil server, never
    // whatever MCP config this machine's user happens to have.
    // Build through the dispatch layer: no userConfigDir → registry nil → resolves to
    // the claude family, byte-identical to the plain ClaudeCodeHarness path.
    let codexBin = ProcessInfo.processInfo.environment["CODEX_BIN"] ?? "codex"
    let opencodeBin = ProcessInfo.processInfo.environment["OPENCODE_BIN"] ?? "opencode"
    let harness = DispatchHarness(claudeBin: claudeBin, codexBin: codexBin,
                                  opencodeBin: opencodeBin,
                                  hookBin: hookBin, mcpBin: mcpBin,
                                  configRoot: sessionDir + "/config", printMode: false,
                                  permissionMode: .bypass, strictMCP: true)
    let orch = Orchestrator(rootNode: root, harness: harness, sessionDir: sessionDir) {
        _ in HeadlessBackend(cols: 200, rows: 50)
    }
    do { try orch.start(rootTask: MANAGER_TASK) }
    catch { print("FAIL: orchestrator start: \(error)"); return 1 }

    var childIDs: Set<NodeID> = []
    var trustHandled: Set<NodeID> = []
    let start = Date()
    let timeout: TimeInterval = 240

    // claude shows a one-time "trust the files in this folder?" startup gate (not a tool
    // perm, so not on the hook path). At a real terminal the human answers it; here the
    // smoke stands in, selecting option 1 directly on the cell's PTY.
    func handleTrustPrompts() async {
        for id in orch.registry.nodeIDs where !trustHandled.contains(id) {
            guard let cell = orch.registry.cell(id) else { continue }
            let screen = (await cell.snapshot()).lowercased()
            if screen.contains("trust the files") || screen.contains("do you trust") {
                print("[smoke] trust gate on \(id) -> selecting 1")
                orch.registry.backend(id)?.send("1")
                trustHandled.insert(id)
            }
        }
    }

    func diskProof() -> String? {
        for id in childIDs {
            let p = sessionDir + "/work/\(id.raw)/result.txt"
            if let s = try? String(contentsOfFile: p, encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.contains("VIGIL_PROOF_") { return t }
            }
        }
        return nil
    }
    func anyRollup() -> String? {
        for (_, n) in orch.store.tree.nodes where n.lastRollup != nil { return n.lastRollup }
        return nil
    }

    var announcedSpawn = false
    while Date().timeIntervalSince(start) < timeout {
        await handleTrustPrompts()
        // Spawn applies immediately — no approval step; just track spawned children.
        for (id, n) in orch.store.tree.nodes where n.parent != nil { childIDs.insert(id) }
        if !childIDs.isEmpty && !announcedSpawn {
            announcedSpawn = true
            print("\n[smoke] spawn effected immediately (no human gate): \(childIDs.map(\.raw))")
        }
        // Observation notices (PermissionRequest hook) — print-only; nothing to answer here.
        for notice in orch.store.notices {
            print("[smoke] NOTICE [\(notice.nodeID)]: \(notice.text)")
        }

        if let proof = diskProof(), anyRollup() != nil {
            print("\n[smoke] disk proof + rollup present, finishing early. proof=\(proof)")
            break
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    // ---- verdict ----
    let proof = diskProof()
    let rollup = anyRollup()
    let childCount = orch.store.tree.nodes.count - 1
    orch.stop()

    print("\n" + String(repeating: "-", count: 72))
    print("  H   MCP struct fired (claude really called spawn)  :", childCount >= 1)
    print("  child cell(s) spawned (immediate, D13)             :", childCount)
    print("  child disk proof (result.txt VIGIL_PROOF_)         :", proof ?? "(none)")
    print("  rollup received (child reported up)                :", rollup ?? "(none)")
    print("  store log tail:")
    for line in orch.store.log.suffix(14) { print("    | " + line) }

    // Core-loop pass = the load-bearing transports + the immediate spawn + the disk write.
    let corePass = childCount >= 1 && proof != nil
    hr(corePass ? "VIGIL SMOKE: ✅ PASS — core loop ran through the product stack"
                : "VIGIL SMOKE: ❌ FAIL — see flags above")
    if corePass && rollup == nil {
        print("  (note: bonus signal incomplete — rollup missing; core still green)")
    }
    try? FileManager.default.removeItem(atPath: sessionDir)
    return corePass ? 0 : 1
}

let rc = await runSmoke()
exit(rc)
