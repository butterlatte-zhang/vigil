// Vigil for Windows — history persistence (pointer approach).
//
// Port of app/Sources/VigilRuntime/SessionArchive.swift. Each session dir under
// %APPDATA%/Vigil/sessions/<id>/ holds orchestration.jsonl (Vigil's own forensic trail:
// tree edges, statuses, timeline, node -> CLI transcript join keys) and meta.json.
// Conversation content stays a POINTER into the CLI's own transcript cache; Vigil never
// copies it. If the CLI rotates it away the pointer dangles and the UI says so.

import fs from 'node:fs'
import path from 'node:path'
import { type AgentCLIKind, type NodeID, type Role, Tree, isTerminal, makeNode } from '../core/domain.js'

export interface SessionArchiveMeta {
  id: string
  name: string
  projectName: string | null
  projectCwd: string | null
  agent: string
  model: string | null
  createdAt: string
  rootSessionId: string | null
  archived: boolean | null
  nameIsCustom: boolean | null
}

export interface ArchivedSession {
  tree: Tree | null
  transcripts: Map<NodeID, string>
  sessionIds: Map<NodeID, string>
  nodeKinds: Map<NodeID, AgentCLIKind>
  firstEventAt: number | null
  lastEventAt: number | null
}

export interface ArchivedSessionSummary {
  id: string
  dir: string
  meta: SessionArchiveMeta | null
  modifiedAt: number | null
}

export function newSessionDirName(now = new Date()): string {
  const pad = (n: number) => String(n).padStart(2, '0')
  const stamp =
    `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-` +
    `${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`
  return `${stamp}-${crypto.randomUUID().slice(0, 8).toLowerCase()}`
}

export function writeMeta(meta: SessionArchiveMeta, dir: string): void {
  fs.mkdirSync(dir, { recursive: true })
  fs.writeFileSync(path.join(dir, 'meta.json'), JSON.stringify(meta, null, 2))
}

export function readMeta(dir: string): SessionArchiveMeta | null {
  try {
    return JSON.parse(fs.readFileSync(path.join(dir, 'meta.json'), 'utf8')) as SessionArchiveMeta
  } catch {
    return null
  }
}

export function setArchived(dir: string, flag: boolean): void {
  let meta = readMeta(dir)
  if (!meta) {
    const id = path.basename(dir)
    meta = {
      id,
      name: id,
      projectName: null,
      projectCwd: null,
      agent: '',
      model: null,
      createdAt: new Date().toISOString(),
      rootSessionId: null,
      archived: null,
      nameIsCustom: null,
    }
  }
  meta.archived = flag ? true : null
  writeMeta(meta, dir)
}

/** Rebuild the tree skeleton from orchestration.jsonl lines. Tolerant by design. */
export function replay(lines: string[]): ArchivedSession {
  let tree: Tree | null = null
  const transcripts = new Map<NodeID, string>()
  const sessionIds = new Map<NodeID, string>()
  const nodeKinds = new Map<NodeID, AgentCLIKind>()
  const terminal = new Set<NodeID>()
  let firstTS: number | null = null
  let lastTS: number | null = null

  for (const line of lines) {
    let obj: any
    try {
      obj = JSON.parse(line)
    } catch {
      continue
    }
    if (!obj || typeof obj.event !== 'string') continue
    const event: string = obj.event
    const ts: number | null = typeof obj.ts === 'string' ? Date.parse(obj.ts) : null
    if (ts !== null && !Number.isNaN(ts)) {
      if (firstTS === null) firstTS = ts
      lastTS = ts
    }
    const node: NodeID | null = typeof obj.node === 'string' ? obj.node : null

    switch (event) {
      case 'cell_launch': {
        if (node === null) continue
        const kind = typeof obj.kind === 'string' ? (obj.kind as AgentCLIKind) : null
        if (kind) nodeKinds.set(node, kind)
        const role: Role = obj.role === 'manager' ? 'manager' : 'leaf'
        const n = makeNode({
          id: node,
          role,
          status: 'killed',
          title: typeof obj.title === 'string' ? obj.title : typeof obj.task === 'string' ? obj.task : '',
          model: typeof obj.model === 'string' ? obj.model : null,
          startedAt: ts,
        })
        if (tree === null) {
          if (obj.root === true || obj.parent === undefined || obj.parent === null) {
            tree = new Tree(n)
          }
        } else {
          const t: Tree = tree
          if (!t.get(node)) {
            const parent: NodeID = typeof obj.parent === 'string' ? obj.parent : t.rootID
            try {
              t.spawn(parent, n)
            } catch {
              try {
                if (parent !== t.rootID) t.spawn(t.rootID, n)
              } catch {
                // skeleton must survive imperfect logs
              }
            }
          } else {
            terminal.delete(node)
            t.relaunch(node, 'killed', ts)
          }
        }
        break
      }
      case 'agent_prompt':
        if (node !== null) {
          if (typeof obj.transcript === 'string') transcripts.set(node, obj.transcript)
          if (typeof obj.session_id === 'string') sessionIds.set(node, obj.session_id)
        }
        break
      case 'exit':
        if (node === null || !tree || !tree.get(node) || terminal.has(node)) break
        terminal.add(node)
        tree.setStatus(node, (typeof obj.code === 'number' ? obj.code : 0) === 0 ? 'done' : 'failed')
        if (ts !== null) tree.setEnded(node, ts)
        break
      case 'kill':
        if (node === null || !tree || !tree.get(node) || terminal.has(node)) break
        terminal.add(node)
        tree.setStatus(node, 'killed')
        if (ts !== null) tree.setEnded(node, ts)
        break
      default:
        break
    }
  }
  return { tree, transcripts, sessionIds, nodeKinds, firstEventAt: firstTS, lastEventAt: lastTS }
}

