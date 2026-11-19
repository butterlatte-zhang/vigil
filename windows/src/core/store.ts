// Vigil for Windows — SessionStore.
//
// Port of app/Sources/VigilCore/SessionStore.swift. The single source of truth for a
// running session: everything enters via send(Command), everything leaves as Effect.
// Struct changes (spawn/kill) apply immediately — permissions are the agent CLI's own
// native mechanism, Vigil observes rather than gates.

import {
  type AgentNotice,
  type Command,
  type Effect,
  type Node,
  type NodeID,
  type NodeStatus,
  type NoticeResolvedVia,
  type PermNoticeInfo,
  type PermResolveMatch,
  type Resolution,
  type StructRequest,
  type StructResult,
  Tree,
  TreeError,
  isTerminal,
  makeNode,
  permissionGraceMs,
  type NoticeKind,
} from './domain.js'

let noticeSeq = 0

export class SessionStore {
  tree: Tree
  notices: AgentNotice[] = []
  /** Never-silent-fail log. */
  log: string[] = []

  private seq = 0
  private nodeSeq = 0
  private deliveredReplies = new Set<string>()
  private stalledSpawns = new Set<NodeID>()
  private erroredNodes = new Set<NodeID>()
  private injectSignalEpoch = new Map<NodeID, number>()
  private openTurns = new Map<NodeID, number>()
  private turnCounter = 0
  private readonly now: () => number
  private readonly perform: (effect: Effect) => void
  private readonly onChange?: () => void

  constructor(
    root: Node,
    perform: (effect: Effect) => void,
    opts: { now?: () => number; onChange?: () => void } = {},
  ) {
    const r = { ...root }
    if (r.startedAt === null) r.startedAt = (opts.now ?? Date.now)()
    this.tree = new Tree(r)
    this.now = opts.now ?? Date.now
    this.perform = perform
    this.onChange = opts.onChange
  }

  // MARK: ingress

  send(command: Command): void {
    switch (command.type) {
      case 'nodeOnline':
        this.tree.setStatus(command.node, 'running')
        return this.note(`node online: ${command.node}`)
      case 'nodeExited':
        return this.selfDeath(
          command.node,
          (command.code ?? 0) === 0 ? 'done' : 'failed',
          `exited(code=${command.code ?? 'nil'})`,
        )
      case 'nodeFailed':
        return this.selfDeath(command.node, 'failed', `failed(${command.reason})`)
      case 'requestStruct':
        return this.applyStructNow(command.request, command.from, command.replyID)
      case 'rollup':
        return this.applyRollup(command.from, command.summary)
      case 'message':
        return this.routeMessage(command.from, command.to, command.text, command.replyID)
      case 'permRequested':
        return this.permRequested(command.from, command.info)
      case 'resolveNotice':
        return this.resolveNotice(command.from, command.match, command.via)
      case 'clearNotices':
        return this.clearNotices(command.node)
      case 'turnStarted':
        return this.turnStarted(command.node)
      case 'turnEnded':
        return this.turnEnded(command.node, command.gen)
      case 'restoreSkeleton':
        return this.restoreSkeleton(command.tree)
      case 'resumeNode':
        return this.resumeNode(command.node, command.sessionID)
      case 'spawnStalled':
        return this.spawnStalled(command.node)
      case 'spawnRecovered':
        return this.spawnRecovered(command.node)
      case 'injectQueued':
        return this.injectQueued(command.node, command.pending, command.epoch)
      case 'injectSettled':
        return this.injectSettled(command.node, command.epoch)
      case 'turnErrored':
        return this.turnErrored(command.node)
    }
  }

  // MARK: attention-state derivation
  // A node can carry several attention signals at once. Every writer routes through
  // this one deriver, so the resulting status is a pure priority function:
  // terminal > permission card > stalled > errored > queued > resting.

  private attentionStatus(id: NodeID): NodeStatus {
    const n = this.tree.get(id)
    if (!n) return 'idle'
    if (isTerminal(n.status)) return n.status
    if (this.notices.some((x) => x.nodeID === id && x.kind !== 'inject-queued')) return 'waiting'
    if (this.stalledSpawns.has(id)) return 'stalled'
    if (this.erroredNodes.has(id)) return 'errored'
    if (this.notices.some((x) => x.nodeID === id && x.kind === 'inject-queued')) return 'queued'
    return this.restingStatus(id)
  }

  // MARK: stall / queue / API-error signals

  private spawnStalled(id: NodeID): void {
    const n = this.tree.get(id)
    if (!n || isTerminal(n.status)) return
    this.stalledSpawns.add(id)
    this.tree.setStatus(id, this.attentionStatus(id))
    this.note(`spawn stalled [${id}]: no agent_connected — the cell may never have spawned`)
  }

