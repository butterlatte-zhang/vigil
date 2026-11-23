import { describe, expect, it } from 'vitest'
import { canonicalJSON, HookGateway, inputSummary, observationHooks } from '../src/main/hook-gateway.js'
import type { Command } from '../src/core/domain.js'
import type { LineChannel } from '../src/main/transport.js'

/** An in-memory LineChannel: lines are written by the test, and reads pop them. */
class FakeChannel implements LineChannel {
  written: string[] = []
  private pending: string[]
  closed = false
  constructor(lines: string[]) {
    this.pending = [...lines]
  }
  async readLine(): Promise<string | null> {
    return this.pending.shift() ?? null
  }
  async write(line: string): Promise<void> {
    this.written.push(line)
  }
  async close(): Promise<void> {
    this.closed = true
  }
}

describe('observationHooks', () => {
  it('emits a quote-free command when every token is space-free (cmd + Git Bash safe)', () => {
    const hooks = observationHooks('node', 'D:/vigil/bin/vigil-hook.js', 'n3', '//./pipe/vigil-test-hook')
    const cmd = (hooks.UserPromptSubmit as any)[0].hooks[0].command as string
    expect(cmd).not.toContain('"')
    expect(cmd).toContain('node D:/vigil/bin/vigil-hook.js --node n3')
    expect(cmd.endsWith('--event prompt')).toBe(true)
    expect((hooks.Stop as any)[0].hooks[0].command.endsWith('--event stop')).toBe(true)
  })

  it('quotes only tokens that need it', () => {
    const hooks = observationHooks('C:/Program Files/nodejs/node.exe', 'D:/a b/vigil-hook.js', 'n1', '//./pipe/x')
    const cmd = (hooks.PermissionRequest as any)[0].hooks[0].command as string
    expect(cmd.startsWith('"C:/Program Files/nodejs/node.exe"')).toBe(true)
    expect(cmd).toContain('"D:/a b/vigil-hook.js"')
  })
})

describe('HookGateway', () => {
  function gateway() {
    const commands: Command[] = []
    const prompts: Array<[string, Record<string, unknown>]> = []
    const gw = new HookGateway({
      emit: (c) => commands.push(c),
      onPrompt: (n, p) => prompts.push([n, p]),
    })
    return { gw, commands, prompts }
  }

  it('turns UserPromptSubmit into turnStarted + clearNotices', async () => {
    const { gw, commands } = gateway()
    const ch = new FakeChannel([
      JSON.stringify({ node: 'n0', event: 'prompt', payload: JSON.stringify({ prompt: 'hi', session_id: 's1' }) }),
    ])
    await gw.handle(ch)
    expect(commands).toEqual([
      { type: 'turnStarted', node: 'n0' },
      { type: 'clearNotices', node: 'n0' },
    ])
    expect(ch.closed).toBe(true)
  })

  it('maps PermissionRequest + PostToolUse to a canonical pairing tuple', async () => {
    const { gw, commands } = generic()
    await gw.handle(
      new FakeChannel([
        JSON.stringify({
          node: 'n2',
          event: 'perm-request',
          payload: JSON.stringify({ tool_name: 'Bash', tool_input: { b: 2, a: 1 }, prompt_id: 'p' }),
        }),
      ]),
    )
    await gw.handle(
      new FakeChannel([
        JSON.stringify({
          node: 'n2',
          event: 'post-tool',
          payload: JSON.stringify({ tool_name: 'Bash', tool_input: { a: 1, b: 2 }, prompt_id: 'p', tool_use_id: 'u' }),
        }),
      ]),
    )
    const req = commands[0] as Extract<Command, { type: 'permRequested' }>
    const res = commands[1] as Extract<Command, { type: 'resolveNotice' }>
    expect(req.info.toolInput).toBe('{"a":1,"b":2}')
    expect(res.match?.toolInput).toBe('{"a":1,"b":2}')
    expect(res.match?.toolUseID).toBe('u')
    expect(res.via).toBe('post-tool')
  })

  it('drops unknown events (observe-only channel)', async () => {
    const { gw, commands } = generic()
    await gw.handle(new FakeChannel([JSON.stringify({ node: 'n0', event: 'notification', payload: '{}' })]))
    expect(commands).toHaveLength(0)
  })
})

describe('hook payload helpers', () => {
  it('canonicalizes JSON with sorted keys and summarizes common tool inputs', () => {
    expect(canonicalJSON({ z: 1, a: { y: 2, b: 3 } })).toBe('{"a":{"b":3,"y":2},"z":1}')
    expect(inputSummary({ command: 'echo hi' })).toBe('echo hi')
    expect(inputSummary({ file_path: 'C:/a/very/long/path/that/keeps/going/and/going/well/past/sixty/chars/x.ts' })).toMatch(/…$/)
  })
})

function generic() {
  const commands: Command[] = []
  const gw = new HookGateway({ emit: (c) => commands.push(c) })
  return { gw, commands }
}
