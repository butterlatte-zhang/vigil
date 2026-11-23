// Vigil for Windows — role identity prompts.
//
// Port of ClaudeCodeHarness.skill and its line constants. Tool lists mirror the MCP
// surface the server actually exposes per role (root = spawn/send/kill/rename,
// sub-manager = spawn/send/report/kill, worker = report only). Keep them in sync.

import type { AgentCLIKind, Role } from './domain.js'

export const spawnToolLine =
  '- spawn(role, task, model?, name?): create a child and return its node id. Use leaf for a ' +
  'bounded one-worker task; use manager only when the child must delegate. model is a model ' +
  'valid for the agent selected by roles.json, not an agent name; omit it for the configured ' +
  'default. name is a short label shown in Vigil\'s node tree.'

export const sendToolLine =
  '- send(node, message): deliver instructions, follow-up context, or a status request to a live child.'

export const killToolLine =
  '- kill(node): immediately terminate a child subtree; use send first when a graceful stop or final report is possible.'

const reportLine =
  '- report(summary): send your result up to your parent — as an actual call of this ' +
  'Vigil tool, not as text in your reply; only a report(...) call reaches your parent, ' +
  'and a turn that ends without one leaves your parent waiting.'

export const delegationPreferenceLine =
  'Delegation: when you hand a subtask to a child, prefer the Vigil spawn/send/kill tools over the ' +
  "agent's own sub-agent or task tools — only Vigil children appear in the node tree, roll their " +
  'results back up to you, and show up for the user; a native sub-agent stays invisible to Vigil and to the user.'

export const sessionRenameLine =
  "- rename(name): set this session's short label in Vigil's sidebar and title bar; name it " +
  'early and update it when the task focus changes.'

// Windows adaptation of the original process-hygiene line: the broad-match operations
// are taskkill /IM and PowerShell's Stop-Process -Name (the cmd/PowerShell equivalents
// of pkill -f / killall / osascript-by-name).
export const processHygieneRedLine =
  'Process hygiene: clean up processes you started by the exact PID you recorded at launch. ' +
  'Any by-name operation is a broad match: `taskkill /IM <name>` and PowerShell ' +
  '`Stop-Process -Name <name>` (or `Get-Process <name> | Stop-Process`) scan every process ' +
  'with that name — either can match and terminate a sibling worker, your manager, or another ' +
  'running instance, tearing down the tree.'

export const toolSearchRecoveryLine =
  'If a Vigil tool call comes back as not available, its mcp__vigil__ schema was deferred by ' +
  "claude's tool-search; running ToolSearch with select:mcp__vigil__<tool-name> reloads that " +
  'schema, and the same call then goes through on retry.'

export const codexLazyToolsRecoveryLine =
  'Vigil tools under codex may load lazily: they can be missing from the upfront tool list ' +
  "(while codex's own multi-agent tools like spawn_agent are visible) yet still be available. " +
  'A tool search for "vigil" loads their schemas; in code mode they appear in the ALL_TOOLS ' +
  'registry and are callable as `tools.mcp__vigil__<tool-name>` inside exec. Confirming the ' +
  'Vigil tools are loaded early in the turn — before the first delegation or the closing ' +
  'report — keeps the work visible in the Vigil tree.'

export const rootSkill = `You are the root manager of a Vigil agent tree; the user works with you directly in this terminal.
Vigil MCP tools:
${spawnToolLine}
${sendToolLine}
${killToolLine}
Your children's report(...) summaries arrive here in your terminal.
${delegationPreferenceLine}
${processHygieneRedLine}`

export const subManagerSkill = `You are a sub-manager in a Vigil agent tree: you own one branch of your parent's task.
Vigil MCP tools:
${spawnToolLine}
${sendToolLine}
${reportLine}
${killToolLine}
${delegationPreferenceLine}
${processHygieneRedLine}`

export const workerSkill = `You are a worker in a Vigil agent tree: You carry out the tasks assigned to you by your manager
Vigil MCP tool:
- report(summary): send your result up to your manager — as an actual call of this Vigil tool, not as the word "report" in your reply. Text printed in this terminal stays local to this cell; only a report(...) tool call reaches your manager, and a turn that ends without one leaves your manager waiting. The natural last step of a finished task is a report call carrying a short summary. Replies from your manager arrive in this terminal.
${processHygieneRedLine}`

export interface PromptExtras {
  claude?: string | null
  codex?: string | null
  opencode?: string | null
  rename?: string | null
}

export interface SkillOptions {
  role: Role
  isRoot: boolean
  kind?: AgentCLIKind
  promptBase?: string | null
  promptOverride?: string | null
  promptAppend?: string | null
  promptExtras?: PromptExtras | null
  toolSearchRecovery?: boolean
}

export function skillText(opts: SkillOptions): string {
  const kind = opts.kind ?? 'claude'
  const extras = opts.promptExtras ?? {}
  let text =
    opts.promptOverride ??
    opts.promptBase ??
    (opts.isRoot ? rootSkill : opts.role === 'manager' ? subManagerSkill : workerSkill)
  if (!opts.promptOverride) {
    if (opts.isRoot) text += '\n' + (extras.rename ?? sessionRenameLine)
    if (kind === 'codex') text += '\n' + (extras.codex ?? codexLazyToolsRecoveryLine)
    if (kind === 'opencode' && extras.opencode) text += '\n' + extras.opencode
    if (opts.toolSearchRecovery) text += '\n' + (extras.claude ?? toolSearchRecoveryLine)
  }
  if (opts.promptAppend && opts.promptAppend.length > 0) text += '\n' + opts.promptAppend
  return text
}

/** A task beginning with `-` would be parsed as a flag in argv; neutralize it. */
export function neutralizeLeadingDash(task: string): string {
  return task.startsWith('-') ? ' ' + task : task
}
