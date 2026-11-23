// Sidebar — port of SidebarView.swift. No inline node tree here (it lives in the
// top-right overlay). Structure: collapse row · pinned new-chat/search · Projects
// (project rows + merged live/dead session rows) · Chats · Settings · Archived.

import { useMemo, useRef, useState } from 'react'
import type { ViewHistoryRow, ViewSession, ViewState } from '../shared/protocol'
import {
  ArchiveGlyph,
  ChevronGlyph,
  ComposeGlyph,
  FolderPlusGlyph,
  NotebookGlyph,
  SearchGlyph,
  SidebarGlyph,
  UnarchiveGlyph,
  XGlyph,
} from './icons'
import { relativeTime } from './format'
import { sessionDotClass, type DotClass } from './status'

export interface SidebarProps {
  state: ViewState
  currentProjectId: string | null
  activeSessionId: string | null
  historyId: string | null
  sections: Record<string, boolean>
  showAll: Record<string, boolean>
  query: string
  searching: boolean
  unseen: Record<string, Set<string>>
  completedUnseen: Record<string, boolean>
  now: number
  onToggleSection: (key: string) => void
  onToggleShowAll: (key: string) => void
  onStartSearch: () => void
  onQuery: (q: string) => void
  onStopSearch: () => void
  onNewChat: () => void
  onOpenLauncher: (projectId: string) => void
  onSelectSession: (id: string) => void
  onOpenHistory: (id: string) => void
  onArchive: (id: string, flag: boolean) => void
  onAddProject: () => void
  onCollapse: () => void
}

type Row =
  | { kind: 'live'; session: ViewSession; at: number }
  | { kind: 'dead'; row: ViewHistoryRow; at: number }

const CAP = 5

