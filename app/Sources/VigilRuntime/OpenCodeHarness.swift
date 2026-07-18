import Foundation
import VigilCore

/// The opencode harness (heterogeneous worker support). opencode-ai 1.17.16. The cleanest
/// of the three families to wire — everything but the plugin file rides ONE env var, zero
/// disk, zero repo write:
///   - MCP  → `OPENCODE_CONFIG_CONTENT` inline JSON `mcp.vigil` (SAME vigil-mcp stdio binary);
///   - three roles → `agent.<root|sub-manager|worker>.prompt` = ClaudeCodeHarness.skill,
///     selected by `--agent`; the server-side MCPToolServer role-trim is the hard tool surface
///     (CLI-agnostic), opencode's own agent.tools would be a redundant second layer;
///   - state truth chain → a per-node PLUGIN (the only thing on disk, written to the node's
///     vigil config dir, never the repo) that execs `vigil-hook` on the events we care about —
///     the SAME `--node/--sock/--event` + stdin-JSON contract as claude/codex hooks, so the
///     reverse channel lands on HookGateway verbatim-isomorphically.
/// Permission all-open = `--auto` (agent-native). `OPENCODE_CONFIG_CONTENT` OVERLAYS the user's
/// global opencode config (auth/providers merge in rather than being replaced) — so unlike
/// codex we need no auth handling.
///
/// Tool namespace: opencode DISPLAYS the tool as `vigil_report`, but the JSON-RPC
/// `tools/call.name` on the wire is the BARE `report` (the server's advertised name) — so
/// MCPToolServer needs no strip, same as claude/codex.
public struct OpenCodeHarness: Harness {
    public let id = "opencode"

    let opencodeBin: String
    let hookBin: String
    let mcpBin: String
    let configRoot: String        // per-node plugin file lives at <configRoot>/<node>/oc-plugin.js
    let printMode: Bool           // true = `opencode run` (headless, tests) · false = TUI (cell)
    let permissionMode: PermissionMode
    let model: String?
    let userConfigDir: String?
    let agentKey: String?

    public init(opencodeBin: String, hookBin: String, mcpBin: String, configRoot: String,
                printMode: Bool = false,
                permissionMode: PermissionMode = .standard,
                model: String? = nil,
                userConfigDir: String? = nil,
                agentKey: String? = nil) {
        self.opencodeBin = opencodeBin; self.hookBin = hookBin; self.mcpBin = mcpBin
        self.configRoot = configRoot; self.printMode = printMode
        self.permissionMode = permissionMode; self.model = model
        self.userConfigDir = userConfigDir; self.agentKey = agentKey
    }

    /// Role → opencode agent name (config.agent.<name> + `--agent <name>`).
    static func agentName(role: Role, isRoot: Bool) -> String {
        if isRoot { return "root" }
        return role == .manager ? "sub-manager" : "worker"
    }

