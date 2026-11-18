// Notification card stack — port of NotifStack.swift. Permission and queued-inject
// cards from EVERY session, newest first with same-session cards adjacent.

import type { ViewNotice, ViewSession, ViewState } from '../shared/protocol'
import { relativeTime } from './format'
import { ClaudeBadge, CodexBadge } from './icons'

interface Entry {
  session: ViewSession
  notice: ViewNotice
}

export function NotifStack({
  state,
  activeSessionId,
  selectedNode,
  now,
  onOpen,
}: {
  state: ViewState
  activeSessionId: string | null
  selectedNode: string | null
  now: number
  onOpen: (sessionId: string, nodeId: string) => void
}) {
  const groups: Array<{ order: number; session: ViewSession; notices: ViewNotice[] }> = []
  Object.values(state.sessions).forEach((session, i) => {
    const visible = session.notices
      .filter((n) => n.displayAfter <= now)
      .sort((a, b) => (a.arrivedAt === b.arrivedAt ? b.seq - a.seq : b.arrivedAt - a.arrivedAt))
    if (visible.length > 0) groups.push({ order: i, session, notices: visible })
  })
  groups.sort((a, b) => {
    const x = a.notices[0].arrivedAt
    const y = b.notices[0].arrivedAt
    return x === y ? a.order - b.order : y - x
  })
  const entries: Entry[] = groups.flatMap((g) => g.notices.map((notice) => ({ session: g.session, notice })))
  if (entries.length === 0) return null

  return (
    <div className="notif-stack">
      {entries.map(({ session, notice }) => {
        const project = state.projects.find((p) => p.id === session.projectId)
        const node = session.nodes.find((n) => n.id === notice.nodeID)
        const selected = activeSessionId === session.id && selectedNode === notice.nodeID
        return (
          <button
            key={notice.id}
            className={`notif-card ${selected ? 'selected' : ''}`}
            onClick={() => onOpen(session.id, notice.nodeID)}
          >
            {session.agentKind === 'codex' ? <CodexBadge /> : <ClaudeBadge />}
            <span className="notif-body">
              <span className="notif-context">
                {(project?.name ?? session.projectName ?? 'Chats') + ' · ' + (session.name ?? 'session')}
              </span>
              <span className="notif-title">{node?.title || notice.nodeID}</span>
              <span className="notif-subtitle">{notice.text}</span>
            </span>
            <span className="notif-right">
              <span className="notif-time">
                {(() => {
                  const r = relativeTime(notice.arrivedAt, now)
                  return r === 'just now' ? r : r + ' ago'
                })()}
              </span>
              <span className="notif-chevron">›</span>
            </span>
          </button>
        )
      })}
    </div>
  )
}