  private spawnRecovered(id: NodeID): void {
    if (!this.stalledSpawns.delete(id)) return
    const n = this.tree.get(id)
    if (!n || isTerminal(n.status)) return
    this.tree.setStatus(id, this.attentionStatus(id))
    this.note(`spawn recovered [${id}]: agent connected`)
  }

  private turnErrored(id: NodeID): void {
    const n = this.tree.get(id)
    if (!n || isTerminal(n.status)) return
    this.erroredNodes.add(id)
    this.tree.setStatus(id, this.attentionStatus(id))
    this.note(`turn errored [${id}]: API error cut the turn short, no Stop hook`)
  }

  private staleInjectSignal(id: NodeID, epoch: number): boolean {
    const last = this.injectSignalEpoch.get(id)
    if (last !== undefined && epoch <= last) return true
    this.injectSignalEpoch.set(id, epoch)
    return false
  }

  private injectQueued(id: NodeID, pending: number, epoch: number): void {
    const n = this.tree.get(id)
    if (!n || isTerminal(n.status)) {
      this.note(`inject queued dropped: no live node ${id}`)
      return
    }
    if (this.staleInjectSignal(id, epoch)) {
      this.note(`inject queued dropped: stale epoch ${epoch} for ${id}`)
      return
    }
    const text = `${pending} message(s) queued — waiting for the input line to free up`
    const i = this.notices.findIndex((x) => x.nodeID === id && x.kind === 'inject-queued')
    if (i >= 0) {
      const old = this.notices[i]
      this.notices[i] = { ...old, text }
    } else {
      this.seq += 1
      this.notices.push(this.makeNotice(id, 'inject-queued', text))
    }
    this.tree.setStatus(id, this.attentionStatus(id))
    this.note(`inject queued [${id}] pending=${pending} epoch=${epoch}`)
  }

  private injectSettled(id: NodeID, epoch: number): void {
    if (this.staleInjectSignal(id, epoch)) {
      this.note(`inject settled dropped: stale epoch ${epoch} for ${id}`)
      return
    }
    const had = this.notices.some((x) => x.nodeID === id && x.kind === 'inject-queued')
    this.notices = this.notices.filter((x) => !(x.nodeID === id && x.kind === 'inject-queued'))
    if (!had) return
    this.settle(id)
    this.note(`inject settled [${id}] epoch=${epoch}`)
  }

  // MARK: tree afterlife

  private restoreSkeleton(archived: Tree): void {
    let grafted = 0
    for (const id of archived.subtree(archived.rootID)) {
      const m = /^n(\d+)$/.exec(id)
      if (m) this.nodeSeq = Math.max(this.nodeSeq, Number(m[1]))
      if (id === archived.rootID || this.tree.get(id)) continue
      const src = archived.get(id)
      if (!src) continue
      const n: Node = { ...src, parent: null, children: [] }
      const parentCandidates = [src.parent, this.tree.rootID].filter(
        (p): p is NodeID => p !== null && p !== undefined,
      )
      let ok = false
      for (const parent of parentCandidates) {
        try {
          this.tree.spawn(parent, n)
          ok = true
          break
        } catch {
          // degraded parent (a leaf in the replay) falls back to root
        }
      }
      if (ok) grafted += 1
    }
    this.note(`restored skeleton: ${grafted} node(s) from previous incarnation`)
  }

  private resumeNode(id: NodeID, sessionID: string): void {
    const n = this.tree.get(id)
    if (!n) return this.note(`resume: no such node ${id}`)
    if (!isTerminal(n.status)) return this.note(`resume ignored: ${id} not terminal (${n.status})`)
    this.tree.relaunch(id, 'starting', this.now())
    this.injectSignalEpoch.delete(id)
    this.perform({ type: 'resumeCell', node: this.tree.get(id) as Node, sessionID })
    this.note(`resume ${id}: cell relaunching with --resume`)
  }

  // MARK: turn lifecycle

  get openTurnRunningNodes(): Array<{ node: NodeID; gen: number }> {
    const out: Array<{ node: NodeID; gen: number }> = []
    for (const [id, gen] of this.openTurns) {
      if (this.tree.get(id)?.status === 'running') out.push({ node: id, gen })
    }
    return out
  }

  private turnStarted(id: NodeID): void {
    const n = this.tree.get(id)
    if (!n || isTerminal(n.status)) return
    this.turnCounter += 1
    this.openTurns.set(id, this.turnCounter)
    this.erroredNodes.delete(id)
    this.tree.setStatus(id, 'running')
  }

