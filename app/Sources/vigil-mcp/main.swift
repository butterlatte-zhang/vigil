// vigil-mcp — the MCP channel's dumb stdio↔UDS pipe (DOCTRINE §5.4).
//
// claude launches this as a stdio MCP server. It connects to the app's UDS, sends a
// one-line {node} handshake (plaintext identity, §10.0), then transparently
// splices claude's MCP JSON-RPC stream: stdin → socket and socket → stdout, byte for
// byte. All MCP protocol logic lives in the app's MCPToolServer — this shim stays trivial.

import Foundation
import VigilShimCore   // arg / connectUDS(SO_NOSIGPIPE) / writeAll — shared with vigil-hook
#if canImport(Darwin)
import Darwin
#endif

let node = arg("--node") ?? "?"
guard let sock = arg("--sock"), let fd = connectUDS(sock) else {
    // Can't reach the app: exit non-zero so claude reports the MCP server as unavailable
    // rather than hanging. (Core loop degrades; perm hook is independent.)
    exit(1)
}

// Handshake: bind this connection to the node id.
if let hs = try? JSONSerialization.data(withJSONObject: ["node": node]) {
    var line = Array(hs); line.append(0x0A)
    writeAll(fd, line[...])
}

// socket → stdout
let pump = Thread {
    var buf = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        writeAll(1, buf[0..<n])
    }
    exit(0)
}
pump.stackSize = 1 << 20
pump.start()

// stdin → socket (main thread)
var buf = [UInt8](repeating: 0, count: 8192)
while true {
    let n = read(0, &buf, buf.count)
    if n <= 0 { break }
    writeAll(fd, buf[0..<n])
}
close(fd)
exit(0)
