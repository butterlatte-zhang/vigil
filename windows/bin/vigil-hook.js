#!/usr/bin/env node
// vigil-hook — the observation channel's tiny hook client.
//
// claude/codex invoke this as a hook command (UserPromptSubmit / PermissionRequest /
// PostToolUse / Stop — the --event value names the channel). It reads the CLI's hook
// JSON from stdin, forwards one envelope line {node, event, payload} to the app's hook
// pipe, and exits — it never waits for a reply and never prints anything. On ANY failure
// it exits 0, so a missing app can never hang or break the agent's own turn.

import net from 'node:net'

function arg(name) {
  const i = process.argv.indexOf(name)
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : null
}

const node = arg('--node') ?? '?'
const event = arg('--event') ?? 'notification'
const sock = arg('--sock')
if (!sock) process.exit(0)

const chunks = []
process.stdin.on('data', (c) => chunks.push(c))
process.stdin.on('end', () => send())
process.stdin.on('error', () => process.exit(0))
setTimeout(() => send(), 10000).unref()

let sent = false
function send() {
  if (sent) return
  sent = true
  const payload = Buffer.concat(chunks).toString('utf8')
  const socket = net.connect(sock)
  const done = () => {
    try {
      socket.destroy()
    } catch {
      // ignore
    }
    process.exit(0)
  }
  socket.setTimeout(2000, done)
  socket.on('connect', () => {
    socket.write(JSON.stringify({ node, event, payload }).replace(/\n/g, ' ') + '\n', done)
  })
  socket.on('error', done)
  socket.on('close', done)
}
