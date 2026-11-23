// Vigil for Windows — the claude harness.
//
// Port of ClaudeCodeHarness.swift. A cell is an interactive `claude` TUI wired to two
// channels: observation hooks -> vigil-hook.js and an MCP server -> vigil-mcp.js.
// Permissions use claude's own `--permission-mode`; Vigil never answers a keystroke.
// The first-turn task rides PTY injection rather than argv (argv is globally readable and
// a by-name kill could match a sibling's task text).

import fs from 'node:fs'
import path from 'node:path'
import type { LaunchInput, LaunchSpec, Harness, HarnessOptions } from './types.js'
import { baseEnv } from './types.js'
import { expandBin, permissionOrDefault, resolveAgent, resolveModel, spawnModelGuardError } from './resolve.js'
import { skillText } from '../../core/prompts.js'
import { observationHooks } from '../hook-gateway.js'
import type { PermissionMode, Role } from '../../core/domain.js'
import { AgentRegistry } from '../../core/config.js'

export const strippedSessionMarkers = [
  'CLAUDECODE',
  'CLAUDE_CODE_ENTRYPOINT',
  'CLAUDE_CODE_SESSION_ID',
  'CLAUDE_CODE_CHILD_SESSION',
  'CLAUDE_CODE_EXECPATH',
]

export const allowedTools =
  'mcp__vigil__spawn,mcp__vigil__send,mcp__vigil__report,mcp__vigil__kill,mcp__vigil__rename'

export class ClaudeHarness implements Harness {
  readonly id = 'claude-code'
  readonly kind = 'claude' as const

  constructor(private readonly opts: HarnessOptions) {}

  /** Write per-node settings.json (hooks) + mcp.json (the vigil shim). */
  writeAgentConfigs(
    dir: string,
    node: string,
    hookPipe: string | null,
    mcpPipe: string | null,
  ): { settings: string | null; mcp: string | null } {
    fs.mkdirSync(dir, { recursive: true })
    let settingsPath: string | null = null
    let mcpPath: string | null = null
    const settings: Record<string, unknown> = {}
    if (hookPipe) {
      settings.hooks = observationHooks(
        this.opts.env.nodeCommand,
        this.opts.env.hookScript,
        node,
        hookPipe,
      )
    }
    // Let claude itself query OSC 10/11 and subscribe to DEC 2031, so a theme flip
    // can self-heal rather than freezing a launch-time snapshot.
    settings.theme = 'auto'
    if (Object.keys(settings).length > 0) {
      const p = path.join(dir, 'settings.json')
      fs.writeFileSync(p, JSON.stringify(settings, null, 2))
      settingsPath = p
    }
    if (mcpPipe) {
      const p = path.join(dir, 'mcp.json')
      const server: Record<string, unknown> = {
        command: this.opts.env.nodeBin,
        args: [path.join(path.dirname(this.opts.env.hookScript), 'vigil-mcp.js'), '--node', node, '--sock', mcpPipe],
        alwaysLoad: true,
      }
      if (Object.keys(this.opts.env.nodeEnv).length > 0) server.env = this.opts.env.nodeEnv
      fs.writeFileSync(p, JSON.stringify({ mcpServers: { vigil: server } }, null, 2))
      mcpPath = p
    }
    return { settings: settingsPath, mcp: mcpPath }
  }

  launchSpec(input: LaunchInput): LaunchSpec {
    const resolved = resolveAgent({
      userConfigDir: this.opts.userConfigDir,
      fallbackBin: this.opts.bin,
      cwd: input.cwd,
      role: input.role,
      isRoot: input.isRoot,
      sessionKey: input.agentKey,
      kind: 'claude',
    })
    const roleCfg = resolved.roleCfg
    const nodeDir = path.join(this.opts.configRoot, input.nodeID)
    const { settings, mcp } = this.writeAgentConfigs(
      nodeDir,
      input.nodeID,
      input.hookEndpoint,
      input.mcpEndpoint,
    )

    const args: string[] = []
    let initialPrompt: string | null = null
    if (input.resumeSessionId) {
      args.push('--resume', input.resumeSessionId)
    } else if (input.task !== '') {
      initialPrompt = input.task
    }
    args.push(
      '--append-system-prompt',
      skillText({
        role: input.role,
        isRoot: input.isRoot,
        kind: 'claude',
        promptBase: resolved.promptBase,
        promptOverride: roleCfg.promptOverride,
        promptAppend: roleCfg.promptAppend,
        promptExtras: resolved.promptExtras,
        toolSearchRecovery: true,
      }),
    )
    if (settings) args.push('--settings', settings)
    if (mcp) args.push('--mcp-config', mcp)
    args.push('--allowedTools', allowedTools)
    args.push('--permission-mode', permissionOrDefault(roleCfg, this.opts.permissionMode))
    const model = resolveModel(input.model, this.opts.model, 'claude', resolved, input.isRoot)
    if (model) args.push('--model', model)
    if (resolved.entry?.extraArgs?.length) args.push(...resolved.entry.extraArgs)

    // Project overlay (<cwd>/.vigil/config.json): extra working directories and flags.
    // addDirs is claude-only; codex/opencode still get extraArgs/env below in their own
    // harnesses (same project overlay, no directory semantics).
    const projectCfg = resolved.projectCfg
    if (projectCfg.addDirs.length > 0) {
      args.push('--add-dir', ...projectCfg.addDirs.map((d) => path.resolve(input.cwd, d)))
    }
    if (projectCfg.extraArgs.length > 0) args.push(...projectCfg.extraArgs)

    const env = baseEnv()
    for (const k of strippedSessionMarkers) delete env[k]
    if (resolved.entry?.env) Object.assign(env, resolved.entry.env)
    if (Object.keys(projectCfg.env).length > 0) Object.assign(env, projectCfg.env)
    // claude only: CLAUDE.md discovery from the folders added above.
    if (projectCfg.additionalClaudeMd) env.CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD = '1'
    Object.assign(env, this.opts.env.nodeEnv)
    env.TERM = 'xterm-256color'

    const bin = expandBin(resolved.entry?.bin ?? this.opts.bin)
    return { executable: bin, args, env, initialPrompt, kind: 'claude' }
  }

  spawnModelGuardError(model: string, role: Role, cwd: string): string | null {
    if (!this.opts.userConfigDir) return null
    const registry = AgentRegistry.load(this.opts.userConfigDir)
    if (!registry) return null
    const resolved = resolveAgent({
      userConfigDir: this.opts.userConfigDir,
      fallbackBin: this.opts.bin,
      cwd,
      role,
      isRoot: false,
      sessionKey: this.opts.agentKey,
      kind: 'claude',
    })
    return spawnModelGuardError(registry, 'claude', resolved, model)
  }
}

export function defaultPermission(access: PermissionMode | undefined): PermissionMode {
  return access ?? 'default'
}
