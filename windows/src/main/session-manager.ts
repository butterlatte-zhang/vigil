// Vigil for Windows — app-level session manager.
//
// Ports the project / session / history glue from AppModel.swift. Three built-in
// buckets mirror the macOS sidebar: user Projects, Chats (scratch), and Settings (the
// ~/.config/vigil workspace). Live sessions are orchestrators; everything durable lives
// in the session dir. Finished sessions become sidebar history rows in their project,
// or in Archived once filed away.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import type { AgentCLIKind, NodeID, PermissionMode, Role } from '../core/domain.js'
import {
  AgentRegistry,
  agentUsable,
  archiveRoot,
  configDir,
  ensureInstalled,
  loadLauncherAgent,
} from '../core/config.js'
import { Orchestrator } from './orchestrator.js'
import { BottomShell } from './bottom-shell.js'
import { loadAppearance } from './appearance.js'
import {
  loadSession,
  listSessions,
  newSessionDirName,
  readMeta,
  resumeKey,
  setArchived,
  writeMeta,
  type SessionArchiveMeta,
} from './archive.js'
import { loadTranscript, transcriptStats, type TranscriptItem, type TranscriptStats } from './transcript.js'
import { probeCLIs, writeDetected, type DetectedCLI } from './prober.js'
import { appSupportRoot } from './paths.js'
import { sessionNameForTask, taskForConfigWorkspace } from '../shared/session.js'

export interface Project {
  id: string
  name: string
  cwd: string | null
  builtin?: 'chats' | 'settings'
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

const CHATS_ID = 'chats'
const SETTINGS_ID = 'settings'
export const SHELL_NODE = '__shell__'

export class SessionManager {
  readonly configDir = configDir()
  readonly archiveRoot = archiveRoot()
  readonly chatsDir = path.join(appSupportRoot(), 'chats')
  detected: DetectedCLI[] = []
  projects: Project[] = []
  sessions = new Map<string, LiveSession>()
  private shells = new Map<string, BottomShell>()
  private broadcaster: Broadcaster | null = null
  private stateTimer: NodeJS.Timeout | null = null
  private metaTimer: NodeJS.Timeout | null = null
  private defaultAgent: string | null = null

  bootstrap(): void {
    fs.mkdirSync(this.configDir, { recursive: true })
    fs.mkdirSync(this.archiveRoot, { recursive: true })
    this.detected = probeCLIs()
    ensureInstalled(this.configDir, this.detected)
    ensureConfigReadme(this.configDir)
    writeDetected(this.detected)
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
      // none yet
    }
    return []
  }

  private saveProjects(): void {
    fs.writeFileSync(this.projectsFile(), JSON.stringify({ projects: this.projects }, null, 2) + '\n')
  }

  allProjects(): Project[] {
    return [
      ...this.projects,
      { id: CHATS_ID, name: 'Chats', cwd: this.chatsDir, builtin: 'chats' },
      { id: SETTINGS_ID, name: 'Settings', cwd: this.configDir, builtin: 'settings' },
    ]
  }

