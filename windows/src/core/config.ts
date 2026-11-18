// Vigil for Windows — settings-as-files.
//
// Port of app/Sources/VigilCore/ConfigFiles.swift. Everything is a file under
// ~/.config/vigil (overridable with VIGIL_CONFIG_DIR). Tolerance contract: missing file
// -> defaults; unparseable file -> defaults; bad field -> that field's default.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import {
  type AgentCLIKind,
  type PermissionMode,
  parsePermissionMode,
  type Role,
} from './domain.js'
import type { PromptExtras } from './prompts.js'

export function configDir(): string {
  const env = process.env.VIGIL_CONFIG_DIR
  if (env && env.length > 0) return env
  return path.join(os.homedir(), '.config', 'vigil')
}

export function expandHome(p: string): string {
  if (p === '~') return os.homedir()
  if (p.startsWith('~/') || p.startsWith('~\\')) return path.join(os.homedir(), p.slice(2))
  return p
}

function readJson(file: string): any | null {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch {
    return null
  }
}

// MARK: - agents.json

export interface AgentEntry {
  key: string
  bin: string
  kind: AgentCLIKind
  models: string[]
  defaultModel: string | null
  extraArgs: string[]
  env: Record<string, string>
}

export function agentUsable(kind: AgentCLIKind): boolean {
  return kind === 'claude' || kind === 'codex' || kind === 'opencode'
}

export class AgentRegistry {
  constructor(public entries: AgentEntry[]) {}

  get(key: string | null | undefined): AgentEntry | undefined {
    if (!key) return undefined
    return this.entries.find((e) => e.key === key)
  }

  static builtinFallback(claudeBin: string): AgentRegistry {
    return new AgentRegistry([
      { key: 'claude', bin: claudeBin, kind: 'claude', models: [], defaultModel: null, extraArgs: [], env: {} },
    ])
  }

  static load(dir: string): AgentRegistry | null {
    const dto = readJson(path.join(dir, 'agents.json'))
    if (!dto || typeof dto !== 'object' || !dto.agents || typeof dto.agents !== 'object') return null
    const entries: AgentEntry[] = []
    for (const [key, raw] of Object.entries<any>(dto.agents)) {
      if (!raw || typeof raw !== 'object' || typeof raw.bin !== 'string' || raw.bin === '') continue
      const kind: AgentCLIKind =
        (typeof raw.kind === 'string' ? (raw.kind as AgentCLIKind) : undefined) ??
        (key === 'claude' || key === 'codex' || key === 'opencode' ? (key as AgentCLIKind) : 'custom')
      entries.push({
        key,
        bin: raw.bin,
        kind,
        models: Array.isArray(raw.models) ? raw.models.filter((x: unknown) => typeof x === 'string') : [],
        defaultModel: typeof raw.defaultModel === 'string' ? raw.defaultModel : null,
        extraArgs: Array.isArray(raw.extraArgs)
          ? raw.extraArgs.filter((x: unknown) => typeof x === 'string')
          : [],
        env:
          raw.env && typeof raw.env === 'object'
            ? Object.fromEntries(Object.entries(raw.env).filter(([, v]) => typeof v === 'string')) as Record<string, string>
            : {},
      })
    }
    entries.sort((a, b) => {
      const au = agentUsable(a.kind) ? 0 : 1
      const bu = agentUsable(b.kind) ? 0 : 1
      if (au !== bu) return au - bu
      return a.key < b.key ? -1 : a.key > b.key ? 1 : 0
    })
    return new AgentRegistry(entries)
  }
}

// MARK: - roles.json

export interface RoleSetting {
  agent?: string | null
  model?: string | null
  modelByKind?: Record<string, string> | null
  modelAnchorAgent?: string | null
  access?: PermissionMode | null
  promptAppend?: string | null
  promptOverride?: string | null
}

export interface RoleTable {
  root: RoleSetting
  subManager: RoleSetting
  worker: RoleSetting
}

export function settingFor(table: RoleTable, role: Role, isRoot: boolean): RoleSetting {
  if (isRoot) return table.root
  return role === 'manager' ? table.subManager : table.worker
}

