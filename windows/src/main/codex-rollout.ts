// Vigil for Windows — codex rollout capture.
//
// Port of app/Sources/VigilRuntime/CodexRollout.swift. codex fires no claude-style
// prompt hook payload, but every codex node has an isolated CODEX_HOME and writes a
// rollout jsonl per turn at `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`.
// That file yields both the resume credential (trailing uuid) and the transcript pointer.
// Task-spawned sub-agents write their own rollouts into the same directory, so main-session
// binding excludes any rollout whose session_meta carries a sub-agent marker.

import fs from 'node:fs'
import path from 'node:path'

export interface CodexCapture {
  sessionId: string
  path: string
}

export function captureCodexRollout(codexHome: string): CodexCapture | null {
  const sessionsDir = path.join(codexHome, 'sessions')
  const rels: string[] = []
  const walk = (dir: string, prefix: string) => {
    let names: string[]
    try {
      names = fs.readdirSync(dir)
    } catch {
      return
    }
    for (const name of names) {
      const abs = path.join(dir, name)
      let st: fs.Stats
      try {
        st = fs.statSync(abs)
      } catch {
        continue
      }
      if (st.isDirectory()) walk(abs, path.join(prefix, name))
      else if (name.startsWith('rollout-') && name.endsWith('.jsonl')) {
        rels.push(path.join(prefix, name))
      }
    }
  }
  walk(sessionsDir, '')
  // Basenames carry an ISO timestamp; lexical order = chronological order.
  rels.sort((a, b) => (path.basename(a) > path.basename(b) ? -1 : 1))
  for (const rel of rels) {
    const full = path.join(sessionsDir, rel)
    if (!isSubagentRollout(full)) {
      const sid = sessionIdFromRollout(full)
      if (sid) return { sessionId: sid, path: full }
    }
  }
  return null
}

function firstLinePayload(p: string): any | null {
  let fd: number | null = null
  try {
    fd = fs.openSync(p, 'r')
    const buf = Buffer.alloc(256 * 1024)
    const n = fs.readSync(fd, buf, 0, buf.length, 0)
    const text = buf.subarray(0, n).toString('utf8')
    const nl = text.indexOf('\n')
    const obj = JSON.parse(nl >= 0 ? text.slice(0, nl) : text)
    return obj?.payload ?? null
  } catch {
    return null
  } finally {
    if (fd !== null) {
      try {
        fs.closeSync(fd)
      } catch {
        // ignore
      }
    }
  }
}

export function isSubagentRollout(p: string): boolean {
  const payload = firstLinePayload(p)
  if (!payload) return false // unreadable meta is not a positive sub-agent marker
  if (payload.thread_source === 'subagent') return true
  if (payload.source?.subagent) return true
  if (payload.agent_role === 'worker') return true
  return false
}

export function sessionIdFromRollout(p: string): string | null {
  const base = path.basename(p, path.extname(p))
  const parts = base.split('-')
  if (parts.length >= 5) {
    const candidate = parts.slice(-5).join('-')
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(candidate)) {
      return candidate
    }
  }
  const payload = firstLinePayload(p)
  return typeof payload?.session_id === 'string' ? payload.session_id : null
}

/** Honest naming fallback: the MAIN rollout's first user_message, first line only. */
export function firstUserMessageTitle(rolloutPath: string, maxChars = 80): string | null {
  let text: string
  try {
    text = fs.readFileSync(rolloutPath, 'utf8')
  } catch {
    return null
  }
  for (const line of text.split('\n')) {
    let obj: any
    try {
      obj = JSON.parse(line)
    } catch {
      continue
    }
    const msg = obj?.payload?.type === 'user_message' ? obj.payload.message : null
    if (typeof msg === 'string' && msg.trim().length > 0) {
      const first = msg.split('\n')[0].trim()
      return first.length > maxChars ? first.slice(0, maxChars) + '…' : first
    }
  }
  return null
}
