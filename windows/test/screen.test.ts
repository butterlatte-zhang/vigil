import { describe, expect, it } from 'vitest'
import { probeInputLine, type AttributedLine } from '../src/main/screen.js'

/** Build an attributed line; `dimFrom` marks a dim character range. */
function line(text: string, dimFrom = -1, dimTo = -1): AttributedLine {
  const dim = [...text].map((_, i) => i >= dimFrom && i < dimTo)
  return { text, dim }
}

const rule = '─'.repeat(80)
const pad = ' '.repeat(80)

describe('claude dim-rule input line', () => {
  it('reads an empty typed box as clear', () => {
    const screen = [line('history'), line(rule), line('❯ ' + pad), line(rule)]
    expect(probeInputLine(screen)).toEqual({ kind: 'clear' })
  })

  it('reads a plain placeholder as clear and a non-dim line as typing', () => {
    const placeholder = line('❯ Try "fix the tests"', 2, '❯ Try "fix the tests"'.length)
    expect(probeInputLine([line(rule), placeholder, line(rule)])).toEqual({ kind: 'clear' })
    expect(probeInputLine([line(rule), line('❯ real typing'), line(rule)])).toEqual({
      kind: 'userTyping',
      content: 'real typing',
    })
  })

  it('ignores a permission box (not rule-bracketed) and reports unknown', () => {
    const screen = [line('│ Do you want to proceed? │'), line('│ ❯ 1. Yes 2. No │')]
    expect(probeInputLine(screen).kind).toBe('unknown')
  })

  it('reads a rule-bracketed box with no mode prefix as unknown', () => {
    expect(probeInputLine([line(rule), line('some content'), line(rule)]).kind).toBe('unknown')
  })
})

describe('codex composer', () => {
  it('dim placeholder = clear, plain text = typing', () => {
    const dimPlaceholder = line('› Ask Codex to do anything', 2, '› Ask Codex to do anything'.length)
    expect(probeInputLine([line('transcript'), dimPlaceholder])).toEqual({ kind: 'clear' })
    expect(probeInputLine([line('transcript'), line('› fix the bug')])).toEqual({
      kind: 'userTyping',
      content: 'fix the bug',
    })
  })

  it('does not mistake the codex header banner for a composer', () => {
    expect(probeInputLine([line('│ >_ OpenAI Codex (v0.144) │')]).kind).toBe('unknown')
  })
})

describe('opencode composer', () => {
  it('only the placeholder yields a verdict', () => {
    expect(probeInputLine([line('┃  Ask anything')])).toEqual({ kind: 'clear' })
    expect(probeInputLine([line('┃  Build · gpt-5')]).kind).toBe('unknown')
    expect(probeInputLine([line('┃  some typed text')]).kind).toBe('unknown')
  })
})

describe('box fallback', () => {
  it('reads │ > … │ as an input line', () => {
    expect(probeInputLine([line('│ >  │')])).toEqual({ kind: 'clear' })
    expect(probeInputLine([line('│ > hello │')])).toEqual({ kind: 'userTyping', content: 'hello' })
  })
})

describe('Screen (headless VT)', () => {
  it('renders written text and reports the composer after a redraw', async () => {
    const { Screen } = await import('../src/main/screen.js')
    const s = new Screen(60, 10)
    const out = await new Promise<string>((resolve) => {
      s.write('hello\r\n› typed text')
      setTimeout(() => resolve(s.text()), 50)
    })
    expect(out).toContain('hello')
    expect(s.probe()).toEqual({ kind: 'userTyping', content: 'typed text' })
    s.dispose()
  })
})