function mergeRole(target: RoleSetting, dto: any, baseDir: string): void {
  if (!dto || typeof dto !== 'object') return
  if (typeof dto.agent === 'string' && dto.agent !== '') target.agent = dto.agent
  if (typeof dto.model === 'string' && dto.model !== '') {
    target.model = dto.model
    target.modelByKind = null
    target.modelAnchorAgent = target.agent ?? null
  } else if (dto.model && typeof dto.model === 'object') {
    const clean: Record<string, string> = {}
    for (const [k, v] of Object.entries(dto.model)) {
      if (typeof v === 'string' && v !== '') clean[k] = v
    }
    if (Object.keys(clean).length > 0) {
      target.modelByKind = clean
      target.model = null
      target.modelAnchorAgent = null
    }
  }
  const access = parsePermissionMode(typeof dto.access === 'string' ? dto.access : null)
  if (access) target.access = access
  const append = resolvePrompt(dto.promptAppend, baseDir)
  if (append) target.promptAppend = append
  const override = resolvePrompt(dto.promptOverride, baseDir)
  if (override) target.promptOverride = override
}

function resolvePrompt(raw: unknown, baseDir: string): string | null {
  if (typeof raw !== 'string' || raw === '') return null
  if (!raw.startsWith('@')) return raw
  const rel = raw.slice(1)
  const p = path.isAbsolute(rel) ? rel : path.join(baseDir, rel)
  try {
    const text = fs.readFileSync(p, 'utf8').trim()
    return text.length > 0 ? text : null
  } catch {
    return null
  }
}

export function loadRoleTable(configDirPath: string | null, projectCwd: string | null): RoleTable {
  const table: RoleTable = { root: {}, subManager: {}, worker: {} }
  const overlay = (file: string, baseDir: string) => {
    const dto = readJson(file)
    if (!dto) return
    mergeRole(table.root, dto.root, baseDir)
    mergeRole(table.subManager, dto.subManager, baseDir)
    mergeRole(table.worker, dto.worker, baseDir)
  }
  if (configDirPath) overlay(path.join(configDirPath, 'roles.json'), configDirPath)
  if (projectCwd) {
    const vd = path.join(projectCwd, '.vigil')
    overlay(path.join(vd, 'roles.json'), vd)
  }
  return table
}

// MARK: - prompts.json

export interface PromptTable {
  root: string | null
  subManager: string | null
  worker: string | null
  extras: PromptExtras
}

function resolveOverride(s: unknown): string | null {
  if (typeof s !== 'string') return null
  const trimmed = s.trim()
  if (trimmed === '' || trimmed === 'default') return null
  return s
}

export function loadPromptTable(dir: string): PromptTable {
  const dto = readJson(path.join(dir, 'prompts.json')) ?? {}
  return {
    root: resolveOverride(dto.root),
    subManager: resolveOverride(dto.subManager),
    worker: resolveOverride(dto.worker),
    extras: {
      claude: resolveOverride(dto.extras?.claude),
      codex: resolveOverride(dto.extras?.codex),
      opencode: resolveOverride(dto.extras?.opencode),
      rename: resolveOverride(dto.extras?.rename),
    },
  }
}

export function promptBaseFor(table: PromptTable, role: Role, isRoot: boolean): string | null {
  if (isRoot) return table.root
  return role === 'manager' ? table.subManager : table.worker
}

// MARK: - runtime.json

export interface RuntimeTuning {
  harvestAfterMinutes: number
  maxLiveSessions: number
  harvestStuckAfterHours: number
  injectHoldTimeoutSeconds: number
  historyTailCapMB: number
  sidebarCollapseThreshold: number
  autoName: boolean
  permDogfoodLog: boolean
  spawnStallSeconds: number
  initialPromptReadyTimeoutSeconds: number
  deliveryMaxAttempts: number
  deliveryReinjectGraceSeconds: number
  orchestrationToasts: boolean
  bottomShellCommand: string
  terminalDebugLog: 'off' | 'standard' | 'metrics'
  reportWatchdog: boolean
}

export const defaultRuntime: RuntimeTuning = {
  harvestAfterMinutes: 60,
  maxLiveSessions: 10,
  harvestStuckAfterHours: 24,
  injectHoldTimeoutSeconds: 300,
  historyTailCapMB: 8,
  sidebarCollapseThreshold: 5,
  autoName: true,
  permDogfoodLog: true,
  spawnStallSeconds: 15,
  initialPromptReadyTimeoutSeconds: 30,
  deliveryMaxAttempts: 3,
  deliveryReinjectGraceSeconds: 4,
  orchestrationToasts: false,
  bottomShellCommand: '',
  terminalDebugLog: 'off',
  reportWatchdog: true,
}

