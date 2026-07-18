// vigil-hook — the observation channel's tiny hook client (see DOCTRINE §5.1).
//
// claude invokes this as a hook command (UserPromptSubmit / PermissionRequest /
// PostToolUse / Stop — the --event value names the channel: prompt / perm-request /
// post-tool / stop; the binary forwards ANY value verbatim, unknown ones the
// gateway drops — e.g. an unrecognized "notification" feed).
// It reads claude's hook JSON from stdin (carries hook_event_name etc.), forwards one
// envelope line {node, event, payload} to the app's HookGateway over a UDS, and exits —
// it never waits for a reply and never prints anything (no permissionDecision
// write-back; approvals live in claude's native flow). On ANY failure it exits 0 →
// fail-open is trivially true, never a hang.

import Foundation
import VigilShimCore   // arg / connectUDS(SO_NOSIGPIPE) / writeAll — shared with vigil-mcp
#if canImport(Darwin)
import Darwin
#endif

let node = arg("--node") ?? "?"
let event = arg("--event") ?? "notification"   // forwarded verbatim; gateway routes/drops
guard let sock = arg("--sock") else { exit(0) }

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
let payload = String(data: stdinData, encoding: .utf8) ?? ""

guard let fd = connectUDS(sock) else { exit(0) }
defer { close(fd) }

let envelope: [String: Any] = ["node": node, "event": event, "payload": payload]
if let envData = try? JSONSerialization.data(withJSONObject: envelope),
   var line = String(data: envData, encoding: .utf8) {
    line = line.replacingOccurrences(of: "\n", with: " ") + "\n"
    writeAll(fd, Array(line.utf8)[...])
}

// Fire-and-forget: no reply to read, nothing to print.
exit(0)
