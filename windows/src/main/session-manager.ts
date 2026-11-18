// Vigil for Windows — app-level session manager.
//
// Ports the session/launcher/history glue from AppModel.swift: projects, live sessions
// (each with its own Orchestrator), finished-session history, and the WebSocket state
// shape the renderer consumes. Live sessions stay in memory; everything durable lives in
// the session dir (orchestration.jsonl + meta.json).

import fs from 'node:fs'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import type { AgentCLIKind, NodeID, PermissionMode, Role } from '../core/domain.js'
import { makeNode } from '../core/domain.js'
import {
  AgentRegistry,
  agentUsable,
  archiveRoot,
  configDir,
  ensureInstalled,
  loadLauncherAgent,
} from '../core/config.js'
import { Orchestrator } from './orchestrator.js'
import {
  loadSession,
  listSessions,
  newSessionDirName,
  readMeta,
  renderClaudeTranscript,
  resumeKey,
  setArchived,
  writeMeta,
  type ArchivedSession,
  type SessionArchiveMeta,
} from './archive.js'
import { probeCLIs, type DetectedCLI } from './prober.js'

export interface Project {
  id: string
  name: string
  cwd: string | null
}

export interface LiveSession {
  id: string
  dir: string
  name: string
  projectId: string
  projectName: string | null
  projectCwd: string | null
  agentKey: string
  agentKind: AgentCLIKind
  model: string | null
  permissionMode: PermissionMode
  createdAt: number
  nameIsCustom: boolean
  orchestrator: Orchestrator
}

export interface Broadcaster {
  state(): void
  pty(sessionId: string, nodeId: string, data: string): void
  ptyExit(sessionId: string, nodeId: string): void
}

export class SessionManager {
  readonly configDir = configDir()
  readonly archiveRoot = archiveRoot()
  detected: DetectedCLI[] = []
  projects: Project[] = []
  sessions = new Map<string, LiveSession>()
  private broadcaster: Broadcaster | null = null
  private stateTimer: NodeJS.Timeout | null = null
  private metaTimer: NodeJS.Timeout | null = null
  private defaultAgent: string | null = null

  bootstrap(): void {
    fs.mkdirSync(this.configDir, { recursive: true })
    fs.mkdirSync(this.archiveRoot, { recursive: true })
    this.detected = probeCLIs()
    ensureInstalled(this.configDir, this.detected)
    this.projects = this.loadProjects()
    this.defaultAgent = loadLauncherAgent(this.configDir) ?? this.detected[0]?.kind ?? 'claude'
    this.metaTimer = setInterval(() => this.refreshLiveMeta(), 5000)
  }

  attach(b: Broadcaster): void {
    this.broadcaster = b
  }

  // MARK: projects

  private projectsFile(): string {
    return path.join(this.configDir, 'projects.json')
  }

  private loadProjects(): Project[] {
    try {
      const raw = JSON.parse(fs.readFileSync(this.projectsFile(), 'utf8'))
      if (Array.isArray(raw.projects)) {
        return raw.projects
          .filter((p: any) => p && typeof p.cwd === 'string' && typeof p.name === 'string')
          .map((p: any) => ({ id: p.id ?? randomUUID(), name: p.name, cwd: p.cwd }))
      }
    } catch {
      // no projects yet
    }
    return []
  }

  private saveProjects(): void {
    fs.writeFileSync(
      this.projectsFile(),
      JSON.stringify({ projects: this.projects }, null, 2) + '\n',
    )
  }

  addProject(cwd: string): { project?: Project; error?: string } {
    const abs = path.resolve(cwd)
    let st: fs.Stats
    try {
      st = fs.statSync(abs)
    } catch {
      return { error: `no such directory: ${abs}` }
    }
    if (!st.isDirectory()) return { error: `not a directory: ${abs}` }
    const existing = this.projects.find((p) => path.resolve(p.cwd ?? '') === abs)
    if (existing) return { project: existing }
    const project: Project = { id: randomUUID(), name: path.basename(abs) || abs, cwd: abs }
    this.projects.push(project)
    this.saveProjects()
    this.scheduleState()
    return { project }
  }

  removeProject(id: string): void {
    this.projects = this.projects.filter((p) => p.id !== id)
    this.saveProjects()
    this.scheduleState()
  }

