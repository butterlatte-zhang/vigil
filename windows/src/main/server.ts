// Vigil for Windows — HTTP + WebSocket bridge.
//
// The core serves the built renderer and streams session state / PTY bytes over a
// WebSocket. All mutations are explicit messages; the renderer never touches a cell
// directly. Bound to loopback only; the WebSocket upgrade requires the per-process token
// handed to the shell via the ready line.

import fs from 'node:fs'
import http from 'node:http'
import path from 'node:path'
import { WebSocketServer, type WebSocket } from 'ws'
import type { SessionManager } from './session-manager.js'
import { packageRoot } from './paths.js'

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.woff2': 'font/woff2',
  '.map': 'application/json',
}

export interface ServerHandle {
  port: number
  close: () => void
}

export function startServer(
  manager: SessionManager,
  opts: { port?: number; token: string },
): Promise<ServerHandle> {
  const rendererDir = path.join(packageRoot, 'dist', 'renderer')

  const server = http.createServer((req, res) => {
    const url = new URL(req.url ?? '/', 'http://localhost')
    let rel = decodeURIComponent(url.pathname)
    if (rel === '/' || rel === '') rel = '/index.html'
    const file = path.join(rendererDir, rel)
    if (!file.startsWith(rendererDir)) {
      res.writeHead(403).end('forbidden')
      return
    }
    fs.readFile(file, (err, data) => {
      if (err) {
        // SPA fallback
        fs.readFile(path.join(rendererDir, 'index.html'), (e2, index) => {
          if (e2) {
            res.writeHead(404).end('not found — run `npm run build:renderer`')
            return
          }
          res.writeHead(200, { 'content-type': MIME['.html'] }).end(index)
        })
        return
      }
      res.writeHead(200, { 'content-type': MIME[path.extname(file)] ?? 'application/octet-stream' })
      res.end(data)
    })
  })

  const wss = new WebSocketServer({ noServer: true })
  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url ?? '/', 'http://localhost')
    if (url.searchParams.get('token') !== opts.token) {
      socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n')
      socket.destroy()
      return
    }
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req))
  })

  const broadcast = (obj: unknown) => {
    const data = JSON.stringify(obj)
    for (const client of wss.clients) {
      if (client.readyState === client.OPEN) client.send(data)
    }
  }

  manager.attach({
    state: () => broadcast({ type: 'state', state: manager.state() }),
    pty: (sessionId, nodeId, data) => broadcast({ type: 'pty', sessionId, nodeId, data }),
    ptyExit: (sessionId, nodeId) => broadcast({ type: 'ptyExit', sessionId, nodeId }),
  })

  const toast = (text: string) => broadcast({ type: 'toast', text })

  wss.on('connection', (ws: WebSocket) => {
    ws.send(JSON.stringify({ type: 'state', state: manager.state() }))
    ws.on('message', (raw) => {
      let msg: any
      try {
        msg = JSON.parse(raw.toString())
      } catch {
        return
      }
      handle(msg, ws).catch((e) => toast(String(e)))
    })
  })

  async function handle(msg: any, ws: WebSocket): Promise<void> {
    switch (msg.type) {
      case 'refresh':
        ws.send(JSON.stringify({ type: 'state', state: manager.state() }))
        return
      case 'newSession': {
        const res = await manager.newSession({
          projectId: msg.projectId ?? null,
          agentKey: msg.agentKey ?? null,
          task: typeof msg.task === 'string' ? msg.task : '',
          model: typeof msg.model === 'string' && msg.model ? msg.model : null,
          permissionMode: msg.permissionMode,
        })
        if (res.error) return toast(res.error)
        if (res.session) {
          ws.send(JSON.stringify({ type: 'sessionStarted', sessionId: res.session.id }))
        }
        manager.scheduleState()
        return
      }
      case 'closeSession':
        manager.closeSession(String(msg.sessionId))
        return
      case 'renameSession':
        manager.setSessionName(String(msg.sessionId), String(msg.name ?? ''), true)
        return
      case 'archiveSession':
        manager.archiveSession(String(msg.sessionId ?? msg.archiveId), Boolean(msg.archived))
        return
      case 'resumeSession': {
        const res = await manager.resumeArchived(String(msg.archiveId))
        if (res.error) return toast(res.error)
        if (res.session) {
          ws.send(JSON.stringify({ type: 'sessionStarted', sessionId: res.session.id }))
        }
        manager.scheduleState()
        return
      }
      case 'resumeNode':
        if (!manager.resumeNode(String(msg.sessionId), String(msg.nodeId))) {
          toast('no captured CLI session id for this node')
        }
        return
      case 'input':
        manager.writeInput(String(msg.sessionId), String(msg.nodeId), String(msg.data ?? ''))
        return
      case 'resize':
        manager.resize(String(msg.sessionId), String(msg.nodeId), Number(msg.cols ?? 100), Number(msg.rows ?? 32))
        return
      case 'attach':
        ws.send(
          JSON.stringify({
            type: 'terminal',
            sessionId: String(msg.sessionId),
            nodeId: String(msg.nodeId),
            data:
              manager.replay(String(msg.sessionId), String(msg.nodeId)) ||
              manager.snapshot(String(msg.sessionId), String(msg.nodeId)),
          }),
        )
        return
      case 'probeDump':
        ws.send(
          JSON.stringify({
            type: 'probeDump',
            sessionId: msg.sessionId,
            nodeId: msg.nodeId,
            dump: manager.probeDump(String(msg.sessionId), String(msg.nodeId)),
          }),
        )
        return
      case 'addProject': {
        const res = manager.addProject(String(msg.cwd ?? ''))
        if (res.error) return toast(res.error)
        manager.scheduleState()
        return
      }
      case 'removeProject':
        manager.removeProject(String(msg.projectId))
        return
      case 'history': {
        const detail = manager.historyDetail(String(msg.archiveId))
        ws.send(JSON.stringify({ type: 'history', archiveId: msg.archiveId, detail }))
        if (!detail) toast('could not read that session')
        return
      }
      case 'historyTranscript': {
        const text = manager.historyTranscript(String(msg.archiveId), String(msg.nodeId))
        ws.send(
          JSON.stringify({
            type: 'historyTranscript',
            archiveId: msg.archiveId,
            nodeId: msg.nodeId,
            text,
          }),
        )
        return
      }
      default:
        toast(`unknown message: ${msg.type}`)
    }
  }

  return new Promise((resolve) => {
    server.listen(opts.port ?? 0, '127.0.0.1', () => {
      const addr = server.address()
      const port = typeof addr === 'object' && addr ? addr.port : 0
      resolve({
        port,
        close: () => {
          wss.close()
          server.close()
        },
      })
    })
  })
}
