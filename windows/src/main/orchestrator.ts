// Vigil for Windows — the per-session orchestrator.
//
// Port of app/Sources/VigilRuntime/Orchestrator.swift: owns the SessionStore, both
// named-pipe gateways, the cell registry, the harnesses, and the per-session work dirs.
// It is the store's `perform` target — Effects flow out here into real ConPTY cells,
// routed injections and the forensic jsonl. State still only enters via Command.

import fs from 'node:fs'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import {
  type AgentCLIKind,
  type Command,
  type Effect,
  type Node,
  type NodeID,
  type Role,
  isTerminal,
  makeNode,
} from '../core/domain.js'
import {
  AgentRegistry,
  configDir,
  loadRuntime,
  type RuntimeTuning,
} from '../core/config.js'
import { SessionStore } from '../core/store.js'
import { resolveAgent } from './harness/resolve.js'
import type { Harness, HarnessOptions, LaunchSpec } from './harness/types.js'
import { ClaudeHarness } from './harness/claude.js'
import { CodexHarness } from './harness/codex.js'
import { OpenCodeHarness } from './harness/opencode.js'
import { RealCell, type InjectAck } from './cell.js'
import { MCPToolServer, PendingReplies } from './mcp-server.js'
import { HookGateway } from './hook-gateway.js'
import { PipeListener, type LineChannel } from './transport.js'
import { pipeNames, shimPath, resolveNodeRuntime, nodeRuntimeEnv } from './paths.js'
import { renderClaudeTranscript } from './archive.js'
import { apiErrorSnippet, fileLength, pendingBackgroundAgents, readSince, stripPaste } from './transcript-scan.js'
import { captureCodexRollout, firstUserMessageTitle } from './codex-rollout.js'

export interface OrchestratorHooks {
  onStateChanged: () => void
  onCellData: (node: NodeID, data: string) => void
  onCellExit: (node: NodeID) => void
  onSessionRename?: (name: string) => void
  onAutoName?: (name: string) => void
}

export interface OrchestratorConfig {
  sessionId: string
  sessionDir: string
  rootCwd: string | null
  rootRole?: Role
  agentKey: string | null
  agentKind: AgentCLIKind
  permissionMode: HarnessOptions['permissionMode']
  model: string | null
  userConfigDir: string | null
  resumeRootSessionId: string | null
  /** Absolute binaries the prober found — the fallback when agents.json is absent. */
  agentBins?: Partial<Record<AgentCLIKind, string>>
}

const REPORT_WATCHDOG_TEXT =
  'Vigil report watchdog: this turn ended without a report(...) call. Text printed in ' +
  'this terminal stays local to this cell — your parent is still waiting. If the work ' +
  'is finished or blocked, send a short summary up now via the report tool.'

export class Orchestrator {
  readonly store: SessionStore
  readonly sessionId: string
  readonly sessionDir: string
  readonly createdAt = Date.now()

  private readonly cfg: OrchestratorConfig
  private readonly hooks: OrchestratorHooks
  private readonly pending = new PendingReplies()
  private readonly cells = new Map<NodeID, RealCell>()
  private readonly harnesses = new Map<AgentCLIKind, Harness>()
  private hookListener: PipeListener | null = null
  private mcpListener: PipeListener | null = null
  private readonly hookPipe: string
  private readonly mcpPipe: string
  private readonly configRoot: string
  private readonly workRoot: string
  private readonly rootCwd: string | null
  private readonly runtime: RuntimeTuning

  transcripts = new Map<NodeID, string>()
  frozenScreens = new Map<NodeID, string>()
  sessionIds = new Map<NodeID, string>()
  nodeKinds = new Map<NodeID, AgentCLIKind>()
  sessionName: string | null = null

  private spawnWatchdogs = new Map<NodeID, NodeJS.Timeout>()
  private stalledSpawns = new Set<NodeID>()
  private watchdogDelivered = new Set<NodeID>()
  private watchdogReminderOutstanding = new Set<NodeID>()
  private pendingWatchdogChecks = new Map<NodeID, NodeJS.Timeout>()
  private reportedSinceTurnStart = new Set<NodeID>()
  private apiScanOffset = new Map<NodeID, number>()
  private deliveryPending: Array<{
    target: NodeID
    caller: NodeID
    text: string
    attempts: number
    baseline: number
    lastAttemptAt: number
  }> = []
  private deliveryTimer: NodeJS.Timeout | null = null
  private trustTimer: NodeJS.Timeout | null = null
  private trustHandled = new Set<NodeID>()
  private killedBy = new Map<NodeID, NodeID>()
  private stopped = false
  private stopping = false

