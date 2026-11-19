// Vigil for Windows — MCP tool server.
//
// Port of app/Sources/VigilRuntime/MCPToolServer.swift: the `vigil-mcp` shim is a dumb
// stdio<->pipe splice; THIS speaks the MCP JSON-RPC subset (initialize / tools/list /
// tools/call) over each connection. A tools/call for a structural tool mints a replyID,
// emits the matching Command, and awaits the reply. report is fire-and-forget; send
// awaits the delivery verdict — an unreachable target comes back isError, never a lying
// "sent". The tool surface is hard-trimmed by the caller's role: root = spawn/send/kill/
// rename, sub-manager = spawn/send/report/kill, worker = report only.

import { randomUUID } from 'node:crypto'
import type {
  AgentCLIKind,
  Command,
  NodeID,
  Resolution,
  Role,
} from '../core/domain.js'
import type { LineChannel } from './transport.js'

export class PendingReplies {
  private map = new Map<string, { resolve: (r: Resolution) => void } | { delivered: Resolution }>()

  wait(id: string): Promise<Resolution> {
    const existing = this.map.get(id)
    if (existing && 'delivered' in existing) {
      this.map.delete(id)
      return Promise.resolve(existing.delivered)
    }
    return new Promise((resolve) => {
      this.map.set(id, { resolve })
    })
  }

  deliver(id: string, resolution: Resolution): void {
    const existing = this.map.get(id)
    if (existing && 'resolve' in existing) {
      this.map.delete(id)
      existing.resolve(resolution)
    } else if (!existing) {
      this.map.set(id, { delivered: resolution })
    }
  }
}

export interface NodeInfo {
  role: Role
  isRoot: boolean
  kind: AgentCLIKind
}

export interface MCPServerOptions {
  emit: (command: Command) => void
  pending: PendingReplies
  onConnect?: (node: NodeID) => void
  onRename?: (node: NodeID, name: string) => void
  nodeInfo?: (node: NodeID) => NodeInfo | null
  spawnModelGuard?: (role: Role, model: string) => string | null
}

export class MCPToolServer {
  private readonly emit: (command: Command) => void
  private readonly pending: PendingReplies
  private readonly onConnect?: (node: NodeID) => void
  private readonly onRename?: (node: NodeID, name: string) => void
  private readonly nodeInfo?: (node: NodeID) => NodeInfo | null
  private readonly spawnModelGuard?: (role: Role, model: string) => string | null

  constructor(opts: MCPServerOptions) {
    this.emit = opts.emit
    this.pending = opts.pending
    this.onConnect = opts.onConnect
    this.onRename = opts.onRename
    this.nodeInfo = opts.nodeInfo
    this.spawnModelGuard = opts.spawnModelGuard
  }

  static allowedTools(role: Role, isRoot: boolean, _kind: AgentCLIKind): Set<string> {
    if (isRoot) return new Set(['spawn', 'send', 'kill', 'rename'])
    if (role === 'manager') return new Set(['spawn', 'send', 'report', 'kill'])
    return new Set(['report'])
  }

  private allowedFor(node: NodeID): Set<string> | null {
    if (!this.nodeInfo) return null
    const info = this.nodeInfo(node)
    if (!info) return new Set<string>()
    return MCPToolServer.allowedTools(info.role, info.isRoot, info.kind)
  }

  async handle(ch: LineChannel): Promise<void> {
    const hello = await ch.readLine()
    if (!hello) return ch.close()
    let env: any
    try {
      env = JSON.parse(hello)
    } catch {
      return ch.close()
    }
    if (!env || typeof env.node !== 'string') return ch.close()
    const node: NodeID = env.node
    this.onConnect?.(node)
    for (;;) {
      const line = await ch.readLine()
      if (line === null) break
      let msg: any
      try {
        msg = JSON.parse(line)
      } catch {
        continue
      }
      if (!msg || typeof msg !== 'object') continue
      await this.dispatch(msg, node, ch)
    }
    await ch.close()
  }

