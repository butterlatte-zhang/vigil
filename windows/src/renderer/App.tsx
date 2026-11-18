// Vigil for Windows — root view. Port of Views.swift AppBody + AppModel glue.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type {
  HistoryDetail,
  TranscriptLoad,
  ViewHistoryRow,
  ViewSession,
  ViewState,
} from '../shared/protocol'
import {
  onDeadNodeTranscript,
  onHistory,
  onHistoryTranscript,
  onSessionStarted,
  onState,
  onToast,
  send,
} from './ws'
import { makeTokens, resolveTheme, type VGTheme } from './theme'
import { unseenMutation } from './status'
import { Sidebar } from './Sidebar'
import { TopBar } from './TopBar'
import { Launcher } from './Launcher'
import { SessionPane } from './SessionPane'
import { HistoryPane } from './HistoryPane'
import { configOnboardingPrompt } from '../shared/session'

const LS = {
  sections: 'vigil.sections',
  tree: 'vigil.treeOpen',
  hideFinished: 'vigil.hideFinished',
  sidebar: 'vigil.sidebarCollapsed',
  shellHeight: 'vigil.shellHeight',
  drafts: 'vigil.drafts',
  agents: 'vigil.agents',
}

function readJson<T>(key: string, fallback: T): T {
  try {
    const raw = localStorage.getItem(key)
    return raw ? (JSON.parse(raw) as T) : fallback
  } catch {
    return fallback
  }
}

function writeJson(key: string, value: unknown): void {
  try {
    localStorage.setItem(key, JSON.stringify(value))
  } catch {
    // ignore
  }
}