export function resumeKey(a: ArchivedSession, node: NodeID): string | null {
  const sid = a.sessionIds.get(node)
  if (sid) return sid
  const t = a.transcripts.get(node)
  if (!t) return null
  const base = path.basename(t, path.extname(t))
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(base) ? base : null
}

export function loadSession(dir: string): ArchivedSession | null {
  let raw: string
  try {
    raw = fs.readFileSync(path.join(dir, 'orchestration.jsonl'), 'utf8')
  } catch {
    return null
  }
  return replay(raw.split('\n'))
}

export function listSessions(root: string): ArchivedSessionSummary[] {
  let names: string[]
  try {
    names = fs.readdirSync(root)
  } catch {
    return []
  }
  const out: ArchivedSessionSummary[] = []
  for (const name of names) {
    const dir = path.join(root, name)
    const logPath = path.join(dir, 'orchestration.jsonl')
    let stat: fs.Stats
    try {
      stat = fs.statSync(logPath)
    } catch {
      continue
    }
    out.push({ id: name, dir, meta: readMeta(dir), modifiedAt: stat.mtimeMs })
  }
  out.sort((a, b) => score(b) - score(a))
  return out
}

function score(s: ArchivedSessionSummary): number {
  if (s.meta?.createdAt) {
    const t = Date.parse(s.meta.createdAt)
    if (!Number.isNaN(t)) return t
  }
  return s.modifiedAt ?? 0
}

/** Best-effort title extraction from a claude transcript (ai-title / custom-title). */
export function readClaudeTitle(transcriptPath: string): string | null {
  let text: string
  try {
    text = fs.readFileSync(transcriptPath, 'utf8')
  } catch {
    return null
  }
  const lines = text.split('\n')
  let title: string | null = null
  for (let i = lines.length - 1; i >= Math.max(0, lines.length - 400); i--) {
    let obj: any
    try {
      obj = JSON.parse(lines[i])
    } catch {
      continue
    }
    if (obj?.type === 'custom-title' && typeof obj.customTitle === 'string') return obj.customTitle
    if (obj?.type === 'ai-title' && typeof obj.aiTitle === 'string' && title === null) {
      title = obj.aiTitle
    }
  }
  return title
}

/** Render a claude JSONL transcript into readable text for the history pane. */
export function renderClaudeTranscript(transcriptPath: string, maxChars = 400_000): string | null {
  let text: string
  try {
    text = fs.readFileSync(transcriptPath, 'utf8')
  } catch {
    return null
  }
  const chunks: string[] = []
  let total = 0
  for (const line of text.split('\n')) {
    let obj: any
    try {
      obj = JSON.parse(line)
    } catch {
      continue
    }
    if (!obj || typeof obj !== 'object') continue
    const type = obj.type
    if (type === 'user' || type === 'assistant') {
      const content = obj.message?.content
      const parts: string[] = []
      if (typeof content === 'string') parts.push(content)
      else if (Array.isArray(content)) {
        for (const c of content) {
          if (c?.type === 'text' && typeof c.text === 'string') parts.push(c.text)
          else if (c?.type === 'tool_use') parts.push(`[tool: ${c.name}] ${JSON.stringify(c.input ?? {})}`)
          else if (c?.type === 'tool_result') parts.push('[tool result]')
        }
      }
      const body = parts.join('\n').trim()
      if (body) {
        const header = type === 'user' ? '❯ you' : '● assistant'
        const block = `${header}\n${body}\n`
        chunks.push(block)
        total += block.length
      }
    } else if (type === 'system' && obj.subtype === 'turn_duration') {
      continue
    }
    if (total >= maxChars) {
      chunks.push('\n[truncated]')
      break
    }
  }
  return chunks.join('\n')
}

export { isTerminal }