  // MARK: registry / agents

  registry(): AgentRegistry {
    const reg = AgentRegistry.load(this.configDir)
    if (reg) return reg
    const fallback = this.detected.find((d) => d.kind === 'claude')?.bin ?? 'claude'
    return AgentRegistry.builtinFallback(fallback)
  }

  availableAgents(): Array<{ key: string; kind: AgentCLIKind; bin: string; usable: boolean; detected: boolean }> {
    const detectedKinds = new Set(this.detected.map((d) => d.kind))
    return this.registry().entries.map((e) => ({
      key: e.key,
      kind: e.kind,
      bin: e.bin,
      usable: agentUsable(e.kind),
      detected: detectedKinds.has(e.kind),
    }))
  }

  // MARK: sessions

  async newSession(input: {
    projectId?: string | null
    agentKey?: string | null
    task: string
    model?: string | null
    permissionMode?: PermissionMode
  }): Promise<{ session?: LiveSession; error?: string }> {
    const project = input.projectId ? this.projects.find((p) => p.id === input.projectId) ?? null : null
    const agentKey = input.agentKey ?? this.defaultAgent ?? 'claude'
    const entry = this.registry().get(agentKey)
    const kind: AgentCLIKind = entry?.kind ?? 'claude'
    if (!agentUsable(kind)) return { error: `agent "${agentKey}" is not a supported CLI` }
    const detectedKind = this.detected.some((d) => d.kind === kind)
    if (!detectedKind) return { error: `agent "${kind}" was not found on this machine` }

    const id = newSessionDirName()
    const dir = path.join(this.archiveRoot, id)
    fs.mkdirSync(dir, { recursive: true })
    const createdAt = new Date()
    const meta: SessionArchiveMeta = {
      id,
      name: project ? `${project.name}` : 'New session',
      projectName: project?.name ?? null,
      projectCwd: project?.cwd ?? null,
      agent: kind,
      model: input.model ?? null,
      createdAt: createdAt.toISOString(),
      rootSessionId: null,
      archived: null,
      nameIsCustom: null,
    }
    writeMeta(meta, dir)

    const session = this.createOrchestratorSession({
      id,
      dir,
      name: meta.name,
      projectId: project?.id ?? 'chats',
      projectName: project?.name ?? null,
      projectCwd: project?.cwd ?? null,
      agentKey,
      agentKind: kind,
      model: input.model ?? null,
      permissionMode: input.permissionMode ?? 'bypassPermissions',
      createdAt: createdAt.getTime(),
      nameIsCustom: false,
      resumeRootSessionId: null,
      rootRole: 'manager',
    })
    await session.orchestrator.start(input.task)
    this.scheduleState()
    return { session }
  }

  /** Resume an archived session in place (same dir, same tree skeleton). */
  async resumeArchived(archiveId: string): Promise<{ session?: LiveSession; error?: string }> {
    if (this.sessions.has(archiveId)) return { error: 'session is already live' }
    const dir = path.join(this.archiveRoot, archiveId)
    const archived = loadSession(dir)
    if (!archived || !archived.tree) return { error: 'no replayable orchestration log for this session' }
    const rootSid = resumeKey(archived, archived.tree.rootID)
    if (!rootSid) return { error: 'this session has no captured CLI session id to resume' }
    const meta = readMeta(dir)
    const root = archived.tree.root
    const kind = archived.nodeKinds.get(archived.tree.rootID) ?? ((meta?.agent as AgentCLIKind) ?? 'claude')
    if (!this.detected.some((d) => d.kind === kind)) {
      return { error: `${kind} was not found on this machine` }
    }
    // Re-attach to the original project when its directory is still registered.
    const project = this.projects.find(
      (p) => p.cwd && meta?.projectCwd && path.resolve(p.cwd) === path.resolve(meta.projectCwd),
    )
    const session = this.createOrchestratorSession({
      id: archiveId,
      dir,
      name: meta?.name ?? archiveId,
      projectId: project?.id ?? 'chats',
      projectName: project?.name ?? meta?.projectName ?? null,
      projectCwd: project?.cwd ?? meta?.projectCwd ?? null,
      agentKey: meta?.agent ?? kind,
      agentKind: kind,
      model: meta?.model ?? null,
      permissionMode: 'bypassPermissions',
      createdAt: meta?.createdAt ? Date.parse(meta.createdAt) : Date.now(),
      nameIsCustom: meta?.nameIsCustom === true,
      resumeRootSessionId: rootSid,
      rootRole: root.role,
      rootTitle: root.title,
      archived,
    })
    await session.orchestrator.start('')
    // Graft the previous incarnation's tree under the live root and adopt its pointers.
    session.orchestrator.store.send({ type: 'restoreSkeleton', tree: archived.tree })
    // Mark restored nodes terminal (replay already set status); keep them as dead records.
    if (meta) {
      meta.archived = null
      writeMeta(meta, dir)
    }
    this.scheduleState()
    return { session }
  }