export default function App() {
  const [state, setState] = useState<ViewState | null>(null)
  const [currentProjectId, setCurrentProjectId] = useState<string | null>(null)
  const [activeSessionId, setActiveSessionId] = useState<string | null>(null)
  const [selectedBySession, setSelectedBySession] = useState<Record<string, string>>({})
  const [historyId, setHistoryId] = useState<string | null>(null)
  const [historyDetail, setHistoryDetail] = useState<HistoryDetail | null>(null)
  const [historyNodeId, setHistoryNodeId] = useState<string | null>(null)
  const [historyTranscript, setHistoryTranscript] = useState<TranscriptLoad | null>(null)
  const [deadTranscripts, setDeadTranscripts] = useState<Record<string, TranscriptLoad>>({})
  const [sidebarCollapsed, setSidebarCollapsed] = useState<boolean>(() => readJson(LS.sidebar, false))
  const [sections, setSections] = useState<Record<string, boolean>>(() => readJson(LS.sections, {}))
  const [showAll, setShowAll] = useState<Record<string, boolean>>({})
  const [query, setQuery] = useState('')
  const [searching, setSearching] = useState(false)
  const [treeOpen, setTreeOpen] = useState<Record<string, boolean>>(() => readJson(LS.tree, {}))
  const [hideFinished, setHideFinished] = useState<Record<string, boolean>>(() => readJson(LS.hideFinished, {}))
  const [drafts, setDrafts] = useState<Record<string, string>>(() => readJson(LS.drafts, {}))
  const [agentByProject, setAgentByProject] = useState<Record<string, string>>(() => readJson(LS.agents, {}))
  const [unseen, setUnseen] = useState<Record<string, Set<string>>>({})
  const [completedUnseen, setCompletedUnseen] = useState<Record<string, boolean>>({})
  const [lastStatus, setLastStatus] = useState<Record<string, string>>({})
  const [now, setNow] = useState(Date.now())
  const [toast, setToast] = useState<string | null>(null)
  const [shellHeight, setShellHeight] = useState<number>(() => readJson(LS.shellHeight, 260))
  const [rename, setRename] = useState<{ id: string; name: string; dead: boolean } | null>(null)
  const [pendingRevive, setPendingRevive] = useState<{ archiveId: string; nodeId: string } | null>(null)
  const [pendingOpenId, setPendingOpenId] = useState<string | null>(null)
  const [systemDark, setSystemDark] = useState(() => window.matchMedia('(prefers-color-scheme: dark)').matches)

  // A stable ref so WS callbacks (registered once) can open a session with fresh state.
  const stateRef = useRef<ViewState | null>(null)
  stateRef.current = state
  const selectedRef = useRef(selectedBySession)
  selectedRef.current = selectedBySession
  const activeRef = useRef(activeSessionId)
  activeRef.current = activeSessionId
  const openSessionRef = useRef<(id: string) => void>(() => {})

  useEffect(() => onState(setState), [])
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
        setHistoryNodeId(detail?.rootID ?? null)
      }),
    [],
  )
  useEffect(
    () =>
      onHistoryTranscript((payload) => {
        setHistoryTranscript({
          path: payload.path ?? null,
          items: payload.items ?? null,
          stats: payload.stats ?? null,
        })
      }),
    [],
  )
  useEffect(
    () =>
      onDeadNodeTranscript((payload) => {
        const key = `${payload.sessionId}:${payload.nodeId}`
        setDeadTranscripts((m) => ({
          ...m,
          [key]: { path: payload.path ?? null, items: payload.items ?? null, stats: payload.stats ?? null },
        }))
      }),
    [],
  )
  useEffect(
    () =>
      onSessionStarted((id) => {
        const pending = pendingRevive
        if (stateRef.current?.sessions[id]) openSessionRef.current(id)
        else setPendingOpenId(id)
        if (pending && pending.archiveId === id) {
          setTimeout(() => send({ type: 'resumeNode', sessionId: id, nodeId: pending.nodeId }), 400)
          setPendingRevive(null)
        }
      }),
    [pendingRevive],
  )

  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(t)
  }, [])

  // Follow the OS when appearance.json says auto.
  useEffect(() => {
    const mq = window.matchMedia('(prefers-color-scheme: dark)')
    const fn = (e: MediaQueryListEvent) => setSystemDark(e.matches)
    mq.addEventListener('change', fn)
    return () => mq.removeEventListener('change', fn)
  }, [])

  const theme: VGTheme = resolveThemeWith(state?.appearance, systemDark)
  const tokens = useMemo(
    () => makeTokens(theme, state?.appearance?.accent ?? 'blue'),
    [theme, state?.appearance?.accent],
  )

  useEffect(() => {
    const root = document.documentElement
    root.dataset.theme = theme
    root.dataset.accent = state?.appearance?.accent ?? 'blue'
    const vars: Record<string, string> = {
      '--term': tokens.term,
      '--panel': tokens.panelSolid,
      '--card': tokens.card,
      '--hair': tokens.hair,
      '--hair2': tokens.hair2,
      '--text': tokens.text,
      '--text2': tokens.text2,
      '--text3': tokens.text3,
      '--node-line': tokens.nodeLine,
      '--spinring': tokens.spinring,
      '--green': tokens.green,
      '--red': tokens.red,
      '--warn': tokens.warn,
      '--accent': tokens.accent,
      '--term-bg': tokens.termBG,
      '--term-fg': tokens.termFG,
    }
    for (const [k, v] of Object.entries(vars)) root.style.setProperty(k, v)
    document.body.style.background = tokens.term
    ;(window as any).vigil?.setTheme?.(theme)
  }, [theme, state?.appearance?.accent, tokens])

  // Unseen transitions: mark completions that land off-screen; clear once watched.
  useEffect(() => {
    if (!state) return
    setLastStatus((prev) => {
      const next = { ...prev }
      const mark: Array<[string, string]> = []
      const clear: Array<[string, string]> = []
      for (const s of Object.values(state.sessions)) {
        for (const n of s.nodes) {
          const key = `${s.id}:${n.id}`
          const watching =
            activeRef.current === s.id && (selectedRef.current[s.id] ?? s.rootID) === n.id && document.hasFocus()
          const v = unseenMutation(prev[key] as any, n.status, watching)
          if (v === 'mark') mark.push([s.id, n.id])
          else if (v === 'clear') clear.push([s.id, n.id])
          next[key] = n.status
        }
      }
      if (mark.length || clear.length) {
        setUnseen((u) => {
          const copy: Record<string, Set<string>> = { ...u }
          for (const [sid] of [...mark, ...clear]) copy[sid] = new Set(copy[sid] ?? [])
          for (const [sid, nid] of mark) copy[sid].add(nid)
          for (const [sid, nid] of clear) copy[sid].delete(nid)
          return copy
        })
      }
      return next
    })
  }, [state])

  // A session coming to rest while you are elsewhere lights the blue dot.
  useEffect(() => {
    if (!state) return
    for (const s of Object.values(state.sessions)) {
      const live = s.nodes.some((n) => n.status === 'running' || n.status === 'starting')
      const rest = s.nodes.length > 0 && !live
      const seenLive = (lastStatus[s.id + ':__live__'] ?? '') === 'live'
      if (rest && seenLive && activeSessionId !== s.id) {
        setCompletedUnseen((m) => (m[s.id] ? m : { ...m, [s.id]: true }))
      }
      const key = s.id + ':__live__'
      const want = live ? 'live' : 'rest'
      if (lastStatus[key] !== want) setLastStatus((m) => ({ ...m, [key]: want }))
    }
  }, [state, activeSessionId, lastStatus])

  useEffect(() => {
    if (pendingOpenId && state?.sessions[pendingOpenId]) {
      openSessionRef.current(pendingOpenId)
      setPendingOpenId(null)
    }
  }, [state, pendingOpenId])

  const sessions = state ? Object.values(state.sessions) : []
  const activeSession: ViewSession | null = activeSessionId ? state?.sessions[activeSessionId] ?? null : null
  const selectedNodeId = activeSession ? selectedBySession[activeSession.id] ?? activeSession.rootID : null
  const historyRow: ViewHistoryRow | null = historyId
    ? state?.history.find((h) => h.id === historyId) ?? null
    : null

  const sessionOrder = useMemo(() => {
    if (!state) return []
    const live = new Map<string, number>()
    for (const s of Object.values(state.sessions)) live.set(s.id, s.createdAt)
    const dead = new Map<string, number>()
    for (const h of state.history) dead.set(h.id, h.createdAt ? Date.parse(h.createdAt) : h.modifiedAt ?? 0)
    const rows: Array<{ id: string; at: number; live: boolean }> = []
    for (const p of state.projects) {
      for (const id of p.sessionIds) rows.push({ id, at: live.get(id) ?? 0, live: true })
      for (const h of state.history.filter((x) => x.projectId === p.id)) {
        rows.push({ id: h.id, at: dead.get(h.id) ?? 0, live: false })
      }
    }
    return rows.sort((a, b) => b.at - a.at)
  }, [state])

  const openSession = useCallback((id: string) => {
    const s = stateRef.current?.sessions[id]
    if (!s) return
    setHistoryId(null)
    setHistoryDetail(null)
    setActiveSessionId(id)
    setCurrentProjectId(s.projectId)
    setCompletedUnseen((m) => (m[id] ? { ...m, [id]: false } : m))
    setUnseen((u) => (u[id] ? { ...u, [id]: new Set() } : u))
  }, [])
  openSessionRef.current = openSession

  const openLauncher = useCallback((projectId: string) => {
    setCurrentProjectId(projectId)
    setActiveSessionId(null)
    setHistoryId(null)
    setHistoryDetail(null)
    setSearching(false)
    setQuery('')
    // First visit to Settings: the macOS app prefills the onboarding prompt once.
    if (projectId === 'settings') {
      const st = stateRef.current
      const usedBefore =
        st &&
        (Object.values(st.sessions).some((s) => s.projectId === 'settings') ||
          st.history.some((h) => h.projectId === 'settings'))
      if (!usedBefore) {
        setDrafts((m) => {
          if (m.settings !== undefined) return m
          const next = { ...m, settings: configOnboardingPrompt }
          writeJson(LS.drafts, next)
          return next
        })
      }
    }
  }, [])

  const openHistory = useCallback((id: string) => {
    setActiveSessionId(null)
    setHistoryId(id)
    setHistoryDetail(null)
    setHistoryTranscript(null)
    setHistoryNodeId(null)
    send({ type: 'history', archiveId: id })
  }, [])

  // Fetch the selected history node's transcript.
  useEffect(() => {
    if (!historyId || !historyNodeId) return
    setHistoryTranscript(null)
    send({ type: 'historyTranscript', archiveId: historyId, nodeId: historyNodeId })
  }, [historyId, historyNodeId])

  // Fetch the selected dead node's transcript (live session afterlife).
  useEffect(() => {
    if (!activeSession || !selectedNodeId) return
    const node = activeSession.nodes.find((n) => n.id === selectedNodeId)
    if (!node) return
    const terminal = node.status === 'done' || node.status === 'failed' || node.status === 'killed'
    if (!terminal) return
    const key = `${activeSession.id}:${node.id}`
    if (deadTranscripts[key]) return
    send({ type: 'deadNodeTranscript', sessionId: activeSession.id, nodeId: node.id })
  }, [activeSession, selectedNodeId, deadTranscripts])

  const toggleSection = (key: string) =>
    setSections((s) => {
      const next = { ...s, [key]: s[key] === false }
      writeJson(LS.sections, next)
      return next
    })
  const toggleShowAll = (key: string) => setShowAll((m) => ({ ...m, [key]: !m[key] }))
  const toggleTreeFor = (key: string) =>
    setTreeOpen((m) => {
      const next = { ...m, [key]: !(m[key] ?? true) }
      writeJson(LS.tree, next)
      return next
    })
  const toggleHideFinished = (key: string) =>
    setHideFinished((m) => {
      const next = { ...m, [key]: !m[key] }
      writeJson(LS.hideFinished, next)
      return next
    })
  const toggleSidebar = () =>
    setSidebarCollapsed((v) => {
      writeJson(LS.sidebar, !v)
      return !v
    })

  const addProject = useCallback(async () => {
    const api = (window as any).vigil
    let cwd: string | null = null
    if (api?.pickFolder) cwd = await api.pickFolder()
    else cwd = window.prompt('Project folder (absolute path)')
    if (cwd) send({ type: 'addProject', cwd })
  }, [])

  const closeActive = useCallback(() => {
    const id = activeRef.current
    if (!id) return
    send({ type: 'closeSession', sessionId: id })
    setActiveSessionId(null)
  }, [])

  const renameTarget = rename ?? null

  // Keyboard shortcuts. The macOS app's global shortcuts are ⌘-modified so they never
  // steal a TUI key; the Windows analog is Ctrl+Shift (plus Ctrl+1–9 for session jumps and
  // Ctrl+, for settings). Plain keys, Escape, Enter and the ordinary Ctrl-series pass through.
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (!e.ctrlKey) return
      const step = (dir: number) => {
        if (!activeSession) return
        const list = flattenVisible(activeSession, hideFinished[activeSession.id] === true)
        if (list.length === 0) return
        const cur = list.findIndex((n) => n.id === selectedNodeId)
        const next = list[(cur + dir + list.length) % list.length]
        if (next) setSelectedBySession((m) => ({ ...m, [activeSession.id]: next.id }))
      }

      // Ctrl+, — open the Settings workspace (macOS ⌘,).
      if (!e.shiftKey && !e.altKey && e.code === 'Comma') {
        e.preventDefault()
        openLauncher('settings')
        return
      }
      // Ctrl+1–9 — jump to the Nth visible session row (macOS ⌘1–9).
      if (!e.shiftKey && !e.altKey && /^Digit[1-9]$/.test(e.code)) {
        e.preventDefault()
        const row = sessionOrder[Number(e.code.slice(5)) - 1]
        if (row) (row.live ? openSession : openHistory)(row.id)
        return
      }
      // Ctrl+Alt+[ / ] — previous / next session (macOS ⌃⌘[ / ]).
      if (e.altKey && !e.shiftKey && (e.code === 'BracketLeft' || e.code === 'BracketRight')) {
        e.preventDefault()
        const list = sessionOrder
        if (list.length === 0) return
        const i = activeRef.current ? list.findIndex((r) => r.id === activeRef.current) : -1
        const dir = e.code === 'BracketRight' ? 1 : -1
        const next = list[(i + dir + list.length) % list.length]
        if (next) (next.live ? openSession : openHistory)(next.id)
        return
      }
      if (!e.shiftKey || e.altKey) return
      const key = e.key.toLowerCase()
      if (key === 't') {
        e.preventDefault()
        openLauncher(currentProjectId ?? 'chats')
      } else if (key === 'o') {
        e.preventDefault()
        void addProject()
      } else if (key === 'w') {
        e.preventDefault()
        closeActive()
      } else if (key === 'r') {
        e.preventDefault()
        const id = activeRef.current ?? historyId
        if (!id) return
        const s = stateRef.current?.sessions[id]
        const h = stateRef.current?.history.find((x) => x.id === id)
        setRename({ id, name: s?.name ?? h?.name ?? '', dead: !s })
      } else if (key === 'b') {
        e.preventDefault()
        toggleSidebar()
      } else if (key === 'j') {
        e.preventDefault()
        if (activeSession) send({ type: 'shellToggle', sessionId: activeSession.id })
      } else if (key === 'u') {
        e.preventDefault()
        const all = Object.values(stateRef.current?.sessions ?? {})
          .flatMap((s) => s.notices.map((n) => ({ sid: s.id, nid: n.nodeID, at: n.arrivedAt })))
          .sort((a, b) => b.at - a.at)
        if (all[0]) {
          openSessionRef.current(all[0].sid)
          setSelectedBySession((m) => ({ ...m, [all[0].sid]: all[0].nid }))
        }
      } else if (e.code === 'BracketLeft') {
        e.preventDefault()
        step(-1)
      } else if (e.code === 'BracketRight') {
        e.preventDefault()
        step(1)
      }
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [
    activeSession,
    selectedNodeId,
    hideFinished,
    historyId,
    currentProjectId,
    sessionOrder,
    openLauncher,
    addProject,
    closeActive,
    openSession,
    openHistory,
  ])

  if (!state) {
    return <div className="boot">connecting…</div>
  }

  const currentProject =
    state.projects.find((p) => p.id === currentProjectId) ?? state.projects.find((p) => p.id === 'chats') ?? state.projects[0]
  const agentKey = agentByProject[currentProject?.id ?? 'chats'] ?? state.defaultAgent ?? state.agents[0]?.key ?? 'claude'
  const treeKey = activeSession?.id ?? (historyId ? 'history' : null)
  const treeVisible = treeKey ? treeOpen[treeKey] ?? true : false
  const showTreeToggle = activeSession !== null || (historyId !== null && (historyDetail?.nodes.length ?? 0) > 1)
  const deadKey = activeSession && selectedNodeId ? `${activeSession.id}:${selectedNodeId}` : null

  return (
    <div className="app">
      {!sidebarCollapsed && (
        <Sidebar
          state={state}
          currentProjectId={currentProjectId}
          activeSessionId={activeSessionId}
          historyId={historyId}
          sections={sections}
          showAll={showAll}
          query={query}
          searching={searching}
          unseen={unseen}
          completedUnseen={completedUnseen}
          now={now}
          onToggleSection={toggleSection}
          onToggleShowAll={toggleShowAll}
          onStartSearch={() => setSearching(true)}
          onQuery={setQuery}
          onStopSearch={() => {
            setSearching(false)
            setQuery('')
          }}
          onNewChat={() => openLauncher(currentProjectId ?? 'chats')}
          onOpenLauncher={openLauncher}
          onSelectSession={openSession}
          onOpenHistory={openHistory}
          onArchive={(id, flag) => send({ type: 'archiveSession', sessionId: id, archived: flag })}
          onAddProject={() => void addProject()}
          onCollapse={toggleSidebar}
        />
      )}

      <div className="main">
        <TopBar
          title={
            activeSession?.name ??
            historyRow?.name ??
            currentProject?.name ??
            'Vigil'
          }
          newTask={!activeSession && !historyId && currentProject !== undefined}
          sidebarCollapsed={sidebarCollapsed}
          onExpandSidebar={toggleSidebar}
          showShell={activeSession !== null}
          shellOpen={activeSession?.shellRunning === true}
          onToggleShell={() => activeSession && send({ type: 'shellToggle', sessionId: activeSession.id })}
          showTree={showTreeToggle}
          treeOpen={treeVisible}
          onToggleTree={() => treeKey && toggleTreeFor(treeKey)}
        />

        <div className="content">
          {activeSession ? (
            <SessionPane
              state={state}
              session={activeSession}
              selectedNodeId={selectedNodeId ?? activeSession.rootID}
              tokens={tokens}
              appearance={state.appearance}
              now={now}
              unseen={unseen[activeSession.id] ?? new Set()}
              hideFinished={hideFinished[activeSession.id] === true}
              onToggleFinished={() => toggleHideFinished(activeSession.id)}
              treeOpen={treeOpen[activeSession.id] ?? true}
              onSelectNode={(id) => {
                setSelectedBySession((m) => ({ ...m, [activeSession.id]: id }))
                setUnseen((u) => {
                  const set = new Set(u[activeSession.id] ?? [])
                  set.delete(id)
                  return { ...u, [activeSession.id]: set }
                })
              }}
              deadTranscript={deadKey ? deadTranscripts[deadKey] ?? null : null}
              onResumeNode={(id) => {
                setDeadTranscripts((m) => {
                  const next = { ...m }
                  delete next[`${activeSession.id}:${id}`]
                  return next
                })
                send({ type: 'resumeNode', sessionId: activeSession.id, nodeId: id })
              }}
              onNoticeOpen={(sid, nid) => {
                openSession(sid)
                setSelectedBySession((m) => ({ ...m, [sid]: nid }))
              }}
              shellVisible={activeSession.shellRunning}
              onToggleShell={() => send({ type: 'shellToggle', sessionId: activeSession.id })}
              onCloseShell={() => send({ type: 'shellToggle', sessionId: activeSession.id })}
              shellHeight={shellHeight}
              onShellHeight={(h) => {
                setShellHeight(h)
                writeJson(LS.shellHeight, h)
              }}
            />
          ) : historyId ? (
            <HistoryPane
              state={state}
              detail={historyDetail}
              selectedNodeId={historyNodeId}
              transcript={historyTranscript}
              tokens={tokens}
              now={now}
              treeOpen={treeOpen['history'] ?? true}
              onSelectNode={setHistoryNodeId}
              onResume={() => {
                const node =
                  historyDetail?.nodes.find((n) => n.id === historyNodeId) ?? null
                if (node && node.id !== historyDetail?.rootID) {
                  setPendingRevive({ archiveId: historyId, nodeId: node.id })
                }
                send({ type: 'resumeSession', archiveId: historyId })
              }}
            />
          ) : (
            currentProject && (
              <Launcher
                state={state}
                project={currentProject}
                agentKey={agentKey}
                onAgent={(key) =>
                  setAgentByProject((m) => {
                    const next = { ...m, [currentProject.id]: key }
                    writeJson(LS.agents, next)
                    return next
                  })
                }
                draft={drafts[currentProject.id] ?? ''}
                onDraft={(text) =>
                  setDrafts((m) => {
                    const next = { ...m, [currentProject.id]: text }
                    writeJson(LS.drafts, next)
                    return next
                  })
                }
                onSubmit={(task) => {
                  send({
                    type: 'newSession',
                    projectId: currentProject.id,
                    agentKey,
                    task,
                    permissionMode: 'bypassPermissions',
                  })
                  setDrafts((m) => {
                    const next = { ...m, [currentProject.id]: '' }
                    writeJson(LS.drafts, next)
                    return next
                  })
                }}
                onSwitchProject={openLauncher}
                onAddProject={() => void addProject()}
              />
            )
          )}
        </div>
      </div>

      {toast && <div className="toast">{toast}</div>}
      {renameTarget && (
        <RenameDialog
          initial={renameTarget.name}
          onCancel={() => setRename(null)}
          onSave={(name) => {
            if (name.trim()) send({ type: 'renameSession', sessionId: renameTarget.id, name: name.trim() })
            setRename(null)
          }}
        />
      )}
    </div>
  )
}

