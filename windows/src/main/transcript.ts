// Vigil for Windows — self-rendered transcript.
//
// Port of app/Sources/VigilApp/TranscriptRender.swift: the read-only view of a finished
// agent conversation. Cluade JSONL, codex rollout JSONL and opencode export JSON each
// have their own parser; unknown/malformed lines are skipped, tool calls collapse into
// one dim line, and stats report only fields the transcript actually contains (never a
// fabricated dollar cost).

import fs from 'node:fs'
import path from 'node:path'

export type TranscriptItemKind = 'user' | 'assistant' | 'tools' | 'notice'

export interface TranscriptItem {
  id: number
  kind: TranscriptItemKind
  text: string
}

export interface ModelUsage {
  model: string
  input: number
  output: number
  cacheRead: number
  cacheWrite: number
}

export interface TranscriptStats {
  version: string | null
  sessionId: string | null
  wallSeconds: number | null
  models: ModelUsage[]
  sessionName: string | null
}

export const maxItems = 400

export function isCodexRollout(p: string): boolean {
  return path.basename(p).startsWith('rollout-')
}

export function isOpenCodeExport(p: string): boolean {
  return path.basename(p).startsWith('opencode-')
}

function parseLine(line: string): any | null {
  try {
    const obj = JSON.parse(line)
    return obj && typeof obj === 'object' ? obj : null
  } catch {
    return null
  }
}

// MARK: - claude JSONL

export function parseClaude(jsonl: string, truncatedHead = false): TranscriptItem[] {
  let out: TranscriptItem[] = []
  const toolNames: string[] = []
  const toolCounts = new Map<string, number>()
  let nextID = 0
  const append = (kind: TranscriptItemKind, text: string) => {
    out.push({ id: nextID++, kind, text })
  }
  const tool = (name: string) => {
    if (!toolCounts.has(name)) toolNames.push(name)
    toolCounts.set(name, (toolCounts.get(name) ?? 0) + 1)
  }
  const flushTools = () => {
    if (toolNames.length === 0) return
    const total = [...toolCounts.values()].reduce((a, b) => a + b, 0)
    const parts = toolNames.slice(0, 6).map((n) => {
      const c = toolCounts.get(n) ?? 1
      return c > 1 ? `${n} ×${c}` : n
    })
    const more = toolNames.length > 6 ? '…' : ''
    append('tools', `⚒ Tool calls ×${total} · ${parts.join(', ')}${more}`)
    toolNames.length = 0
    toolCounts.clear()
  }

  for (const line of jsonl.split('\n')) {
    const obj = parseLine(line)
    if (!obj || typeof obj.type !== 'string') continue
    const message = obj.message
    if (obj.type === 'user') {
      if (obj.isMeta === true) continue
      const text = userText(message?.content)
      if (!text) continue
      flushTools()
      append(text.startsWith('[Request interrupted') ? 'notice' : 'user', text)
    } else if (obj.type === 'assistant') {
      const content = message?.content
      if (!Array.isArray(content)) continue
      for (const part of content) {
        if (part?.type === 'text') {
          const t = String(part.text ?? '').trim()
          if (!t) continue
          flushTools()
          append('assistant', t)
        } else if (part?.type === 'tool_use') {
          tool(typeof part.name === 'string' ? part.name : '?')
        }
      }
    }
  }
  flushTools()

  let capped = false
  if (out.length > maxItems) {
    out = out.slice(-maxItems)
    capped = true
  }
  if (truncatedHead || capped) {
    out.unshift({ id: -1, kind: 'notice', text: '── Earlier content omitted (transcript too long) ──' })
  }
  return out
}

function userText(content: unknown): string | null {
  let pieces: string[] = []
  if (typeof content === 'string') pieces = [content]
  else if (Array.isArray(content)) {
    pieces = content
      .filter((p: any) => p?.type === 'text' && typeof p.text === 'string')
      .map((p: any) => p.text)
  }
  const joined = pieces.join('\n').trim()
  if (!joined) return null
  if (joined.includes('<local-command-stdout>')) return null
  const cmd = capture(joined, '<command-name>([\\s\\S]*?)</command-name>')
  if (cmd) {
    const args = capture(joined, '<command-args>([\\s\\S]*?)</command-args>') ?? ''
    return args ? `${cmd} ${args}` : cmd
  }
  return joined
}

function capture(s: string, pattern: string): string | null {
  const m = new RegExp(pattern).exec(s)
  const v = m?.[1]?.trim()
  return v ? v : null
}

// MARK: - codex rollout

