import { useEffect, useMemo, useRef, useState } from 'react'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import '@xterm/xterm/css/xterm.css'
import {
  onHistory,
  onHistoryTranscript,
  onSessionStarted,
  onState,
  onToast,
  send,
  subscribeTerminal,
} from './ws'
import type {
  HistoryDetail,
  NodeStatus,
  ViewNode,
  ViewSession,
  ViewState,
} from '../shared/protocol'

const TERM_THEME = {
  background: '#161719',
  foreground: '#ececee',
  cursor: '#0a84ff',
  cursorAccent: '#161719',
  selectionBackground: 'rgba(10,132,255,0.30)',
  black: '#1b1c20',
  red: '#ff453a',
  green: '#30d158',
  yellow: '#ff9f0a',
  blue: '#0a84ff',
  magenta: '#bf5af2',
  cyan: '#2bc4b0',
  white: '#d8d8dc',
  brightBlack: '#5a5b61',
  brightRed: '#ff6961',
  brightGreen: '#4be36f',
  brightYellow: '#ffb340',
  brightBlue: '#409cff',
  brightMagenta: '#d07bff',
  brightCyan: '#5fe0cd',
  brightWhite: '#ffffff',
}

function statusLabel(s: NodeStatus): string {
  switch (s) {
    case 'starting':
      return 'starting'
    case 'running':
      return 'running'
    case 'idle':
      return 'idle'
    case 'waiting':
      return 'awaiting you'
    case 'queued':
      return 'message queued'
    case 'stalled':
      return 'spawn stalled'
    case 'errored':
      return 'turn errored'
    case 'done':
      return 'done'
    case 'failed':
      return 'failed'
    case 'killed':
      return 'killed'
  }
}

function dotClass(s: NodeStatus): string {
  switch (s) {
    case 'running':
    case 'starting':
      return 'dot dot-run'
    case 'waiting':
      return 'dot dot-warn'
    case 'queued':
      return 'dot dot-queue'
    case 'stalled':
    case 'errored':
    case 'failed':
      return 'dot dot-bad'
    case 'done':
      return 'dot dot-done'
    case 'idle':
      return 'dot dot-idle'
    case 'killed':
      return 'dot dot-dead'
  }
}

function nodeById(session: ViewSession, id: string | null | undefined): ViewNode | null {
  if (!id) return null
  return session.nodes.find((n) => n.id === id) ?? null
}

function isTerminal(s: NodeStatus): boolean {
  return s === 'done' || s === 'failed' || s === 'killed'
}

