import Foundation
import VigilCore

/// The hook channel's event names — the ONE truth source shared by the mount side
/// (ClaudeCodeHarness writes `--event <rawValue>` into each node's settings.json) and
/// the dispatch side (HookGateway switches the envelope's event through here). Keeping both
/// ends pinned to this single enum avoids the two spelling the strings independently, where
/// one typo would silently kill the channel. Wire literals pinned by HookEventTests. Anything
/// NOT in the enum parses to nil = the gateway's observe-only drop.
public enum HookEvent: String {
    case prompt                          // UserPromptSubmit
    case permRequest = "perm-request"    // PermissionRequest (box appeared)
    case postTool = "post-tool"          // PostToolUse (approval resolved)
    case stop                            // Stop (turn ended)
}

/// The four observation hooks, built ONCE for every harness family. claude bakes this into
/// settings.json; codex into $CODEX_HOME/hooks.json — same nested
/// `{EventName:[{hooks:[{type,command}]}]}` shape, same fire-and-forget
/// `vigil-hook --node N --sock S --event X` command-line contract. Keeping the map here is
/// the mirror law for the state-truth chain across CLIs.
enum HookConfig {
    static func observationHooks(hookBin: String, node: NodeID, hookSock: String)
        -> [String: Any] {
        let base = "\(posixShellQuote(hookBin)) --node \(node.raw) --sock \(posixShellQuote(hookSock))"
        func entry(_ event: HookEvent) -> [[String: Any]] {
            [["hooks": [["type": "command", "command": base + " --event \(event.rawValue)"]]]]
        }
        return [
            "UserPromptSubmit": entry(.prompt),      // → auto-namer + clearNotices
            "PermissionRequest": entry(.permRequest), // → permission card
            "PostToolUse": entry(.postTool),          // → resolve pairing
            "Stop": entry(.stop),                     // → turn ended (idle/running)
        ]
    }
}