  private turnEnded(id: NodeID, gen: number | null): void {
    if (gen !== null && this.openTurns.get(id) !== gen) return
    this.openTurns.delete(id)
    const n = this.tree.get(id)
    if (!n || isTerminal(n.status)) return
    this.tree.setStatus(id, this.attentionStatus(id))
    this.note(`turn ended [${id}] -> ${this.tree.get(id)?.status}`)
  }

  private restingStatus(id: NodeID): NodeStatus {
    return this.openTurns.has(id) ? 'running' : 'idle'
  }

  // MARK: struct apply (immediate)

  private applyStructNow(request: StructRequest, from: NodeID, replyID: string): void {
    try {
      const result = this.applyStruct(request, from)
      this.deliverOnce(replyID, { type: 'structResult', result })
    } catch (e) {
      if (e instanceof TreeError && e.code === 'notInSubtree') {
        const target = request.type === 'kill' ? request.node : ''
        this.deliverOnce(replyID, {
          type: 'structResult',
          result: { type: 'denied', reason: `node ${target} not in your subtree` },
        })
        this.note(`kill DENIED [${from}]: ${target} not in ${from}'s subtree`)
      } else {
        this.deliverOnce(replyID, {
          type: 'structResult',
          result: { type: 'failed', reason: String(e) },
        })
        this.note(`struct apply FAILED [${from}]: ${String(e)}`)
      }
    }
  }

  private applyStruct(request: StructRequest, from: NodeID): StructResult {
    if (request.type === 'spawn') {
      this.nodeSeq += 1
      const label = (request.name ?? '').trim()
      const child = makeNode({
        id: `n${this.nodeSeq}`,
        role: request.role,
        status: 'starting',
        title: label.length > 0 ? label : request.task,
        model: request.model,
        startedAt: this.now(),
      })
      this.tree.spawn(request.parent, child)
      this.perform({ type: 'spawnCell', node: this.tree.get(child.id) as Node, task: request.task })
      this.note(`spawned ${child.id} (${request.role}) under ${request.parent}`)
      return { type: 'spawned', node: child.id }
    }
    const reaped = this.tree.kill(request.node, from)
    const sealed = this.tree.subtree(request.node)
    for (const n of sealed) this.tree.setEnded(n, this.now())
    this.cascadeTeardown(sealed)
    this.perform({ type: 'killCells', nodes: reaped })
    this.note(`killed ${request.node}: sealed ${sealed.join(',')}; reaped ${reaped.join(',')}`)
    return { type: 'killed', nodes: sealed }
  }

  // MARK: node self-death

  private selfDeath(id: NodeID, status: NodeStatus, why: string): void {
    const node = this.tree.get(id)
    if (!node) return this.note(`self-death: no such node ${id}`)
    if (isTerminal(node.status)) {
      return this.note(`self-death ignored: ${id} already terminal (${node.status}) [${why}]`)
    }
    const sealed = this.tree.subtree(id)
    this.cascadeTeardown(sealed)
    this.tree.setStatus(id, status)
    const reaped = this.tree.sealSubtree(id)
    for (const n of sealed) this.tree.setEnded(n, this.now())
    if (reaped.length > 0) this.perform({ type: 'killCells', nodes: reaped })
    this.note(
      `self-death ${id} -> ${status} [${why}]; sealed ${sealed.join(',')}; reaped ${reaped.join(',')}`,
    )
  }

  private cascadeTeardown(ids: NodeID[]): void {
    const set = new Set(ids)
    for (const id of set) {
      this.openTurns.delete(id)
      this.stalledSpawns.delete(id)
      this.erroredNodes.delete(id)
      this.injectSignalEpoch.delete(id)
    }
    const dropped = this.notices.filter((x) => set.has(x.nodeID))
    this.notices = this.notices.filter((x) => !set.has(x.nodeID))
    this.logResolved(dropped, 'node-death')
  }

  // MARK: notices

  private makeNotice(
    nodeID: NodeID,
    kind: NoticeKind,
    text: string,
    extra: Partial<AgentNotice> = {},
  ): AgentNotice {
    const now = this.now()
    noticeSeq += 1
    return {
      id: `${now}-${noticeSeq}`,
      seq: this.seq,
      nodeID,
      kind,
      text,
      promptID: null,
      toolName: null,
      toolInput: null,
      inputSummary: null,
      arrivedAt: now,
      displayAfter: kind === 'permission' ? now + permissionGraceMs : now,
      ...extra,
    }
  }