export default function App() {
  const [state, setState] = useState<ViewState | null>(null)
  const [activeSessionId, setActiveSessionId] = useState<string | null>(null)
  const [selectedBySession, setSelectedBySession] = useState<Record<string, string>>({})
  const [sidebarOpen, setSidebarOpen] = useState(true)
  const [treeOpen, setTreeOpen] = useState(true)
  const [toast, setToast] = useState<string | null>(null)
  const [now, setNow] = useState(Date.now())
  const [historyId, setHistoryId] = useState<string | null>(null)
  const [historyDetail, setHistoryDetail] = useState<HistoryDetail | null>(null)
  const [historyNode, setHistoryNode] = useState<string | null>(null)
  const [historyText, setHistoryText] = useState<string | null>(null)
  const openSessionRef = useRef<(id: string) => void>(() => {})

  useEffect(() => onState(setState), [])
  useEffect(() => onSessionStarted((id) => openSessionRef.current(id)), [])
  useEffect(
    () =>
      onToast((text) => {
        setToast(text)
        setTimeout(() => setToast((t) => (t === text ? null : t)), 5000)
      }),
    [],
  )
  useEffect(
    () =>
      onHistory((detail) => {
        setHistoryDetail(detail)
        setHistoryNode(detail?.rootID ?? null)
      }),
    [],
  )
  useEffect(
    () =>
      onHistoryTranscript((payload) => {
        setHistoryText(payload.text ?? null)
      }),
    [],
  )
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(t)
  }, [])

  const sessions = useMemo(() => Object.values(state?.sessions ?? {}), [state])
  const activeSession = activeSessionId ? state?.sessions[activeSessionId] ?? null : null
  const selectedNodeId =
    (activeSessionId && selectedBySession[activeSessionId]) || activeSession?.rootID || null

  const selectNode = (sessionId: string, nodeId: string) => {
    setSelectedBySession((m) => ({ ...m, [sessionId]: nodeId }))
  }

  const openSession = (sessionId: string) => {
    setHistoryId(null)
    setActiveSessionId(sessionId)
    const s = state?.sessions[sessionId]
    if (s) selectNode(sessionId, s.rootID)
  }
  openSessionRef.current = openSession

  const openHistory = (id: string) => {
    setHistoryId(id)
    setHistoryDetail(null)
    setHistoryText(null)
    send({ type: 'history', archiveId: id })
  }

  const selectHistoryNode = (id: string) => {
    setHistoryNode(id)
    if (historyId) send({ type: 'historyTranscript', archiveId: historyId, nodeId: id })
  }

  // Keyboard: every global shortcut uses Ctrl+Shift so plain keys, Escape, Enter and
  // Ctrl-series still reach the agent's TUI untouched.
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (!e.ctrlKey || !e.shiftKey) return
      const key = e.key.toLowerCase()
      if (key === 't') {
        e.preventDefault()
        setHistoryId(null)
        setActiveSessionId(null)
      } else if (key === 'w') {
        e.preventDefault()
        if (activeSessionId) {
          send({ type: 'closeSession', sessionId: activeSessionId })
          setActiveSessionId(null)
        }
      } else if (key === 'b') {
        e.preventDefault()
        setSidebarOpen((v) => !v)
      } else if (key === 'j') {
        e.preventDefault()
        setTreeOpen((v) => !v)
      } else if (key === 'u') {
        e.preventDefault()
        const notice = state
          ? Object.values(state.sessions)
              .flatMap((s) => s.notices.map((n) => ({ session: s.id, node: n.nodeID, seq: n.seq })))
              .sort((a, b) => b.seq - a.seq)[0]
          : null
        if (notice) {
          setHistoryId(null)
          openSession(notice.session)
          selectNode(notice.session, notice.node)
        }
      } else if (e.code === 'BracketLeft' || e.code === 'BracketRight') {
        e.preventDefault()
        const ordered = state?.projects.flatMap((p) => p.sessionIds) ?? []
        if (ordered.length === 0) return
        const i = activeSessionId ? ordered.indexOf(activeSessionId) : -1
        const step = e.code === 'BracketRight' ? 1 : -1
        const next = ordered[(i + step + ordered.length) % ordered.length]
        if (next) openSession(next)
      }
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [activeSessionId, state])

  return (
    <div className="app">
      <header className="titlebar">
        <div className="brand">
          <span className="brand-mark">◆</span> Vigil
        </div>
        <div className="crumb">
          {activeSession ? activeSession.name || 'session' : historyId ? 'history' : 'launcher'}
        </div>
        <div className="titlebar-right">
          <span className="hint">Ctrl+Shift+T new · W close · B sidebar · J tree · U alert</span>
        </div>
      </header>

      <div className="body">
        {sidebarOpen && (
          <Sidebar
            state={state}
            activeSessionId={activeSessionId}
            historyId={historyId}
            onNew={() => {
              setHistoryId(null)
              setActiveSessionId(null)
            }}
            onOpenSession={openSession}
            onOpenHistory={openHistory}
            onCloseSession={(id) => {
              send({ type: 'closeSession', sessionId: id })
              if (activeSessionId === id) setActiveSessionId(null)
            }}
          />
        )}

        <main className="main">
          {historyId ? (
            <HistoryView
              detail={historyDetail}
              selectedNode={historyNode}
              transcript={historyText}
              onSelectNode={selectHistoryNode}
              onResume={() => {
                send({ type: 'resumeSession', archiveId: historyId })
                setTimeout(() => {
                  setHistoryId(null)
                }, 300)
              }}
              onArchive={() => send({ type: 'archiveSession', sessionId: historyId, archived: true })}
            />
          ) : activeSession ? (
            <SessionView
              session={activeSession}
              selectedNodeId={selectedNodeId}
              selectNode={(id) => selectNode(activeSession.id, id)}
              treeOpen={treeOpen}
              now={now}
              onResumeNode={(id) => send({ type: 'resumeNode', sessionId: activeSession.id, nodeId: id })}
              onRename={(name) => send({ type: 'renameSession', sessionId: activeSession.id, name })}
              onClose={() => {
                send({ type: 'closeSession', sessionId: activeSession.id })
                setActiveSessionId(null)
              }}
            />
          ) : (
            <Launcher state={state} />
          )}
        </main>
      </div>

      {toast && <div className="toast">{toast}</div>}
      {sessions.length === 0 && !state && <div className="boot">connecting…</div>}
    </div>
  )
}

