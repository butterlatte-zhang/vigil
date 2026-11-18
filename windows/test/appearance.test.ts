import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { loadAppearance } from '../src/main/appearance.js'

const dirs: string[] = []
function tmp(): string {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'vigil-appearance-'))
  dirs.push(d)
  return d
}
afterEach(() => {
  for (const d of dirs.splice(0)) fs.rmSync(d, { recursive: true, force: true })
})

describe('appearance.json', () => {
  it('defaults to auto/blue with no file', () => {
    const a = loadAppearance(tmp())
    expect(a.theme).toBe('auto')
    expect(a.accent).toBe('blue')
  })

  it('parses a pin and accent, and tolerates garbage fields', () => {
    const d = tmp()
    fs.writeFileSync(
      path.join(d, 'appearance.json'),
      JSON.stringify({ theme: 'dark', accent: 'teal', terminal: { fontSize: 14, fontFamily: ['Cascadia Mono'], cursorStyle: 'bar' } }),
    )
    const a = loadAppearance(d)
    expect(a.theme).toBe('dark')
    expect(a.accent).toBe('teal')
    expect(a.terminal.fontSize).toBe(14)
    expect(a.terminal.fontFamily).toEqual(['Cascadia Mono'])

    fs.writeFileSync(path.join(d, 'appearance.json'), JSON.stringify({ theme: 'weird', accent: 'nope', terminal: 'x' }))
    const b = loadAppearance(d)
    expect(b.theme).toBe('auto')
    expect(b.accent).toBe('blue')
  })
})
