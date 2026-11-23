import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import {
  fmtTokens,
  loadTranscript,
  parseClaude,
  parseCodex,
  parseOpenCode,
  transcriptStats,
} from '../src/main/transcript.js'

const dirs: string[] = []
function tmp(): string {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'vigil-transcript-'))
  dirs.push(d)
  return d
}
afterEach(() => {
  for (const d of dirs.splice(0)) fs.rmSync(d, { recursive: true, force: true })
})

describe('claude transcript parsing', () => {
  it('renders user text and assistant text, collapsing tool calls', () => {
    const lines = [
      JSON.stringify({ type: 'user', message: { content: 'fix the bug' } }),
      JSON.stringify({
        type: 'assistant',
        message: {
          content: [
            { type: 'text', text: 'Looking.' },
            { type: 'tool_use', name: 'Bash' },
            { type: 'tool_use', name: 'Read' },
            { type: 'tool_use', name: 'Bash' },
          ],
        },
      }),
      JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: '  ' }] } }),
    ].join('\n')
    const items = parseClaude(lines)
    expect(items.map((i) => i.kind)).toEqual(['user', 'assistant', 'tools'])
    expect(items[2].text).toBe('⚒ Tool calls ×3 · Bash ×2, Read')
  })

  it('drops isMeta, local-command output and unwraps slash commands', () => {
    const items = parseClaude(
      [
        JSON.stringify({ type: 'user', isMeta: true, message: { content: 'meta' } }),
        JSON.stringify({ type: 'user', message: { content: '<local-command-stdout>x</local-command-stdout>' } }),
        JSON.stringify({
          type: 'user',
          message: { content: '<command-name>/clear</command-name><command-args></command-args>' },
        }),
      ].join('\n'),
    )
    expect(items).toHaveLength(1)
    expect(items[0].text).toBe('/clear')
  })

  it('caps a long transcript and prefixes an honest notice', () => {
    const lines = Array.from({ length: 420 }, (_, i) =>
      JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: `line ${i}` }] } }),
    ).join('\n')
    const items = parseClaude(lines)
    expect(items).toHaveLength(401)
    expect(items[0].kind).toBe('notice')
  })

  it('computes stats with usage deduplicated by requestId', () => {
    const lines = [
      JSON.stringify({ version: '2.1.327', sessionId: 'sid-1', timestamp: '2026-11-18T08:00:00.000Z' }),
      JSON.stringify({
        type: 'assistant',
        requestId: 'r1',
        timestamp: '2026-11-18T08:00:01.000Z',
        message: { model: 'claude-test', usage: { input_tokens: 10, output_tokens: 2, cache_read_input_tokens: 4, cache_creation_input_tokens: 1 } },
      }),
      JSON.stringify({
        type: 'assistant',
        requestId: 'r1',
        timestamp: '2026-11-18T08:00:02.000Z',
        message: { model: 'claude-test', usage: { input_tokens: 10, output_tokens: 2 } },
      }),
      JSON.stringify({ timestamp: '2026-11-18T08:00:11.000Z' }),
    ].join('\n')
    const d = tmp()
    const p = path.join(d, 'sid-1.jsonl')
    fs.writeFileSync(p, lines)
    const stats = transcriptStats(p)!
    expect(stats.version).toBe('2.1.327')
    expect(stats.sessionId).toBe('sid-1')
    expect(stats.wallSeconds).toBe(11)
    expect(stats.models).toEqual([{ model: 'claude-test', input: 10, output: 2, cacheRead: 4, cacheWrite: 1 }])
  })
})

describe('codex + opencode parsing', () => {
  it('renders codex event_msg user/agent messages and tool begin events', () => {
    const items = parseCodex(
      [
        JSON.stringify({ type: 'event_msg', payload: { type: 'user_message', message: 'hello' } }),
        JSON.stringify({ type: 'event_msg', payload: { type: 'exec_command_begin' } }),
        JSON.stringify({ type: 'event_msg', payload: { type: 'agent_message', message: 'hi' } }),
        JSON.stringify({ type: 'response_item', payload: { type: 'user_message', message: 'ignored' } }),
      ].join('\n'),
    )
    expect(items.map((i) => i.kind)).toEqual(['user', 'tools', 'assistant'])
  })

  it('renders an opencode export', () => {
    const items = parseOpenCode(
      JSON.stringify({
        info: { id: 's', version: '1.17', model: { providerID: 'p', id: 'm' }, tokens: { input: 5, output: 1, cache: { read: 2, write: 0 } }, time: { created: 1000, updated: 5000 } },
        messages: [
          { info: { role: 'user' }, parts: [{ type: 'text', text: 'hey' }] },
          { info: { role: 'assistant' }, parts: [{ type: 'tool', tool: 'bash' }, { type: 'text', text: 'yo' }] },
        ],
      }),
    )
    expect(items.map((i) => i.kind)).toEqual(['user', 'tools', 'assistant'])
  })

  it('loads from a path and formats token counts like claude', () => {
    const d = tmp()
    const p = path.join(d, 'rollout-2026-11-18T10-00-00-11111111-1111-1111-1111-111111111111.jsonl')
    fs.writeFileSync(p, JSON.stringify({ type: 'event_msg', payload: { type: 'user_message', message: 'hi' } }))
    expect(loadTranscript(p)?.map((i) => i.text)).toEqual(['hi'])
    expect(fmtTokens(629)).toBe('629')
    expect(fmtTokens(4800)).toBe('4.8k')
    expect(fmtTokens(4_500_000)).toBe('4.5m')
  })
})