// MARK: - Sidebar

function Sidebar(props: {
  state: ViewState | null
  activeSessionId: string | null
  historyId: string | null
  onNew: () => void
  onOpenSession: (id: string) => void
  onOpenHistory: (id: string) => void
  onCloseSession: (id: string) => void
}) {
  const { state } = props
  const [addOpen, setAddOpen] = useState(false)
  const [cwd, setCwd] = useState('')
  const liveIds = new Set(Object.keys(state?.sessions ?? {}))
  const history = (state?.history ?? []).filter((h) => !liveIds.has(h.id) || h.archived)

  return (
    <aside className="sidebar">
      <div className="side-actions">
        <button className="btn primary" onClick={props.onNew}>
          + New session
        </button>
        <button className="btn ghost" title="Add project" onClick={() => setAddOpen((v) => !v)}>
          + Project
        </button>
      </div>
      {addOpen && (
        <form
          className="add-project"
          onSubmit={(e) => {
            e.preventDefault()
            if (cwd.trim()) send({ type: 'addProject', cwd: cwd.trim() })
            setCwd('')
            setAddOpen(false)
          }}
        >
          <input
            autoFocus
            placeholder="C:\\path\\to\\project"
            value={cwd}
            onChange={(e) => setCwd(e.target.value)}
          />
        </form>
      )}

      <div className="side-scroll">
        {(state?.projects ?? []).map((project) => {
          const rows = project.sessionIds
            .map((id) => state?.sessions[id])
            .filter((s): s is ViewSession => Boolean(s))
          if (rows.length === 0 && project.id !== 'chats') return null
          return (
            <section key={project.id} className="project">
              <div className="project-head">
                <span className="project-name">{project.name}</span>
                {project.cwd && <span className="project-cwd">{project.cwd}</span>}
              </div>
              {rows.map((s) => {
                const root = nodeById(s, s.rootID)
                const status = root?.status ?? 'idle'
                const attention = s.notices.length
                return (
                  <button
                    key={s.id}
                    className={`session-row ${props.activeSessionId === s.id ? 'active' : ''}`}
                    onClick={() => props.onOpenSession(s.id)}
                  >
                    <span className={dotClass(status)} />
                    <span className="session-name">{s.name || 'session'}</span>
                    {attention > 0 && <span className="badge">{attention}</span>}
                    <span
                      className="row-close"
                      title="Close session"
                      onClick={(e) => {
                        e.stopPropagation()
                        props.onCloseSession(s.id)
                      }}
                    >
                      ×
                    </span>
                  </button>
                )
              })}
              {rows.length === 0 && <div className="empty-row">No sessions yet</div>}
            </section>
          )
        })}

        <section className="history-block">
          <div className="project-head">
            <span className="project-name">History</span>
          </div>
          {history.length === 0 && <div className="empty-row">Finished sessions appear here</div>}
          {history.map((h) => (
            <button
              key={h.id}
              className={`session-row ${props.historyId === h.id ? 'active' : ''}`}
              onClick={() => props.onOpenHistory(h.id)}
            >
              <span className="dot dot-dead" />
              <span className="session-name">{h.name}</span>
              {h.archived && <span className="tag">archived</span>}
            </button>
          ))}
        </section>
      </div>

      <div className="side-foot">
        <div className="agents-line">
          {(state?.agents ?? []).map((a) => (
            <span key={a.key} className={a.detected ? 'agent-on' : 'agent-off'} title={a.bin}>
              {a.kind}
            </span>
          ))}
        </div>
        <div className="cfg-line" title={state?.configDir}>
          {state?.configDir}
        </div>
      </div>
    </aside>
  )
}

