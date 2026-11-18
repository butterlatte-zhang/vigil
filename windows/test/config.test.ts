import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import {
  AgentRegistry,
  ensureInstalled,
  loadLauncherAgent,
  loadPromptTable,
  loadRoleTable,
  loadRuntime,
  promptBaseFor,
} from '../src/core/config.js'

const dirs: string[] = []
function tmp(): string {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'vigil-config-'))
  dirs.push(d)
  return d
}
afterEach(() => {
  for (const d of dirs.splice(0)) fs.rmSync(d, { recursive: true, force: true })
})

describe('agents.json', () => {
  it('loads entries, normalizes kind, and orders usable entries first', () => {
    const d = tmp()
    fs.writeFileSync(
      path.join(d, 'agents.json'),
      JSON.stringify({
        agents: {
          proxy: { bin: 'C:/bin/claude.exe', kind: 'claude' },
          custom: { bin: 'C:/bin/x.exe' },
          codex: { bin: 'C:/bin/codex.cmd', kind: 'codex' },
        },
      }),
    )
    const reg = AgentRegistry.load(d)!
    expect(reg.get('proxy')?.kind).toBe('claude')
    expect(reg.get('custom')?.kind).toBe('custom')
    expect(reg.entries[reg.entries.length - 1].key).toBe('custom')
  })

  it('returns null for a missing or unparseable file (caller falls back)', () => {
    const d = tmp()
    expect(AgentRegistry.load(d)).toBeNull()
    fs.writeFileSync(path.join(d, 'agents.json'), '{broken')
    expect(AgentRegistry.load(d)).toBeNull()
  })
})

describe('roles.json', () => {
  it('merges global then project, with field-level override and a family-anchored bare model', () => {
    const d = tmp()
    const project = tmp()
    fs.writeFileSync(
      path.join(d, 'roles.json'),
      JSON.stringify({
        root: { agent: 'claude', access: 'bypass' },
        worker: { model: 'claude-haiku-4-5' },
      }),
    )
    fs.mkdirSync(path.join(project, '.vigil'), { recursive: true })
    fs.writeFileSync(
      path.join(project, '.vigil', 'roles.json'),
      JSON.stringify({
        worker: { agent: 'codex' },
        subManager: { model: { codex: 'gpt-5' }, access: 'plan' },
      }),
    )
    const t = loadRoleTable(d, project)
    expect(t.root.access).toBe('bypassPermissions')
    expect(t.worker.agent).toBe('codex')
    // the bare model was declared while claude was the anchor — it must not follow codex
    expect(t.worker.model).toBe('claude-haiku-4-5')
    expect(t.worker.modelAnchorAgent ?? 'claude').toBe('claude')
    expect(t.subManager.modelByKind).toEqual({ codex: 'gpt-5' })
    expect(t.subManager.access).toBe('plan')
  })

  it('resolves @file prompt references relative to the declaring file', () => {
    const d = tmp()
    fs.writeFileSync(path.join(d, 'extra.md'), '  appended text  ')
    fs.writeFileSync(
      path.join(d, 'roles.json'),
      JSON.stringify({ root: { promptAppend: '@extra.md' } }),
    )
    const t = loadRoleTable(d, null)
    expect(t.root.promptAppend).toBe('appended text')
  })
})

describe('prompts.json', () => {
  it('treats "default", blank and null as unset and passes real text verbatim', () => {
    const d = tmp()
    fs.writeFileSync(
      path.join(d, 'prompts.json'),
      JSON.stringify({
        root: 'default',
        worker: '  ',
        subManager: 'You are special.',
        extras: { claude: 'default', rename: 'My rename line' },
      }),
    )
    const t = loadPromptTable(d)
    expect(t.root).toBeNull()
    expect(t.worker).toBeNull()
    expect(t.subManager).toBe('You are special.')
    expect(t.extras.claude).toBeNull()
    expect(t.extras.rename).toBe('My rename line')
    expect(promptBaseFor(t, 'manager', true)).toBeNull()
  })
})

describe('runtime.json + launcher + seeding', () => {
  it('applies only valid positive knobs and defaults the rest', () => {
    const d = tmp()
    fs.writeFileSync(
      path.join(d, 'runtime.json'),
      JSON.stringify({ spawnStallSeconds: 0, playbackQuery: 1, reportWatchdog: false, autoName: false, terminalDebugLog: 'METRICS' }),
    )
    const t = loadRuntime(d)
    expect(t.spawnStallSeconds).toBe(15)
    expect(t.reportWatchdog).toBe(false)
    expect(t.autoName).toBe(false)
    expect(t.terminalDebugLog).toBe('metrics')
  })

  it('seeds a usable config dir without overwriting existing files', () => {
    const d = tmp()
    ensureInstalled(d, [{ kind: 'claude', bin: 'C:/bin/claude.exe' }])
    expect(fs.existsSync(path.join(d, 'agents.json'))).toBe(true)
    expect(fs.existsSync(path.join(d, 'prompts.json'))).toBe(true)
    expect(loadLauncherAgent(d)).toBe('claude')
    fs.writeFileSync(path.join(d, 'agents.json'), '{"agents":{}}')
    ensureInstalled(d, [])
    expect(fs.readFileSync(path.join(d, 'agents.json'), 'utf8')).toBe('{"agents":{}}')
  })
})
