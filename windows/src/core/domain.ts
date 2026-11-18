// Vigil for Windows — core domain.
//
// A direct port of app/Sources/VigilCore/Domain.swift: the same node tree, the same
// single-root / single-parent invariants, the same Command-in / Effect-out direction.
// This module has ZERO I/O and ZERO UI so it stays deterministic and unit-testable.

export type NodeID = string
export type Role = 'leaf' | 'manager'
export type NodeKind = 'cell' | 'observed'

/**
 * running = a turn is in flight (prompt -> stop); idle = turn closed, the process
 * lives; waiting = a permission box needs the human; stalled = spawn never connected;
 * queued = a routed message is held behind the user's own typing; errored = a turn
 * died on an API error and fired no Stop hook. done/failed/killed only on process exit.
 */
export type NodeStatus =
  | 'starting'
  | 'running'
  | 'idle'
  | 'waiting'
  | 'done'
  | 'failed'
  | 'killed'
  | 'stalled'
  | 'queued'
  | 'errored'

export interface Node {
  id: NodeID
  kind: NodeKind
  role: Role
  parent: NodeID | null
  children: NodeID[]
  status: NodeStatus
  title: string
  lastRollup: string | null
  model: string | null
  startedAt: number | null
  endedAt: number | null
}

export function isTerminal(status: NodeStatus): boolean {
  return status === 'done' || status === 'failed' || status === 'killed'
}

export function makeNode(init: Partial<Node> & { id: NodeID; role: Role }): Node {
  return {
    kind: 'cell',
    parent: null,
    children: [],
    status: 'starting',
    title: '',
    lastRollup: null,
    model: null,
    startedAt: null,
    endedAt: null,
    ...init,
  }
}

// MARK: structural requests

export type StructRequest =
  | { type: 'spawn'; parent: NodeID; role: Role; task: string; model: string | null; name: string | null }
  | { type: 'kill'; node: NodeID }

export interface StructResult {
  type: 'spawned' | 'killed' | 'denied' | 'failed'
  node?: NodeID
  nodes?: NodeID[]
  reason?: string
}

// MARK: observation notices

export type NoticeKind = 'permission' | 'inject-queued'
export type NoticeResolvedVia = 'post-tool' | 'scrape' | 'prompt' | 'node-death'

export interface PermNoticeInfo {
  promptID?: string | null
  toolName?: string | null
  toolInput?: string | null
  inputSummary?: string | null
  text: string
}

export interface PermResolveMatch {
  promptID?: string | null
  toolName?: string | null
  toolInput?: string | null
  toolUseID?: string | null
}

export interface AgentNotice {
  id: string
  seq: number
  nodeID: NodeID
  kind: NoticeKind
  text: string
  promptID?: string | null
  toolName?: string | null
  toolInput?: string | null
  inputSummary?: string | null
  arrivedAt: number
  /** A permission card only becomes visible this long after arrival. */
  displayAfter: number
}

export const permissionGraceMs = 2500

export interface PermLogEntry {
  event: 'perm_request' | 'perm_resolve'
  nodeID: NodeID
  kind: NoticeKind
  promptID?: string | null
  toolName?: string | null
  toolUseID?: string | null
  via?: string | null
}

export type PermissionMode = 'default' | 'acceptEdits' | 'plan' | 'bypassPermissions'

export function parsePermissionMode(raw: string | null | undefined): PermissionMode | null {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'bypass':
    case 'bypasspermissions':
    case 'full':
    case 'all':
    case 'yolo':
      return 'bypassPermissions'
    case 'default':
    case 'standard':
    case 'ask':
      return 'default'
    case 'acceptedits':
    case 'accept-edits':
    case 'edits':
      return 'acceptEdits'
    case 'plan':
    case 'readonly':
    case 'read-only':
      return 'plan'
    default:
      return null
  }
}

// MARK: Command / Effect / Resolution

export type Command =
  | { type: 'nodeOnline'; node: NodeID }
  | { type: 'nodeExited'; node: NodeID; code: number | null }
  | { type: 'nodeFailed'; node: NodeID; reason: string }
  | { type: 'requestStruct'; request: StructRequest; from: NodeID; replyID: string }
  | { type: 'rollup'; from: NodeID; summary: string }
  | { type: 'message'; from: NodeID; to: NodeID; text: string; replyID: string | null }
  | { type: 'permRequested'; from: NodeID; info: PermNoticeInfo }
  | { type: 'resolveNotice'; from: NodeID; match: PermResolveMatch | null; via: NoticeResolvedVia }
  | { type: 'clearNotices'; node: NodeID }
  | { type: 'turnStarted'; node: NodeID }
  | { type: 'turnEnded'; node: NodeID; gen: number | null }
  | { type: 'restoreSkeleton'; tree: Tree }
  | { type: 'resumeNode'; node: NodeID; sessionID: string }
  | { type: 'spawnStalled'; node: NodeID }
  | { type: 'spawnRecovered'; node: NodeID }
  | { type: 'injectQueued'; node: NodeID; pending: number; epoch: number }
  | { type: 'injectSettled'; node: NodeID; epoch: number }
  | { type: 'turnErrored'; node: NodeID }

export type Resolution =
  | { type: 'structResult'; result: StructResult }
  | { type: 'cancelled'; reason: string }
  | { type: 'sendAck'; delivered: boolean; note: string }

export type Effect =
  | { type: 'spawnCell'; node: Node; task: string }
  | { type: 'resumeCell'; node: Node; sessionID: string }
  | { type: 'killCells'; nodes: NodeID[] }
  | { type: 'route'; to: NodeID; text: string; viaPath: NodeID[]; replyID: string | null }
  | { type: 'routeFailed'; from: NodeID; to: NodeID; reason: string }
  | { type: 'deliver'; replyID: string; resolution: Resolution }
  | { type: 'permLog'; entry: PermLogEntry }

