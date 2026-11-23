// Design tokens — port of app/Sources/VigilApp/Theme.swift. The CSS variables in
// styles.css carry the same values for layout chrome; these TS tokens cover the terminal
// palette and the few inline SVG colors.

import type { Appearance } from '../shared/protocol'

export type VGTheme = 'dark' | 'light'
export type VGAccent = 'blue' | 'teal' | 'amber' | 'purple'

export interface Tokens {
  theme: VGTheme
  accentHex: string
  term: string
  panelSolid: string
  card: string
  hair: string
  hair2: string
  text: string
  text2: string
  text3: string
  nodeLine: string
  spinring: string
  green: string
  red: string
  warn: string
  accent: string
  termBG: string
  termFG: string
  termCaret: string
}

export function accentHexFor(theme: VGTheme, accent: VGAccent): string {
  switch (accent) {
    case 'teal':
      return theme === 'dark' ? '#2BC4B0' : '#0FA594'
    case 'amber':
      return '#FF9F0A'
    case 'purple':
      return theme === 'dark' ? '#BF5AF2' : '#9D4EDD'
    default:
      return theme === 'dark' ? '#0A84FF' : '#007AFF'
  }
}

export function makeTokens(theme: VGTheme, accent: VGAccent): Tokens {
  const accentHex = accentHexFor(theme, accent)
  if (theme === 'dark') {
    return {
      theme,
      accentHex,
      term: '#161719',
      panelSolid: '#202126',
      card: '#26272c',
      hair: 'rgba(255,255,255,0.085)',
      hair2: 'rgba(255,255,255,0.15)',
      text: 'rgba(255,255,255,0.93)',
      text2: 'rgba(255,255,255,0.56)',
      text3: 'rgba(255,255,255,0.32)',
      nodeLine: 'rgba(255,255,255,0.15)',
      spinring: 'rgba(255,255,255,0.18)',
      green: '#30D158',
      red: '#FF453A',
      warn: '#FF9F0A',
      accent: accentHex,
      termBG: '#161719',
      termFG: '#EDEDEF',
      termCaret: accentHex,
    }
  }
  return {
    theme,
    accentHex,
    term: '#FBFBFD',
    panelSolid: '#F4F4F6',
    card: '#FFFFFF',
    hair: 'rgba(0,0,0,0.1)',
    hair2: 'rgba(0,0,0,0.15)',
    text: 'rgba(0,0,0,0.88)',
    text2: 'rgba(0,0,0,0.5)',
    text3: 'rgba(0,0,0,0.3)',
    nodeLine: 'rgba(0,0,0,0.15)',
    spinring: 'rgba(0,0,0,0.165)',
    green: '#28C840',
    red: '#FF3B30',
    warn: '#E8890C',
    accent: accentHex,
    termBG: '#FBFBFD',
    termFG: 'rgba(0,0,0,0.88)',
    termCaret: accentHex,
  }
}

export function resolveTheme(appearance: Appearance | undefined): VGTheme {
  if (appearance?.theme === 'dark' || appearance?.theme === 'light') return appearance.theme
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
}

/** xterm.js palette built from the Vigil tokens (background/foreground/cursor are the
 *  theme's built-in values unless appearance.json overrides them). */
export function terminalTheme(tokens: Tokens, appearance: Appearance | undefined) {
  const t = appearance?.terminal
  const dark = tokens.theme === 'dark'
  const background = t?.background && t.background !== 'auto' ? t.background : tokens.termBG
  const foreground = t?.foreground && t.foreground !== 'auto' ? t.foreground : tokens.termFG
  const cursor = t?.cursorColor && t.cursorColor !== 'auto' ? t.cursorColor : tokens.termCaret
  return {
    background,
    foreground,
    cursor,
    cursorAccent: background,
    selectionBackground: dark ? 'rgba(255,255,255,0.20)' : 'rgba(0,0,0,0.16)',
    black: dark ? '#1B1C20' : '#3B3B3D',
    red: dark ? '#FF453A' : '#C41A16',
    green: dark ? '#30D158' : '#0E7A20',
    yellow: dark ? '#FF9F0A' : '#8A6100',
    blue: dark ? '#0A84FF' : '#0059C8',
    magenta: dark ? '#BF5AF2' : '#9D30C8',
    cyan: dark ? '#2BC4B0' : '#08887B',
    white: dark ? '#D8D8DC' : '#C7C7CC',
    brightBlack: dark ? '#5A5B61' : '#8E8E93',
    brightRed: dark ? '#FF6961' : '#FF3B30',
    brightGreen: dark ? '#4BE36F' : '#28A745',
    brightYellow: dark ? '#FFB340' : '#B8860B',
    brightBlue: dark ? '#409CFF' : '#007AFF',
    brightMagenta: dark ? '#D07BFF' : '#BF5AF2',
    brightCyan: dark ? '#5FE0CD' : '#2BC4B0',
    brightWhite: dark ? '#FFFFFF' : '#000000',
  }
}
