// Vigil for Windows — platform paths and runtime resolution.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/** The `windows/` package root (works from src/main/*.ts and dist/main/*.js alike). */
export const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')

export function shimPath(name: 'vigil-mcp.js' | 'vigil-hook.js'): string {
  return path.join(packageRoot, 'bin', name)
}

export interface NodeRuntime {
  bin: string
  /** True when the binary is the Electron executable and needs ELECTRON_RUN_AS_NODE=1. */
  electron: boolean
  /** True when `bin` was found on PATH, so the bare name `node` resolves too. */
  onPath: boolean
}

let cachedNode: NodeRuntime | null = null

/**
 * The Node binary used for the two shims (claude/codex launch them as MCP servers and
 * hooks). Prefer a real `node.exe` on PATH; fall back to Electron's embedded Node.
 */
export function resolveNodeRuntime(): NodeRuntime {
  if (cachedNode) return cachedNode
  const override = process.env.VIGIL_NODE_BIN
  if (override && fs.existsSync(override)) {
    cachedNode = { bin: override, electron: false, onPath: false }
    return cachedNode
  }
  const pathDirs = (process.env.PATH ?? '').split(path.delimiter).filter(Boolean)
  for (const dir of pathDirs) {
    for (const name of ['node.exe', 'node']) {
      const p = path.join(dir, name)
      try {
        if (fs.statSync(p).isFile()) {
          cachedNode = { bin: p, electron: false, onPath: true }
          return cachedNode
        }
      } catch {
        // keep looking
      }
    }
  }
  const electron = Boolean((process.versions as Record<string, string | undefined>).electron)
  cachedNode = { bin: process.execPath, electron, onPath: false }
  return cachedNode
}

/** Extra env a shim needs when it is launched through the Electron binary. */
export function nodeRuntimeEnv(rt: NodeRuntime): Record<string, string> {
  return rt.electron ? { ELECTRON_RUN_AS_NODE: '1' } : {}
}

/**
 * Windows named pipe — the direct analog of the macOS app's per-session Unix-domain
 * sockets. Short, unique, and filesystem-free.
 */
export function pipeNames(token: string): { hook: string; mcp: string } {
  // Forward slashes on purpose: this path is embedded inside a *shell command* in the
  // hook config, and claude runs hooks through Git Bash — bash collapses `\\` to `\`
  // inside double quotes, silently turning `\\.\pipe\x` into the invalid `\.\pipe\x`.
  // Node/libuv normalize `//./pipe/x` to the same named pipe, so no shell has to
  // preserve a backslash.
  const base = `//./pipe/vigil-${process.pid}-${token}`
  return { hook: `${base}-hook`, mcp: `${base}-mcp` }
}

export function ensureDir(dir: string): void {
  fs.mkdirSync(dir, { recursive: true })
}

export function appSupportRoot(): string {
  const base = process.env.APPDATA ?? path.join(os.homedir(), 'AppData', 'Roaming')
  return path.join(base, 'Vigil')
}
