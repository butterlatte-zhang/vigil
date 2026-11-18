// Vigil for Windows — headless screen + input-line probe.
//
// Port of the macOS app's libghostty-vt headless path (VtScreen / HostScreenParser) and
// RealCell.probeInputLine. Each cell keeps a headless xterm running its PTY stream so the
// orchestrator can ask "what is on screen?" — the same question the Swift app answers with
// libghostty-vt. Injection holds, the first-prompt readiness gate and the closed-loop
// submit all read this probe.

import { createRequire } from 'node:module'
import type * as XtermHeadless from '@xterm/headless'

// @xterm/headless is CommonJS; Node's ESM named-export detection does not see
// `Terminal`, so resolve it through createRequire.
const nodeRequire = createRequire(import.meta.url)
const { Terminal } = nodeRequire('@xterm/headless') as typeof XtermHeadless

export interface AttributedLine {
  text: string
  /** dim flag per character, aligned with `text` */
  dim: boolean[]
}

export type InputLineProbe =
  | { kind: 'clear' }
  | { kind: 'userTyping'; content: string }
  | { kind: 'unknown' }

const RULE_MIN_RUN = 20
const MODE_PREFIXES = new Set(['❯', '!', '#', '>'])
const CODEX_PROMPT_PREFIX = '›'
const OPENCODE_PROMPT_PREFIX = '┃'
const OPENCODE_PLACEHOLDER_LEAD = 'Ask anything'

export class Screen {
  readonly term: XtermHeadless.Terminal
  private disposed = false

  constructor(
    public cols = 100,
    public rows = 32,
  ) {
    this.term = new Terminal({
      cols,
      rows,
      allowProposedApi: true,
      scrollback: 4000,
    })
  }

  write(data: string): void {
    if (this.disposed) return
    this.term.write(data)
  }

  resize(cols: number, rows: number): void {
    if (this.disposed) return
    this.cols = cols
    this.rows = rows
    this.term.resize(cols, rows)
  }

  /** The visible screen as attributed lines. */
  lines(): AttributedLine[] {
    const buf = this.term.buffer.active
    const out: AttributedLine[] = []
    const start = buf.viewportY
    for (let y = 0; y < this.rows; y++) {
      const line = buf.getLine(start + y)
      if (!line) {
        out.push({ text: '', dim: [] })
        continue
      }
      let text = ''
      const dim: boolean[] = []
      for (let x = 0; x < this.cols; x++) {
        const cell = line.getCell(x)
        if (!cell) {
          text += ' '
          dim.push(false)
          continue
        }
        const chars = cell.getChars()
        const c = chars.length > 0 ? chars : ' '
        const isDim = Boolean(cell.isDim())
        for (let i = 0; i < c.length; i++) {
          dim.push(isDim)
        }
        text += c
      }
      out.push({ text, dim })
    }
    return out
  }

  text(): string {
    return this.lines()
      .map((l) => l.text)
      .join('\n')
  }

  probe(): InputLineProbe {
    return probeInputLine(this.lines())
  }

  dispose(): void {
    if (this.disposed) return
    this.disposed = true
    try {
      this.term.dispose()
    } catch {
      // ignore
    }
  }
}

// MARK: - probe (port of RealCell.probeInputLine)

export function probeInputLine(lines: AttributedLine[]): InputLineProbe {
  const dim = probeDimInputLine(lines)
  if (dim) return dim
  const codex = probeCodexComposerLine(lines)
  if (codex) return codex
  const opencode = probeOpenCodeComposerLine(lines)
  if (opencode) return opencode
  return probeBoxInputLine(lines)
}

function isRuleLine(text: string): boolean {
  const t = text.trim()
  return t.length >= RULE_MIN_RUN && [...t].every((c) => c === '─')
}

function isProbeWhitespace(c: string): boolean {
  // Unicode whitespace incl. NBSP (claude pads the prefix with NBSP).
  return /^[\s ]$/u.test(c)
}

function isPlaceholderText(trimmed: string): boolean {
  return trimmed.startsWith('Try "') && trimmed.endsWith('"') && trimmed.length > 5
}

function stripModePrefix(line: AttributedLine): { rest: string; restDim: boolean[] } | null {
  const chars = [...line.text]
  let i = 0
  while (i < chars.length && isProbeWhitespace(chars[i])) i++
  if (i >= chars.length || !MODE_PREFIXES.has(chars[i])) return null
  i++
  while (i < chars.length && isProbeWhitespace(chars[i])) i++
  return { rest: chars.slice(i).join(''), restDim: line.dim.slice(i) }
}

function bottomRulePair(lines: AttributedLine[]): [number, number] | null {
  let bottom: number | null = null
  for (let i = lines.length - 1; i >= 0; i--) {
    if (!isRuleLine(lines[i].text)) continue
    if (bottom !== null) return [i, bottom]
    bottom = i
  }
  return null
}

function probeDimInputLine(lines: AttributedLine[]): InputLineProbe | null {
  const pair = bottomRulePair(lines)
  if (!pair) return null
  const [top, bottom] = pair
  const content = lines.slice(top + 1, bottom)
  if (content.every((l) => l.text.trim() === '')) return { kind: 'clear' }
  for (const line of content) {
    const stripped = stripModePrefix(line)
    if (!stripped) continue
    const trimmed = stripped.rest.trim()
    if (trimmed === '') return { kind: 'clear' }
    if (stripped.restDim[0] === true) return { kind: 'clear' }
    if (isPlaceholderText(trimmed)) return { kind: 'clear' }
    return { kind: 'userTyping', content: trimmed }
  }
  return null
}

function probeCodexComposerLine(lines: AttributedLine[]): InputLineProbe | null {
  for (let li = lines.length - 1; li >= 0; li--) {
    const line = lines[li]
    const chars = [...line.text]
    let i = 0
    while (i < chars.length && isProbeWhitespace(chars[i])) i++
    if (i >= chars.length || chars[i] !== CODEX_PROMPT_PREFIX) continue
    i++
    while (i < chars.length && isProbeWhitespace(chars[i])) i++
    const contentStart = i
    const rest = chars.slice(contentStart).join('').trim()
    if (rest === '') return { kind: 'clear' }
    const dimmed = contentStart < line.dim.length ? line.dim[contentStart] : false
    if (dimmed) return { kind: 'clear' }
    return { kind: 'userTyping', content: rest }
  }
  return null
}

function probeOpenCodeComposerLine(lines: AttributedLine[]): InputLineProbe | null {
  for (let li = lines.length - 1; li >= 0; li--) {
    const chars = [...lines[li].text]
    let i = 0
    while (i < chars.length && isProbeWhitespace(chars[i])) i++
    if (i >= chars.length || chars[i] !== OPENCODE_PROMPT_PREFIX) continue
    i++
    while (i < chars.length && isProbeWhitespace(chars[i])) i++
    const rest = chars.slice(i).join('').trim()
    if (rest.startsWith(OPENCODE_PLACEHOLDER_LEAD)) return { kind: 'clear' }
  }
  return null
}

function probeBoxInputLine(lines: AttributedLine[]): InputLineProbe {
  for (let li = lines.length - 1; li >= 0; li--) {
    let line = lines[li].text.trim()
    if (!line.startsWith('│')) continue
    let body = line.slice(1)
    if (body.endsWith('│')) body = body.slice(0, -1)
    const inner = body.trim()
    if (!inner.startsWith('>')) continue
    if (inner.startsWith('>_')) continue
    const content = inner.slice(1).trim()
    return content === '' ? { kind: 'clear' } : { kind: 'userTyping', content }
  }
  return { kind: 'unknown' }
}
