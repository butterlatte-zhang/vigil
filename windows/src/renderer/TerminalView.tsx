// xterm.js host — the agent cell (ConPTY) or the bottom shell.

import { useEffect, useRef } from 'react'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import '@xterm/xterm/css/xterm.css'
import type { Appearance } from '../shared/protocol'
import type { Tokens } from './theme'
import { terminalTheme } from './theme'
import { send, subscribeTerminal } from './ws'

export function TerminalView({
  sessionId,
  nodeId,
  shell = false,
  tokens,
  appearance,
}: {
  sessionId: string
  nodeId: string
  shell?: boolean
  tokens: Tokens
  appearance: Appearance | undefined
}) {
  const host = useRef<HTMLDivElement | null>(null)
  const termRef = useRef<Terminal | null>(null)

  useEffect(() => {
    const prefs = appearance?.terminal
    const fontFamily =
      prefs?.fontFamily && prefs.fontFamily.length > 0
        ? prefs.fontFamily.join(', ')
        : 'Cascadia Mono, Consolas, ui-monospace, monospace'
    const fontSize = prefs?.fontSize && prefs.fontSize >= 6 && prefs.fontSize <= 72 ? prefs.fontSize : 13
    const cursorStyle =
      prefs?.cursorStyle === 'bar' || prefs?.cursorStyle === 'underline' ? prefs.cursorStyle : 'block'
    const term = new Terminal({
      theme: terminalTheme(tokens, appearance),
      fontFamily,
      fontSize,
      lineHeight: 1.15,
      cursorBlink: true,
      cursorStyle,
      scrollback: 5000,
      allowProposedApi: true,
      macOptionIsMeta: false,
    })
    termRef.current = term
    const fit = new FitAddon()
    term.loadAddon(fit)
    if (host.current) term.open(host.current)
    fit.fit()
    term.focus()

    let replayDone = false
    const buffered: string[] = []
    const flush = () => {
      replayDone = true
      for (const d of buffered.splice(0)) term.write(d)
    }
    const off = subscribeTerminal(sessionId, nodeId, (ev) => {
      if (ev.kind === 'terminal') {
        if (ev.data) term.write(ev.data)
        flush()
      } else if (ev.kind === 'pty') {
        if (replayDone) term.write(ev.data)
        else buffered.push(ev.data)
      } else {
        term.write('\r\n\x1b[2m[process exited]\x1b[0m\r\n')
      }
    })
    send(shell ? { type: 'attachShell', sessionId } : { type: 'attach', sessionId, nodeId })
    const fallback = setTimeout(flush, 700)
    const disposable = term.onData((data) =>
      send(shell ? { type: 'shellInput', sessionId, data } : { type: 'input', sessionId, nodeId, data }),
    )
    const resize = () => {
      try {
        fit.fit()
        if (shell) send({ type: 'shellResize', sessionId, cols: term.cols, rows: term.rows })
        else send({ type: 'resize', sessionId, nodeId, cols: term.cols, rows: term.rows })
      } catch {
        // not measurable yet
      }
    }
    const ro = new ResizeObserver(resize)
    if (host.current) ro.observe(host.current)
    resize()

    return () => {
      clearTimeout(fallback)
      ro.disconnect()
      disposable.dispose()
      off()
      term.dispose()
      termRef.current = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId, nodeId, shell])

  // Theme/font edits apply live to an existing terminal.
  useEffect(() => {
    const term = termRef.current
    if (!term) return
    term.options.theme = terminalTheme(tokens, appearance)
    const p = appearance?.terminal
    if (p?.fontFamily && p.fontFamily.length > 0) term.options.fontFamily = p.fontFamily.join(', ')
    if (p?.fontSize) term.options.fontSize = p.fontSize
  }, [tokens, appearance])

  return <div className="terminal-host" ref={host} />
}
