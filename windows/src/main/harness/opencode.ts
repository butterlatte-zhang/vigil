// Vigil for Windows — the opencode harness.
//
// Port of OpenCodeHarness.swift. Everything but the per-node plugin rides one env var:
//   - MCP -> OPENCODE_CONFIG_CONTENT mcp.vigil (same vigil-mcp shim)
//   - role identity -> agent.<root|sub-manager|worker>.prompt, selected by --agent
//   - state truth chain -> a per-node plugin that forwards opencode's event bus to
//     vigil-hook with the same --node/--sock/--event + stdin-JSON contract as claude/codex
// OPENCODE_CONFIG_CONTENT OVERLAYS the user's global config, so provider/auth settings
// survive. opencode is only offered when the prober actually finds it.

import fs from 'node:fs'
import path from 'node:path'
import type { Harness, HarnessOptions, LaunchInput, LaunchSpec } from './types.js'
import { baseEnv } from './types.js'
import { expandBin, permissionOrDefault, resolveAgent, resolveModel } from './resolve.js'
import { skillText } from '../../core/prompts.js'

export function agentName(role: 'leaf' | 'manager', isRoot: boolean): string {
  if (isRoot) return 'root'
  return role === 'manager' ? 'sub-manager' : 'worker'
}

export class OpenCodeHarness implements Harness {
  readonly id = 'opencode'
  readonly kind = 'opencode' as const

  constructor(private readonly opts: HarnessOptions) {}

  private writePlugin(dir: string): string {
    fs.mkdirSync(dir, { recursive: true })
    const p = path.join(dir, 'oc-plugin.js')
    fs.writeFileSync(p, pluginJS(), 'utf8')
    return p
  }

  launchSpec(input: LaunchInput): LaunchSpec {
    const resolved = resolveAgent({
      userConfigDir: this.opts.userConfigDir,
      fallbackBin: this.opts.bin,
      cwd: input.cwd,
      role: input.role,
      isRoot: input.isRoot,
      sessionKey: input.agentKey,
      kind: 'opencode',
    })
    const roleCfg = resolved.roleCfg
    const agent = agentName(input.role, input.isRoot)
    const skill = skillText({
      role: input.role,
      isRoot: input.isRoot,
      kind: 'opencode',
      promptBase: resolved.promptBase,
      promptOverride: roleCfg.promptOverride,
      promptAppend: roleCfg.promptAppend,
      promptExtras: resolved.promptExtras,
    })

    const nodeDir = path.join(this.opts.configRoot, input.nodeID)
    const pluginPath = input.hookEndpoint ? this.writePlugin(nodeDir) : null

    const cfg: Record<string, any> = { $schema: 'https://opencode.ai/config.json' }
    if (input.mcpEndpoint) {
      cfg.mcp = {
        vigil: {
          type: 'local',
          command: [
            this.opts.env.nodeBin,
            path.join(path.dirname(this.opts.env.hookScript), 'vigil-mcp.js'),
            '--node',
            input.nodeID,
            '--sock',
            input.mcpEndpoint,
          ],
          enabled: true,
        },
      }
    }
    if (pluginPath) cfg.plugin = [pluginPath]
    cfg.agent = { [agent]: { prompt: skill, mode: 'primary' } }

    const model = resolveModel(input.model, this.opts.model, 'opencode', resolved, input.isRoot)
    const args: string[] = ['--agent', agent]
    const mode = permissionOrDefault(roleCfg, this.opts.permissionMode)
    if (mode === 'bypassPermissions') args.push('--auto')
    if (model) args.push('-m', model)
    if (resolved.entry?.extraArgs?.length) args.push(...resolved.entry.extraArgs)
    if (input.resumeSessionId) args.push('--session', input.resumeSessionId)

    const env = baseEnv()
    if (resolved.entry?.env) Object.assign(env, resolved.entry.env)
    Object.assign(env, this.opts.env.nodeEnv)
    env.OPENCODE_CONFIG_CONTENT = JSON.stringify(cfg)
    if (input.hookEndpoint) {
      env.VIGIL_NODE_BIN = this.opts.env.nodeBin
      env.VIGIL_HOOK_SCRIPT = this.opts.env.hookScript
      env.VIGIL_NODE = input.nodeID
      env.VIGIL_SOCK = input.hookEndpoint
    }
    env.TERM = 'xterm-256color'

    return {
      executable: expandBin(resolved.entry?.bin ?? this.opts.bin),
      args,
      env,
      initialPrompt: input.task === '' || input.resumeSessionId ? null : input.task,
      kind: 'opencode',
    }
  }

  spawnModelGuardError(): string | null {
    return null
  }
}

/** Forwarder JS: opencode's event bus -> vigil-hook, mirroring the claude/codex hook set. */
function pluginJS(): string {
  return `import { spawn } from "node:child_process"
const BIN = process.env.VIGIL_NODE_BIN, HOOK = process.env.VIGIL_HOOK_SCRIPT
const NODE = process.env.VIGIL_NODE, SOCK = process.env.VIGIL_SOCK
function fire(event, payload) {
  if (!BIN || !HOOK || !NODE || !SOCK) return
  try {
    const p = spawn(BIN, [HOOK, "--node", NODE, "--sock", SOCK, "--event", event],
                    { stdio: ["pipe", "ignore", "ignore"], detached: true, windowsHide: true })
    p.on("error", () => {})
    p.stdin.write(JSON.stringify(payload || {})); p.stdin.end(); p.unref()
  } catch (e) {}
}
export default async function () {
  return {
    event: async ({ event }) => {
      const t = event && event.type, p = (event && event.properties) || {}
      if (t === "session.idle") fire("stop", { session_id: p.sessionID, hook_event_name: t })
      else if (t === "message.updated" && p.info && p.info.role === "user")
        fire("prompt", { session_id: p.sessionID, hook_event_name: t })
    },
    "tool.execute.after": async (input) => fire("post-tool", { tool: input && input.tool }),
    "permission.ask": async () => fire("perm-request", {}),
  }
}
`
}
