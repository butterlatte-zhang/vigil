// Vigil for Windows — per-launch agent resolution.
//
// Port of app/Sources/VigilRuntime/HarnessDispatch.swift's HarnessResolve: agents.json
// and roles.json are point-read at every launch, so file edits apply to the next spawn
// and never to a running cell.

import path from 'node:path'
import {
  type AgentCLIKind,
  type PermissionMode,
  type Role,
} from '../../core/domain.js'
import {
  AgentRegistry,
  type AgentEntry,
  agentUsable,
  loadPromptTable,
  loadRoleTable,
  promptBaseFor,
  type RoleSetting,
} from '../../core/config.js'
import type { PromptExtras } from '../../core/prompts.js'

export interface ResolvedAgent {
  entry: AgentEntry | null
  roleCfg: RoleSetting
  sessionKind: AgentCLIKind | null
  roleAgentKind: AgentCLIKind | null
  promptBase: string | null
  promptExtras: PromptExtras
}

export interface ResolveInput {
  userConfigDir: string | null
  fallbackBin: string
  cwd: string
  role: Role
  isRoot: boolean
  sessionKey: string | null
  kind?: AgentCLIKind | null
}

export function resolveAgent(input: ResolveInput): ResolvedAgent {
  const registry: AgentRegistry | null = input.userConfigDir
    ? AgentRegistry.load(input.userConfigDir) ?? AgentRegistry.builtinFallback(input.fallbackBin)
    : null
  const roleTable = input.userConfigDir ? loadRoleTable(input.userConfigDir, input.cwd) : null
  const roleCfg: RoleSetting = roleTable
    ? input.isRoot
      ? roleTable.root
      : input.role === 'manager'
        ? roleTable.subManager
        : roleTable.worker
    : {}
  const entry = resolveEntry(
    registry,
    input.sessionKey,
    input.isRoot ? null : roleCfg.agent ?? null,
    input.kind ?? null,
  )
  const promptTable = input.userConfigDir ? loadPromptTable(input.userConfigDir) : null
  return {
    entry,
    roleCfg,
    sessionKind: input.sessionKey ? registry?.get(input.sessionKey)?.kind ?? null : null,
    roleAgentKind: roleCfg.modelAnchorAgent ? registry?.get(roleCfg.modelAnchorAgent)?.kind ?? null : null,
    promptBase: promptTable ? promptBaseFor(promptTable, input.role, input.isRoot) : null,
    promptExtras: promptTable?.extras ?? {},
  }
}

export function resolveEntry(
  registry: AgentRegistry | null,
  sessionKey: string | null,
  roleKey: string | null,
  kind: AgentCLIKind | null,
): AgentEntry | null {
  if (!registry) return null
  const ok = (e: AgentEntry) => agentUsable(e.kind) && (kind === null || e.kind === kind)
  if (roleKey) {
    const e = registry.get(roleKey)
    if (e && ok(e)) return e
  }
  if (sessionKey) {
    const e = registry.get(sessionKey)
    if (e && ok(e)) return e
  }
  if (kind === null || kind === 'claude') {
    const c = registry.get('claude')
    return c && agentUsable(c.kind) ? c : null
  }
  return null
}

export function resolveModel(
  param: string | null,
  sessionModel: string | null,
  kind: AgentCLIKind,
  resolved: ResolvedAgent,
  isRoot: boolean,
): string | null {
  const roleModel: string | null = (() => {
    if (resolved.roleCfg.modelByKind) return resolved.roleCfg.modelByKind[kind] ?? null
    const bare = resolved.roleCfg.model
    if (!bare) return null
    return (resolved.roleAgentKind ?? 'claude') === kind ? bare : null
  })()
  const session = (resolved.sessionKind ?? kind) === kind ? sessionModel : null
  const entryDefault = resolved.entry?.defaultModel ?? null
  if (isRoot) return param ?? session ?? roleModel ?? entryDefault
  return param ?? roleModel ?? session ?? entryDefault
}

/**
 * Reject a spawn model that provably names an agent (or another agent's model) instead
 * of a model for this node's family. Only provable class errors are rejected.
 */
export function spawnModelGuardError(
  registry: AgentRegistry | null,
  kind: AgentCLIKind,
  resolved: ResolvedAgent,
  model: string,
): string | null {
  if (!registry) return null
  const lower = model.trim().toLowerCase()
  if (lower === '') return null
  if (registry.get(model) || ['claude', 'codex', 'opencode'].includes(lower)) {
    return `model "${model}" looks like an agent name, not a model id. Leave model empty to inherit the configured default; choose the child's agent in roles.json.`
  }
  const own = resolved.entry?.models ?? []
  const ownHas = own.length === 0 || own.includes(model)
  if (!ownHas) {
    for (const e of registry.entries) {
      if (e.kind === kind) continue
      if (e.models.includes(model)) {
        return `model "${model}" is listed under agent "${e.key}", not under this child's agent ("${resolved.entry?.key ?? kind}").`
      }
    }
  }
  return null
}

export function expandBin(bin: string): string {
  if (bin === '~') return process.env.USERPROFILE ?? bin
  if (bin.startsWith('~/') || bin.startsWith('~\\')) {
    return path.join(process.env.USERPROFILE ?? '', bin.slice(2))
  }
  return bin
}

export function permissionOrDefault(setting: RoleSetting | undefined, fallback: PermissionMode): PermissionMode {
  return setting?.access ?? fallback
}