  constructor(cfg: OrchestratorConfig, hooks: OrchestratorHooks) {
    this.cfg = cfg
    this.hooks = hooks
    this.sessionId = cfg.sessionId
    this.sessionDir = cfg.sessionDir
    this.rootCwd = cfg.rootCwd
    this.runtime = loadRuntime(configDir())
    const token = randomUUID().slice(0, 8)
    const pipes = pipeNames(token)
    this.hookPipe = pipes.hook
    this.mcpPipe = pipes.mcp
    this.configRoot = path.join(cfg.sessionDir, 'config')
    this.workRoot = path.join(cfg.sessionDir, 'work')

    const root = makeNode({
      id: 'n0',
      role: cfg.rootRole ?? 'manager',
      status: 'starting',
      title: 'root',
      model: cfg.model,
      startedAt: Date.now(),
    })
    this.store = new SessionStore(root, (eff) => this.perform(eff), {
      onChange: () => this.hooks.onStateChanged(),
    })
    this.buildHarnesses()
  }

  private buildHarnesses(): void {
    const rt = resolveNodeRuntime()
    const env = {
      nodeBin: rt.bin,
      // A shell resolves bare `node` through the cell's PATH; a quoted absolute path
      // breaks cmd.exe's hook runner. Only an Electron-as-Node runtime needs the path.
      nodeCommand: rt.electron ? rt.bin : rt.onPath ? 'node' : rt.bin,
      hookScript: shimPath('vigil-hook.js'),
      nodeEnv: nodeRuntimeEnv(rt),
    }
    const make = (bin: string, kind: AgentCLIKind): Harness => {
      const opts: HarnessOptions = {
        bin,
        env,
        configRoot: this.configRoot,
        permissionMode: this.cfg.permissionMode,
        model: this.cfg.model,
        userConfigDir: this.cfg.userConfigDir,
        agentKey: this.cfg.agentKey,
      }
      if (kind === 'codex') return new CodexHarness(opts)
      if (kind === 'opencode') return new OpenCodeHarness(opts)
      return new ClaudeHarness(opts)
    }
    const registry = this.cfg.userConfigDir ? AgentRegistry.load(this.cfg.userConfigDir) : null
    for (const kind of ['claude', 'codex', 'opencode'] as AgentCLIKind[]) {
      const entry = registry ? registry.entries.find((e) => e.kind === kind) : undefined
      const bin =
        entry?.bin ??
        this.cfg.agentBins?.[kind] ??
        ({ claude: 'claude', codex: 'codex', opencode: 'opencode' } as Record<string, string>)[kind]
      this.harnesses.set(kind, make(bin, kind))
    }
  }

  // MARK: lifecycle

