// Vigil for Windows — appearance.json (theme / accent / terminal prefs).
//
// Port of the appearance half of UserConfig.swift + Theme.swift. The renderer reads
// `theme` / `accent` from state and resolves "auto" against prefers-color-scheme.

import fs from 'node:fs'
import path from 'node:path'

export type ThemePreference = 'auto' | 'dark' | 'light'
export type Accent = 'blue' | 'teal' | 'amber' | 'purple'

export interface TerminalPrefs {
  fontFamily: string[]
  fontSize: number | null
  cursorStyle: string | null
  padding: number | null
  background: string | null
  foreground: string | null
  cursorColor: string | null
}

export interface Appearance {
  theme: ThemePreference
  accent: Accent
  terminal: TerminalPrefs
}

export const defaultAppearance: Appearance = {
  theme: 'auto',
  accent: 'blue',
  terminal: {
    fontFamily: [],
    fontSize: null,
    cursorStyle: null,
    padding: null,
    background: null,
    foreground: null,
    cursorColor: null,
  },
}

let cache: { path: string; mtime: number; value: Appearance } | null = null

export function loadAppearance(configDir: string): Appearance {
  const p = path.join(configDir, 'appearance.json')
  let mtime = 0
  try {
    mtime = fs.statSync(p).mtimeMs
  } catch {
    return defaultAppearance
  }
  if (cache && cache.path === p && cache.mtime === mtime) return cache.value
  let value: Appearance = defaultAppearance
  try {
    const dto = JSON.parse(fs.readFileSync(p, 'utf8'))
    const theme: ThemePreference =
      dto?.theme === 'dark' || dto?.theme === 'light' ? dto.theme : 'auto'
    const accent: Accent =
      dto?.accent === 'teal' || dto?.accent === 'amber' || dto?.accent === 'purple'
        ? dto.accent
        : 'blue'
    const t = dto?.terminal ?? {}
    const strOrNull = (v: unknown) => (typeof v === 'string' && v.length > 0 ? v : null)
    value = {
      theme,
      accent,
      terminal: {
        fontFamily: Array.isArray(t.fontFamily)
          ? t.fontFamily.filter((x: unknown) => typeof x === 'string')
          : [],
        fontSize: typeof t.fontSize === 'number' ? t.fontSize : null,
        cursorStyle: strOrNull(t.cursorStyle),
        padding: typeof t.padding === 'number' ? t.padding : null,
        background: strOrNull(t.background),
        foreground: strOrNull(t.foreground),
        cursorColor: strOrNull(t.cursorColor),
      },
    }
  } catch {
    value = defaultAppearance
  }
  cache = { path: p, mtime, value }
  return value
}