export function Sidebar(props: SidebarProps) {
  const { state } = props
  const q = props.query.trim().toLowerCase()
  const search = useRef<HTMLInputElement | null>(null)

  const liveProjectIds = new Set(state.projects.map((p) => p.id))
  const deadByProject = useMemo(() => {
    const map = new Map<string, ViewHistoryRow[]>()
    for (const h of state.history) {
      if (h.archived) continue
      const list = map.get(h.projectId) ?? []
      list.push(h)
      map.set(h.projectId, list)
    }
    return map
  }, [state.history])

  const rowsFor = (projectId: string): Row[] => {
    const project = state.projects.find((p) => p.id === projectId)
    const live = (project?.sessionIds ?? [])
      .map((id) => state.sessions[id])
      .filter(Boolean)
      .map((s) => ({ kind: 'live' as const, session: s, at: s.createdAt }))
    const dead = (deadByProject.get(projectId) ?? []).map((r) => ({
      kind: 'dead' as const,
      row: r,
      at: r.createdAt ? Date.parse(r.createdAt) : r.modifiedAt ?? 0,
    }))
    return [...live, ...dead].sort((a, b) => b.at - a.at)
  }

  const matches = (name: string) => q === '' || name.toLowerCase().includes(q)

  const archived = state.history.filter((h) => h.archived && matches(h.name))
  const userProjects = state.projects.filter((p) => !p.builtin)
  const projectsShown =
    q === ''
      ? userProjects
      : userProjects.filter(
          (p) => matches(p.name) || rowsFor(p.id).some((r) => matches(r.kind === 'live' ? r.session.name ?? '' : r.row.name)),
        )

  const sectionOpen = (key: string) => (q !== '' ? true : props.sections[key] !== false)

  return (
    <aside className="sidebar">
      <div className="side-top">
        <span className="spacer" />
        <button className="icon-btn" title="Collapse sidebar" onClick={props.onCollapse}>
          <SidebarGlyph />
        </button>
      </div>

      <div className="side-pinned">
        <button className="pinned-row" onClick={props.onNewChat}>
          <span className="pinned-icon"><ComposeGlyph /></span>
          <span>New chat</span>
        </button>
        {props.searching ? (
          <input
            ref={search}
            autoFocus
            className="search-field"
            placeholder="Search sessions…"
            value={props.query}
            onChange={(e) => props.onQuery(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Escape') props.onStopSearch()
            }}
            onBlur={() => {
              if (props.query.trim() === '') props.onStopSearch()
            }}
          />
        ) : (
          <button className="pinned-row" onClick={props.onStartSearch}>
            <span className="pinned-icon"><SearchGlyph /></span>
            <span>Search</span>
          </button>
        )}
      </div>

      <div className="side-scroll">
        <>
          <Section
            title="Projects"
            open={sectionOpen('projects')}
            onToggle={() => props.onToggleSection('projects')}
            accessory={
              <button className="icon-btn small" title="Add project (choose a folder)" onClick={props.onAddProject}>
                <FolderPlusGlyph />
              </button>
            }
          />
          {sectionOpen('projects') &&
            projectsShown.map((p) => (
              <ProjectBlock
                key={p.id}
                project={p}
                rows={rowsFor(p.id)}
                selected={props.currentProjectId === p.id && props.activeSessionId === null && props.historyId === null}
                expanded={p.id === props.currentProjectId || props.showAll['proj:' + p.id] === true}
                forcedOpen={q !== ''}
                showAll={props.showAll['proj:' + p.id] === true}
                query={q}
                now={props.now}
                unseen={props.unseen}
                completedUnseen={props.completedUnseen}
                activeSessionId={props.activeSessionId}
                historyId={props.historyId}
                onOpenLauncher={() => props.onOpenLauncher(p.id)}
                onToggleExpand={() => props.onToggleShowAll('proj:' + p.id)}
                onSelectSession={props.onSelectSession}
                onOpenHistory={props.onOpenHistory}
                onArchive={props.onArchive}
                onNewSession={() => props.onOpenLauncher(p.id)}
              />
            ))}

        </>

        <PseudoSection
          title="Chats"
          keyName="chats"
          projectId="chats"
          open={sectionOpen('chats')}
          onToggle={() => props.onToggleSection('chats')}
          onNew={() => props.onOpenLauncher('chats')}
          rows={rowsFor('chats')}
          query={q}
          showAll={props.showAll['chats'] === true}
          onToggleShowAll={() => props.onToggleShowAll('chats')}
          now={props.now}
          unseen={props.unseen}
          completedUnseen={props.completedUnseen}
          activeSessionId={props.activeSessionId}
          historyId={props.historyId}
          onSelectSession={props.onSelectSession}
          onOpenHistory={props.onOpenHistory}
          onArchive={props.onArchive}
        />

        <PseudoSection
          title="Settings"
          keyName="settings"
          projectId="settings"
          open={sectionOpen('settings')}
          onToggle={() => props.onToggleSection('settings')}
          onNew={() => props.onOpenLauncher('settings')}
          rows={rowsFor('settings')}
          query={q}
          showAll={props.showAll['settings'] === true}
          onToggleShowAll={() => props.onToggleShowAll('settings')}
          now={props.now}
          unseen={props.unseen}
          completedUnseen={props.completedUnseen}
          activeSessionId={props.activeSessionId}
          historyId={props.historyId}
          onSelectSession={props.onSelectSession}
          onOpenHistory={props.onOpenHistory}
          onArchive={props.onArchive}
        />

        <Section
          title="Archived"
          open={sectionOpen('archived')}
          onToggle={() => props.onToggleSection('archived')}
        />
        {sectionOpen('archived') && (
          <>
            {archived.map((h) => (
              <DeadRow
                key={h.id}
                row={h}
                leftPad={12}
                selected={props.historyId === h.id}
                now={props.now}
                unarchive
                onOpen={() => props.onOpenHistory(h.id)}
                onArchive={() => props.onArchive(h.id, false)}
              />
            ))}

          </>
        )}

        {q !== '' && projectsShown.length === 0 && archived.length === 0 && rowsFor('chats').length === 0 && rowsFor('settings').length === 0 && (
          <div className="empty-note">No sessions match “{props.query}”</div>
        )}
      </div>
    </aside>
  )
}

function Section({
  title,
  open,
  onToggle,
  accessory,
}: {
  title: string
  open: boolean
  onToggle: () => void
  accessory?: React.ReactNode
}) {
  const [hover, setHover] = useState(false)
  return (
    <div className="section-header" onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}>
      <button className="section-toggle" onClick={onToggle}>
        <span className="section-title">{title}</span>
        <span className="section-chevron"><ChevronGlyph open={open} /></span>
      </button>
      <span className="spacer" />
      <span className={`section-accessory ${hover ? 'show' : ''}`}>{accessory}</span>
    </div>
  )
}