export function parseCodex(jsonl: string, truncatedHead = false): TranscriptItem[] {
  let out: TranscriptItem[] = []
  const toolNames: string[] = []
  const toolCounts = new Map<string, number>()
  let nextID = 0
  const append = (kind: TranscriptItemKind, text: string) => {
    out.push({ id: nextID++, kind, text })
  }
  const tool = (name: string) => {
    if (!toolCounts.has(name)) toolNames.push(name)
    toolCounts.set(name, (toolCounts.get(name) ?? 0) + 1)
  }
  const flushTools = () => {
    if (toolNames.length === 0) return
    const total = [...toolCounts.values()].reduce((a, b) => a + b, 0)
    const parts = toolNames.slice(0, 6).map((n) => {
      const c = toolCounts.get(n) ?? 1
      return c > 1 ? `${n} ×${c}` : n
    })
    const more = toolNames.length > 6 ? '…' : ''
    append('tools', `⚒ Tool calls ×${total} · ${parts.join(', ')}${more}`)
    toolNames.length = 0
    toolCounts.clear()
  }

  for (const line of jsonl.split('\n')) {
    const obj = parseLine(line)
    if (obj?.type !== 'event_msg' || !obj.payload) continue
    const p = obj.payload
    if (p.type === 'user_message') {
      const msg = String(p.message ?? '').trim()
      if (!msg) continue
      flushTools()
      append('user', msg)
    } else if (p.type === 'agent_message') {
      const msg = String(p.message ?? '').trim()
      if (!msg) continue
      flushTools()
      append('assistant', msg)
    } else if (p.type === 'exec_command_begin') tool('shell')
    else if (p.type === 'mcp_tool_call_begin') tool(String(p.tool ?? p.server ?? 'mcp'))
    else if (p.type === 'patch_apply_begin') tool('apply_patch')
  }
  flushTools()

  let capped = false
  if (out.length > maxItems) {
    out = out.slice(-maxItems)
    capped = true
  }
  if (truncatedHead || capped) {
    out.unshift({ id: -1, kind: 'notice', text: '── Earlier content omitted (transcript too long) ──' })
  }
  return out
}

// MARK: - opencode export

export function parseOpenCode(jsonText: string): TranscriptItem[] {
  let obj: any
  try {
    obj = JSON.parse(jsonText)
  } catch {
    return []
  }
  const messages: any[] = Array.isArray(obj?.messages) ? obj.messages : []
  let out: TranscriptItem[] = []
  const toolNames: string[] = []
  const toolCounts = new Map<string, number>()
  let nextID = 0
  const append = (kind: TranscriptItemKind, text: string) => {
    out.push({ id: nextID++, kind, text })
  }
  const tool = (name: string) => {
    if (!toolCounts.has(name)) toolNames.push(name)
    toolCounts.set(name, (toolCounts.get(name) ?? 0) + 1)
  }
  const flushTools = () => {
    if (toolNames.length === 0) return
    const total = [...toolCounts.values()].reduce((a, b) => a + b, 0)
    const parts = toolNames.slice(0, 6).map((n) => {
      const c = toolCounts.get(n) ?? 1
      return c > 1 ? `${n} ×${c}` : n
    })
    append('tools', `⚒ Tool calls ×${total} · ${parts.join(', ')}${toolNames.length > 6 ? '…' : ''}`)
    toolNames.length = 0
    toolCounts.clear()
  }

  for (const msg of messages) {
    const role = msg?.info?.role
    if (!Array.isArray(msg?.parts)) continue
    for (const part of msg.parts) {
      if (part?.type === 'text') {
        const t = String(part.text ?? '').trim()
        if (!t) continue
        flushTools()
        append(role === 'user' ? 'user' : 'assistant', t)
      } else if (part?.type === 'tool') tool(String(part.tool ?? 'tool'))
      else if (part?.type === 'patch') tool('apply_patch')
    }
  }
  flushTools()
  if (out.length > maxItems) {
    out = out.slice(-maxItems)
    out.unshift({ id: -1, kind: 'notice', text: '── Earlier content omitted (transcript too long) ──' })
  }
  return out
}

// MARK: - load

export function loadTranscript(
  transcriptPath: string | null,
  opts: { maxBytes?: number } = {},
): TranscriptItem[] | null {
  if (!transcriptPath) return null
  const maxBytes = opts.maxBytes ?? 8 * 1024 * 1024
  let raw: string
  try {
    raw = fs.readFileSync(transcriptPath, 'utf8')
  } catch {
    return null
  }
  if (isOpenCodeExport(transcriptPath)) return parseOpenCode(raw)
  let text = raw
  let truncated = false
  const bytes = Buffer.byteLength(raw, 'utf8')
  if (bytes > maxBytes) {
    const buf = fs.readFileSync(transcriptPath)
    const start = buf.length - maxBytes
    text = buf.subarray(start).toString('utf8')
    const nl = text.indexOf('\n')
    if (nl >= 0) text = text.slice(nl + 1)
    truncated = true
  }
  return isCodexRollout(transcriptPath) ? parseCodex(text, truncated) : parseClaude(text, truncated)
}

// MARK: - stats

export function transcriptStats(transcriptPath: string | null): TranscriptStats | null {
  if (!transcriptPath) return null
  let raw: string
  try {
    raw = fs.readFileSync(transcriptPath, 'utf8')
  } catch {
    return null
  }
  if (isCodexRollout(transcriptPath)) return codexStats(raw)
  if (isOpenCodeExport(transcriptPath)) return openCodeStats(raw)
  return claudeStats(raw)
}

