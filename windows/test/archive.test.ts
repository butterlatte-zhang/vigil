import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import {
  loadSession,
  readClaudeTitle,
  renderClaudeTranscript,
  replay,
  resumeKey,
} from '../src/main/archive.js'

const dirs: string[] = []
function tmp(): string {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'vigil-archive-'))
  dirs.push(d)
  return d
}
afterEach(() => {
  for (const d of dirs.splice(0)) fs.rmSync(d, { recursive: true, force: true })
})

const lines = [
  { ts: '2026-07-07T15:30:00.000Z', event: 'cell_launch', node: 'n0', role: 'manager', root: true, task: 'root task', kind: 'claude' },
  { ts: '2026-07-07T15:30:01.000Z', event: 'agent_prompt', node: 'n0', transcript: '/tmp/11111111-1111-1111-1111-111111111111.jsonl', session_id: '11111111-1111-1111-1111-111111111111' },
  { ts: '2026-07-07T15:30:02.000Z', event: 'cell_launch', node: 'n1', role: 'leaf', task: 'worker task', kind: 'claude', parent: 'n0', title: 'probe' },
  { ts: '2026-07-07T15:30:05.000Z', event: 'exit', node: 'n1', code: 0 },
  { ts: '2026-07-07T15:31:00.000Z', event: 'kill', node: 'n0' },
]

describe('SessionArchive replay', () => {
  it('rebuilds the tree, per-node kind, transcript and resume key', () => {
    const a = replay(lines.map((l) => JSON.stringify(l)))
    expect(a.tree?.get('n0')?.status).toBe('killed')
    expect(a.tree?.get('n1')?.status).toBe('done')
    expect(a.tree?.get('n1')?.title).toBe('probe')
    expect(a.tree?.get('n1')?.parent).toBe('n0')
    expect(resumeKey(a, 'n0')).toBe('11111111-1111-1111-1111-111111111111')
    expect(a.nodeKinds.get('n1')).toBe('claude')
    expect(a.firstEventAt).toBe(Date.parse('2026-07-07T15:30:00.000Z'))
  })

  it('tolerates malformed lines and a missing parent', () => {
    const a = replay([
      'not json',
      JSON.stringify({ ts: '2026-07-07T15:30:00.000Z', event: 'cell_launch', node: 'n0', root: true, role: 'manager' }),
      JSON.stringify({ ts: '2026-07-07T15:30:01.000Z', event: 'cell_launch', node: 'n1', parent: 'gone', role: 'leaf' }),
      JSON.stringify({ event: 'future_event', node: 'n0' }),
    ])
    expect(a.tree?.get('n1')?.parent).toBe('n0')
  })

  it('loads a session dir and renders a claude transcript', () => {
    const d = tmp()
    fs.writeFileSync(path.join(d, 'orchestration.jsonl'), lines.map((l) => JSON.stringify(l)).join('\n'))
    const a = loadSession(d)
    expect(a?.tree?.rootID).toBe('n0')

    const transcript = path.join(d, 't.jsonl')
    fs.writeFileSync(
      transcript,
      [
        JSON.stringify({ type: 'user', message: { content: 'hello' } }),
        JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: 'hi there' }] } }),
        JSON.stringify({ type: 'ai-title', aiTitle: 'Cool title' }),
      ].join('\n'),
    )
    const text = renderClaudeTranscript(transcript)
    expect(text).toContain('❯ you')
    expect(text).toContain('hi there')
    expect(readClaudeTitle(transcript)).toBe('Cool title')
  })

  it('prefers a custom title over the auto title', () => {
    const d = tmp()
    const p = path.join(d, 't.jsonl')
    fs.writeFileSync(
      p,
      [
        JSON.stringify({ type: 'ai-title', aiTitle: 'Auto' }),
        JSON.stringify({ type: 'custom-title', customTitle: 'Mine' }),
      ].join('\n'),
    )
    expect(readClaudeTitle(p)).toBe('Mine')
  })
})