  private createOrchestratorSession(input: {
    id: string
    dir: string
    name: string
    projectId: string
    projectName: string | null
    projectCwd: string | null
    agentKey: string
    agentKind: AgentCLIKind
    model: string | null
    permissionMode: PermissionMode
    createdAt: number
    nameIsCustom: boolean
    resumeRootSessionId: string | null
    rootRole: Role
    rootTitle?: string
    archived?: ArchivedSession
  }): LiveSession {
    const orch = new Orchestrator(
      {
        sessionId: input.id,
        sessionDir: input.dir,
        rootCwd: input.projectCwd,
        rootRole: input.rootRole,
        agentKey: input.agentKey,
        agentKind: input.agentKind,
        permissionMode: input.permissionMode,
        model: input.model,
        userConfigDir: this.configDir,
        resumeRootSessionId: input.resumeRootSessionId,
        agentBins: Object.fromEntries(this.detected.map((d) => [d.kind, d.bin])) as Partial<
          Record<AgentCLIKind, string>
        >,
      },
      {
        onStateChanged: () => this.scheduleState(),
        onCellData: (node, data) => this.broadcaster?.pty(input.id, node, data),
        onCellExit: (node) => this.broadcaster?.ptyExit(input.id, node),
        onSessionRename: (name) => this.setSessionName(input.id, name, true),
        onAutoName: (name) => this.setSessionName(input.id, name, false),
      },
    )
    if (input.rootTitle) {
      const root = orch.store.tree.root
      root.title = input.rootTitle
    }
    const session: LiveSession = {
      id: input.id,
      dir: input.dir,
      name: input.name,
      projectId: input.projectId,
      projectName: input.projectName,
      projectCwd: input.projectCwd,
      agentKey: input.agentKey,
      agentKind: input.agentKind,
      model: input.model,
      permissionMode: input.permissionMode,
      createdAt: input.createdAt,
      nameIsCustom: input.nameIsCustom,
      orchestrator: orch,
    }
    this.sessions.set(input.id, session)
    return session
  }

  closeSession(id: string): void {
    const s = this.sessions.get(id)
    if (!s) return
    s.orchestrator.stop()
    this.sessions.delete(id)
    this.refreshMeta(s)
    this.scheduleState()
  }

  setSessionName(id: string, name: string, custom: boolean): void {
    const s = this.sessions.get(id)
    if (!s) return
    if (!custom && s.nameIsCustom) return
    s.name = name
    if (custom) s.nameIsCustom = true
    this.refreshMeta(s)
    this.scheduleState()
  }

  archiveSession(id: string, flag: boolean): void {
    const dir = this.sessions.get(id)?.dir ?? path.join(this.archiveRoot, id)
    setArchived(dir, flag)
    this.scheduleState()
  }

  private refreshMeta(s: LiveSession): void {
    const meta = readMeta(s.dir) ?? {
      id: s.id,
      name: s.name,
      projectName: s.projectName,
      projectCwd: s.projectCwd,
      agent: s.agentKind,
      model: s.model,
      createdAt: new Date(s.createdAt).toISOString(),
      rootSessionId: null,
      archived: null,
      nameIsCustom: null,
    }
    meta.name = s.name
    meta.projectName = s.projectName
    meta.projectCwd = s.projectCwd
    meta.agent = s.agentKind
    meta.model = s.model
    meta.rootSessionId = s.orchestrator.sessionIds.get(s.orchestrator.rootID) ?? meta.rootSessionId ?? null
    meta.nameIsCustom = s.nameIsCustom ? true : meta.nameIsCustom ?? null
    meta.archived = null
    writeMeta(meta, s.dir)
  }