const emptyStats = (): TranscriptStats => ({
  version: null,
  sessionId: null,
  wallSeconds: null,
  models: [],
  sessionName: null,
})

function parseTime(s: unknown): number | null {
  if (typeof s !== 'string') return null
  const t = Date.parse(s)
  return Number.isNaN(t) ? null : t
}

function claudeStats(raw: string): TranscriptStats {
  const out = emptyStats()
  let first: number | null = null
  let last: number | null = null
  const seen = new Set<string>()
  const order: string[] = []
  const usage = new Map<string, ModelUsage>()

  for (const line of raw.split('\n')) {
    const obj = parseLine(line)
    if (!obj) continue
    if (typeof obj.version === 'string') out.version = obj.version
    if (typeof obj.sessionId === 'string') out.sessionId = obj.sessionId
    const t = parseTime(obj.timestamp)
    if (t !== null) {
      if (first === null) first = t
      last = t
    }
    if (obj.type !== 'assistant' || !obj.message?.usage) continue
    const key = typeof obj.requestId === 'string' ? obj.requestId : typeof obj.message.id === 'string' ? obj.message.id : null
    if (!key || seen.has(key)) continue
    seen.add(key)
    const model = typeof obj.message.model === 'string' ? obj.message.model : '?'
    if (!usage.has(model)) {
      usage.set(model, { model, input: 0, output: 0, cacheRead: 0, cacheWrite: 0 })
      order.push(model)
    }
    const u = usage.get(model)!
    const us = obj.message.usage
    u.input += Number(us.input_tokens ?? 0)
    u.output += Number(us.output_tokens ?? 0)
    u.cacheRead += Number(us.cache_read_input_tokens ?? 0)
    u.cacheWrite += Number(us.cache_creation_input_tokens ?? 0)
  }
  out.models = order.map((m) => usage.get(m)!)
  if (first !== null && last !== null) out.wallSeconds = Math.max(0, Math.round((last - first) / 1000))
  return out
}

function codexStats(raw: string): TranscriptStats {
  const out = emptyStats()
  let first: number | null = null
  let last: number | null = null
  let model: string | null = null
  let usage: ModelUsage | null = null
  for (const line of raw.split('\n')) {
    const obj = parseLine(line)
    if (!obj) continue
    const t = parseTime(obj.timestamp)
    if (t !== null) {
      if (first === null) first = t
      last = t
    }
    const p = obj.payload
    if (typeof p?.model === 'string') model = p.model
    if (obj.type === 'session_meta') {
      if (typeof p?.session_id === 'string') out.sessionId = p.session_id
      if (typeof p?.cli_version === 'string') out.version = p.cli_version
    } else if (obj.type === 'event_msg' && p?.type === 'token_count' && p.info?.total_token_usage) {
      const tot = p.info.total_token_usage
      usage = {
        model: model ?? 'codex',
        input: Number(tot.input_tokens ?? 0),
        output: Number(tot.output_tokens ?? 0),
        cacheRead: Number(tot.cached_input_tokens ?? 0),
        cacheWrite: 0,
      }
    }
  }
  if (usage) {
    usage.model = model ?? usage.model
    out.models = [usage]
  }
  if (first !== null && last !== null) out.wallSeconds = Math.max(0, Math.round((last - first) / 1000))
  return out
}

function openCodeStats(raw: string): TranscriptStats {
  const out = emptyStats()
  let obj: any
  try {
    obj = JSON.parse(raw)
  } catch {
    return out
  }
  const info = obj?.info
  if (!info) return out
  out.sessionId = typeof info.id === 'string' ? info.id : null
  out.version = typeof info.version === 'string' ? info.version : null
  let modelName = 'opencode'
  if (info.model) {
    const id = typeof info.model.id === 'string' ? info.model.id : null
    const provider = typeof info.model.providerID === 'string' ? info.model.providerID : null
    if (provider && id) modelName = `${provider}/${id}`
    else if (id) modelName = id
    else if (provider) modelName = provider
  }
  if (info.tokens) {
    const u: ModelUsage = {
      model: modelName,
      input: Number(info.tokens.input ?? 0),
      output: Number(info.tokens.output ?? 0),
      cacheRead: Number(info.tokens.cache?.read ?? 0),
      cacheWrite: Number(info.tokens.cache?.write ?? 0),
    }
    out.models = [u]
  }
  if (info.time && typeof info.time.created === 'number' && typeof info.time.updated === 'number') {
    out.wallSeconds = Math.max(0, Math.round((info.time.updated - info.time.created) / 1000))
  }
  return out
}

export function fmtTokens(n: number): string {
  const trim = (v: number) => {
    const s = v.toFixed(1)
    return s.endsWith('.0') ? s.slice(0, -2) : s
  }
  if (n < 1000) return String(n)
  if (n < 1_000_000) return trim(n / 1000) + 'k'
  return trim(n / 1_000_000) + 'm'
}
