// Design status mapping — port of designStatus/statusText/statusColor/dotClass and the
// session-row rollup from AppModel.swift + SidebarView.swift.

import type { NodeStatus, ViewNode } from '../shared/protocol'
import type { Tokens } from './theme'

export type DStatus =
  | 'running'
  | 'idle'
  | 'waiting'
  | 'done'
  | 'failed'
  | 'killed'
  | 'starting'
  | 'subagent'
  | 'stalled'
  | 'queued'
  | 'errored'

export type DotClass = 'spinner' | 'blue' | 'yellow' | 'plain'

export function designStatus(node: ViewNode): DStatus {
  if (node.kind === 'observed') return 'subagent'
  return node.status as DStatus
}

export function statusText(d: DStatus): string {
  switch (d) {
    case 'running':
      return 'Running'
    case 'idle':
      return 'Idle'
    case 'waiting':
      return 'Awaiting approval'
    case 'done':
      return 'Done'
    case 'failed':
      return 'Failed'
    case 'killed':
      return 'Terminated'
    case 'starting':
      return 'Starting'
    case 'subagent':
      return 'Running'
    case 'stalled':
      return "spawn didn't connect"
    case 'queued':
      return 'Message queued'
    case 'errored':
      return 'Turn ended abnormally'
  }
}

export function statusColor(d: DStatus, tokens: Tokens): string {
  switch (d) {
    case 'running':
      return tokens.accent
    case 'idle':
      return tokens.text2
    case 'waiting':
      return tokens.warn
    case 'done':
      return tokens.green
    case 'failed':
      return tokens.red
    case 'killed':
      return tokens.text3
    case 'starting':
      return tokens.text3
    case 'subagent':
      return tokens.text2
    case 'stalled':
    case 'queued':
    case 'errored':
      return tokens.warn
  }
}

export function dotClass(status: NodeStatus, unseen: boolean): DotClass {
  switch (status) {
    case 'starting':
    case 'running':
      return 'spinner'
    case 'waiting':
    case 'stalled':
    case 'queued':
      return 'yellow'
    case 'errored':
    case 'failed':
      return unseen ? 'yellow' : 'plain'
    case 'idle':
    case 'done':
      return unseen ? 'blue' : 'plain'
    case 'killed':
      return 'plain'
  }
}

export type SessionIndicator = 'attention' | 'live' | 'rest'

export function sessionIndicator(badge: number, nodes: ViewNode[], unseen: Set<string>): SessionIndicator {
  if (badge > 0) return 'attention'
  let spinner = false
  for (const n of nodes) {
    const cls = dotClass(n.status, unseen.has(n.id))
    if (cls === 'yellow') return 'attention'
    if (cls === 'spinner') spinner = true
  }
  return spinner ? 'live' : 'rest'
}

export function sessionDotClass(
  badge: number,
  nodes: ViewNode[],
  unseen: Set<string>,
  completedUnseen: boolean,
): DotClass {
  switch (sessionIndicator(badge, nodes, unseen)) {
    case 'attention':
      return 'yellow'
    case 'live':
      return 'spinner'
    case 'rest':
      return completedUnseen ? 'blue' : 'plain'
  }
}

/** The one-time unseen transition rule (AppModel.unseenMutation). */
export function unseenMutation(prev: NodeStatus | undefined, now: NodeStatus, watching: boolean): 'mark' | 'clear' | 'none' {
  if (prev === now) return 'none'
  if (now === 'running' || now === 'starting' || now === 'killed') return 'clear'
  if (now === 'idle' || now === 'done' || now === 'errored' || now === 'failed') {
    return watching ? 'clear' : 'mark'
  }
  return 'none'
}
