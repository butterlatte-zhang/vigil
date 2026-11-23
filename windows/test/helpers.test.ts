import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import {
  apiErrorSnippet,
  pendingBackgroundAgents,
  readSince,
  stripPaste,
} from '../src/main/transcript-scan.js'
import {
  captureCodexRollout,
  firstUserMessageTitle,
  isSubagentRollout,
  sessionIdFromRollout,
} from '../src/main/codex-rollout.js'

const dirs: string[] = []
function tmp(): string {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'vigil-helpers-'))
  dirs.push(d)
  return d
}
afterEach(() => {
  for (const d of dirs.splice(0)) fs.rmSync(d, { recursive: true, force: true })
})

describe('transcript scan', () => {
  it('flags an isApiErrorMessage line and caps the reason', () => {
    const text = [
      JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: 'working' }] } }),
      JSON.stringify({ isApiErrorMessage: true, message: { content: [{ type: 'text', text: 'API Error: Connection closed mid-response' }] } }),
      JSON.stringify({ type: 'system', content: 'API Error: second' }),
    ].join('\n')
    expect(apiErrorSnippet(text)).toBe('API Error: Connection closed mid-response')
  })

  it('returns null for a clean transcript', () => {
    expect(apiErrorSnippet(JSON.stringify({ type: 'user', message: { content: 'hi' } }))).toBeNull()
  })

  it('reads the LAST turn_duration background count', () => {
    const text = [
      JSON.stringify({ type: 'system', subtype: 'turn_duration', pendingBackgroundAgentCount: 2 }),
      JSON.stringify({ type: 'system', subtype: 'turn_duration', pendingBackgroundAgentCount: 0 }),
    ].join('\n')
    expect(pendingBackgroundAgents(text)).toBe(0)
    expect(pendingBackgroundAgents('nothing')).toBe(0)
  })

  it('strips bracketed-paste wrappers', () => {
    expect(stripPaste('\x1b[200~hi\x1b[201~')).toBe('hi')
  })

  it('reads only bytes after an offset', () => {
    const d = tmp()
    const p = path.join(d, 't.jsonl')
    fs.writeFileSync(p, 'aaaa\nbbbb\n')
    expect(readSince(p, 5)).toBe('bbbb\n')
    // a file shorter than the offset (rotated/truncated) falls back to the capped tail
    expect(readSince(p, 9999)).toBe('aaaa\nbbbb\n')
  })
})

describe('codex rollout capture', () => {
  function writeRollout(home: string, name: string, payload: Record<string, unknown>): string {
    const dir = path.join(home, 'sessions', '2026', '11', '18')
    fs.mkdirSync(dir, { recursive: true })
    const p = path.join(dir, name)
    const line = JSON.stringify({ timestamp: '2026-11-18T00:00:00Z', type: 'session_meta', payload })
    fs.writeFileSync(p, line + '\n')
    return p
  }

  it('binds the main session, skipping a newer sub-agent rollout', () => {
    const home = tmp()
    writeRollout(home, 'rollout-2026-11-18T10-00-00-11111111-1111-1111-1111-111111111111.jsonl', {
      session_id: '11111111-1111-1111-1111-111111111111',
      thread_source: 'user',
    })
    const sub = writeRollout(home, 'rollout-2026-11-18T11-00-00-22222222-2222-2222-2222-222222222222.jsonl', {
      session_id: '11111111-1111-1111-1111-111111111111',
      thread_source: 'subagent',
    })
    expect(isSubagentRollout(sub)).toBe(true)
    const cap = captureCodexRollout(home)!
    expect(cap.sessionId).toBe('11111111-1111-1111-1111-111111111111')
    expect(cap.path).toContain('11111111-1111-1111-1111-111111111111')
  })

  it('falls back to session_meta when the filename has no uuid tail', () => {
    const home = tmp()
    const p = writeRollout(home, 'rollout-custom.jsonl', { session_id: 'from-meta' })
    expect(sessionIdFromRollout(p)).toBe('from-meta')
  })

  it('derives an honest title from the first main-session user message', () => {
    const home = tmp()
    const p = writeRollout(home, 'rollout-2026-11-18T10-00-00-11111111-1111-1111-1111-111111111111.jsonl', {
      session_id: '11111111-1111-1111-1111-111111111111',
    })
    fs.appendFileSync(p, JSON.stringify({ payload: { type: 'user_message', message: 'Fix the login bug\nmore detail' } }) + '\n')
    expect(firstUserMessageTitle(p)).toBe('Fix the login bug')
  })

  it('returns null instead of inventing a capture when no rollout exists', () => {
    expect(captureCodexRollout(tmp())).toBeNull()
  })
})
