// Vigil for Windows — transcript scanning helpers.
//
// Port of app/Sources/VigilRuntime/TranscriptScan.swift's API-error / background-agent
// signals, plus the small byte-offset readers used by the orchestrator. Pure functions so
// the turn-death logic is unit-testable without a PTY.

import fs from 'node:fs'

export function fileLength(p: string): number {
  try {
    return fs.statSync(p).size
  } catch {
    return 0
  }
}

export function readSince(p: string, offset: number, maxBytes = 256 * 1024): string {
  let fd: number | null = null
  try {
    fd = fs.openSync(p, 'r')
    const size = fs.fstatSync(fd).size
    let start = size >= offset ? offset : 0
    if (size - start > maxBytes) start = size - maxBytes
    const len = size - start
    if (len <= 0) return ''
    const buf = Buffer.alloc(len)
    fs.readSync(fd, buf, 0, len, start)
    return buf.toString('utf8')
  } catch {
    return ''
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

function assistantOrSystemText(content: unknown): string | null {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return null
  const parts: string[] = []
  for (const c of content) {
    if (c && typeof c === 'object' && typeof (c as any).text === 'string') parts.push((c as any).text)
  }
  return parts.join('\n') || null
}

/**
 * The first API-error line in a transcript chunk, trimmed to ~200 chars. Claude fires no
 * Stop hook on an API-error death, so this durable line is the only signal the parent's
 * wait is doomed.
 */
export function apiErrorSnippet(text: string): string | null {
  for (const line of text.split('\n')) {
    let obj: any
    try {
      obj = JSON.parse(line)
    } catch {
      continue
    }
    if (!obj || typeof obj !== 'object') continue
    const flagged = obj.isApiErrorMessage === true
    const bodyText = assistantOrSystemText(obj.message?.content)
    const topText = typeof obj.content === 'string' ? obj.content : null
    const anchorHit =
      bodyText?.toLowerCase().includes('api error') || topText?.toLowerCase().includes('api error')
    if (!flagged && !anchorHit) continue
    const s = bodyText || topText || 'API Error'
    return s.trim().slice(0, 200)
  }
  return null
}

/** The pending background-agent count of the LAST turn_duration line (0 = none). */
export function pendingBackgroundAgents(text: string): number {
  let last: any = null
  for (const line of text.split('\n')) {
    let obj: any
    try {
      obj = JSON.parse(line)
    } catch {
      continue
    }
    if (obj?.type === 'system' && obj?.subtype === 'turn_duration') last = obj
  }
  if (!last) return 0
  const v = last.pendingBackgroundAgentCount ?? last.pending_background_agent_count
  return typeof v === 'number' ? v : 0
}

/** Remove bracketed-paste escapes so a delivered message can be found in a transcript. */
export function stripPaste(text: string): string {
  return text.replace(/\x1b\[200~|\x1b\[201~/g, '')
}
