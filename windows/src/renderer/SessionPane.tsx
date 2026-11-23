// Center pane for a live session — port of TerminalPane / DeadNodePane / BottomTerminalPanel.

import { useEffect, useRef, useState } from 'react'
import type { Appearance, TranscriptLoad, ViewNode, ViewSession, ViewState } from '../shared/protocol'
import type { Tokens } from './theme'
import { designStatus, statusColor, statusText } from './status'
import { homeAbbrev } from './format'
import { SpinnerRing } from './Sidebar'
import { TerminalView } from './TerminalView'
import { TreePanel } from './TreePanel'
import { NotifStack } from './NotifStack'
import { TranscriptView, ResumeHintBar } from './TranscriptView'
import { TerminalGlyph, XGlyph } from './icons'
import { resumeSyntaxFor } from '../shared/resume'

export function SessionPane({
  state,
  session,
  selectedNodeId,
  tokens,
  appearance,
  now,
  unseen,
  hideFinished,
  onToggleFinished,
  treeOpen,
  onSelectNode,
  deadTranscript,
  onResumeNode,
  onNoticeOpen,
  shellVisible,
  onToggleShell,
  onCloseShell,
  shellHeight,
  onShellHeight,
}: {
  state: ViewState
  session: ViewSession
  selectedNodeId: string
  tokens: Tokens
  appearance: Appearance | undefined
  now: number
  unseen: Set<string>
  hideFinished: boolean
  onToggleFinished: () => void
  treeOpen: boolean
  onSelectNode: (id: string) => void
  deadTranscript: TranscriptLoad | null
  onResumeNode: (id: string) => void
  onNoticeOpen: (sessionId: string, nodeId: string) => void
  shellVisible: boolean
  onToggleShell: () => void
  onCloseShell: () => void
  shellHeight: number
  onShellHeight: (h: number) => void
}) {
  const node = session.nodes.find((n) => n.id === selectedNodeId) ?? session.nodes.find((n) => n.id === session.rootID)!
  const terminal = isTerminal(node.status)
  const liveCell = session.hasLiveCells.includes(node.id)
  const cwd = session.cwdByNode[node.id] ?? session.projectCwd ?? ''
  const home = state.home

  return (
    <div className="session-pane">
      <NodeHeader
        node={node}
        isRoot={node.id === session.rootID}
        model={session.model}
        status={node.kind === 'observed' ? 'Running' : statusText(designStatus(node))}
        tokens={tokens}
        trailing={homeAbbrev(cwd, home)}
      />
      <div className="center-body">
        {terminal ? (
          <DeadNodePane
            node={node}
            tokens={tokens}
            transcript={deadTranscript}
            frozenFrame={null}
            canResume={(session.sessionIds[node.id] ?? null) !== null}
            kind={session.nodeKinds[node.id] ?? session.agentKind}
            onResume={() => onResumeNode(node.id)}
          />
        ) : liveCell ? (
          <TerminalView
            key={`${session.id}:${node.id}`}
            sessionId={session.id}
            nodeId={node.id}
            tokens={tokens}
            appearance={appearance}
          />
        ) : (
          <div className="ghost">
            <SpinnerRing size={22} line={2.5} />
          </div>
        )}

        <div className="overlay-column">
          {treeOpen && (
            <TreePanel
              session={session}
              selectedID={node.id}
              hideFinished={hideFinished}
              onToggleFinished={onToggleFinished}
              unseen={unseen}
              now={now}
              tokens={tokens}
              onSelect={onSelectNode}
            />
          )}
          <NotifStack
            state={state}
            activeSessionId={session.id}
            selectedNode={node.id}
            now={now}
            onOpen={onNoticeOpen}
          />
        </div>
      </div>

      {shellVisible && (
        <BottomShellPanel
          session={session}
          tokens={tokens}
          appearance={appearance}
          height={shellHeight}
          onHeight={onShellHeight}
          onClose={onCloseShell}
        />
      )}
    </div>
  )
}

function isTerminal(status: string): boolean {
  return status === 'done' || status === 'failed' || status === 'killed'
}

export function NodeHeader({
  node,
  isRoot = false,
  model,
  status,
  tokens,
  trailing,
  readOnly = false,
}: {
  node: ViewNode
  isRoot?: boolean
  model: string | null
  status: string
  tokens: Tokens
  trailing?: string
  readOnly?: boolean
}) {
  const title = isRoot ? 'root' : node.title || node.id
  return (
    <div className="node-header">
      <span className="role-glyph"><RoleGlyph kind={node.kind === 'observed' ? 'sub' : node.role === 'manager' ? 'manager' : 'leaf'} /></span>
      <span className="node-header-text">
        <span className="node-header-title">{title}</span>
        <span className="node-header-model">· {model ?? 'default'}</span>
        <span className="node-header-status">{status}</span>
        {readOnly && <span className="readonly-badge">Read-only history</span>}
      </span>
      <span className="spacer" />
      {trailing && <span className="node-header-trailing">{trailing}</span>}
    </div>
  )
}

