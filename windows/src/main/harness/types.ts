// Vigil for Windows — harness contract.

import type { AgentCLIKind, NodeID, PermissionMode, Role } from '../../core/domain.js'

export interface LaunchSpec {
  executable: string
  args: string[]
  env: Record<string, string>
  /** The first-turn task, delivered by PTY injection after the cell is up (not argv). */
  initialPrompt: string | null
  kind: AgentCLIKind
}

export interface LaunchInput {
  task: string
  cwd: string
  nodeID: NodeID
  role: Role
  isRoot: boolean
  model: string | null
  resumeSessionId: string | null
  mcpEndpoint: string | null
  hookEndpoint: string | null
  agentKey: string | null
}

export interface HarnessEnv {
  /** Absolute path to the Node binary used by the two shims (MCP config, spawn). */
  nodeBin: string
  /** The token a *shell* should use to run Node (bare `node` when it is on PATH). */
  nodeCommand: string
  /** Absolute path to windows/bin/vigil-hook.js. */
  hookScript: string
  /** Extra env the shims need (Electron-as-node). */
  nodeEnv: Record<string, string>
}

export interface Harness {
  readonly id: string
  readonly kind: AgentCLIKind
  launchSpec(input: LaunchInput): LaunchSpec
  spawnModelGuardError(model: string, role: Role, cwd: string): string | null
}

export interface HarnessOptions {
  bin: string
  env: HarnessEnv
  configRoot: string
  permissionMode: PermissionMode
  model: string | null
  userConfigDir: string | null
  agentKey: string | null
}

export function baseEnv(extra: Record<string, string> = {}): Record<string, string> {
  const env: Record<string, string> = {}
  for (const [k, v] of Object.entries(process.env)) if (typeof v === 'string') env[k] = v
  Object.assign(env, extra)
  env.TERM = env.TERM || 'xterm-256color'
  return env
}
