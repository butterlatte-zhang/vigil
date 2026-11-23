// Read-only transcript view — port of TranscriptReadView / ResumeHintBar.

import { useEffect, useRef } from 'react'
import type { TranscriptItem, TranscriptStats } from '../shared/protocol'
import { fmtTokens, wallText } from './format'

export function TranscriptView({
  items,
  stats,
}: {
  items: TranscriptItem[]
  stats: TranscriptStats | null
}) {
  const ref = useRef<HTMLDivElement | null>(null)
  useEffect(() => {
    const el = ref.current
    if (el) el.scrollTop = el.scrollHeight
  }, [items, stats])

  return (
    <div className="transcript-scroll" ref={ref}>
      <div className="transcript">
        {items.map((item) => {
          switch (item.kind) {
            case 'user':
              return (
                <div key={item.id} className="tx-user">
                  <span className="tx-gutter">&gt;</span>
                  <span className="tx-body">{item.text}</span>
                </div>
              )
            case 'assistant':
              return (
                <div key={item.id} className="tx-assistant">
                  <span className="tx-gutter dot">•</span>
                  <span className="tx-body">{item.text}</span>
                </div>
              )
            case 'tools':
              return (
                <div key={item.id} className="tx-tools">
                  {item.text}
                </div>
              )
            default:
              return (
                <div key={item.id} className="tx-notice">
                  {item.text}
                </div>
              )
          }
        })}
        {stats && (stats.version || stats.sessionId || stats.models.length > 0) && (
          <StatsCard stats={stats} />
        )}
      </div>
    </div>
  )
}

function StatsCard({ stats }: { stats: TranscriptStats }) {
  const rows: Array<[string, string]> = []
  if (stats.version) rows.push(['Version:', stats.version])
  if (stats.sessionName) rows.push(['Session name:', stats.sessionName])
  if (stats.sessionId) rows.push(['Session ID:', stats.sessionId])
  if (stats.models.length > 0) rows.push(['Model:', stats.models.map((m) => m.model).join(', ')])
  if (stats.wallSeconds !== null) rows.push(['Total duration (wall):', wallText(stats.wallSeconds)])
  return (
    <div className="tx-stats">
      {rows.map(([label, value]) => (
        <div className="tx-stat-row" key={label}>
          <span className="tx-stat-label">{label}</span>
          <span className="tx-stat-value">{value}</span>
        </div>
      ))}
      {stats.models.length > 0 && (
        <>
          <div className="tx-stat-usage">Usage by model:</div>
          {stats.models.map((m) => (
            <div className="tx-stat-model" key={m.model}>
              <span className="tx-stat-model-name">{m.model}:</span>
              <span>
                {fmtTokens(m.input)} input · {fmtTokens(m.output)} output · {fmtTokens(m.cacheRead)} cache read ·{' '}
                {fmtTokens(m.cacheWrite)} cache write
              </span>
            </div>
          ))}
        </>
      )}
    </div>
  )
}

export function ResumeHintBar({
  hint,
  readOnlyText,
  onResume,
}: {
  hint: string | null
  readOnlyText: string
  onResume?: () => void
}) {
  return (
    <div className="resume-bar">
      <span className={`resume-prompt ${hint ? 'live' : ''}`}>❯</span>
      <span className="resume-text">{hint ?? readOnlyText}</span>
      <span className="spacer" />
      {hint && (
        <span className="resume-key">
          Press <span className="keycap">Enter</span> to resume
        </span>
      )}
    </div>
  )
}