function flattenVisible(session: ViewSession, hideFinished: boolean) {
  const byId = new Map(session.nodes.map((n) => [n.id, n]))
  const out: ViewSession['nodes'] = []
  const walk = (id: string) => {
    const n = byId.get(id)
    if (!n) return
    out.push(n)
    for (const c of n.children) {
      const child = byId.get(c)
      if (!child) continue
      if (hideFinished && (child.status === 'done' || child.status === 'failed' || child.status === 'killed')) continue
      walk(c)
    }
  }
  walk(session.rootID)
  return out
}

function resolveThemeWith(appearance: ViewState['appearance'] | undefined, systemDark: boolean): VGTheme {
  if (appearance?.theme === 'dark' || appearance?.theme === 'light') return appearance.theme
  return systemDark ? 'dark' : 'light'
}

function RenameDialog({
  initial,
  onCancel,
  onSave,
}: {
  initial: string
  onCancel: () => void
  onSave: (name: string) => void
}) {
  const [value, setValue] = useState(initial)
  const input = useRef<HTMLInputElement | null>(null)
  useEffect(() => {
    input.current?.focus()
    input.current?.select()
  }, [])
  return (
    <div className="modal-backdrop" onMouseDown={onCancel}>
      <div className="modal" onMouseDown={(e) => e.stopPropagation()}>
        <div className="modal-title">Rename session</div>
        <input
          ref={input}
          className="modal-input"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') onSave(value)
            if (e.key === 'Escape') onCancel()
          }}
        />
        <div className="modal-actions">
          <button className="btn ghost" onClick={onCancel}>Cancel</button>
          <button className="btn primary" onClick={() => onSave(value)}>Rename</button>
        </div>
      </div>
    </div>
  )
}
