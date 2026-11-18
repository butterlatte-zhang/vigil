// Vigil for Windows — startup CLI probe.
//
// Port of VigilApp/CLIProber.swift. Which agent CLIs actually live on this machine is
// probed by Vigil, never delegated to an agent. On Windows a CLI may be an .exe, a .cmd
// npm shim, or a .bat wrapper; all three count. The result is written to detected.json
// every start (probe fact, not a setting) and seeds agents.json / launcher.json.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import type { AgentCLIKind } from '../core/domain.js'
import { configDir } from '../core/config.js'

export interface DetectedCLI {
  kind: string
  bin: string
}

const order: AgentCLIKind[] = ['claude', 'codex', 'opencode']

function candidateDirs(): string[] {
  const env = process.env.VIGIL_PROBE_DIRS
  if (env) return env.split(path.delimiter).filter(Boolean)
  const home = os.homedir()
  const dirs = [
    path.join(home, '.local', 'bin'),
    process.env.APPDATA ? path.join(process.env.APPDATA, 'npm') : '',
    process.env.LOCALAPPDATA ? path.join(process.env.LOCALAPPDATA, 'npm') : '',
    path.join(home, 'AppData', 'Roaming', 'npm'),
    path.join(home, '.bun', 'bin'),
    path.join(home, '.volta', 'bin'),
    path.join(home, 'bin'),
    ...(process.env.PATH ?? '').split(path.delimiter),
  ]
  const seen = new Set<string>()
  return dirs.filter((d) => {
    if (!d) return false
    const key = path.resolve(d).toLowerCase()
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
}

const extensions = (() => {
  const raw = process.env.PATHEXT ?? '.COM;.EXE;.BAT;.CMD'
  return raw
    .split(';')
    .map((e) => e.trim().toLowerCase())
    .filter(Boolean)
})()

export function probeCLIs(dirs: string[] = candidateDirs()): DetectedCLI[] {
  const found: DetectedCLI[] = []
  for (const kind of order) {
    let hit: string | null = null
    for (const dir of dirs) {
      for (const ext of extensions) {
        const p = path.join(dir, kind + ext)
        try {
          if (fs.statSync(p).isFile()) {
            hit = p
            break
          }
        } catch {
          // not here
        }
      }
      if (hit) break
    }
    if (hit) found.push({ kind, bin: hit })
  }
  return found
}

export function writeDetected(found: DetectedCLI[]): void {
  const dir = configDir()
  fs.mkdirSync(dir, { recursive: true })
  const notFound = order.filter((k) => !found.some((f) => f.kind === k))
  const obj = {
    probedAt: new Date().toISOString(),
    found,
    notFound,
  }
  fs.writeFileSync(path.join(dir, 'detected.json'), JSON.stringify(obj, null, 2) + '\n')
}
