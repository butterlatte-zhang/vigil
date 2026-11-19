// Vigil for Windows — one node's runtime container.
//
// Port of app/Sources/VigilRuntime/RealCell.swift on top of ConPTY (node-pty):
//   start / inject(->ack) / snapshot / terminate, plus the hold loop and the
//   closed-loop submit. The terminal is also the human's only input surface, so a
//   blind inject would append to (and submit) whatever they were mid-typing: probe the
//   input line first and hold while real user content is there.

import { createRequire } from 'node:module'
import { spawn as spawnProcess } from 'node:child_process'
import type { IPty } from 'node-pty'
import type { LaunchSpec } from './harness/types.js'
import { Screen, type InputLineProbe } from './screen.js'

const require = createRequire(import.meta.url)
const nodePty = require('node-pty') as typeof import('node-pty')

export interface InjectAck {
  delivered: boolean
  note?: string
}

export interface CellTuning {
  poll: number
  maxQueueWait: number
  holdNoticeDelay: number
  initialReadyTimeout: number
  landTimeout: number
  confirmWindow: number
  retryTimeout: number
  retryInterval: number
}

export const defaultCellTuning: CellTuning = {
  poll: 500,
  maxQueueWait: 300_000,
  holdNoticeDelay: 2000,
  initialReadyTimeout: 30_000,
  landTimeout: 5000,
  confirmWindow: 2000,
  retryTimeout: 30_000,
  retryInterval: 1000,
}

export interface CellOptions {
  nodeID: string
  launch: LaunchSpec
  cwd: string
  cols?: number
  rows?: number
  tuning?: Partial<CellTuning>
  initialPrompt?: string | null
  onData?: (data: string) => void
  onExit: (code: number | null) => void
  onInitialPromptAck?: (ack: InjectAck) => void
  onInjectHold?: (pending: number, held: boolean, epoch: number) => void
}

const REPLAY_CAP = 1_000_000

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms))
}

export class RealCell {
  readonly nodeID: string
  readonly cwd: string
  private readonly launch: LaunchSpec
  private readonly tuning: CellTuning
  private readonly screen: Screen
  private readonly onData?: (data: string) => void
  private readonly onExit: (code: number | null) => void
  private readonly onInitialPromptAck?: (ack: InjectAck) => void
  private readonly onInjectHold?: (pending: number, held: boolean, epoch: number) => void
  private proc: IPty | null = null
  private started = false
  private exited = false
  private replay = ''
  private codexState = ''
  private pendingInjects = 0
  private holdNoticed = false
  private holdSeq = 0
  private injectTail: Promise<void> = Promise.resolve()
  private disposeData: { dispose(): void } | null = null

  constructor(opts: CellOptions) {
    this.nodeID = opts.nodeID
    this.cwd = opts.cwd
    this.launch = opts.launch
    this.tuning = { ...defaultCellTuning, ...(opts.tuning ?? {}) }
    this.screen = new Screen(opts.cols ?? 100, opts.rows ?? 32)
    this.onData = opts.onData
    this.onExit = opts.onExit
    this.onInitialPromptAck = opts.onInitialPromptAck
    this.onInjectHold = opts.onInjectHold
  }

  get pid(): number | null {
    return this.proc?.pid ?? null
  }

  get isRunning(): boolean {
    return this.started && !this.exited
  }

  start(): void {
    this.started = true
    const { executable, args, env, initialPrompt } = this.launch
    let exe = executable
    let argv = args
    if (process.platform === 'win32' && /\.(cmd|bat)$/i.test(exe)) {
      exe = process.env.ComSpec || 'cmd.exe'
      argv = ['/d', '/s', '/c', executable, ...args]
    }
    this.proc = nodePty.spawn(exe, argv, {
      name: 'xterm-256color',
      cols: this.screen.cols,
      rows: this.screen.rows,
      cwd: this.cwd,
      env: env as Record<string, string>,
      useConpty: true,
    })
    this.disposeData = this.proc.onData((data) => this.handleData(data))
    this.proc.onExit(({ exitCode }) => this.handleExit(exitCode))
    if (initialPrompt && initialPrompt !== '') {
      void this.deliverInitialPrompt(initialPrompt)
    }
  }