  async start(rootTask: string): Promise<void> {
    fs.mkdirSync(this.sessionDir, { recursive: true })
    for (const d of [this.configRoot, this.workRoot]) fs.mkdirSync(d, { recursive: true })

    const gateway = new HookGateway({
      emit: (cmd) => this.receive(cmd),
      onPrompt: (node, payload) => {
        this.recordAgentPrompt(node, payload)
        this.armWatchdogFromPrompt(node, payload)
        this.maybeAutoName(node)
        // claude writes ai-title DURING the turn; a short retry catches a first turn whose
        // title was not on disk yet when the hook fired.
        this.laterAutoName(node, 2500)
      },
      onStop: (node) => {
        this.maybeAutoName(node)
        this.laterAutoName(node, 2500)
        this.captureOpenCodeSession(node)
      },
    })
    const mcp = new MCPToolServer({
      emit: (cmd) => this.receive(cmd),
      pending: this.pending,
      onConnect: (node) => {
        this.orchLog('agent_connected', { node })
        this.noteAgentConnected(node)
      },
      onRename: (node, name) => {
        this.sessionName = name
        this.hooks.onSessionRename?.(name)
      },
      nodeInfo: (node) => {
        const n = this.store.tree.get(node)
        if (!n) return null
        return {
          role: n.role,
          isRoot: node === this.store.tree.rootID,
          kind: this.nodeKinds.get(node) ?? 'claude',
        }
      },
      spawnModelGuard: (role, model) => {
        const kind = this.resolveKind(role, false, this.currentCwd())
        return this.harnesses.get(kind)?.spawnModelGuardError(model, role, this.currentCwd()) ?? null
      },
    })

    this.hookListener = new PipeListener(this.hookPipe)
    await this.hookListener.start((ch: LineChannel) => void gateway.handle(ch))
    this.mcpListener = new PipeListener(this.mcpPipe)
    await this.mcpListener.start((ch: LineChannel) => void mcp.handle(ch))

    if (this.cfg.resumeRootSessionId) {
      this.sessionIds.set(this.store.tree.rootID, this.cfg.resumeRootSessionId)
    }
    this.launchCell(this.store.tree.root, rootTask, false, this.cfg.resumeRootSessionId)
    if (this.cfg.resumeRootSessionId) {
      this.store.send({ type: 'turnEnded', node: this.store.tree.rootID, gen: null })
    }
    this.deliveryTimer = setInterval(() => this.deliveryTick(), 1000)
    // Best-effort directory-trust watcher (port of AppModel.startTrustWatcher): a fresh
    // cwd may pop claude's "Do you trust the files in this folder?" box, which would hold
    // the first prompt forever. ~2 minutes of watching, answered in the CLI's own UI.
    let trustTicks = 0
    this.trustTimer = setInterval(() => {
      trustTicks += 1
      if (trustTicks > 120) {
        if (this.trustTimer) clearInterval(this.trustTimer)
        this.trustTimer = null
        return
      }
      for (const [id, cell] of this.cells) {
        if (this.trustHandled.has(id)) continue
        const s = cell.snapshot().toLowerCase()
        if (
          s.includes('quick safety check') ||
          s.includes('is this project you created') ||
          s.includes('yes, i trust this folder')
        ) {
          // claude 2.1.32x: option 1 is "No, exit" and option 2 is "Yes, I trust this
          // folder" — move down once, then confirm. Sending "1" here would quit claude.
          cell.writeUser('\x1b[B\r')
          this.trustHandled.add(id)
        } else if (s.includes('trust the files') || s.includes('do you trust')) {
          // older wording: option 1 is Yes
          cell.writeUser('1\r')
          this.trustHandled.add(id)
        }
      }
    }, 1000)
  }

  stop(): void {
    if (this.stopped) return
    this.stopped = true
    this.stopping = true
    for (const t of this.spawnWatchdogs.values()) clearTimeout(t)
    this.spawnWatchdogs.clear()
    for (const t of this.pendingWatchdogChecks.values()) clearTimeout(t)
    this.pendingWatchdogChecks.clear()
    if (this.deliveryTimer) clearInterval(this.deliveryTimer)
    if (this.trustTimer) clearInterval(this.trustTimer)
    this.hookListener?.stop()
    this.mcpListener?.stop()
    for (const cell of this.cells.values()) cell.terminate()
    this.cells.clear()
  }

  // MARK: public view for the UI

  get rootID(): NodeID {
    return this.store.tree.rootID
  }

  cell(node: NodeID): RealCell | undefined {
    return this.cells.get(node)
  }

  writeInput(node: NodeID, data: string): void {
    this.cells.get(node)?.writeUser(data)
  }

  resize(node: NodeID, cols: number, rows: number): void {
    this.cells.get(node)?.resize(cols, rows)
  }

  replayFor(node: NodeID): string {
    return this.cells.get(node)?.replayData() ?? ''
  }

  snapshotFor(node: NodeID): string {
    return this.cells.get(node)?.snapshot() ?? this.frozenScreens.get(node) ?? ''
  }

  probeDump(node: NodeID): unknown {
    return this.cells.get(node)?.probeDump() ?? null
  }

  resumeNode(node: NodeID): boolean {
    const sid = this.sessionIds.get(node)
    if (!sid) return false
    this.store.send({ type: 'resumeNode', node, sessionID: sid })
    return true
  }

  transcriptText(node: NodeID): string | null {
    const p = this.transcripts.get(node)
    if (!p) return null
    return renderClaudeTranscript(p)
  }

  private cwdFor(node: NodeID): string {
    return this.rootCwd ?? path.join(this.workRoot, node)
  }

  publicState() {
    const nodes: Node[] = [...this.store.tree.nodes.values()].map((n) => ({ ...n, children: [...n.children] }))
    return {
      id: this.sessionId,
      createdAt: this.createdAt,
      rootID: this.rootID,
      name: this.sessionName,
      cwdByNode: Object.fromEntries(nodes.map((n) => [n.id, this.cwdFor(n.id)])),
      nodes,
      notices: this.store.notices,
      log: this.store.log.slice(-120),
      transcripts: Object.fromEntries(this.transcripts),
      sessionIds: Object.fromEntries(this.sessionIds),
      nodeKinds: Object.fromEntries(this.nodeKinds),
      hasLiveCells: [...this.cells.keys()],
    }
  }

