// Node tree panel — port of TreePanel.swift / HistoryTreePanel.swift.

import { useEffect, useRef } from 'react'
import type { ViewNode, ViewSession } from '../shared/protocol'
import type { Tokens } from './theme'
import { designStatus, dotClass, statusColor, type DotClass, type DStatus } from './status'
import { runtimeSeconds } from './format'
import { SpinnerRing } from './Sidebar'

export interface DisplayRow {
  node: ViewNode
  depth: number
  lineage: boolean[]
}

export function flattenTree(nodes: ViewNode[], rootID: string, hideFinished: boolean): DisplayRow[] {
  const byId = new Map(nodes.map((n) => [n.id, n]))
  const out: DisplayRow[] = []
  const walk = (id: string, depth: number, lineage: boolean[]) => {
    const node = byId.get(id)
    if (!node) return
    out.push({ node, depth, lineage })
    const kids = node.children
      .map((c) => byId.get(c))
      .filter((n): n is ViewNode => Boolean(n))
      .filter((n) => !hideFinished || !isTerminal(n.status))
    kids.forEach((kid, i) => walk(kid.id, depth + 1, [...lineage, i === kids.length - 1]))
  }
  walk(rootID, 0, [])
  return out
}

function isTerminal(status: string): boolean {
  return status === 'done' || status === 'failed' || status === 'killed'
}

export function nodeRuntimeText(node: ViewNode, now: number): string {
  if (designStatus(node) === 'starting') return '—'
  if (node.startedAt === null) return '—'
  return runtimeSeconds(node.startedAt, node.endedAt, now)
}

export function TreePanel({
  session,
  selectedID,
  hideFinished,
  onToggleFinished,
  unseen,
  now,
  tokens,
  onSelect,
}: {
  session: ViewSession
  selectedID: string
  hideFinished: boolean
  onToggleFinished: () => void
  unseen: Set<string>
  now: number
  tokens: Tokens
  onSelect: (id: string) => void
}) {
  const rows = flattenTree(session.nodes, session.rootID, hideFinished)
  const finished = session.nodes.filter((n) => isTerminal(n.status) && n.id !== session.rootID).length
  return (
    <div className="overlay-card tree-card">
      <div className="card-head">
        <span className="card-title">Tree</span>
        <span className="spacer" />
        {finished > 0 && (
          <button className="link-btn" onClick={onToggleFinished}>
            {hideFinished ? `Show finished ${finished}` : 'Hide finished'}
          </button>
        )}
        <span className="card-meta">{rows.length} nodes</span>
      </div>
      <TreeList
        rows={rows}
        selectedID={selectedID}
        now={now}
        tokens={tokens}
        unseen={unseen}
        onSelect={onSelect}
        live
      />
    </div>
  )
}

export function HistoryTreePanel({
  nodes,
  rootID,
  selectedID,
  lastEventAt,
  tokens,
  onSelect,
}: {
  nodes: ViewNode[]
  rootID: string | null
  selectedID: string | null
  lastEventAt: number | null
  tokens: Tokens
  onSelect: (id: string) => void
}) {
  if (!rootID) return null
  const rows = flattenTree(nodes, rootID, false)
  const now = lastEventAt ?? Date.now()
  return (
    <div className="overlay-card tree-card">
      <div className="card-head">
        <span className="card-title">Tree · History</span>
        <span className="spacer" />
        <span className="card-meta">{rows.length} nodes</span>
      </div>
      <TreeList
        rows={rows}
        selectedID={selectedID ?? ''}
        now={now}
        tokens={tokens}
        unseen={new Set()}
        onSelect={onSelect}
        live={false}
        timeLeadingPad={10}
      />
    </div>
  )
}

function TreeList({
  rows,
  selectedID,
  now,
  tokens,
  unseen,
  onSelect,
  live,
  timeLeadingPad = 0,
}: {
  rows: DisplayRow[]
  selectedID: string
  now: number
  tokens: Tokens
  unseen: Set<string>
  onSelect: (id: string) => void
  live: boolean
  timeLeadingPad?: number
}) {
  const refs = useRef(new Map<string, HTMLButtonElement>())
  useEffect(() => {
    const el = refs.current.get(selectedID)
    if (el) el.scrollIntoView({ block: 'center', behavior: 'smooth' })
  }, [selectedID, rows.length])

  return (
    <div className="tree-list">
      {rows.map((row) => {
        const dot: DotClass =
          !live
            ? 'plain'
            : row.node.kind === 'observed'
              ? 'spinner'
              : dotClass(row.node.status, unseen.has(row.node.id))
        return (
          <button
            key={row.node.id}
            ref={(el) => {
              if (el) refs.current.set(row.node.id, el)
              else refs.current.delete(row.node.id)
            }}
            className={`node-row ${selectedID === row.node.id ? 'selected' : ''} ${
              isTerminal(row.node.status) ? 'terminal' : ''
            }`}
            onClick={() => onSelect(row.node.id)}
            title={row.node.title}
          >
            {row.lineage.map((isLast, level) => {
              const kind =
                level < row.depth - 1 ? (isLast ? 'blank' : 'vline') : isLast ? 'ell' : 'tee'
              return <Connector key={level} kind={kind} />
            })}
            <span className="node-dot">
              <NodeDot dot={dot} status={row.node.status} live={live} tokens={tokens} />
            </span>
            <span className="node-id">{row.node.id}</span>
            <span className={`node-title ${row.node.role === 'manager' ? 'manager' : ''}`}>
              {row.node.title || row.node.id}
            </span>
            <span className="spacer" />
            <span className="node-time" style={{ paddingLeft: timeLeadingPad }}>
              {nodeRuntimeText(row.node, now)}
            </span>
          </button>
        )
      })}
    </div>
  )
}

function NodeDot({
  dot,
  status,
  live,
  tokens,
}: {
  dot: DotClass
  status: string
  live: boolean
  tokens: Tokens
}) {
  if (!live) {
    return <span className="dot" style={{ background: statusColor(status as DStatus, tokens) }} />
  }
  switch (dot) {
    case 'spinner':
      return <SpinnerRing size={9} line={1.5} />
    case 'blue':
      return <span className="dot" style={{ background: tokens.accentHex }} />
    case 'yellow':
      return <span className="dot" style={{ background: tokens.warn }} />
    default:
      return <span className="dot ring" style={{ borderColor: tokens.text2 }} />
  }
}

function Connector({ kind }: { kind: 'blank' | 'vline' | 'tee' | 'ell' }) {
  if (kind === 'blank') return <span className="connector" />
  return (
    <span className="connector">
      {(kind === 'vline' || kind === 'tee') && <span className="conn-v" />}
      {kind === 'ell' && <span className="conn-v short" />}
      {(kind === 'tee' || kind === 'ell') && <span className="conn-h" />}
    </span>
  )
}