  private handleData(data: string): void {
    const osc = /\]7501;state=([a-z]+)/.exec(data)
    if (osc) this.codexState = osc[1]
    this.replay += data
    if (this.replay.length > REPLAY_CAP) this.replay = this.replay.slice(-REPLAY_CAP)
    this.screen.write(data)
    this.onData?.(data)
  }

  private handleExit(code: number): void {
    if (this.exited) return
    this.exited = true
    this.onExit(code)
  }

  // MARK: initial prompt

  private async deliverInitialPrompt(text: string): Promise<void> {
    const deadline = Date.now() + this.tuning.initialReadyTimeout
    while (Date.now() < deadline) {
      if (this.exited) return
      if (this.screen.probe().kind === 'clear') break
      await sleep(this.tuning.poll)
    }
    try {
      const ack = await this.inject(text)
      this.onInitialPromptAck?.(ack)
    } catch {
      // fail-open: the first task is never dropped by a probe error
    }
  }

  // MARK: injection

  /** Serialized, ack-bearing injection. */
  inject(text: string): Promise<InjectAck> {
    this.pendingInjects += 1
    const previous = this.injectTail
    const job = (async () => {
      await previous
      try {
        return await this.performInject(text)
      } finally {
        this.pendingInjects -= 1
      }
    })()
    this.injectTail = job.then(
      () => undefined,
      () => undefined,
    )
    if (this.holdNoticed) {
      this.holdSeq += 1
      this.onInjectHold?.(this.pendingInjects, true, this.holdSeq)
    }
    return job
  }

  private async performInject(text: string): Promise<InjectAck> {
    if (!this.isRunning) return { delivered: false, note: 'cell not running' }

    let note: string | undefined
    let heldFailOpen = false
    if (this.screen.probe().kind === 'userTyping') {
      const queuedAt = Date.now()
      let failOpen = false
      try {
        for (;;) {
          await sleep(this.tuning.poll)
          if (this.exited) return { delivered: false, note: 'cell exited while inject queued' }
          if (this.screen.probe().kind !== 'userTyping') break
          if (Date.now() - queuedAt >= this.tuning.maxQueueWait) {
            failOpen = true
            break
          }
          if (!this.holdNoticed && Date.now() - queuedAt >= this.tuning.holdNoticeDelay) {
            this.holdNoticed = true
            this.holdSeq += 1
            this.onInjectHold?.(this.pendingInjects, true, this.holdSeq)
          }
        }
      } finally {
        if (this.holdNoticed) {
          this.holdNoticed = false
          this.holdSeq += 1
          this.onInjectHold?.(this.pendingInjects, false, this.holdSeq)
        }
      }
      heldFailOpen = failOpen
      const waited = ((Date.now() - queuedAt) / 1000).toFixed(1) + 's'
      note = failOpen
        ? `queued ${waited}: input line still busy, fail-open inject`
        : `queued ${waited}: waited for user input line to clear`
    }

    const closedLoop = !heldFailOpen && this.screen.probe().kind === 'clear'
    this.sendText(text)
    const sentAt = Date.now()
    const settle = 150
    if (!closedLoop) {
      await sleep(settle)
      this.sendRaw('\r')
      return { delivered: true, note }
    }

    const landPoll = Math.min(this.tuning.poll, 50)
    let landed: string | null = null
    let candidate: string | null = null
    let candidateSince = sentAt
    for (;;) {
      const p = this.screen.probe()
      if (p.kind === 'userTyping') {
        if (p.content !== candidate) {
          candidate = p.content
          candidateSince = Date.now()
        } else if (Date.now() - candidateSince >= settle) {
          landed = p.content
          break
        }
      } else {
        candidate = null
      }
      if (this.exited || Date.now() - sentAt >= this.tuning.landTimeout) {
        landed = candidate
        break
      }
      await sleep(landPoll)
    }
    const unsettled = settle - (Date.now() - sentAt)
    if (unsettled > 0) await sleep(unsettled)
    this.sendRaw('\r')
    if (landed === null) return { delivered: true, note }
    // Recognising OUR text across redraws: codex repaints the composer with different
    // spacing/aliasing after a swallowed Enter, so exact string equality is unreliable.
    // Compare whitespace-stripped prefixes bidirectionally.
    // codex's composer is a horizontally scrolled one-liner: a long paste is visible only
    // as its TAIL (plus a ↑/↓ scroll glyph). Recognise our text by prefix, suffix, or a
    // sufficiently long substring.
    const norm = (s: string) => s.replace(/\s+/g, '').replace(/[↑↓]/g, '')
    const oursNorm = norm(landed)
    const oursPrefix = oursNorm.slice(0, 24)
    const oursSuffix = oursNorm.slice(-24)
    const isOurs = (p: InputLineProbe): boolean => {
      if (p.kind !== 'userTyping') return false
      const n = norm(p.content)
      if (!n) return false
      // Both TUIs corrupt characters through incremental redraws (a headless VT can
      // legitimately hold an intermediate frame), so exact matching is not available.
      // A very long line in the box is our paste; a fresh human line of that size during
      // the inject window is not a realistic failure mode.
      if (n.length >= 40) return true
      const probePrefix = n.slice(0, 24)
      return (
        (oursPrefix.length > 0 && probePrefix.startsWith(oursPrefix)) ||
        (oursSuffix.length > 0 && n.endsWith(oursSuffix)) ||
        (n.length >= 8 && oursNorm.includes(n))
      )
    }
    const submittedState = () =>
      this.launch.kind === 'codex' && (this.codexState === 'running' || this.codexState === 'done')

    const confirmed = async (): Promise<boolean> => {
      const t0 = Date.now()
      for (;;) {
        if (submittedState()) return true
        if (!isOurs(this.screen.probe())) {
          // A transient clear during a redraw is not proof. Only count the box leaving
          // our text once it stays that way for a long beat.
          await sleep(800)
          if (submittedState()) return true
          if (!isOurs(this.screen.probe())) return true
        }
        if (this.exited || Date.now() - t0 >= this.tuning.confirmWindow) return false
        await sleep(landPoll)
      }
    }
    const joined = (extra?: string) => [note, extra].filter(Boolean).join('; ') || undefined

    if (await confirmed()) return { delivered: true, note }

    // Unconfirmed: a lone CR is re-sent ONLY while the probe is exactly our own text,
    // still sitting unsubmitted in the same input box.
    let extraCRs = 0
    let interval = this.tuning.retryInterval
    const retryStart = Date.now()
    while (Date.now() - retryStart < this.tuning.retryTimeout) {
      await sleep(interval)
      interval = Math.min(interval * 1.5, 5000)
      if (this.exited) {
        return { delivered: true, note: joined(`submit unconfirmed after ${1 + extraCRs} CR (stopped early)`) }
      }
      if (!isOurs(this.screen.probe())) {
        return { delivered: true, note: joined(`submit confirmed after ${extraCRs} extra CR`) }
      }
      this.sendRaw('\r')
      extraCRs += 1
      if (await confirmed()) {
        return { delivered: true, note: joined(`submit confirmed after ${extraCRs} extra CR`) }
      }
    }
    return { delivered: true, note: joined(`submit unconfirmed after ${1 + extraCRs} CR`) }
  }

  /** Paste text bracketed so embedded newlines do not submit the TUI input box. */
  private sendText(text: string): void {
    this.sendRaw(`\x1b[200~${text}\x1b[201~`)
  }

  /** Raw keystrokes from the human. */
  writeUser(data: string): void {
    this.sendRaw(data)
  }

  private sendRaw(data: string): void {
    try {
      this.proc?.write(data)
    } catch {
      // process gone; the exit path reports it
    }
  }

  resize(cols: number, rows: number): void {
    if (!this.proc) return
    try {
      this.proc.resize(Math.max(2, cols), Math.max(2, rows))
      this.screen.resize(Math.max(2, cols), Math.max(2, rows))
    } catch {
      // ignore
    }
  }

  snapshot(): string {
    return this.screen.text()
  }

  /** Diagnostics: the current probe verdict plus the attributed tail of the screen. */
  probeDump(): unknown {
    return {
      probe: this.screen.probe(),
      lines: this.screen.lines().slice(-14).map((l) => ({
        text: l.text.trimEnd(),
        dim: l.dim.filter(Boolean).length,
      })),
    }
  }

  /** Raw PTY output retained for a late-attaching renderer. */
  replayData(): string {
    return this.replay
  }

  terminate(): void {
    const pid = this.proc?.pid
    if (pid && process.platform === 'win32') {
      // ConPTY children (cmd -> node -> claude) do not always die with the pty handle.
      try {
        spawnProcess('taskkill', ['/pid', String(pid), '/T', '/F'], {
          stdio: 'ignore',
          windowsHide: true,
        }).on('error', () => undefined)
      } catch {
        // ignore
      }
    }
    try {
      this.proc?.kill()
    } catch {
      // ignore
    }
    this.disposeData?.dispose()
    this.disposeData = null
    this.screen.dispose()
  }
}

