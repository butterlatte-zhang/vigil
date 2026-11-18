// Per-family resume syntax, shown verbatim in dead-node/history hints.

export function resumeSyntaxFor(kind: string): string {
  switch (kind) {
    case 'codex':
      return 'codex resume'
    case 'opencode':
      return 'opencode --session'
    default:
      return 'claude --resume'
  }
}