function PseudoSection(props: {
  title: string
  keyName: string
  projectId: string
  open: boolean
  onToggle: () => void
  onNew: () => void
  rows: Row[]
  query: string
  showAll: boolean
  onToggleShowAll: () => void
  now: number
  unseen: Record<string, Set<string>>
  completedUnseen: Record<string, boolean>
  activeSessionId: string | null
  historyId: string | null
  onSelectSession: (id: string) => void
  onOpenHistory: (id: string) => void
  onArchive: (id: string, flag: boolean) => void
}) {
  const filtered = props.query ? props.rows.filter((r) => (r.kind === 'live' ? (r.session.name ?? '') : r.row.name).toLowerCase().includes(props.query)) : props.rows
  const shown = props.query || props.showAll ? filtered : filtered.slice(0, CAP)
  return (
    <>
      <Section
        title={props.title}
        open={props.open}
        onToggle={props.onToggle}
        accessory={
          <button className="icon-btn small" title={props.keyName === 'settings' ? 'Send an agent to change config' : 'New chat'} onClick={props.onNew}>
            <ComposeGlyph size={12} />
          </button>
        }
      />
      {props.open &&
        shown.map((r) =>
          r.kind === 'live' ? (
            <LiveRow
              key={r.session.id}
              session={r.session}
              leftPad={12}
              selected={props.activeSessionId === r.session.id}
              now={props.now}
              unseen={props.unseen[r.session.id] ?? new Set()}
              completedUnseen={props.completedUnseen[r.session.id] === true}
              onOpen={() => props.onSelectSession(r.session.id)}
              onArchive={() => props.onArchive(r.session.id, true)}
            />
          ) : (
            <DeadRow
              key={r.row.id}
              row={r.row}
              leftPad={12}
              selected={props.historyId === r.row.id}
              now={props.now}
              onOpen={() => props.onOpenHistory(r.row.id)}
              onArchive={() => props.onArchive(r.row.id, true)}
            />
          ),
        )}
      {!props.query && props.rows.length > CAP && (
        <button className="show-all" onClick={props.onToggleShowAll}>
          {props.showAll ? 'Collapse' : `Show all (${props.rows.length})`}
        </button>
      )}
    </>
  )
}

function ProjectBlock(props: {
  project: ViewState['projects'][number]
  rows: Row[]
  selected: boolean
  expanded: boolean
  forcedOpen: boolean
  showAll: boolean
  query: string
  now: number
  unseen: Record<string, Set<string>>
  completedUnseen: Record<string, boolean>
  activeSessionId: string | null
  historyId: string | null
  onOpenLauncher: () => void
  onToggleExpand: () => void
  onSelectSession: (id: string) => void
  onOpenHistory: (id: string) => void
  onArchive: (id: string, flag: boolean) => void
  onNewSession: () => void
}) {
  const [hover, setHover] = useState(false)
  const expanded = props.expanded
  const filtered = props.query
    ? props.rows.filter((r) => (r.kind === 'live' ? (r.session.name ?? '') : r.row.name).toLowerCase().includes(props.query))
    : props.rows
  const shown = props.query || props.showAll ? filtered : filtered.slice(0, CAP)
  const attention = props.rows.reduce((n, r) => (r.kind === 'live' ? n + r.session.notices.length : n), 0)
  return (
    <div className="project-block">
      <div
        className={`project-row ${props.selected ? 'selected' : ''} ${hover ? 'hover' : ''}`}
        onMouseEnter={() => setHover(true)}
        onMouseLeave={() => setHover(false)}
      >
        <button
          className="project-main"
          onClick={() => {
            props.onOpenLauncher()
            if (props.selected) props.onToggleExpand()
          }}
        >
          <span className="notebook"><NotebookGlyph open={expanded} /></span>
          <span className="project-name">{props.project.name}</span>
          {(props.selected || hover) && <span className="project-chevron"><ChevronGlyph open={expanded} /></span>}
          <span className="spacer" />
          {!expanded && attention > 0 && !hover && !props.selected && <span className="attn-dot" />}
        </button>
        {(props.selected || hover) && (
          <button className="icon-btn small" title="New session in this project" onClick={props.onNewSession}>
            <ComposeGlyph size={12} />
          </button>
        )}
      </div>
      {expanded && (
        <>
          {shown.map((r) =>
            r.kind === 'live' ? (
              <LiveRow
                key={r.session.id}
                session={r.session}
                leftPad={36}
                selected={props.activeSessionId === r.session.id}
                now={props.now}
                unseen={props.unseen[r.session.id] ?? new Set()}
                completedUnseen={props.completedUnseen[r.session.id] === true}
                onOpen={() => props.onSelectSession(r.session.id)}
                onArchive={() => props.onArchive(r.session.id, true)}
              />
            ) : (
              <DeadRow
                key={r.row.id}
                row={r.row}
                leftPad={36}
                selected={props.historyId === r.row.id}
                now={props.now}
                onOpen={() => props.onOpenHistory(r.row.id)}
                onArchive={() => props.onArchive(r.row.id, true)}
              />
            ),
          )}
          {shown.length === 0 && props.rows.length === 0 && !props.forcedOpen && (
            <div className="empty-note indent">No conversations yet</div>
          )}
          {!props.query && props.rows.length > CAP && (
            <button className="show-all indented" onClick={props.onToggleExpand}>
              {props.showAll ? 'Collapse' : `Show all (${props.rows.length})`}
            </button>
          )}
        </>
      )}
    </div>
  )
}