  private permRequested(from: NodeID, info: PermNoticeInfo): void {
    if (!this.tree.get(from)) return this.note(`perm notice: no such node ${from}`)
    this.seq += 1
    const notice = this.makeNotice(from, 'permission', info.text, {
      promptID: info.promptID ?? null,
      toolName: info.toolName ?? null,
      toolInput: info.toolInput ?? null,
      inputSummary: info.inputSummary ?? null,
    })
    this.notices.push(notice)
    this.perform({
      type: 'permLog',
      entry: {
        event: 'perm_request',
        nodeID: from,
        kind: 'permission',
        promptID: info.promptID ?? null,
        toolName: info.toolName ?? null,
        via: null,
      },
    })
    this.tree.setStatus(from, this.attentionStatus(from))
    this.note(`perm notice [${from}] ${info.toolName ?? '?'} prompt=${info.promptID ?? '-'}`)
  }

  private resolveNotice(from: NodeID, match: PermResolveMatch | null, via: NoticeResolvedVia): void {
    const candidates = this.notices.filter(
      (n) =>
        n.nodeID === from &&
        n.kind !== 'inject-queued' &&
        (match === null ||
          (n.promptID === (match.promptID ?? null) &&
            n.toolName === (match.toolName ?? null) &&
            n.toolInput === (match.toolInput ?? null))),
    )
    if (candidates.length === 0) return
    const hit = match !== null ? [candidates.reduce((a, b) => (a.seq <= b.seq ? a : b))] : candidates
    const ids = new Set(hit.map((n) => n.id))
    this.notices = this.notices.filter((n) => !ids.has(n.id))
    this.logResolved(hit, via, match?.toolUseID ?? null)
    this.settle(from)
    this.note(`perm resolved [${from}] via ${via} ×${hit.length}`)
  }

  private clearNotices(id: NodeID): void {
    const dropped = this.notices.filter((n) => n.nodeID === id)
    this.notices = this.notices.filter((n) => n.nodeID !== id)
    this.logResolved(dropped, 'prompt')
    this.erroredNodes.delete(id)
    const n = this.tree.get(id)
    if (n && (n.status === 'waiting' || n.status === 'queued' || n.status === 'errored')) {
      this.tree.setStatus(id, this.attentionStatus(id))
    }
  }

  private settle(id: NodeID): void {
    const n = this.tree.get(id)
    if (!n || isTerminal(n.status)) return
    this.tree.setStatus(id, this.attentionStatus(id))
  }

  private logResolved(
    dropped: AgentNotice[],
    via: NoticeResolvedVia,
    toolUseID: string | null = null,
  ): void {
    for (const n of dropped) {
      if (n.kind === 'inject-queued') continue
      this.perform({
        type: 'permLog',
        entry: {
          event: 'perm_resolve',
          nodeID: n.nodeID,
          kind: n.kind,
          promptID: n.promptID ?? null,
          toolName: n.toolName ?? null,
          toolUseID,
          via,
        },
      })
    }
  }

  // MARK: routing / rollup

  private applyRollup(from: NodeID, summary: string): void {
    if (!this.tree.get(from)) return this.note(`rollup: no such node ${from}`)
    this.tree.setRollup(from, summary)
    const parent = this.tree.get(from)?.parent ?? null
    if (parent !== null) {
      this.perform({
        type: 'route',
        to: parent,
        text: `CHILD_ROLLUP:${summary}`,
        viaPath: this.tree.path(from, parent),
        replyID: null,
      })
    }
    this.note(`rollup [${from}] ${summary}`)
  }

  private routeMessage(from: NodeID, to: NodeID, text: string, replyID: string | null): void {
    const fail = (reason: string, ackNote: string) => {
      this.note(`route FAILED: ${reason} ${from}->${to}`)
      this.perform({ type: 'routeFailed', from, to, reason })
      if (replyID !== null) {
        this.deliverOnce(replyID, { type: 'sendAck', delivered: false, note: ackNote })
      }
    }
    const target = this.tree.get(to)
    if (!target) {
      return fail(
        'no such node',
        `node ${to} not reachable: no such node in the tree (killed or never existed)`,
      )
    }
    if (isTerminal(target.status)) {
      return fail(
        `node terminal (${target.status})`,
        `node ${to} not reachable: node is ${target.status}, no live cell`,
      )
    }
    const p = this.tree.path(from, to)
    if (p.length === 0) {
      return fail('no path', `node ${to} not reachable: no route from ${from}`)
    }
    this.perform({ type: 'route', to, text, viaPath: p, replyID })
    this.note(`route ${from}->${to} via ${p.join('->')}`)
  }

  // MARK: util

  private deliverOnce(replyID: string, resolution: Resolution): void {
    if (this.deliveredReplies.has(replyID)) return
    this.deliveredReplies.add(replyID)
    this.perform({ type: 'deliver', replyID, resolution })
  }

  note(s: string): void {
    this.log.push(s)
    if (this.log.length > 500) this.log.splice(0, this.log.length - 500)
    this.onChange?.()
  }
}