  // MARK: harness dispatch

  private currentCwd(): string {
    return this.rootCwd ?? this.workRoot
  }

  private resolveKind(role: Role, isRoot: boolean, cwd: string): AgentCLIKind {
    const resolved = resolveAgent({
      userConfigDir: this.cfg.userConfigDir,
      fallbackBin: 'claude',
      cwd,
      role,
      isRoot,
      sessionKey: this.cfg.agentKey,
      kind: null,
    })
    return resolved.entry?.kind ?? (isRoot ? this.cfg.agentKind : resolved.sessionKind ?? this.cfg.agentKind)
  }

  private harnessFor(kind: AgentCLIKind): Harness {
    return this.harnesses.get(kind) ?? this.harnesses.get('claude')!
  }

  // MARK: Command ingress interception

  private receive(cmd: Command): void {
    this.store.send(cmd)
    switch (cmd.type) {
      case 'turnEnded': {
        const baseline = this.apiScanOffset.get(cmd.node) ?? 0
        this.checkTurnError(cmd.node)
        this.captureCodexSession(cmd.node)
        this.checkReportWatchdog(cmd.node, baseline)
        break
      }
      case 'turnStarted':
        this.reportedSinceTurnStart.delete(cmd.node)
        {
          const t = this.pendingWatchdogChecks.get(cmd.node)
          if (t) clearTimeout(t)
          this.pendingWatchdogChecks.delete(cmd.node)
        }
        break
      case 'rollup':
        this.reportedSinceTurnStart.add(cmd.from)
        this.watchdogReminderOutstanding.delete(cmd.from)
        this.watchdogDelivered.delete(cmd.from)
        break
      case 'requestStruct':
        if (cmd.request.type === 'kill' && isTerminal(this.store.tree.get(cmd.request.node)?.status ?? 'idle')) {
          for (const n of this.store.tree.subtree(cmd.request.node)) this.killedBy.set(n, cmd.from)
        }
        break
      default:
        break
    }
  }

  // MARK: Effect sink

  private perform(effect: Effect): void {
    switch (effect.type) {
      case 'spawnCell':
        this.launchCell(effect.node, effect.task, true, null)
        break
      case 'resumeCell': {
        const old = this.cells.get(effect.node.id)
        if (old) {
          old.terminate()
          this.cells.delete(effect.node.id)
        }
        this.launchCell(effect.node, '', true, effect.sessionID)
        this.store.send({ type: 'turnEnded', node: effect.node.id, gen: null })
        break
      }
      case 'killCells':
        for (const id of effect.nodes) {
          this.orchLog('kill', { node: id })
          this.cancelSpawnWatchdog(id)
          const cell = this.cells.get(id)
          if (cell) {
            const screen = cell.snapshot()
            if (screen.trim() !== '') this.frozenScreens.set(id, screen)
            cell.terminate()
            this.cells.delete(id)
          }
        }
        break
      case 'route':
        this.handleRoute(effect)
        break
      case 'routeFailed':
        this.orchLog('route_failed', { from: effect.from, to: effect.to, reason: effect.reason })
        break
      case 'deliver':
        this.pending.deliver(effect.replyID, effect.resolution)
        break
      case 'permLog':
        this.appendPermLog(effect.entry)
        break
    }
  }

  private handleRoute(effect: Extract<Effect, { type: 'route' }>): void {
    const kind = routeKind(effect.text)
    const cap = kind === 'rollup' ? 400 : 80
    const logFields: Record<string, unknown> = { to: effect.to, kind, text: effect.text.slice(0, cap) }
    const caller = effect.viaPath[0] ?? null
    if (caller) logFields.from = caller
    this.orchLog('route', logFields)
    const cell = this.cells.get(effect.to)
    if (!cell) {
      this.failRoute(effect.to, 'no live cell', 'route dropped: no cell', effect.replyID)
      return
    }
    const preBaseline =
      caller && this.transcripts.get(effect.to)
        ? fileLength(this.transcripts.get(effect.to) as string)
        : 0
    void cell
      .inject(effect.text)
      .then((ack: InjectAck) => {
        if (ack.note) {
          this.orchLog('inject_note', { to: effect.to, delivered: ack.delivered, note: ack.note })
        }
        if (!ack.delivered) {
          this.failRoute(effect.to, ack.note ?? 'not delivered', `route inject UNDELIVERED: ${effect.to}`, effect.replyID)
          return
        }
        if (kind === 'message') this.watchdogDelivered.add(effect.to)
        if (effect.replyID && effect.text.startsWith('MESSAGE FROM')) {
          const tracked = this.registerDelivery(effect.to, caller, effect.text, preBaseline)
          const tail = tracked
            ? 'confirming delivery (a SYSTEM receipt will follow on failure)'
            : "this agent's context entry cannot be externally confirmed (no delivery receipt)"
          this.pending.deliver(effect.replyID, {
            type: 'sendAck',
            delivered: true,
            note: `${ack.note ? ack.note + '; ' : ''}injected ${effect.to}, ${tail}`,
          })
        } else if (effect.replyID) {
          this.pending.deliver(effect.replyID, {
            type: 'sendAck',
            delivered: true,
            note: ack.note ?? 'sent',
          })
        }
      })
      .catch((err) => {
        this.failRoute(effect.to, `inject failed: ${String(err)}`, `route inject FAILED: ${effect.to}`, effect.replyID)
      })
  }