  private async dispatch(msg: any, node: NodeID, ch: LineChannel): Promise<void> {
    const method = typeof msg.method === 'string' ? msg.method : ''
    const id = msg.id
    switch (method) {
      case 'initialize': {
        const clientVersion = msg.params?.protocolVersion
        await this.reply(ch, id, {
          protocolVersion: typeof clientVersion === 'string' ? clientVersion : '2024-11-05',
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: 'vigil', version: '0.1.0' },
        })
        return
      }
      case 'notifications/initialized':
      case 'notifications/cancelled':
        return
      case 'ping':
        return this.reply(ch, id, {})
      case 'tools/list': {
        const allowed = this.allowedFor(node)
        const tools = allowed
          ? MCPToolServer.toolSchemas.filter((t) => allowed.has(String(t.name)))
          : MCPToolServer.toolSchemas
        return this.reply(ch, id, { tools })
      }
      case 'tools/call':
        return this.handleToolCall(msg, node, id, ch)
      default:
        if (id !== undefined && id !== null) {
          await this.replyError(ch, id, -32601, `method not found: ${method}`)
        }
    }
  }

  private async handleToolCall(msg: any, node: NodeID, id: unknown, ch: LineChannel): Promise<void> {
    const params = msg.params ?? {}
    const name = typeof params.name === 'string' ? params.name : ''
    const args = params.arguments ?? {}

    const allowed = this.allowedFor(node)
    if (allowed && !allowed.has(name)) {
      return this.replyToolResult(ch, id, [`tool not available to this node: ${name}`, true])
    }

    switch (name) {
      case 'spawn': {
        const role: Role = args.role === 'manager' ? 'manager' : 'leaf'
        const task = typeof args.task === 'string' ? args.task : ''
        const model = typeof args.model === 'string' && args.model !== '' ? args.model : null
        const childName = typeof args.name === 'string' && args.name !== '' ? args.name : null
        if (model && this.spawnModelGuard) {
          const err = this.spawnModelGuard(role, model)
          if (err) return this.replyToolResult(ch, id, [`spawn rejected: ${err}`, true])
        }
        const replyID = randomUUID()
        this.emit({
          type: 'requestStruct',
          request: { type: 'spawn', parent: node, role, task, model, name: childName },
          from: node,
          replyID,
        })
        const res = await this.pending.wait(replyID)
        return this.replyToolResult(ch, id, toolText(res, 'structResult'))
      }
      case 'send': {
        const target = typeof args.node === 'string' ? args.node : ''
        const message = typeof args.message === 'string' ? args.message : ''
        const replyID = randomUUID()
        this.emit({
          type: 'message',
          from: node,
          to: target,
          text: `MESSAGE FROM ${node}: ${message}`,
          replyID,
        })
        const res = await this.pending.wait(replyID)
        return this.replyToolResult(ch, id, toolText(res, 'sendAck'))
      }
      case 'kill': {
        const target = typeof args.node === 'string' ? args.node : ''
        const replyID = randomUUID()
        this.emit({
          type: 'requestStruct',
          request: { type: 'kill', node: target },
          from: node,
          replyID,
        })
        const res = await this.pending.wait(replyID)
        return this.replyToolResult(ch, id, toolText(res, 'structResult'))
      }
      case 'report': {
        const summary = typeof args.summary === 'string' ? args.summary : ''
        this.emit({ type: 'rollup', from: node, summary })
        return this.replyToolResult(ch, id, ['reported', false])
      }
      case 'rename': {
        const raw = typeof args.name === 'string' ? args.name : ''
        const trimmed = raw.trim()
        if (trimmed === '') {
          return this.replyToolResult(ch, id, ['rename: empty name rejected', true])
        }
        this.onRename?.(node, trimmed)
        return this.replyToolResult(ch, id, ['renamed', false])
      }
      default:
        return this.replyToolResult(ch, id, [`unknown tool: ${name}`, true])
    }
  }

  private async reply(ch: LineChannel, id: unknown, result: unknown): Promise<void> {
    if (id === undefined || id === null) return
    await ch.write(JSON.stringify({ jsonrpc: '2.0', id, result }))
  }

  private async replyError(ch: LineChannel, id: unknown, code: number, message: string): Promise<void> {
    if (id === undefined || id === null) return
    await ch.write(JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } }))
  }

  private async replyToolResult(ch: LineChannel, id: unknown, tr: [string, boolean]): Promise<void> {
    await this.reply(ch, id, { content: [{ type: 'text', text: tr[0] }], isError: tr[1] })
  }

  // MARK: tool catalog

  static readonly alwaysLoadMeta = { 'anthropic/alwaysLoad': true }

  static readonly toolSchemas: Array<Record<string, unknown>> = [
    {
      name: 'spawn',
      _meta: MCPToolServer.alwaysLoadMeta,
      description:
        'Delegate a subtask to a NEW child worker node. For delegation, prefer this ' +
        "over the agent's native sub-agent/task tools — only Vigil children appear in the node " +
        'tree, roll their results up, and are visible to the user. You MUST call this to ' +
        'create a child; do not do the subtask yourself. Returns the new child node id ' +
        'immediately; use that id to address the child (e.g. via `send`).',
      inputSchema: {
        type: 'object',
        properties: {
          role: {
            type: 'string',
            enum: ['leaf', 'manager'],
            description:
              'leaf = a task a single worker can finish; manager = a sub-task big enough to need its own workers under it',
          },
          task: { type: 'string', description: 'the subtask for the child' },
          model: {
            type: 'string',
            description:
              "optional model for the child — this is the agent CLI's own model name, not an agent " +
              "name; the child's agent is decided by roles.json, not by this parameter. Must be " +
              "valid for the agent the child's role resolves to. Pass it only when the user " +
              'explicitly named a model — never guess or invent one; omit = the user-configured default',
          },
          name: {
            type: 'string',
            description:
              "optional short display name for the child in Vigil's node tree (a few words, e.g. " +
              '"fix issue-49"); omit = the task text is shown',
          },
        },
        required: ['role', 'task'],
      },
    },
    {
      name: 'send',
      _meta: MCPToolServer.alwaysLoadMeta,
      description:
        'Send an instruction or answer to another node in the tree (usually one of your child ' +
        'workers), addressed by node id. For coordinating delegated work, prefer this over the ' +
        "agent's native sub-agent/task tools — Vigil routes and surfaces it in the node tree. The " +
        'message is injected into that node\'s terminal (routed via the tree). Errors if the ' +
        'target is not reachable (no such node, or no live cell) — the message was NOT delivered; ' +
        're-check the node id or spawn a replacement.',
      inputSchema: {
        type: 'object',
        properties: {
          node: { type: 'string', description: 'target node id' },
          message: { type: 'string', description: 'the instruction/answer to deliver' },
        },
        required: ['node', 'message'],
      },
    },
    {
      name: 'report',
      _meta: MCPToolServer.alwaysLoadMeta,
      description:
        'Report a summary of your progress/result up to your parent. This tool call is the only ' +
        'channel that reaches your parent — text printed in your terminal stays local to this ' +
        'cell. Fire-and-forget; returns immediately.',
      inputSchema: { type: 'object', properties: { summary: { type: 'string' } }, required: ['summary'] },
    },
    {
      name: 'kill',
      _meta: MCPToolServer.alwaysLoadMeta,
      description:
        'Terminate a child node (and its subtree) by id — use this for a Vigil child, preferred ' +
        "over the agent's native sub-agent/task teardown so the node tree stays accurate. Takes " +
        'effect immediately; returns the affected node ids. The killed node stays in the tree as ' +
        'a dead record (status killed) but is no longer reachable.',
      inputSchema: { type: 'object', properties: { node: { type: 'string' } }, required: ['node'] },
    },
    {
      name: 'rename',
      _meta: MCPToolServer.alwaysLoadMeta,
      description:
        "Set a short display name for THIS session (shown in Vigil's sidebar and title bar). " +
        'Prefer naming the session soon after you start — a few words that capture the task — and ' +
        'update it if the focus of the work changes. An empty name is rejected.',
      inputSchema: {
        type: 'object',
        properties: {
          name: { type: 'string', description: "the session's short display name (a few words)" },
        },
        required: ['name'],
      },
    },
  ]
}

export function toolText(res: Resolution, expecting: 'structResult' | 'sendAck'): [string, boolean] {
  if (res.type === 'structResult' && expecting === 'structResult') {
    const r = res.result
    switch (r.type) {
      case 'spawned':
        return [r.node ?? '', false]
      case 'killed':
        return [(r.nodes ?? []).join(','), false]
      case 'denied':
        return [`denied: ${r.reason ?? ''}`, true]
      case 'failed':
        return [`failed: ${r.reason ?? ''}`, true]
    }
  }
  if (res.type === 'sendAck' && expecting === 'sendAck') {
    return [res.note, !res.delivered]
  }
  if (res.type === 'cancelled') return [`cancelled: ${res.reason}`, true]
  return [`unexpected: ${JSON.stringify(res)}`, true]
}