  private refreshLiveMeta(): void {
    for (const s of this.sessions.values()) this.refreshMeta(s)
  }

  // MARK: terminal / node actions

  writeInput(sessionId: string, nodeId: NodeID, data: string): void {
    this.sessions.get(sessionId)?.orchestrator.writeInput(nodeId, data)
  }

  resize(sessionId: string, nodeId: NodeID, cols: number, rows: number): void {
    this.sessions.get(sessionId)?.orchestrator.resize(nodeId, cols, rows)
  }

  replay(sessionId: string, nodeId: NodeID): string {
    return this.sessions.get(sessionId)?.orchestrator.replayFor(nodeId) ?? ''
  }

  snapshot(sessionId: string, nodeId: NodeID): string {
    return this.sessions.get(sessionId)?.orchestrator.snapshotFor(nodeId) ?? ''
  }

  probeDump(sessionId: string, nodeId: NodeID): unknown {
    return this.sessions.get(sessionId)?.orchestrator.probeDump(nodeId) ?? null
  }

  resumeNode(sessionId: string, nodeId: NodeID): boolean {
    return this.sessions.get(sessionId)?.orchestrator.resumeNode(nodeId) ?? false
  }

  // MARK: history

  history(): any[] {
    return listSessions(this.archiveRoot).map((s) => ({
      id: s.id,
      name: s.meta?.name ?? s.id,
      projectName: s.meta?.projectName ?? null,
      agent: s.meta?.agent ?? null,
      createdAt: s.meta?.createdAt ?? null,
      modifiedAt: s.modifiedAt,
      archived: s.meta?.archived === true,
      live: this.sessions.has(s.id),
      rootSessionId: s.meta?.rootSessionId ?? null,
    }))
  }

  historyDetail(archiveId: string): any | null {
    const dir = path.join(this.archiveRoot, archiveId)
    const a = loadSession(dir)
    if (!a) return null
    const nodes = a.tree
      ? [...a.tree.nodes.values()].map((n) => ({ ...n, children: [...n.children] }))
      : []
    return {
      id: archiveId,
      rootID: a.tree?.rootID ?? null,
      nodes,
      transcripts: Object.fromEntries(a.transcripts),
      sessionIds: Object.fromEntries(a.sessionIds),
      nodeKinds: Object.fromEntries(a.nodeKinds),
      firstEventAt: a.firstEventAt,
      lastEventAt: a.lastEventAt,
    }
  }

  historyTranscript(archiveId: string, nodeId: NodeID): string | null {
    const dir = path.join(this.archiveRoot, archiveId)
    const a = loadSession(dir)
    if (!a) return null
    const p = a.transcripts.get(nodeId)
    if (!p) return null
    return renderClaudeTranscript(p)
  }

  // MARK: state

  scheduleState(): void {
    if (this.stateTimer) return
    this.stateTimer = setTimeout(() => {
      this.stateTimer = null
      this.broadcaster?.state()
    }, 60)
  }

  state(): any {
    const sessions = [...this.sessions.values()].map((s) => ({ ...s.orchestrator.publicState(), name: s.name }))
    const bySession = Object.fromEntries(sessions.map((s: any) => [s.id, s]))
    const idsFor = (projectId: string) =>
      sessions.filter((s: any) => this.sessionProjectOf(s.id) === projectId).map((s: any) => s.id)
    return {
      configDir: this.configDir,
      archiveRoot: this.archiveRoot,
      detected: this.detected,
      defaultAgent: this.defaultAgent,
      agents: this.availableAgents(),
      projects: [
        { id: 'chats', name: 'Chats', cwd: null, sessionIds: idsFor('chats') },
        ...this.projects.map((p) => ({
          id: p.id,
          name: p.name,
          cwd: p.cwd,
          sessionIds: idsFor(p.id),
        })),
      ],
      sessions: bySession,
      history: this.history(),
    }
  }

  private sessionProjectOf(sessionId: string): string {
    return this.sessions.get(sessionId)?.projectId ?? 'chats'
  }

  shutdown(): void {
    if (this.metaTimer) clearInterval(this.metaTimer)
    for (const s of this.sessions.values()) {
      this.refreshMeta(s)
      s.orchestrator.stop()
    }
    this.sessions.clear()
  }
}

export { makeNode }