function LiveRow(props: {
  session: ViewSession
  leftPad: number
  selected: boolean
  now: number
  unseen: Set<string>
  completedUnseen: boolean
  onOpen: () => void
  onArchive: () => void
}) {
  const [hover, setHover] = useState(false)
  const badge = props.session.notices.length
  const dot = sessionDotClass(badge, props.session.nodes, props.unseen, props.completedUnseen)
  return (
    <button
      className={`row ${props.selected ? 'selected' : ''} ${hover ? 'hover' : ''}`}
      style={{ paddingLeft: props.leftPad }}
      onClick={props.onOpen}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
    >
      <span className="row-name">{props.session.name || 'session'}</span>
      <span className="row-indicator"><Indicator dot={dot} /></span>
      <span className="row-trailing">
        {hover ? (
          <span
            className="icon-btn small"
            title="Archive"
            onClick={(e) => {
              e.stopPropagation()
              props.onArchive()
            }}
          >
            <ArchiveGlyph />
          </span>
        ) : (
          <span className="row-time">{relativeTime(props.session.createdAt, props.now)}</span>
        )}
      </span>
    </button>
  )
}

function DeadRow(props: {
  row: ViewHistoryRow
  leftPad: number
  selected: boolean
  now: number
  unarchive?: boolean
  onOpen: () => void
  onArchive: () => void
}) {
  const [hover, setHover] = useState(false)
  const at = props.row.createdAt ? Date.parse(props.row.createdAt) : props.row.modifiedAt
  return (
    <button
      className={`row dead ${props.selected ? 'selected' : ''} ${hover ? 'hover' : ''}`}
      style={{ paddingLeft: props.leftPad }}
      onClick={props.onOpen}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
    >
      <span className="row-name dead-name">{props.row.name}</span>
      <span className="row-trailing">
        {hover ? (
          <span
            className="icon-btn small"
            title={props.unarchive ? 'Unarchive' : 'Archive'}
            onClick={(e) => {
              e.stopPropagation()
              props.onArchive()
            }}
          >
            {props.unarchive ? <UnarchiveGlyph /> : <ArchiveGlyph />}
          </span>
        ) : (
          <span className="row-time">{relativeTime(at, props.now)}</span>
        )}
      </span>
    </button>
  )
}

export function SpinnerRing({ size = 11, line = 1.5 }: { size?: number; line?: number }) {
  return (
    <span
      className="spinner-ring"
      style={{ width: size, height: size, borderWidth: line }}
      aria-hidden
    />
  )
}

function Indicator({ dot }: { dot: DotClass }) {
  switch (dot) {
    case 'yellow':
      return <span className="dot-warn" />
    case 'blue':
      return <span className="dot-blue" />
    case 'spinner':
      return <SpinnerRing size={11} />
    default:
      return null
  }
}

export { XGlyph }