export function loadRuntime(dir: string): RuntimeTuning {
  const dto = readJson(path.join(dir, 'runtime.json'))
  const t: RuntimeTuning = { ...defaultRuntime }
  if (!dto || typeof dto !== 'object') return t
  const num = (k: keyof RuntimeTuning, positive = false) => {
    const v = dto[k]
    if (typeof v === 'number' && Number.isFinite(v) && (!positive || v > 0)) {
      ;(t as any)[k] = v
    }
  }
  num('harvestAfterMinutes')
  num('maxLiveSessions')
  num('harvestStuckAfterHours')
  num('injectHoldTimeoutSeconds', true)
  num('historyTailCapMB', true)
  num('sidebarCollapseThreshold', true)
  num('spawnStallSeconds', true)
  num('initialPromptReadyTimeoutSeconds', true)
  num('deliveryMaxAttempts', true)
  num('deliveryReinjectGraceSeconds', true)
  if (typeof dto.autoName === 'boolean') t.autoName = dto.autoName
  if (typeof dto.permDogfoodLog === 'boolean') t.permDogfoodLog = dto.permDogfoodLog
  if (typeof dto.orchestrationToasts === 'boolean') t.orchestrationToasts = dto.orchestrationToasts
  if (typeof dto.reportWatchdog === 'boolean') t.reportWatchdog = dto.reportWatchdog
  if (typeof dto.bottomShellCommand === 'string') {
    const trimmed = dto.bottomShellCommand.trim()
    t.bottomShellCommand = trimmed.toLowerCase() === 'auto' ? '' : trimmed
  }
  if (typeof dto.terminalDebugLog === 'string') {
    const v = dto.terminalDebugLog.toLowerCase()
    t.terminalDebugLog = v === 'standard' || v === 'metrics' ? v : 'off'
  }
  return t
}

// MARK: - launcher.json

export function loadLauncherAgent(dir: string): string | null {
  const dto = readJson(path.join(dir, 'launcher.json')) ?? readJson(path.join(dir, 'agent.json'))
  if (dto && typeof dto.agent === 'string' && dto.agent !== '') return dto.agent
  return null
}

// MARK: - archive root

export function archiveRoot(): string {
  const env = process.env.VIGIL_ARCHIVE_ROOT
  if (env && env.length > 0) return env
  const base =
    process.env.APPDATA && process.env.APPDATA.length > 0
      ? process.env.APPDATA
      : path.join(os.homedir(), 'AppData', 'Roaming')
  return path.join(base, 'Vigil', 'sessions')
}

// MARK: - seeding

export function ensureInstalled(dir: string, detected: Array<{ kind: string; bin: string }>): void {
  fs.mkdirSync(dir, { recursive: true })
  const seed = (name: string, content: string) => {
    const p = path.join(dir, name)
    if (!fs.existsSync(p)) fs.writeFileSync(p, content, 'utf8')
  }
  const agents: Record<string, unknown> = {}
  for (const d of detected) {
    agents[d.kind] = { bin: d.bin, kind: d.kind }
  }
  if (Object.keys(agents).length === 0) {
    agents.claude = { bin: 'claude', kind: 'claude' }
  }
  seed('agents.json', JSON.stringify({ agents }, null, 2) + '\n')
  seed(
    'roles.json',
    JSON.stringify(
      {
        root: { agent: 'claude' },
        subManager: { agent: 'claude' },
        worker: { agent: 'claude' },
        _comment:
          'Per-role agent/model/access/prompt settings. See windows/README.md. Delete this key freely.',
      },
      null,
      2,
    ) + '\n',
  )
  seed(
    'prompts.json',
    JSON.stringify(
      {
        root: 'default',
        subManager: 'default',
        worker: 'default',
        extras: { claude: 'default', codex: 'default', opencode: 'default', rename: 'default' },
      },
      null,
      2,
    ) + '\n',
  )
  seed('launcher.json', JSON.stringify({ agent: detected[0]?.kind ?? 'claude' }, null, 2) + '\n')
  seed('runtime.json', JSON.stringify(defaultRuntime, null, 2) + '\n')
}
