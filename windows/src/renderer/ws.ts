// The renderer's one WebSocket, with per-terminal subscriptions (agent cells + the
// bottom shell, which uses the reserved `__shell__` node id).

export const SHELL_NODE = '__shell__'

type TerminalEvent = { kind: 'pty' | 'terminal' | 'ptyExit'; data: string }
type Handler = (ev: TerminalEvent) => void

const token = new URLSearchParams(location.search).get('token') ?? ''
const proto = location.protocol === 'https:' ? 'wss' : 'ws'
const url = `${proto}://${location.host}/?token=${encodeURIComponent(token)}`

let socket: WebSocket | null = null
let stateHandler: ((state: any) => void) | null = null
let toastHandler: ((text: string) => void) | null = null
let historyHandler: ((detail: any) => void) | null = null
let historyTextHandler: ((payload: any) => void) | null = null
let deadNodeHandler: ((payload: any) => void) | null = null
let sessionStartedHandler: ((id: string) => void) | null = null
const handlers = new Map<string, Set<Handler>>()
const queue: string[] = []

function connect(): void {
  socket = new WebSocket(url)
  socket.onopen = () => {
    for (const m of queue.splice(0)) socket?.send(m)
  }
  socket.onmessage = (ev) => {
    let msg: any
    try {
      msg = JSON.parse(ev.data as string)
    } catch {
      return
    }
    switch (msg.type) {
      case 'state':
        stateHandler?.(msg.state)
        break
      case 'toast':
        toastHandler?.(msg.text)
        break
      case 'pty': {
        const key = `${msg.sessionId}:${msg.nodeId}`
        for (const h of handlers.get(key) ?? []) h({ kind: 'pty', data: msg.data })
        break
      }
      case 'ptyExit': {
        const key = `${msg.sessionId}:${msg.nodeId}`
        for (const h of handlers.get(key) ?? []) h({ kind: 'ptyExit', data: '' })
        break
      }
      case 'terminal': {
        const key = `${msg.sessionId}:${msg.nodeId}`
        for (const h of handlers.get(key) ?? []) h({ kind: 'terminal', data: msg.data })
        break
      }
      case 'shellTerminal': {
        const key = `${msg.sessionId}:${SHELL_NODE}`
        for (const h of handlers.get(key) ?? []) h({ kind: 'terminal', data: msg.data })
        break
      }
      case 'history':
        historyHandler?.(msg.detail)
        break
      case 'historyTranscript':
        historyTextHandler?.({
          archiveId: msg.archiveId,
          nodeId: msg.nodeId,
          path: msg.path ?? null,
          items: msg.items ?? null,
          stats: msg.stats ?? null,
        })
        break
      case 'deadNodeTranscript':
        deadNodeHandler?.({
          sessionId: msg.sessionId,
          nodeId: msg.nodeId,
          path: msg.path ?? null,
          items: msg.items ?? null,
          stats: msg.stats ?? null,
        })
        break
      case 'sessionStarted':
        sessionStartedHandler?.(msg.sessionId)
        break
    }
  }
  socket.onclose = () => setTimeout(connect, 800)
}

export function send(msg: unknown): void {
  const data = JSON.stringify(msg)
  if (socket && socket.readyState === WebSocket.OPEN) socket.send(data)
  else queue.push(data)
}

export function onState(fn: (state: any) => void): () => void {
  stateHandler = fn
  return () => {
    if (stateHandler === fn) stateHandler = null
  }
}

export function onToast(fn: (text: string) => void): () => void {
  toastHandler = fn
  return () => {
    if (toastHandler === fn) toastHandler = null
  }
}

export function onHistory(fn: (detail: any) => void): () => void {
  historyHandler = fn
  return () => {
    if (historyHandler === fn) historyHandler = null
  }
}

export function onHistoryTranscript(fn: (payload: any) => void): () => void {
  historyTextHandler = fn
  return () => {
    if (historyTextHandler === fn) historyTextHandler = null
  }
}

export function onDeadNodeTranscript(fn: (payload: any) => void): () => void {
  deadNodeHandler = fn
  return () => {
    if (deadNodeHandler === fn) deadNodeHandler = null
  }
}

export function onSessionStarted(fn: (id: string) => void): () => void {
  sessionStartedHandler = fn
  return () => {
    if (sessionStartedHandler === fn) sessionStartedHandler = null
  }
}

export function subscribeTerminal(sessionId: string, nodeId: string, fn: Handler): () => void {
  const key = `${sessionId}:${nodeId}`
  let set = handlers.get(key)
  if (!set) {
    set = new Set()
    handlers.set(key, set)
  }
  set.add(fn)
  return () => {
    set?.delete(fn)
  }
}

connect()