  private failRoute(to: NodeID, reason: string, note: string, replyID: string | null): void {
    this.orchLog('route_failed', { to, reason })
    this.store.note(note)
    if (replyID) {
      this.pending.deliver(replyID, {
        type: 'sendAck',
        delivered: false,
        note: `node ${to} not reachable: ${reason}`,
      })
    }
  }

  // MARK: cell lifecycle

  private launchCell(node: Node, task: string, markOnline: boolean, resumeSessionId: string | null): void {
    const cwd = this.rootCwd ?? path.join(this.workRoot, node.id)
    const nodeDir = path.join(this.configRoot, node.id)
    try {
      fs.mkdirSync(cwd, { recursive: true })
      fs.mkdirSync(nodeDir, { recursive: true })
    } catch (e) {
      this.orchLog('cell_launch_aborted', { node: node.id, reason: String(e) })
      this.store.send({ type: 'nodeFailed', node: node.id, reason: 'config/work dir creation failed' })
      return
    }

    const isRoot = node.id === this.store.tree.rootID
    const kind = this.resolveKind(node.role, isRoot, cwd)
    this.nodeKinds.set(node.id, kind)
    const harness = this.harnessFor(kind)
    let launch: LaunchSpec
    try {
      launch = harness.launchSpec({
        task,
        cwd,
        nodeID: node.id,
        role: node.role,
        isRoot,
        model: node.model,
        resumeSessionId,
        mcpEndpoint: this.mcpPipe,
        hookEndpoint: this.hookPipe,
        agentKey: this.cfg.agentKey,
      })
    } catch (e) {
      this.orchLog('cell_launch_aborted', { node: node.id, reason: String(e) })
      this.store.send({ type: 'nodeFailed', node: node.id, reason: `launch spec failed: ${String(e)}` })
      return
    }

    const fields: Record<string, unknown> = {
      node: node.id,
      role: node.role,
      root: isRoot,
      task: task.slice(0, 80),
      kind,
    }
    if (node.title && node.title !== task) fields.title = node.title.slice(0, 80)
    if (node.model) fields.model = node.model
    if (node.parent) fields.parent = node.parent
    if (resumeSessionId) fields.resume = resumeSessionId
    this.orchLog('cell_launch', fields)
    if (!resumeSessionId) this.armSpawnWatchdog(node.id)

    const cell = new RealCell({
      nodeID: node.id,
      launch,
      cwd,
      initialPrompt: launch.initialPrompt,
      cols: 100,
      rows: 32,
      tuning: {
        poll: 500,
        maxQueueWait: this.runtime.injectHoldTimeoutSeconds * 1000,
        initialReadyTimeout: this.runtime.initialPromptReadyTimeoutSeconds * 1000,
      },
      onData: (data) => this.hooks.onCellData(node.id, data),
      onExit: (code) => this.handleExit(node.id, code),
      onInitialPromptAck: (ack) => {
        if (ack.note) this.orchLog('inject_note', { to: node.id, delivered: ack.delivered, note: ack.note })
      },
      onInjectHold: (pending, held, epoch) => {
        this.store.send(
          held
            ? { type: 'injectQueued', node: node.id, pending, epoch }
            : { type: 'injectSettled', node: node.id, epoch },
        )
      },
    })
    this.cells.set(node.id, cell)
    try {
      cell.start()
    } catch (e) {
      // A spawn that cannot even create the process must fail the node honestly, not
      // leave a tree entry that only later reads as "spawn stalled".
      this.orchLog('cell_launch_aborted', { node: node.id, reason: String(e) })
      this.cells.delete(node.id)
      this.cancelSpawnWatchdog(node.id)
      try {
        cell.terminate()
      } catch {
        // ignore
      }
      this.store.send({ type: 'nodeFailed', node: node.id, reason: `spawn failed: ${String(e)}` })
      return
    }
    if (markOnline) this.store.send({ type: 'nodeOnline', node: node.id })
  }

