// Vigil for Windows — hook channel server.
//
// Port of app/Sources/VigilRuntime/HookGateway.swift. claude/codex hooks are a pure
// OBSERVATION feed: one firing = one short-lived connection, one envelope line,
// fire-and-forget. Nothing is ever written back, so fail-open is trivially true.
//   prompt      (UserPromptSubmit) -> turnStarted + clearNotices + auto-namer input
//   perm-request(PermissionRequest)-> a permission card appeared
//   post-tool   (PostToolUse)      -> the approval (if any) resolved
//   stop        (Stop)             -> turn ended

import type { Command, NodeID } from '../core/domain.js'
import type { LineChannel } from './transport.js'

export type HookEvent = 'prompt' | 'perm-request' | 'post-tool' | 'stop'

export const hookEvents: Record<string, HookEvent> = {
  prompt: 'prompt',
  'perm-request': 'perm-request',
  'post-tool': 'post-tool',
  stop: 'stop',
}

export interface HookGatewayOptions {
  emit: (command: Command) => void
  onPrompt?: (node: NodeID, payload: Record<string, any>) => void
  onStop?: (node: NodeID, payload: Record<string, any>) => void
}

function payloadDict(env: Record<string, any>): Record<string, any> {
  if (typeof env.payload === 'string') {
    try {
      const d = JSON.parse(env.payload)
      if (d && typeof d === 'object') return d
    } catch {
      return {}
    }
  }
  if (env.payload && typeof env.payload === 'object') return env.payload
  if (env.request && typeof env.request === 'object') return env.request
  return {}
}

export function canonicalJSON(value: unknown): string | null {
  if (value === undefined || value === null) return null
  if (typeof value === 'string') return value
  return JSON.stringify(sortKeys(value))
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys)
  if (value && typeof value === 'object') {
    const out: Record<string, unknown> = {}
    for (const k of Object.keys(value as Record<string, unknown>).sort()) {
      out[k] = sortKeys((value as Record<string, unknown>)[k])
    }
    return out
  }
  return value
}

export function inputSummary(value: unknown): string | null {
  if (!value || typeof value !== 'object') return null
  const d = value as Record<string, unknown>
  const s =
    (typeof d.command === 'string' && d.command) ||
    (typeof d.file_path === 'string' && d.file_path) ||
    (typeof d.pattern === 'string' && d.pattern) ||
    (typeof d.url === 'string' && d.url) ||
    canonicalJSON(d)
  if (!s) return null
  return s.length > 60 ? s.slice(0, 60) + '…' : s
}

export class HookGateway {
  constructor(private readonly opts: HookGatewayOptions) {}

  async handle(ch: LineChannel): Promise<void> {
    const line = await ch.readLine()
    if (line === null) return ch.close()
    let env: Record<string, any>
    try {
      env = JSON.parse(line)
    } catch {
      return ch.close()
    }
    const node: NodeID = typeof env.node === 'string' ? env.node : '?'
    const event = typeof env.event === 'string' ? env.event : ''
    const payload = payloadDict(env)

    switch (hookEvents[event]) {
      case 'prompt':
        this.opts.onPrompt?.(node, payload)
        this.opts.emit({ type: 'turnStarted', node })
        this.opts.emit({ type: 'clearNotices', node })
        break
      case 'stop':
        this.opts.onStop?.(node, payload)
        this.opts.emit({ type: 'turnEnded', node, gen: null })
        break
      case 'perm-request': {
        const tool = typeof payload.tool_name === 'string' ? payload.tool_name : null
        const summary = inputSummary(payload.tool_input)
        this.opts.emit({
          type: 'permRequested',
          from: node,
          info: {
            promptID: typeof payload.prompt_id === 'string' ? payload.prompt_id : null,
            toolName: tool,
            toolInput: canonicalJSON(payload.tool_input),
            inputSummary: summary,
            text: `Awaiting approval · ${tool ?? '?'}${summary ? `(${summary})` : ''}`,
          },
        })
        break
      }
      case 'post-tool':
        this.opts.emit({
          type: 'resolveNotice',
          from: node,
          match: {
            promptID: typeof payload.prompt_id === 'string' ? payload.prompt_id : null,
            toolName: typeof payload.tool_name === 'string' ? payload.tool_name : null,
            toolInput: canonicalJSON(payload.tool_input),
            toolUseID: typeof payload.tool_use_id === 'string' ? payload.tool_use_id : null,
          },
          via: 'post-tool',
        })
        break
      default:
        // unknown events: observation-only channel, drop
        break
    }
    await ch.close()
  }
}

/** The four observation hooks, built once for every harness family. */

/** Windows needs a shell command that survives BOTH cmd.exe and Git Bash. */
function shellToken(token: string): string {
  return /\s/.test(token) ? `"${token}"` : token
}

function forwardSlashes(p: string): string {
  return p.replace(/\\/g, '/')
}

export function observationHooks(
  nodeCommand: string,
  hookScript: string,
  node: NodeID,
  hookPipe: string,
): Record<string, unknown> {
  // Quote-free when every token is space-free: cmd.exe mis-parses a *leading* quoted
  // token (codex's runner reports "hook exited with code 1"), and Git Bash collapses
  // `\` inside double quotes. Forward slashes are accepted by both the executable
  // loader and Node.
  const base =
    `${shellToken(forwardSlashes(nodeCommand))} ` +
    `${shellToken(forwardSlashes(hookScript))} --node ${node} --sock ${shellToken(hookPipe)}`
  const entry = (event: HookEvent) => [
    { hooks: [{ type: 'command', command: `${base} --event ${event}` }] },
  ]
  return {
    UserPromptSubmit: entry('prompt'),
    PermissionRequest: entry('perm-request'),
    PostToolUse: entry('post-tool'),
    Stop: entry('stop'),
  }
}
