// Vigil for Windows — the bottom scratch shell.
//
// Port of BottomShell.swift's model: a plain shell on the same ConPTY machinery, with
// every agent layer stripped off. It is NOT a node in the tree (no orchestration.jsonl,
// no MCP, no hooks, no reaper) and it dies with its session. The macOS app launches an
// interactive login $SHELL; Windows uses runtime.json `bottomShellCommand` when set,
// otherwise %COMSPEC% (cmd.exe), with the same inherited env + TERM.

import { createRequire } from 'node:module'
import type { IPty } from 'node-pty'
import { loadRuntime } from '../core/config.js'

const require = createRequire(import.meta.url)
const nodePty = require('node-pty') as typeof import('node-pty')

export interface BottomShellOptions {
  cwd: string
  configDir: string
  cols?: number
  rows?: number
  onData: (data: string) => void
  onExit: () => void
}

export class BottomShell {
  private proc: IPty | null = null
  private replay = ''
  private disposed = false

  constructor(private readonly opts: BottomShellOptions) {}

  get running(): boolean {
    return this.proc !== null
  }

  start(): void {
    if (this.proc) return
    const cfg = loadRuntime(this.opts.configDir)
    const configured = cfg.bottomShellCommand.trim()
    const exe = configured || process.env.ComSpec || process.env.COMSPEC || 'cmd.exe'
    const args = configured ? [] : ['/d']
    const env: Record<string, string> = {}
    for (const [k, v] of Object.entries(process.env)) if (typeof v === 'string') env[k] = v
    env.TERM = 'xterm-256color'
    this.proc = nodePty.spawn(exe, args, {
      name: 'xterm-256color',
      cols: this.opts.cols ?? 120,
      rows: this.opts.rows ?? 20,
      cwd: this.opts.cwd,
      env,
      useConpty: true,
    })
    this.proc.onData((data) => {
      if (this.disposed) return
      this.replay += data
      if (this.replay.length > 500_000) this.replay = this.replay.slice(-500_000)
      this.opts.onData(data)
    })
    this.proc.onExit(() => {
      if (this.disposed) return
      this.proc = null
      this.opts.onExit()
    })
  }

  write(data: string): void {
    try {
      this.proc?.write(data)
    } catch {
      // shell gone
    }
  }

  resize(cols: number, rows: number): void {
    try {
      this.proc?.resize(Math.max(2, cols), Math.max(2, rows))
    } catch {
      // ignore
    }
  }

  replayData(): string {
    return this.replay
  }

  terminate(): void {
    this.disposed = true
    try {
      this.proc?.kill()
    } catch {
      // ignore
    }
    this.proc = null
  }
}