// MARK: - Launcher

function Launcher({ state }: { state: ViewState | null }) {
  const [projectId, setProjectId] = useState('chats')
  const [agentKey, setAgentKey] = useState<string>('')
  const [permissionMode, setPermissionMode] = useState('bypassPermissions')
  const [model, setModel] = useState('')
  const [task, setTask] = useState('')
  const [busy, setBusy] = useState(false)

  const agents = (state?.agents ?? []).filter((a) => a.usable)
  const effectiveAgent = agentKey || state?.defaultAgent || agents[0]?.key || 'claude'
  const anyDetected = (state?.agents ?? []).some((a) => a.detected)

  return (
    <div className="launcher">
      <div className="launcher-card">
        <h1>Start a session</h1>
        <p className="sub">
          Vigil gives one manager a live tree of workers. Hand it a task — it spawns,
          delegates, and reports back here.
        </p>

        {state && !anyDetected && (
          <div className="warn-banner">
            No agent CLI found on PATH. Install Claude Code (<code>claude</code>), Codex
            (<code>codex</code>), or OpenCode (<code>opencode</code>) first.
          </div>
        )}

        <div className="row2">
          <label>
            Project
            <select value={projectId} onChange={(e) => setProjectId(e.target.value)}>
              {(state?.projects ?? []).map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                  {p.cwd ? ` — ${p.cwd}` : ''}
                </option>
              ))}
            </select>
          </label>
          <label>
            Agent
            <select value={effectiveAgent} onChange={(e) => setAgentKey(e.target.value)}>
              {agents.map((a) => (
                <option key={a.key} value={a.key} disabled={!a.detected}>
                  {a.key} {a.detected ? '' : '(not installed)'}
                </option>
              ))}
            </select>
          </label>
        </div>
        <div className="row2">
          <label>
            Permission mode
            <select value={permissionMode} onChange={(e) => setPermissionMode(e.target.value)}>
              <option value="bypassPermissions">bypassPermissions (all open)</option>
              <option value="acceptEdits">acceptEdits</option>
              <option value="plan">plan</option>
              <option value="default">default (ask)</option>
            </select>
          </label>
          <label>
            Model <span className="dim">(optional — Vigil never picks one)</span>
            <input value={model} onChange={(e) => setModel(e.target.value)} placeholder="CLI default" />
          </label>
        </div>

        <label className="task">
          Task
          <textarea
            autoFocus
            value={task}
            onChange={(e) => setTask(e.target.value)}
            placeholder="Describe the work. The manager will split it into a tree of workers."
            rows={6}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) start()
            }}
          />
        </label>

        <div className="launch-actions">
          <span className="dim">Ctrl+Enter to start</span>
          <button
            className="btn primary"
            disabled={busy || task.trim() === '' || !anyDetected}
            onClick={start}
          >
            {busy ? 'Starting…' : 'Start session'}
          </button>
        </div>
      </div>
    </div>
  )

  function start() {
    if (busy || task.trim() === '') return
    setBusy(true)
    send({
      type: 'newSession',
      projectId,
      agentKey: effectiveAgent,
      task,
      model: model.trim() || null,
      permissionMode,
    })
    // The state update opens the session; clear busy after a moment in case it errors.
    setTimeout(() => setBusy(false), 2500)
  }
}

