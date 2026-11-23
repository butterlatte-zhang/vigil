// Windows-conventional key handling for the xterm surface.
//
// xterm.js only ever sees a bare CR for Enter and Shift+Enter (ConPTY cannot tell them
// apart), sends ^V for Ctrl+V, and cannot copy its own selection with the browser's copy
// command. These rules translate the Windows habits — Shift+Enter newline, Ctrl+C copy
// when something is selected, Ctrl+V paste in the scratch shell — into what the PTY and
// the clipboard need. Kept pure so it is unit-tested away from the DOM.

export interface TerminalKey {
  type: string
  key?: string
  code?: string
  shiftKey: boolean
  ctrlKey: boolean
  altKey: boolean
  metaKey: boolean
}

export type TerminalKeyAction =
  /** Insert a newline instead of submitting (agent cells only). */
  | { kind: 'newline' }
  /** Copy the terminal's selection and consume the key. */
  | { kind: 'copy' }
  /** Read the clipboard and paste into the shell. */
  | { kind: 'paste' }

export function terminalKeyAction(
  ev: TerminalKey,
  opts: { shell: boolean; hasSelection: boolean },
): TerminalKeyAction | null {
  if (ev.metaKey) return null

  // Shift+Enter fires both keydown and keypress; the caller sends the newline once and
  // swallows both events. Alt+Enter keeps xterm's own ESC+CR path.
  if (!opts.shell && ev.shiftKey && !ev.ctrlKey && !ev.altKey && ev.key === 'Enter') {
    return { kind: 'newline' }
  }

  if (ev.type !== 'keydown') return null
  const ctrl = ev.ctrlKey && !ev.altKey
  const isC = ev.code === 'KeyC' || ev.key?.toLowerCase() === 'c'
  // Ctrl+Shift+C always copies; plain Ctrl+C copies only when there is a selection, so
  // an unselected Ctrl+C still reaches the agent as the interrupt.
  if (ctrl && isC && (ev.shiftKey || opts.hasSelection)) return { kind: 'copy' }
  // The scratch shell is a plain cmd/PowerShell prompt, where Ctrl+V should paste.
  // Agent TUIs keep Ctrl+V for their own clipboard handling (Claude Code pastes images).
  if (opts.shell && ctrl && !ev.shiftKey && (ev.code === 'KeyV' || ev.key?.toLowerCase() === 'v')) {
    return { kind: 'paste' }
  }
  return null
}
