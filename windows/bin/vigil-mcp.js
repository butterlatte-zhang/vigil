#!/usr/bin/env node
// vigil-mcp — the MCP channel's dumb stdio<->named-pipe splice.
//
// claude/codex launch this as a stdio MCP server. It connects to the app's per-session
// named pipe, sends a one-line {node} handshake (plaintext identity), then transparently
// splices the MCP JSON-RPC stream: stdin -> pipe and pipe -> stdout, byte for byte. All
// protocol logic lives in the app's MCPToolServer — this shim stays trivial.

import net from 'node:net'

function arg(name) {
  const i = process.argv.indexOf(name)
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : null
}

const node = arg('--node') ?? '?'
const sock = arg('--sock')
if (!sock) {
  // Can't reach the app: exit non-zero so the CLI reports the MCP server unavailable
  // rather than hanging. (The Core loop degrades; the hook channel is independent.)
  process.exit(1)
}

const socket = net.connect(sock)
let connected = false

socket.setNoDelay(true)
socket.on('connect', () => {
  connected = true
  socket.write(JSON.stringify({ node }) + '\n')
  process.stdin.on('data', (chunk) => socket.write(chunk))
  process.stdin.on('end', () => socket.end())
  process.stdin.resume()
})
socket.on('data', (chunk) => {
  if (!process.stdout.write(chunk)) socket.pause()
})
process.stdout.on('drain', () => socket.resume())
socket.on('close', () => process.exit(0))
socket.on('error', () => process.exit(connected ? 0 : 1))
// A dead app must never leave an agent hung: if the pipe cannot be reached promptly,
// fail loudly (the agent then treats the MCP server as unavailable).
setTimeout(() => {
  if (!connected) process.exit(1)
}, 5000).unref()