  projectById(id: string | null | undefined): Project | undefined {
    if (!id) return undefined
    return this.allProjects().find((p) => p.id === id)
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
    const existing = this.projects.find((p) => p.cwd && path.resolve(p.cwd) === abs)
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
    const project = this.projectById(input.projectId) ?? this.projectById(CHATS_ID)
    if (!project) return { error: 'no project' }
    const agentKey = input.agentKey ?? this.defaultAgent ?? 'claude'
    const entry = this.registry().get(agentKey)
    const kind: AgentCLIKind = entry?.kind ?? 'claude'
    if (!agentUsable(kind)) return { error: `agent "${agentKey}" is not a supported CLI` }
    if (!this.detected.some((d) => d.kind === kind)) {
      return { error: `agent "${kind}" was not found on this machine` }
    }
    if (!project.cwd) return { error: 'this project has no directory' }
    fs.mkdirSync(project.cwd, { recursive: true })

    const id = newSessionDirName()
    const dir = path.join(this.archiveRoot, id)
    fs.mkdirSync(dir, { recursive: true })
    const createdAt = new Date()
    const task = project.id === SETTINGS_ID ? taskForConfigWorkspace(input.task) : input.task
    const meta: SessionArchiveMeta = {
      id,
      name: sessionNameForTask(input.task),
      projectName: project.name,
      projectCwd: project.cwd,
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
      projectId: project.id,
      projectName: project.name,
      projectCwd: project.cwd,
      agentKey,
      agentKind: kind,
      model: input.model ?? null,
      permissionMode: input.permissionMode ?? 'bypassPermissions',
      createdAt: createdAt.getTime(),
      nameIsCustom: false,
      resumeRootSessionId: null,
      rootRole: 'manager',
    })
    await session.orchestrator.start(task)
    this.scheduleState()
    return { session }
  }

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
    const project =
      this.allProjects().find((p) => p.cwd && meta?.projectCwd && path.resolve(p.cwd) === path.resolve(meta.projectCwd)) ??
      this.projectById(CHATS_ID)
    const session = this.createOrchestratorSession({
      id: archiveId,
      dir,
      name: meta?.name ?? archiveId,
      projectId: project?.id ?? CHATS_ID,
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
    })
    await session.orchestrator.start('')
    session.orchestrator.store.send({ type: 'restoreSkeleton', tree: archived.tree })
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
    if (input.rootTitle) orch.store.tree.root.title = input.rootTitle
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
    this.terminateShell(id)
    s.orchestrator.stop()
    this.sessions.delete(id)
    this.refreshMeta(s)
    this.scheduleState()
  }

  /** Sidebar archive: a live row is shut down first, then filed away. */
  archiveSession(id: string, flag: boolean): void {
    const s = this.sessions.get(id)
    if (flag && s) {
      this.closeSession(id)
      setArchived(s.dir, true)
    } else {
      const dir = s?.dir ?? path.join(this.archiveRoot, id)
      setArchived(dir, flag)
    }
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

  /** Manual rename of a live session; also works on a dead session's meta. */
  renameSession(id: string, name: string): void {
    const trimmed = name.trim()
    if (!trimmed) return
    const s = this.sessions.get(id)
    if (s) {
      s.name = trimmed
      s.nameIsCustom = true
      this.refreshMeta(s)
    } else {
      const dir = path.join(this.archiveRoot, id)
      const meta = readMeta(dir)
      if (meta) {
        meta.name = trimmed
        meta.nameIsCustom = true
        writeMeta(meta, dir)
      }
    }
    this.scheduleState()
  }

  // MARK: bottom shell

  toggleShell(sessionId: string): { running: boolean } {
    const s = this.sessions.get(sessionId)
    if (!s) return { running: false }
    const existing = this.shells.get(sessionId)
    if (existing) {
      this.terminateShell(sessionId)
      return { running: false }
    }
    const shell = new BottomShell({
      cwd: s.projectCwd ?? s.dir,
      configDir: this.configDir,
      onData: (data) => this.broadcaster?.pty(sessionId, SHELL_NODE, data),
      onExit: () => {
        this.shells.delete(sessionId)
        this.broadcaster?.ptyExit(sessionId, SHELL_NODE)
        this.scheduleState()
      },
    })
    this.shells.set(sessionId, shell)
    shell.start()
    this.scheduleState()
    return { running: true }
  }

  shellRunning(sessionId: string): boolean {
    return this.shells.has(sessionId)
  }

  shellInput(sessionId: string, data: string): void {
    this.shells.get(sessionId)?.write(data)
  }

  shellResize(sessionId: string, cols: number, rows: number): void {
    this.shells.get(sessionId)?.resize(cols, rows)
  }

  shellReplay(sessionId: string): string {
    return this.shells.get(sessionId)?.replayData() ?? ''
  }

  private terminateShell(sessionId: string): void {
    const shell = this.shells.get(sessionId)
    if (!shell) return
    this.shells.delete(sessionId)
    shell.terminate()
  }

  // MARK: meta

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

  // MARK: transcripts

  deadNodeTranscript(sessionId: string, nodeId: NodeID): {
    path: string | null
    items: TranscriptItem[] | null
    stats: TranscriptStats | null
  } {
    const orch = this.sessions.get(sessionId)?.orchestrator
    const p = orch?.transcripts.get(nodeId) ?? null
    return { path: p, items: loadTranscript(p), stats: transcriptStats(p) }
  }

  historyTranscript(archiveId: string, nodeId: NodeID): {
    path: string | null
    items: TranscriptItem[] | null
    stats: TranscriptStats | null
  } {
    const dir = path.join(this.archiveRoot, archiveId)
    const a = loadSession(dir)
    const p = a?.transcripts.get(nodeId) ?? null
    const stats = transcriptStats(p)
    if (stats && nodeId === a?.tree?.rootID) stats.sessionName = readMeta(dir)?.name ?? null
    return { path: p, items: loadTranscript(p), stats }
  }

  // MARK: history

  private projectIdForCwd(cwd: string | null): string {
    if (!cwd) return CHATS_ID
    const abs = path.resolve(cwd)
    const hit = this.allProjects().find((p) => p.cwd && path.resolve(p.cwd) === abs)
    if (hit) return hit.id
    if (abs === path.resolve(this.chatsDir)) return CHATS_ID
    return CHATS_ID
  }

  history(): any[] {
    return listSessions(this.archiveRoot)
      .filter((s) => !this.sessions.has(s.id))
      .map((s) => ({
        id: s.id,
        name: s.meta?.name ?? s.id,
        projectId: this.projectIdForCwd(s.meta?.projectCwd ?? null),
        projectName: s.meta?.projectName ?? null,
        projectCwd: s.meta?.projectCwd ?? null,
        agent: s.meta?.agent ?? null,
        model: s.meta?.model ?? null,
        createdAt: s.meta?.createdAt ?? null,
        modifiedAt: s.modifiedAt,
        archived: s.meta?.archived === true,
        live: false,
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
      meta: readMeta(dir),
    }
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
    const sessions = [...this.sessions.values()].map((s) => ({
      ...s.orchestrator.publicState(),
      name: s.name,
      projectId: s.projectId,
      projectName: s.projectName,
      projectCwd: s.projectCwd,
      agentKey: s.agentKey,
      agentKind: s.agentKind,
      model: s.model,
      nameIsCustom: s.nameIsCustom,
      shellRunning: this.shells.has(s.id),
      createdAt: s.createdAt,
    }))
    const bySession = Object.fromEntries(sessions.map((s: any) => [s.id, s]))
    const idsFor = (projectId: string) =>
      sessions.filter((s: any) => s.projectId === projectId).map((s: any) => s.id)
    return {
      home: os.homedir(),
      configDir: this.configDir,
      archiveRoot: this.archiveRoot,
      chatsDir: this.chatsDir,
      detected: this.detected,
      defaultAgent: this.defaultAgent,
      agents: this.availableAgents(),
      appearance: loadAppearance(this.configDir),
      projects: this.allProjects().map((p) => ({
        id: p.id,
        name: p.name,
        cwd: p.cwd,
        builtin: p.builtin ?? null,
        sessionIds: idsFor(p.id),
      })),
      sessions: bySession,
      history: this.history(),
    }
  }

  shutdown(): void {
    if (this.metaTimer) clearInterval(this.metaTimer)
    for (const id of [...this.shells.keys()]) this.terminateShell(id)
    for (const s of this.sessions.values()) {
      this.refreshMeta(s)
      s.orchestrator.stop()
    }
    this.sessions.clear()
  }
}

// MARK: - Settings workspace guide

/**
 * The Settings pseudo-project's agent-neutral guide, rewritten on every launch (like the
 * macOS app's shipped README): the configurator agent reads it to learn the field set.
 */
export function ensureConfigReadme(dir: string): void {
  const content = `# Vigil settings (Windows)

Everything here is a file; there is no settings page. Edit the JSON and the change
applies at the next spawn (or live, for appearance/runtime).

## agents.json — the launcher registry
\`\`\`json
{ "agents": { "claude": { "bin": "C:\\path\\to\\claude.exe", "kind": "claude",
  "models": [], "defaultModel": null, "extraArgs": [], "env": {} } } }
\`\`\`
- \`bin\` is required. \`kind\` is claude | codex | opencode | custom.
- Multiple entries of the same kind = multiple providers/proxies.
- Cells are spawned directly (no login shell), so put proxies/keys in \`env\`, never in
  shell aliases; wrapper flags go in \`extraArgs\`.

## roles.json — per-role settings (\`root\`, \`subManager\`, \`worker\`)
\`\`\`json
{ "worker": { "agent": "claude", "model": "claude-haiku-4-5", "access": "bypass" } }
\`\`\`
- \`agent\` = an agents.json key. \`model\` may be a bare string (bound to that agent's
  family) or a map keyed by family: \`{ "claude": "...", "codex": "..." }\`.
- \`access\` = default | acceptEdits | plan | bypass.
- \`promptAppend\` appends text after Vigil's identity/tools section; \`promptOverride\`
  replaces it entirely. \`@relative/path.md\` reads text from a file.
- \`<project>\.vigil\roles.json\` overlays this file field by field.

## prompts.json — user-owned identity text
Keys: \`root\`, \`subManager\`, \`worker\`, and \`extras: { claude, codex, opencode, rename }\`.
Any value that is blank or the literal \`"default"\` falls back to Vigil's built-in line.

## launcher.json — \`{ "agent": "claude" }\` (default agent)

## runtime.json — knobs (read live)
spawnStallSeconds, injectHoldTimeoutSeconds, initialPromptReadyTimeoutSeconds,
deliveryMaxAttempts, deliveryReinjectGraceSeconds, reportWatchdog, autoName,
permDogfoodLog, orchestrationToasts, bottomShellCommand, terminalDebugLog,
harvestAfterMinutes, maxLiveSessions, harvestStuckAfterHours, sidebarCollapseThreshold,
historyTailCapMB.

## appearance.json — \`{ "theme": "auto|dark|light", "accent": "blue|teal|amber|purple", "terminal": {...} }\`

## detected.json — probe facts, rewritten on every launch; hand edits do not stick.

Sessions live under %APPDATA%\Vigil\sessions.
`
  try {
    fs.mkdirSync(dir, { recursive: true })
    fs.writeFileSync(path.join(dir, 'README.md'), content, 'utf8')
  } catch {
    // never take the app down for a guide
  }
}
