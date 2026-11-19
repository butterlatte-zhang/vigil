// Vigil for Windows — the codex harness.
//
// Port of CodexHarness.swift. A codex cell is an interactive TUI whose channels ride a
// per-node CODEX_HOME:
//   - MCP  -> config.toml [mcp_servers.vigil] (the same vigil-mcp shim as claude)
//   - hooks -> $CODEX_HOME/hooks.json (identical command-line contract as claude)
//   - auth -> a copy of the user's real auth.json (Windows has no dependable symlink
//             privilege for an un-elevated app, so this is a copy, refreshed each launch)
// The per-node home is a view of the user's real codex home: config.toml inherits the
// user's config with only the Vigil-owned parts replaced.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import type { Harness, HarnessOptions, LaunchInput, LaunchSpec } from './types.js'
import { baseEnv } from './types.js'
import { expandBin, permissionOrDefault, resolveAgent, resolveModel, spawnModelGuardError } from './resolve.js'
import { skillText } from '../../core/prompts.js'
import { observationHooks } from '../hook-gateway.js'
import { AgentRegistry } from '../../core/config.js'
import type { PermissionMode, Role } from '../../core/domain.js'

export function codexPermission(mode: PermissionMode): { approval: string; sandbox: string } {
  return mode === 'bypassPermissions'
    ? { approval: 'never', sandbox: 'danger-full-access' }
    : { approval: 'on-request', sandbox: 'workspace-write' }
}

export function userCodexHome(): string {
  const env = process.env.CODEX_HOME
  if (env && env.length > 0) return env
  return path.join(os.homedir(), '.codex')
}

function tomlString(s: string): string {
  return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"'
}

/** Remove a top-level [table] (and its body) from a TOML document. */
function stripTable(text: string, header: string): string {
  const lines = text.split(/\r?\n/)
  const out: string[] = []
  let skipping = false
  for (const line of lines) {
    const trimmed = line.trim()
    if (trimmed.startsWith('[')) {
      skipping = trimmed === header
      if (skipping) continue
    }
    if (!skipping) out.push(line)
  }
  return out.join('\n')
}

function stripTopLevelKeys(text: string, keys: string[]): string {
  const lines = text.split(/\r?\n/)
  const out: string[] = []
  let inTable = false
  for (const line of lines) {
    if (line.trim().startsWith('[')) inTable = true
    if (!inTable && keys.some((k) => line.trimStart().startsWith(k + ' ') || line.trimStart().startsWith(k + '='))) {
      continue
    }
    out.push(line)
  }
  return out.join('\n')
}

function copyRecursive(src: string, dst: string): void {
  try {
    const st = fs.statSync(src)
    if (st.isDirectory()) {
      fs.mkdirSync(dst, { recursive: true })
      for (const name of fs.readdirSync(src)) copyRecursive(path.join(src, name), path.join(dst, name))
    } else {
      fs.copyFileSync(src, dst)
    }
  } catch {
    // absent user artifact: nothing to pass through
  }
}

export class CodexHarness implements Harness {
  readonly id = 'codex'
  readonly kind = 'codex' as const

  constructor(private readonly opts: HarnessOptions) {}

  static codexHome(configRoot: string, node: string): string {
    return path.join(configRoot, node, 'codex-home')
  }