  private handleExit(node: NodeID, code: number | null): void {
    if (this.stopping) {
      // A user-close is not a node failure: drop the cell silently so the archive's
      // replay shows the node as terminated (no exit code), not failed.
      this.cancelSpawnWatchdog(node)
      this.cells.delete(node)
      return
    }
    this.captureCodexSession(node)
    this.captureOpenCodeSession(node)
    this.orchLog('exit', code === null ? { node } : { node, code })
    this.cancelSpawnWatchdog(node)
    const cell = this.cells.get(node)
    if (cell) {
      // Freeze the last frame, then drop the cell: the node is a dead record now, and a
      // lingering cell would make the UI believe it is still live (hiding Resume).
      const screen = cell.snapshot()
      if (screen.trim() !== '') this.frozenScreens.set(node, screen)
      cell.terminate()
      this.cells.delete(node)
    }
    if (code === null) {
      this.store.send({ type: 'nodeFailed', node, reason: 'process ended without an exit code' })
    } else {
      this.store.send({ type: 'nodeExited', node, code })
    }
    this.hooks.onCellExit(node)
  }

  // MARK: spawn watchdog

  private armSpawnWatchdog(node: NodeID): void {
    this.cancelSpawnWatchdog(node)
    const t = setTimeout(() => {
      this.spawnWatchdogs.delete(node)
      const n = this.store.tree.get(node)
      if (!n || isTerminal(n.status)) return
      this.stalledSpawns.add(node)
      this.orchLog('spawn_stalled', { node, window_s: this.runtime.spawnStallSeconds })
      this.store.send({ type: 'spawnStalled', node })
    }, this.runtime.spawnStallSeconds * 1000)
    this.spawnWatchdogs.set(node, t)
  }

  private cancelSpawnWatchdog(node: NodeID): void {
    const t = this.spawnWatchdogs.get(node)
    if (t) clearTimeout(t)
    this.spawnWatchdogs.delete(node)
    this.stalledSpawns.delete(node)
  }

  private noteAgentConnected(node: NodeID): void {
    const t = this.spawnWatchdogs.get(node)
    if (t) clearTimeout(t)
    this.spawnWatchdogs.delete(node)
    if (this.stalledSpawns.delete(node)) {
      this.orchLog('spawn_recovered', { node })
      this.store.send({ type: 'spawnRecovered', node })
    }
    this.captureCodexSession(node)
  }

  // MARK: transcript capture / naming

  private recordAgentPrompt(node: NodeID, payload: Record<string, any>): void {
    const fields: Record<string, unknown> = { node }
    if (typeof payload.transcript_path === 'string') {
      fields.transcript = payload.transcript_path
      this.transcripts.set(node, payload.transcript_path)
    }
    if (typeof payload.session_id === 'string') {
      fields.session_id = payload.session_id
      this.sessionIds.set(node, payload.session_id)
    }
    this.orchLog('agent_prompt', fields)
  }

  private armWatchdogFromPrompt(node: NodeID, payload: Record<string, any>): void {
    const promptText = typeof payload.prompt === 'string' ? payload.prompt : ''
    const isOwn = promptText === REPORT_WATCHDOG_TEXT
    const isSystem = promptText.startsWith('<task-notification>')
    if (!isOwn && !isSystem) this.watchdogDelivered.add(node)
  }

  private laterAutoName(node: NodeID, ms: number): void {
    setTimeout(() => {
      if (!this.stopped) this.maybeAutoName(node)
    }, ms).unref?.()
  }

  private maybeAutoName(node: NodeID): void {
    if (!this.runtime.autoName) return
    const p = this.transcripts.get(node)
    if (!p) return
    // Reading the title is best-effort and off the hot path.
    import('./archive.js')
      .then(({ readClaudeTitle }) => {
        const title = readClaudeTitle(p)
        if (title && title !== this.sessionName) {
          this.sessionName = title
          this.hooks.onAutoName?.(title)
        }
      })
      .catch(() => undefined)
  }