// MARK: - Session view

function SessionView(props: {
  session: ViewSession
  selectedNodeId: string | null
  selectNode: (id: string) => void
  treeOpen: boolean
  now: number
  onResumeNode: (id: string) => void
  onRename: (name: string) => void
  onClose: () => void
}) {
  const { session, selectedNodeId } = props
  const node = nodeById(session, selectedNodeId) ?? nodeById(session, session.rootID)
  const notices = session.notices.filter((n) => n.displayAfter <= props.now)
  const live = node ? session.hasLiveCells.includes(node.id) : false

  return (
    <div className={`session-view ${props.treeOpen ? 'with-tree' : ''}`}>
      <div className="center">
        <div className="center-head">
          <span className={`${dotClass(node?.status ?? 'idle')}`} />
          <span className="center-title">{session.name || 'session'}</span>
          <span className="node-chip" title="selected node">
            {node?.id} · {node ? statusLabel(node.status) : '—'}
          </span>
          {node?.title && node.title !== session.name && (
            <span className="node-task">{node.title}</span>
          )}
          <span className="spacer" />
          {node && !live && session.sessionIds[node.id] && (
            <button className="btn ghost" onClick={() => props.onResumeNode(node.id)}>
              Resume node
            </button>
          )}
          <button
            className="btn ghost"
            onClick={() => {
              const name = window.prompt('Session name', session.name ?? '')
              if (name && name.trim()) props.onRename(name.trim())
            }}
          >
            Rename
          </button>
          <button className="btn ghost danger" onClick={props.onClose}>
            Close
          </button>
        </div>
        <div className="terminal-wrap">
          {node && (
            <TerminalView
              key={`${session.id}:${node.id}`}
              sessionId={session.id}
              nodeId={node.id}
              live={live}
            />
          )}
        </div>
      </div>

      {props.treeOpen && (
        <aside className="overlay">
          <div className="panel tree-panel">
            <div className="panel-head">
              <span>Tree</span>
              <span className="dim">{session.nodes.length} node(s)</span>
            </div>
            <TreeList
              session={session}
              selected={selectedNodeId}
              onSelect={props.selectNode}
            />
          </div>
          <NoticeStack
            session={session}
            notices={notices}
            onSelect={(id) => props.selectNode(id)}
          />
          {node?.lastRollup && (
            <div className="panel rollup">
              <div className="panel-head">
                <span>Last rollup · {node.id}</span>
              </div>
              <div className="rollup-body">{node.lastRollup}</div>
            </div>
          )}
        </aside>
      )}
    </div>
  )
}

function TreeList(props: { session: ViewSession; selected: string | null; onSelect: (id: string) => void }) {
  const byParent = new Map<string | null, ViewNode[]>()
  for (const n of props.session.nodes) {
    const key = n.parent
    if (!byParent.has(key)) byParent.set(key, [])
    byParent.get(key)?.push(n)
  }
  const rows: Array<{ node: ViewNode; depth: number }> = []
  const walk = (parent: string | null, depth: number) => {
    for (const n of byParent.get(parent) ?? []) {
      rows.push({ node: n, depth })
      walk(n.id, depth + 1)
    }
  }
  walk(null, 0)
  return (
    <div className="tree-list">
      {rows.map(({ node, depth }) => (
        <button
          key={node.id}
          className={`tree-row ${props.selected === node.id ? 'selected' : ''}`}
          style={{ paddingLeft: 10 + depth * 14 }}
          onClick={() => props.onSelect(node.id)}
          title={node.title}
        >
          <span className={dotClass(node.status)} />
          <span className="tree-id">{node.id}</span>
          <span className="tree-title">{node.title || node.role}</span>
          <span className="tree-role">{node.role === 'manager' ? 'mgr' : ''}</span>
        </button>
      ))}
    </div>
  )
}

