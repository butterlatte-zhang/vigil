import { describe, expect, it } from 'vitest'
import { terminalKeyAction, type TerminalKey } from '../src/shared/keymap.js'

function key(overrides: Partial<TerminalKey>): TerminalKey {
  return {
    type: 'keydown',
    key: '',
    code: '',
    shiftKey: false,
    ctrlKey: false,
    altKey: false,
    metaKey: false,
    ...overrides,
  }
}

const agent = { shell: false, hasSelection: false }
const shell = { shell: true, hasSelection: false }
const selectedAgent = { shell: false, hasSelection: true }

describe('terminal key map', () => {
  it('turns Shift+Enter into a newline in an agent cell', () => {
    const ev = key({ key: 'Enter', code: 'Enter', shiftKey: true })
    expect(terminalKeyAction(ev, agent)).toEqual({ kind: 'newline' })
    // keypress carries the same modifiers and must be swallowed too
    expect(terminalKeyAction({ ...ev, type: 'keypress' }, agent)).toEqual({ kind: 'newline' })
  })

  it('leaves plain Enter and Alt+Enter to xterm', () => {
    expect(terminalKeyAction(key({ key: 'Enter', code: 'Enter' }), agent)).toBeNull()
    expect(terminalKeyAction(key({ key: 'Enter', code: 'Enter', altKey: true }), agent)).toBeNull()
    expect(terminalKeyAction(key({ key: 'Enter', code: 'Enter', ctrlKey: true }), agent)).toBeNull()
  })

  it('does not remap Shift+Enter in the scratch shell', () => {
    expect(terminalKeyAction(key({ key: 'Enter', code: 'Enter', shiftKey: true }), shell)).toBeNull()
  })

  it('copies on Ctrl+Shift+C and on Ctrl+C with a selection', () => {
    expect(terminalKeyAction(key({ key: 'C', code: 'KeyC', ctrlKey: true, shiftKey: true }), agent)).toEqual({ kind: 'copy' })
    expect(terminalKeyAction(key({ key: 'c', code: 'KeyC', ctrlKey: true }), selectedAgent)).toEqual({ kind: 'copy' })
    expect(terminalKeyAction(key({ key: 'C', code: 'KeyC', ctrlKey: true, shiftKey: true }), shell)).toEqual({ kind: 'copy' })
  })

  it('leaves Ctrl+C as the interrupt when nothing is selected', () => {
    expect(terminalKeyAction(key({ key: 'c', code: 'KeyC', ctrlKey: true }), agent)).toBeNull()
    expect(terminalKeyAction(key({ key: 'c', code: 'KeyC', ctrlKey: true }), shell)).toBeNull()
  })

  it('pastes on Ctrl+V in the shell only', () => {
    expect(terminalKeyAction(key({ key: 'v', code: 'KeyV', ctrlKey: true }), shell)).toEqual({ kind: 'paste' })
    expect(terminalKeyAction(key({ key: 'v', code: 'KeyV', ctrlKey: true }), agent)).toBeNull()
    expect(terminalKeyAction(key({ key: 'v', code: 'KeyV', ctrlKey: true, shiftKey: true }), shell)).toBeNull()
  })

  it('ignores keypress for the clipboard chords and anything with Meta', () => {
    expect(terminalKeyAction(key({ key: 'C', code: 'KeyC', ctrlKey: true, shiftKey: true, type: 'keypress' }), agent)).toBeNull()
    expect(terminalKeyAction(key({ key: 'Enter', code: 'Enter', shiftKey: true, metaKey: true }), agent)).toBeNull()
  })
})