  private captureCodexSession(node: NodeID): void {
    if (this.nodeKinds.get(node) !== 'codex') return
    const home = CodexHarness.codexHome(this.configRoot, node)
    const cap = captureCodexRollout(home)
    if (!cap) return
    if (this.sessionIds.get(node) === cap.sessionId && this.transcripts.get(node) === cap.path) return
    this.transcripts.set(node, cap.path)
    this.sessionIds.set(node, cap.sessionId)
    this.orchLog('agent_prompt', { node, transcript: cap.path, session_id: cap.sessionId })
    this.watchdogDelivered.add(node)
    // codex generates no session title of its own; the first user_message IS the user's
    // prompt (same fallback the original macOS app uses). Never fabricates a title.
    if (this.runtime.autoName) {
      const title = firstUserMessageTitle(cap.path)
      if (title && title !== this.sessionName) {
        this.sessionName = title
        this.hooks.onAutoName?.(title)
      }
    }
  }

  private captureOpenCodeSession(node: NodeID): void {
    // opencode's transcript lives in SQLite; without the `opencode export` binary there is
    // no external snapshot to point at. The sid captured from the hook is still enough for
    // `opencode --session` resume — we degrade honestly instead of writing a hollow pointer.
    if (this.nodeKinds.get(node) !== 'opencode') return
    const sid = this.sessionIds.get(node)
    if (sid) this.orchLog('opencode_capture', { node, session_id: sid, degraded: 'no external transcript' })
  }

  // MARK: API-error turn death

  private checkTurnError(node: NodeID): void {
    const p = this.transcripts.get(node)
    if (!p) return
    const baseline = this.apiScanOffset.get(node) ?? 0
    const content = readSince(p, baseline)
    this.apiScanOffset.set(node, fileLength(p))
    const reason = apiErrorSnippet(content)
    if (!reason) return
    this.orchLog('turn_errored', { node, reason })
    this.store.send({ type: 'turnErrored', node })
    const parent = this.store.tree.get(node)?.parent ?? null
    if (parent && !isTerminal(this.store.tree.get(parent)?.status ?? 'idle')) {
      const text = this.reportedSinceTurnStart.has(node)
        ? `SYSTEM: worker ${node} turn ended with an API error after its report was delivered — the report was received, so a re-run is usually unnecessary.`
        : `SYSTEM: worker ${node} turn ended abnormally with an API error and sent no report — you may need to re-run it.`
      this.store.send({ type: 'message', from: node, to: parent, text, replyID: null })
    }
  }

  // MARK: report watchdog

  private checkReportWatchdog(node: NodeID, baseline: number): void {
    if (!this.runtime.reportWatchdog) return
    if (node === this.store.tree.rootID) return
    if (!this.watchdogDelivered.has(node)) return
    if (this.watchdogReminderOutstanding.has(node)) return
    if (this.reportedSinceTurnStart.has(node)) return
    const n = this.store.tree.get(node)
    if (!n || isTerminal(n.status)) return
    if (!this.cells.has(node)) return
    const prev = this.pendingWatchdogChecks.get(node)
    if (prev) clearTimeout(prev)
    const t = setTimeout(() => this.fireReportWatchdog(node, baseline), 2000)
    this.pendingWatchdogChecks.set(node, t)
  }

  private fireReportWatchdog(node: NodeID, baseline: number): void {
    if (!this.pendingWatchdogChecks.delete(node)) return
    if (!this.runtime.reportWatchdog) return
    if (node === this.store.tree.rootID) return
    if (!this.watchdogDelivered.has(node)) return
    if (this.watchdogReminderOutstanding.has(node)) return
    if (this.reportedSinceTurnStart.has(node)) return
    const n = this.store.tree.get(node)
    if (!n || isTerminal(n.status) || n.status === 'running' || n.status === 'starting') return
    const cell = this.cells.get(node)
    if (!cell) return
    const p = this.transcripts.get(node)
    if (p && pendingBackgroundAgents(readSince(p, baseline)) > 0) {
      this.orchLog('report_watchdog_skipped', { node, reason: 'background_agents_pending' })
      return
    }
    this.watchdogReminderOutstanding.add(node)
    this.orchLog('report_watchdog', { node })
    void cell.inject(REPORT_WATCHDOG_TEXT)
  }

  // MARK: delivery confirmation

  private registerDelivery(target: NodeID, caller: NodeID | null, text: string,
                           baseline: number): boolean {
    if (!caller) return false
    const kind = this.nodeKinds.get(target)
    if (kind === 'opencode' || kind === 'codex') {
      this.orchLog('delivery_unconfirmed', {
        to: target,
        caller,
        reason:
          kind === 'codex'
            ? 'codex rollout=event_msg shape, claude scan misses'
            : 'opencode transcript=SQLite, no external tail-read surface',
        text: text.slice(0, 80),
      })
      return false
    }
    const p = this.transcripts.get(target)
    if (!p) return false
    this.deliveryPending.push({
      target,
      caller,
      text,
      attempts: 0,
      baseline: baseline || fileLength(p),
      lastAttemptAt: Date.now(),
    })
    return true
  }