export function RoleGlyph({ kind }: { kind: 'manager' | 'leaf' | 'sub' }) {
  const stroke = 'currentColor'
  return (
    <svg width="15" height="15" viewBox="0 0 16 16" fill="none" aria-hidden>
      {kind === 'manager' && (
        <>
          <circle cx="4.2" cy="3.8" r="1.9" fill={stroke} />
          <path d="M4.2 5.9V10h3.6" stroke={stroke} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
          <circle cx="10.6" cy="10" r="1.9" stroke={stroke} strokeWidth="1.5" />
        </>
      )}
      {kind === 'leaf' && (
        <>
          <circle cx="4.2" cy="3.8" r="1.9" stroke={stroke} strokeWidth="1.5" />
          <path d="M4.2 5.9V10h3.6" stroke={stroke} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
          <circle cx="10.6" cy="10" r="1.9" fill={stroke} />
        </>
      )}
      {kind === 'sub' && (
        <>
          <circle cx="3.1" cy="2.9" r="1.55" stroke={stroke} strokeWidth="1.4" />
          <path d="M3.1 4.6v3h2.5" stroke={stroke} strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
          <circle cx="7.3" cy="7.6" r="1.55" stroke={stroke} strokeWidth="1.4" />
          <path d="M7.3 9.3v3h2.5" stroke={stroke} strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
          <circle cx="11.5" cy="12.3" r="1.55" fill={stroke} />
        </>
      )}
    </svg>
  )
}

function DeadNodePane({
  node,
  tokens,
  transcript,
  frozenFrame,
  canResume,
  kind,
  onResume,
}: {
  node: ViewNode
  tokens: Tokens
  transcript: TranscriptLoad | null
  frozenFrame: string | null
  canResume: boolean
  kind: string
  onResume: () => void
}) {
  const design = designStatus(node)
  const pointer = transcript?.path ? 'conversation record below' : 'no transcript record'
  const hint = canResume ? `Press Enter to resume this agent (${resumeSyntaxFor(kind)})` : null
  // Enter to resume (the pane is focusable, like the macOS TranscriptHostView).
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Enter' && canResume && !e.shiftKey && !e.ctrlKey && !e.metaKey) {
        const tag = (e.target as HTMLElement)?.tagName
        if (tag === 'INPUT' || tag === 'TEXTAREA') return
        e.preventDefault()
        onResume()
      }
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [canResume, onResume])

  return (
    <div className="dead-node">
      <div className="dead-hint-row">
        <span className="dot" style={{ background: statusColor(design, tokens) }} />
        <span className="dead-hint-text">
          {statusText(design)} · this node's process has ended · {pointer}
        </span>
      </div>
      <div className="dead-body">
        {transcript?.items && transcript.items.length > 0 ? (
          <TranscriptView items={transcript.items} stats={transcript.stats} />
        ) : frozenFrame ? (
          <pre className="frozen-frame">{frozenFrame}</pre>
        ) : (
          <div className="empty-transcript">
            {transcript?.path
              ? 'No renderable conversation content in the transcript'
              : 'This node has no transcript record (never received a prompt)'}
          </div>
        )}
      </div>
      <ResumeHintBar
        hint={hint}
        readOnlyText="Read-only — this node has no resume credentials"
        onResume={onResume}
      />
    </div>
  )
}

function BottomShellPanel({
  session,
  tokens,
  appearance,
  height,
  onHeight,
  onClose,
}: {
  session: ViewSession
  tokens: Tokens
  appearance: Appearance | undefined
  height: number
  onHeight: (h: number) => void
  onClose: () => void
}) {
  const dragRef = useRef<{ startY: number; startH: number } | null>(null)
  const [dragHeight, setDragHeight] = useState<number | null>(null)
  useEffect(() => {
    const move = (e: MouseEvent) => {
      const d = dragRef.current
      if (!d) return
      const next = Math.min(Math.max(120, d.startH - (e.clientY - d.startY)), Math.floor(window.innerHeight * 0.7))
      setDragHeight(next)
    }
    const up = () => {
      if (dragRef.current && dragHeight !== null) onHeight(dragHeight)
      dragRef.current = null
      setDragHeight(null)
    }
    window.addEventListener('mousemove', move)
    window.addEventListener('mouseup', up)
    return () => {
      window.removeEventListener('mousemove', move)
      window.removeEventListener('mouseup', up)
    }
  }, [dragHeight, onHeight])

  return (
    <div className="bottom-shell" style={{ height: dragHeight ?? height }}>
      <div
        className="bottom-handle"
        onMouseDown={(e) => {
          dragRef.current = { startY: e.clientY, startH: dragHeight ?? height }
        }}
      />
      <div className="bottom-head">
        <span className="bottom-icon"><TerminalGlyph size={11} /></span>
        <span className="bottom-title">Terminal</span>
        <span className="spacer" />
        <button className="icon-btn small" title="Close terminal (ends the shell)" onClick={onClose}>
          <XGlyph />
        </button>
      </div>
      <div className="bottom-body">
        <TerminalView
          key={session.id + ':shell'}
          sessionId={session.id}
          nodeId="__shell__"
          shell
          tokens={tokens}
          appearance={appearance}
        />
      </div>
    </div>
  )
}
