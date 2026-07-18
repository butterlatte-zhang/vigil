import Foundation
import VigilCore

/// A scriptable stand-in agent for UI tests (T2) — runs an
/// arbitrary script via /bin/bash instead of a real claude, so golden flows never burn
/// tokens. The cell's REAL channel endpoints are exported as VIGIL_* env vars, letting
/// the script drive the production paths itself (hook UDS → notification cards, MCP UDS
/// → spawn/report through the actual gate). Pure injection point: the app only selects
/// this harness when the XCUITest runner sets VIGIL_FAKE_AGENT_CMD (see AppModel's
/// UITestSupport); product logic and semantics are untouched otherwise.
public struct ScriptHarness: Harness {
    public let id = "script"

    /// Path of (or inline) bash script; launched as `/bin/bash <command>`.
    let command: String

    public init(command: String) { self.command = command }

    public func launchSpec(task: String, cwd: String, nodeID: NodeID,
                           role: Role, isRoot: Bool, model: String? = nil,
                           resumeSessionId: String? = nil,   // fake agent: nothing to resume
                           mcpEndpoint: String?, hookEndpoint: String?,
                           idCred: String?) -> LaunchSpec {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = vigilFallbackTERM
        env["VIGIL_NODE"] = nodeID.raw
        env["VIGIL_TASK"] = task
        env["VIGIL_ROLE"] = isRoot ? "root" : role.rawValue
        if let hookEndpoint { env["VIGIL_HOOK_SOCK"] = hookEndpoint }
        if let mcpEndpoint { env["VIGIL_MCP_SOCK"] = mcpEndpoint }
        return LaunchSpec(executable: "/bin/bash", args: [command], env: env)
    }
}