export type AgentCLIKind = 'claude' | 'codex' | 'opencode' | 'custom'

export function resumeSyntax(kind: AgentCLIKind): string {
  switch (kind) {
    case 'codex':
      return 'codex resume'
    case 'opencode':
      return 'opencode --session'
    default:
      return 'claude --resume'
  }
}

// MARK: Tree

export class TreeError extends Error {
  constructor(
    public readonly code: 'noSuchNode' | 'notManager' | 'duplicate' | 'cannotKillRoot' | 'notInSubtree',
    message: string,
  ) {
    super(message)
  }
}

/**
 * The node tree with its invariants: single root, single parent, acyclic. All
 * mutations go through these methods so the invariants cannot be violated.
 */
export class Tree {
  readonly nodes = new Map<NodeID, Node>()
  readonly rootID: NodeID

  constructor(root: Node) {
    if (root.parent !== null) throw new Error('root must have no parent')
    this.rootID = root.id
    this.nodes.set(root.id, { ...root })
  }

  get(id: NodeID): Node | undefined {
    return this.nodes.get(id)
  }

  get root(): Node {
    return this.nodes.get(this.rootID) as Node
  }

  get count(): number {
    return this.nodes.size
  }

  clone(): Tree {
    const t = new Tree({ ...this.root })
    t.nodes.clear()
    for (const [k, v] of this.nodes) t.nodes.set(k, { ...v, children: [...v.children] })
    return t
  }

  spawn(parent: NodeID, child: Node): void {
    const p = this.nodes.get(parent)
    if (!p) throw new TreeError('noSuchNode', `no such node ${parent}`)
    if (p.role !== 'manager') throw new TreeError('notManager', `${parent} is not a manager`)
    if (this.nodes.has(child.id)) throw new TreeError('duplicate', `duplicate node ${child.id}`)
    const c = { ...child, parent }
    this.nodes.set(child.id, c)
    p.children.push(child.id)
  }

  /** Seal a whole subtree as dead records; returns ids that were live (DFS, id first). */
  kill(id: NodeID, by: NodeID | null = null): NodeID[] {
    if (!this.nodes.has(id)) throw new TreeError('noSuchNode', `no such node ${id}`)
    if (id === this.rootID) throw new TreeError('cannotKillRoot', 'cannot kill the root')
    if (by !== null && !this.pathToRoot(id).includes(by)) {
      throw new TreeError('notInSubtree', `node ${id} not in your subtree`)
    }
    return this.sealSubtree(id)
  }

  sealSubtree(id: NodeID): NodeID[] {
    const live: NodeID[] = []
    for (const nid of this.subtree(id)) {
      const n = this.nodes.get(nid)
      if (n && !isTerminal(n.status)) {
        live.push(nid)
        this.setStatus(nid, 'killed')
      }
    }
    return live
  }

  setStatus(id: NodeID, status: NodeStatus): void {
    const n = this.nodes.get(id)
    if (n) n.status = status
  }

  /** Freeze the runtime clock once — a later teardown echo must not move it. */
  setEnded(id: NodeID, at: number): void {
    const n = this.nodes.get(id)
    if (n && n.endedAt === null) n.endedAt = at
  }

  /** Re-incarnation on resume: clear the previous lifetime's frozen terminal state. */
  relaunch(id: NodeID, status: NodeStatus, startedAt: number | null): void {
    const n = this.nodes.get(id)
    if (!n) return
    n.status = status
    n.endedAt = null
    if (startedAt !== null) n.startedAt = startedAt
  }

  setRollup(id: NodeID, summary: string): void {
    const n = this.nodes.get(id)
    if (n) n.lastRollup = summary
  }

  childrenOf(id: NodeID): NodeID[] {
    return this.nodes.get(id)?.children ?? []
  }

  subtree(id: NodeID): NodeID[] {
    if (!this.nodes.has(id)) return []
    const out: NodeID[] = []
    const stack = [id]
    while (stack.length) {
      const cur = stack.pop() as NodeID
      out.push(cur)
      const kids = this.nodes.get(cur)?.children ?? []
      for (let i = kids.length - 1; i >= 0; i--) stack.push(kids[i])
    }
    return out
  }

  pathToRoot(id: NodeID): NodeID[] {
    const out: NodeID[] = []
    let cur: NodeID | null = id
    while (cur && this.nodes.has(cur)) {
      out.push(cur)
      cur = this.nodes.get(cur)?.parent ?? null
    }
    return out
  }

  lca(a: NodeID, b: NodeID): NodeID | null {
    const aset = new Set(this.pathToRoot(a))
    for (const n of this.pathToRoot(b)) if (aset.has(n)) return n
    return null
  }

  /** The unique tree path a ↑ LCA ↓ b — cross-subtree traffic never forms a mesh. */
  path(from: NodeID, to: NodeID): NodeID[] {
    if (!this.nodes.has(from) || !this.nodes.has(to)) return []
    const l = this.lca(from, to)
    if (l === null) return []
    const up: NodeID[] = []
    let cur: NodeID | null = from
    while (cur) {
      up.push(cur)
      if (cur === l) break
      cur = this.nodes.get(cur)?.parent ?? null
    }
    const down: NodeID[] = []
    cur = to
    while (cur && cur !== l) {
      down.push(cur)
      cur = this.nodes.get(cur)?.parent ?? null
    }
    return [...up, ...down.reverse()]
  }
}
