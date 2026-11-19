import { describe, expect, it } from 'vitest'
import type { Command, Resolution, Role } from '../src/core/domain.js'
import { MCPToolServer, PendingReplies, toolText } from '../src/main/mcp-server.js'
import type { LineChannel } from '../src/main/transport.js'

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
  replies(): any[] {
    return this.written.map((w) => JSON.parse(w))
  }
}

function makeServer(role: Role, isRoot: boolean, respond?: (cmd: Command) => Resolution | null) {
  const commands: Command[] = []
  const pending = new PendingReplies()
  const server = new MCPToolServer({
    emit: (cmd) => {
      commands.push(cmd)
      const resolution = respond?.(cmd)
      if (resolution && 'replyID' in cmd && cmd.replyID) {
        setTimeout(() => pending.deliver(cmd.replyID as string, resolution), 1)
      }
    },
    pending,
    nodeInfo: (node) => (node === 'n0' ? { role, isRoot, kind: 'claude' } : null),
  })
  const channel = (calls: Array<{ name: string; args: Record<string, unknown>; id: number }>) => {
    const lines = [JSON.stringify({ node: 'n0' }), JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} })]
    for (const c of calls) {
      lines.push(
        JSON.stringify({ jsonrpc: '2.0', id: c.id, method: 'tools/call', params: { name: c.name, arguments: c.args } }),
      )
    }
    return new FakeChannel(lines)
  }
  return { server, commands, channel }
}

describe('MCPToolServer tool surface', () => {
  it('is identity-scoped: root, sub-manager and worker get different sets', () => {
    expect([...MCPToolServer.allowedTools('manager', true, 'claude')].sort()).toEqual(['kill', 'rename', 'send', 'spawn'])
    expect([...MCPToolServer.allowedTools('manager', false, 'claude')].sort()).toEqual(['kill', 'report', 'send', 'spawn'])
    expect([...MCPToolServer.allowedTools('leaf', false, 'claude')]).toEqual(['report'])
  })

  it('hard-trims tools/list to the node surface', async () => {
    const { server, channel } = makeServer('leaf', false)
    const ch = channel([])
    ;(ch as any).pending.push(JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list' }))
    await server.handle(ch)
    const list = ch.replies().find((r) => r.id === 2)
    expect(list.result.tools.map((t: any) => t.name)).toEqual(['report'])
  })

  it('rejects a tool outside the surface even when called by name', async () => {
    const { server, channel } = makeServer('leaf', false)
    const ch = channel([{ name: 'spawn', args: { role: 'leaf', task: 'x' }, id: 3 }])
    await server.handle(ch)
    const res = ch.replies().find((r) => r.id === 3)
    expect(res.result.isError).toBe(true)
    expect(res.result.content[0].text).toContain('not available')
  })

  it('spawn emits a requestStruct and reports the spawned id', async () => {
    const { server, commands, channel } = makeServer('manager', true, (cmd) =>
      cmd.type === 'requestStruct'
        ? { type: 'structResult', result: { type: 'spawned', node: 'n7' } }
        : null,
    )
    const ch = channel([{ name: 'spawn', args: { role: 'leaf', task: 'do it', name: 'probe' }, id: 4 }])
    await server.handle(ch)
    const cmd = commands.find((c) => c.type === 'requestStruct') as Extract<Command, { type: 'requestStruct' }>
    expect(cmd.request).toEqual({ type: 'spawn', parent: 'n0', role: 'leaf', task: 'do it', model: null, name: 'probe' })
    const res = ch.replies().find((r) => r.id === 4)
    expect(res.result).toEqual({ content: [{ type: 'text', text: 'n7' }], isError: false })
  })

  it('send awaits the delivery verdict and surfaces a drop as isError', async () => {
    const { server, channel } = makeServer('manager', true, () => ({
      type: 'sendAck',
      delivered: false,
      note: 'node n3 not reachable: no such node in the tree',
    }))
    const ch = channel([{ name: 'send', args: { node: 'n3', message: 'hello' }, id: 5 }])
    await server.handle(ch)
    const res = ch.replies().find((r) => r.id === 5)
    expect(res.result.isError).toBe(true)
    expect(res.result.content[0].text).toContain('not reachable')
  })

  it('report is fire-and-forget and worker-only', async () => {
    const worker = makeServer('leaf', false)
    const ch = worker.channel([{ name: 'report', args: { summary: 'done' }, id: 6 }])
    await worker.server.handle(ch)
    expect(worker.commands).toEqual([{ type: 'rollup', from: 'n0', summary: 'done' }])
    expect(ch.replies().find((r) => r.id === 6).result.isError).toBe(false)

    const root = makeServer('manager', true)
    const ch2 = root.channel([{ name: 'report', args: { summary: 'x' }, id: 7 }])
    await root.server.handle(ch2)
    expect(ch2.replies().find((r) => r.id === 7).result.isError).toBe(true)
  })

  it('rename validates synchronously and pins the name', async () => {
    const names: string[] = []
    const pending = new PendingReplies()
    const server = new MCPToolServer({
      emit: () => undefined,
      pending,
      nodeInfo: () => ({ role: 'manager', isRoot: true, kind: 'claude' }),
      onRename: (_n, name) => names.push(name),
    })
    const ch = new FakeChannel([
      JSON.stringify({ node: 'n0' }),
      JSON.stringify({ jsonrpc: '2.0', id: 8, method: 'tools/call', params: { name: 'rename', arguments: { name: '   ' } } }),
      JSON.stringify({ jsonrpc: '2.0', id: 9, method: 'tools/call', params: { name: 'rename', arguments: { name: ' Fix login ' } } }),
    ])
    await server.handle(ch)
    const empty = ch.replies().find((r) => r.id === 8)
    const ok = ch.replies().find((r) => r.id === 9)
    expect(empty.result.isError).toBe(true)
    expect(ok.result.content[0].text).toBe('renamed')
    expect(names).toEqual(['Fix login'])
  })
})

describe('toolText', () => {
  it('maps a cancelled wait and a mismatched decision honestly', () => {
    expect(toolText({ type: 'cancelled', reason: 'gone' }, 'structResult')).toEqual(['cancelled: gone', true])
    expect(toolText({ type: 'sendAck', delivered: true, note: 'sent' }, 'structResult')[1]).toBe(true)
  })
})