    public func launchSpec(task: String, cwd: String, nodeID: NodeID,
                           role: Role, isRoot: Bool, model: String? = nil,
                           resumeSessionId: String? = nil,
                           mcpEndpoint: String?, hookEndpoint: String?,
                           idCred: String?) -> LaunchSpec {
        let resolved = HarnessResolve.resolve(
            userConfigDir: userConfigDir, claudeBin: opencodeBin, cwd: cwd,
            role: role, isRoot: isRoot, sessionKey: agentKey, kind: .opencode)
        let entry = resolved.entry
        let roleCfg = resolved.roleCfg

        let agentName = Self.agentName(role: role, isRoot: isRoot)
        let skill = ClaudeCodeHarness.skill(
            role: role, isRoot: isRoot, kind: .opencode,
            promptBase: resolved.promptBase,
            promptOverride: roleCfg?.promptOverride, promptAppend: roleCfg?.promptAppend,
            promptExtras: resolved.promptExtras)

        // The plugin file (reverse channel) — the ONLY thing on disk, in the node's vigil
        // config dir. Its per-node identity (node/sock) rides env, so the JS is static.
        let nodeDir = (configRoot as NSString).appendingPathComponent(nodeID.raw)
        let pluginPath: String? = hookEndpoint == nil ? nil
            : Self.writePlugin(dir: nodeDir)

        // OPENCODE_CONFIG_CONTENT: mcp (if wired) + plugin (if wired) + this node's agent.
        var cfg: [String: Any] = ["$schema": "https://opencode.ai/config.json"]
        if let mcpSock = mcpEndpoint {
            cfg["mcp"] = ["vigil": ["type": "local",
                                    "command": [mcpBin, "--node", nodeID.raw, "--sock", mcpSock],
                                    "enabled": true]]
        }
        if let pluginPath = pluginPath { cfg["plugin"] = [pluginPath] }
        cfg["agent"] = [agentName: ["prompt": skill, "mode": "primary"]]

        let resolvedModel = HarnessResolve.resolveModel(
            param: model, sessionModel: self.model, kind: .opencode, resolved: resolved,
            isRoot: isRoot)

        var args: [String] = []
        var initialPrompt: String?
        if printMode { args += ["run", "--format", "json"] }   // headless (tests) vs TUI cell
        args += ["--agent", agentName]
        // Per-role roles.json `access` overrides the session default (all-open fallback).
        if Self.autoApprove(roleCfg?.access ?? permissionMode) { args.append("--auto") }
        if let m = resolvedModel { args += ["-m", m] }
        if let extra = entry?.extraArgs, !extra.isEmpty { args += extra }
        if let sid = resumeSessionId {
            args += ["--session", ClaudeCodeHarness.neutralizeLeadingDash(sid)]
        } else if !task.isEmpty {
            // The TUI cell takes the initial message via PTY injection
            // (RealCell.deliverInitialPrompt), NOT `--prompt` — keeping the task out of argv
            // where `ps`/`pkill -f` could read/match it. Headless `run` (tests, ephemeral)
            // keeps the positional message — no PTY to inject into. (The identity skill already
            // rides OPENCODE_CONFIG_CONTENT/env, never argv, so nothing else to move.)
            if printMode { args.append(ClaudeCodeHarness.neutralizeLeadingDash(task)) }
            else { initialPrompt = task }
        }

        // Config hygiene: inherit user env, overlay entry.env (integration point: provider
        // keys / base URLs), then the vigil channels. OPENCODE_CONFIG_CONTENT MERGES with the user's
        // global config (auth/providers survive). VIGIL_* feed the plugin's reverse channel.
        var env = ProcessInfo.processInfo.environment
        if let e = entry { for (k, v) in e.env { env[k] = v } }
        if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            env["OPENCODE_CONFIG_CONTENT"] = json
        }
        if let hookSock = hookEndpoint {
            env["VIGIL_HOOK_BIN"] = hookBin
            env["VIGIL_NODE"] = nodeID.raw
            env["VIGIL_SOCK"] = hookSock
        }
        env["TERM"] = vigilFallbackTERM

        let bin = entry.map { VigilConfigDir.expandTilde($0.bin) } ?? opencodeBin
        return LaunchSpec(executable: bin, args: args, env: env, initialPrompt: initialPrompt)
    }

    /// PermissionMode → opencode all-open: bypass = `--auto` (auto-approve). Guarded modes keep
    /// opencode's native prompting (no --auto).
    static func autoApprove(_ mode: PermissionMode) -> Bool { mode == .bypass }

    // MARK: reverse-channel plugin

    /// Write the per-node plugin and return its path. Static JS: it reads VIGIL_NODE/SOCK/
    /// HOOK_BIN from env and execs vigil-hook on the mapped events. The event → HookEvent
    /// map is interpolated from the enum so the two ends can't drift.
    @discardableResult
    static func writePlugin(dir: String) -> String {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("oc-plugin.js")
        try? pluginJS().write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// The forwarder JS. opencode's `event` bus + typed hooks → vigil-hook, mirroring the
    /// claude/codex hook set: session.idle → stop, a user message → prompt, tool.execute.after
    /// → post-tool, permission.ask → perm-request. High-volume events (message.part.delta …)
    /// are dropped. session.idle carries sessionID (opencode transcripts are SQLite, so no
    /// transcript_path — sid is what rides through for resume/naming).
    static func pluginJS() -> String {
        """
        import { spawn } from "node:child_process"
        const HOOK = process.env.VIGIL_HOOK_BIN, NODE = process.env.VIGIL_NODE, SOCK = process.env.VIGIL_SOCK
        function fire(event, payload) {
          if (!HOOK || !NODE || !SOCK) return
          try {
            const p = spawn(HOOK, ["--node", NODE, "--sock", SOCK, "--event", event],
                            { stdio: ["pipe", "ignore", "ignore"], detached: true })
            p.on("error", () => {})
            p.stdin.write(JSON.stringify(payload || {})); p.stdin.end(); p.unref()
          } catch (e) {}
        }
        export default async function () {
          return {
            event: async ({ event }) => {
              const t = event && event.type, p = (event && event.properties) || {}
              if (t === "session.idle") fire("\(HookEvent.stop.rawValue)", { session_id: p.sessionID, hook_event_name: t })
              else if (t === "message.updated" && p.info && p.info.role === "user")
                fire("\(HookEvent.prompt.rawValue)", { session_id: p.sessionID, hook_event_name: t })
            },
            "tool.execute.after": async (input) => fire("\(HookEvent.postTool.rawValue)", { tool: input && input.tool }),
            "permission.ask": async () => fire("\(HookEvent.permRequest.rawValue)", {}),
          }
        }
        """
    }
}