function NoticeStack(props: {
  session: ViewSession
  notices: ViewSession['notices']
  onSelect: (id: string) => void
}) {
  if (props.notices.length === 0) {
    return (
      <div className="panel notices empty">
        <div className="panel-head">
          <span>Attention</span>
        </div>
        <div className="empty-note">Nothing needs you right now.</div>
      </div>
    )
  }
  return (
    <div className="notices">
      {props.notices.map((n) => (
        <button key={n.id} className="notice-card" onClick={() => props.onSelect(n.nodeID)}>
          <div className="notice-top">
            <span className={n.kind === 'permission' ? 'dot dot-warn' : 'dot dot-queue'} />
            <span className="notice-node">{n.nodeID}</span>
            <span className="spacer" />
            <span className="notice-time">{new Date(n.arrivedAt).toLocaleTimeString()}</span>
          </div>
          <div className="notice-text">{n.text}</div>
          <div className="notice-hint">Open that terminal to answer it</div>
        </button>
      ))}
    </div>
  )
}

// MARK: - Terminal

function TerminalView({ sessionId, nodeId, live }: { sessionId: string; nodeId: string; live: boolean }) {
  const host = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    const term = new Terminal({
      theme: TERM_THEME,
      fontFamily: 'Cascadia Mono, Consolas, ui-monospace, monospace',
      fontSize: 13,
      lineHeight: 1.15,
      cursorBlink: true,
      scrollback: 5000,
      allowProposedApi: true,
    })
    const fit = new FitAddon()
    term.loadAddon(fit)
    if (host.current) term.open(host.current)
    fit.fit()

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
    send({ type: 'attach', sessionId, nodeId })
    const fallback = setTimeout(flush, 700)
    const disposable = term.onData((data) => send({ type: 'input', sessionId, nodeId, data }))
    const resize = () => {
      try {
        fit.fit()
        send({ type: 'resize', sessionId, nodeId, cols: term.cols, rows: term.rows })
      } catch {
        // container not measurable yet
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
    }
  }, [sessionId, nodeId])

  return (
    <div className="terminal-host" ref={host} data-live={live ? '1' : '0'} />
  )
}

// MARK: - History

function HistoryView(props: {
  detail: HistoryDetail | null
  selectedNode: string | null
  transcript: string | null
  onSelectNode: (id: string) => void
  onResume: () => void
  onArchive: () => void
}) {
  const detail = props.detail
  return (
    <div className="history-view">
      <div className="center-head">
        <span className="center-title">Session replay</span>
        <span className="node-chip">{detail ? `${detail.nodes.length} node(s), read-only` : 'loading…'}</span>
        <span className="spacer" />
        <button className="btn ghost" onClick={props.onResume}>
          Resume session
        </button>
        <button className="btn ghost" onClick={props.onArchive}>
          Archive
        </button>
      </div>
      <div className="history-body">
        <div className="history-tree">
          {detail?.nodes.map((n) => (
            <button
              key={n.id}
              className={`tree-row ${props.selectedNode === n.id ? 'selected' : ''}`}
              onClick={() => props.onSelectNode(n.id)}
            >
              <span className={dotClass(n.status)} />
              <span className="tree-id">{n.id}</span>
              <span className="tree-title">{n.title || n.role}</span>
            </button>
          ))}
        </div>
        <pre className="history-transcript">
          {props.transcript ??
            (detail
              ? 'Select a node to read its transcript.'
              : 'Reading the orchestration log…')}
        </pre>
      </div>
    </div>
  )
}
