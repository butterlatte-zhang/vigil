// Read-only history pane — port of HistoryPane.swift.

import { useEffect } from 'react'
import type { HistoryDetail, TranscriptLoad, ViewNode, ViewState } from '../shared/protocol'
import type { Tokens } from './theme'
import { designStatus, statusText } from './status'
import { fmtDate, homeAbbrev } from './format'
import { NodeHeader } from './SessionPane'
import { HistoryTreePanel } from './TreePanel'
import { NotifStack } from './NotifStack'
import { ResumeHintBar, TranscriptView } from './TranscriptView'
import { resumeSyntaxFor } from '../shared/resume'

export function HistoryPane({
  state,
  detail,
  selectedNodeId,
  transcript,
  tokens,
  now,
  treeOpen,
  onSelectNode,
  onResume,
}: {
  state: ViewState
  detail: HistoryDetail | null
  selectedNodeId: string | null
  transcript: TranscriptLoad | null
  tokens: Tokens
  now: number
  treeOpen: boolean
  onSelectNode: (id: string) => void
  onResume: () => void
}) {
  const node: ViewNode | null =
    detail?.nodes.find((n) => n.id === selectedNodeId) ??
    detail?.nodes.find((n) => n.id === detail.rootID) ??
    null
  const isRoot = node !== null && node.id === detail?.rootID
  const rootResumable = Boolean(detail?.meta?.rootSessionId && detail?.meta?.projectCwd)
  const nodeResumable = node ? Boolean(detail?.sessionIds?.[node.id]) : false
  const hint =
    rootResumable && node
      ? isRoot
        ? `Press Enter to resume this conversation (${resumeSyntaxFor(detail?.nodeKinds?.[node.id] ?? 'claude')})`
        : nodeResumable
          ? `Press Enter to resume the conversation and revive this node (${resumeSyntaxFor(detail?.nodeKinds?.[node.id] ?? 'claude')})`
          : 'This node has no resume credentials — press Enter to resume the session itself'
      : null

  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Enter' && hint && !e.shiftKey && !e.ctrlKey && !e.metaKey) {
        const tag = (e.target as HTMLElement)?.tagName
        if (tag === 'INPUT' || tag === 'TEXTAREA') return
        e.preventDefault()
        onResume()
      }
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [hint, onResume])

  return (
    <div className="session-pane history-pane">
      {node ? (
        <NodeHeader
          node={node}
          isRoot={isRoot}
          model={detail?.meta?.model ?? null}
          status={statusText(designStatus(node))}
          tokens={tokens}
          trailing={fmtDate(detail?.meta?.createdAt ?? null)}
          readOnly
        />
      ) : (
        <div className="node-header">
          <span className="node-header-title">root</span>
        </div>
      )}
      <div className="center-body">
        <div className="history-content">
          {!detail ? (
            <div className="empty-transcript">Reading the orchestration log…</div>
          ) : transcript?.items && transcript.items.length > 0 ? (
            <TranscriptView items={transcript.items} stats={transcript.stats} />
          ) : transcript?.path ? (
            <div className="empty-transcript">No renderable conversation content in the transcript</div>
          ) : (
            <div className="empty-transcript">
              This node has no transcript record (never received a prompt)
            </div>
          )}
          <ResumeHintBar
            hint={hint}
            readOnlyText="Read-only — this archive has no resume credentials (old data or a very short session)"
            onResume={onResume}
          />
        </div>
        <div className="overlay-column">
          {treeOpen && detail && (detail.nodes.length ?? 0) > 1 && (
            <HistoryTreePanel
              nodes={detail.nodes}
              rootID={detail.rootID}
              selectedID={node?.id ?? null}
              lastEventAt={detail.lastEventAt}
              tokens={tokens}
              onSelect={onSelectNode}
            />
          )}
          <NotifStack
            state={state}
            activeSessionId={null}
            selectedNode={null}
            now={now}
            onOpen={() => undefined}
          />
        </div>
      </div>
    </div>
  )
}