  private deliveryTick(): void {
    if (this.stopped || this.deliveryPending.length === 0) return
    const now = Date.now()
    const keep: typeof this.deliveryPending = []
    for (const item of this.deliveryPending) {
      const p = this.transcripts.get(item.target)
      const cell = this.cells.get(item.target)
      if (!p || !cell || !cell.isRunning) {
        this.onDeliveryFailed(item, 'target cell gone')
        continue
      }
      const since = readSince(p, item.baseline)
      if (since.includes(stripPaste(item.text)) || since.includes(item.text)) {
        this.orchLog('delivery_confirmed', { to: item.target, text: item.text.slice(0, 80) })
        continue
      }
      const st = this.store.tree.get(item.target)?.status
      const idleEnough = st !== 'running' && st !== 'starting'
      if (!idleEnough || now - item.lastAttemptAt < this.runtime.deliveryReinjectGraceSeconds * 1000) {
        keep.push(item)
        continue
      }
      if (item.attempts >= this.runtime.deliveryMaxAttempts) {
        this.onDeliveryFailed(item, `unconfirmed after ${item.attempts} reinjection(s)`)
        continue
      }
      item.attempts += 1
      item.baseline = fileLength(p)
      item.lastAttemptAt = now
      this.orchLog('delivery_retry', { to: item.target, text: item.text.slice(0, 80) })
      void cell.inject(item.text)
      keep.push(item)
    }
    this.deliveryPending = keep
  }

  private onDeliveryFailed(
    item: { target: NodeID; caller: NodeID; text: string; attempts: number },
    reason: string,
  ): void {
    this.orchLog('delivery_failed', {
      to: item.target,
      caller: item.caller,
      attempts: item.attempts,
      reason,
    })
    this.store.note(`delivery failed ${item.caller}->${item.target}: ${reason}`)
    const caller = this.store.tree.get(item.caller)
    if (!caller || isTerminal(caller.status)) return
    const targetStatus = this.store.tree.get(item.target)?.status
    if (targetStatus && isTerminal(targetStatus)) {
      if (this.killedBy.get(item.target) === item.caller) return
      this.store.send({
        type: 'message',
        from: item.target,
        to: item.caller,
        text: `SYSTEM: your message to ${item.target} was voided — that node has terminated (${targetStatus}); do not resend.`,
        replyID: null,
      })
      return
    }
    this.store.send({
      type: 'message',
      from: item.target,
      to: item.caller,
      text: `SYSTEM: your message to ${item.target} is still unconfirmed after ${item.attempts} reinjection(s); you may need to resend.`,
      replyID: null,
    })
  }

  // MARK: telemetry

  private appendPermLog(entry: {
    event: string
    nodeID: NodeID
    kind: string
    promptID?: string | null
    toolName?: string | null
    toolUseID?: string | null
    via?: string | null
  }): void {
    if (!this.runtime.permDogfoodLog) return
    const obj: Record<string, unknown> = {
      ts: new Date().toISOString(),
      event: entry.event,
      node: entry.nodeID,
      kind: entry.kind,
    }
    if (entry.promptID) obj.prompt_id = entry.promptID
    if (entry.toolName) obj.tool = entry.toolName
    if (entry.toolUseID) obj.tool_use_id = entry.toolUseID
    if (entry.via) obj.via = entry.via
    this.appendJSONL(obj, 'perm_dogfood.jsonl')
  }

  private orchLog(event: string, fields: Record<string, unknown>): void {
    this.appendJSONL({ ts: new Date().toISOString(), event, ...fields }, 'orchestration.jsonl')
  }

  private appendJSONL(obj: Record<string, unknown>, file: string): void {
    try {
      fs.appendFileSync(path.join(this.sessionDir, file), JSON.stringify(obj) + '\n')
    } catch {
      // telemetry never takes the session down
    }
  }
}

function routeKind(text: string): string {
  if (text.startsWith('CHILD_ROLLUP:')) return 'rollup'
  if (text.startsWith('MESSAGE FROM')) return 'message'
  if (text.startsWith('SYSTEM:')) return 'system'
  if (text.startsWith('PERMISSION REVIEW REQUEST')) return 'perm_review'
  return 'other'
}