  writeCodexHome(
    node: string,
    hookPipe: string | null,
    mcpPipe: string | null,
    approval: string,
    sandbox: string,
    projectCwd: string,
  ): string {
    const dir = CodexHarness.codexHome(this.opts.configRoot, node)
    fs.mkdirSync(dir, { recursive: true })
    const userHome = userCodexHome()

    let top = `approval_policy = ${tomlString(approval)}\n`
    top += `sandbox_mode = ${tomlString(sandbox)}\n`
    top += 'check_for_update_on_startup = false\n'

    let tables = ''
    tables += `\n[projects.${tomlString(projectCwd)}]\n`
    tables += 'trust_level = "trusted"\n'
    if (mcpPipe) {
      tables += '\n[mcp_servers.vigil]\n'
      tables += `command = ${tomlString(this.opts.env.nodeBin)}\n`
      const mcpScript = path.join(path.dirname(this.opts.env.hookScript), 'vigil-mcp.js')
      const argv = [mcpScript, '--node', node, '--sock', mcpPipe].map(tomlString).join(', ')
      tables += `args = [${argv}]\n`
    }

    let userToml = ''
    try {
      userToml = fs.readFileSync(path.join(userHome, 'config.toml'), 'utf8')
    } catch {
      userToml = ''
    }
    userToml = stripTopLevelKeys(userToml, ['approval_policy', 'sandbox_mode', 'check_for_update_on_startup'])
    userToml = stripTable(userToml, '[mcp_servers.vigil]')
    userToml = stripTable(userToml, `[projects.${tomlString(projectCwd)}]`)
    const merged = `${top}${userToml ? '\n' + userToml : ''}\n${tables}`
    fs.writeFileSync(path.join(dir, 'config.toml'), merged)

    if (hookPipe) {
      fs.writeFileSync(
        path.join(dir, 'hooks.json'),
        JSON.stringify(
          { hooks: observationHooks(this.opts.env.nodeCommand, this.opts.env.hookScript, node, hookPipe) },
          null,
          2,
        ),
      )
    }

    for (const name of ['auth.json', 'AGENTS.md']) {
      const src = path.join(userHome, name)
      const dst = path.join(dir, name)
      try {
        if (fs.existsSync(src)) {
          if (fs.existsSync(dst)) fs.rmSync(dst, { force: true })
          fs.copyFileSync(src, dst)
        }
      } catch {
        // best-effort passthrough
      }
    }
    copyRecursive(path.join(userHome, 'prompts'), path.join(dir, 'prompts'))
    return dir
  }

  launchSpec(input: LaunchInput): LaunchSpec {
    const resolved = resolveAgent({
      userConfigDir: this.opts.userConfigDir,
      fallbackBin: this.opts.bin,
      cwd: input.cwd,
      role: input.role,
      isRoot: input.isRoot,
      sessionKey: input.agentKey,
      kind: 'codex',
    })
    const roleCfg = resolved.roleCfg
    const perm = codexPermission(permissionOrDefault(roleCfg, this.opts.permissionMode))
    const home = this.writeCodexHome(
      input.nodeID,
      input.hookEndpoint,
      input.mcpEndpoint,
      perm.approval,
      perm.sandbox,
      input.cwd,
    )

    const model = resolveModel(input.model, this.opts.model, 'codex', resolved, input.isRoot)
    const args: string[] = []
    let initialPrompt: string | null = null
    if (input.resumeSessionId) {
      args.push('resume', input.resumeSessionId, '--dangerously-bypass-hook-trust')
    } else {
      args.push('--dangerously-bypass-hook-trust')
      if (model) args.push('-m', model)
      if (resolved.entry?.extraArgs?.length) args.push(...resolved.entry.extraArgs)
      if (resolved.projectCfg.extraArgs.length > 0) args.push(...resolved.projectCfg.extraArgs)
      const skill = skillText({
        role: input.role,
        isRoot: input.isRoot,
        kind: 'codex',
        promptBase: resolved.promptBase,
        promptOverride: roleCfg.promptOverride,
        promptAppend: roleCfg.promptAppend,
        promptExtras: resolved.promptExtras,
      })
      const prompt = input.task === '' ? skill : `${skill}\n\n---\n\n${input.task}`
      initialPrompt = prompt
    }

    const env = baseEnv()
    if (resolved.entry?.env) Object.assign(env, resolved.entry.env)
    if (Object.keys(resolved.projectCfg.env).length > 0) Object.assign(env, resolved.projectCfg.env)
    Object.assign(env, this.opts.env.nodeEnv)
    env.CODEX_HOME = home
    env.TERM = 'xterm-256color'

    return {
      executable: expandBin(resolved.entry?.bin ?? this.opts.bin),
      args,
      env,
      initialPrompt,
      kind: 'codex',
    }
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
      kind: 'codex',
    })
    return spawnModelGuardError(registry, 'codex', resolved, model)
  }
}
