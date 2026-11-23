// Launcher — port of CenterView2.swift LauncherView. Project · agent chips, a
// plain-Enter submit, and no model/access pickers (access defaults all-open; model tier
// lives in roles.json).

import { useEffect, useRef, useState } from 'react'
import type { ViewProject, ViewState } from '../shared/protocol'
import { ArrowUpGlyph, ChevronGlyph, NotebookGlyph, PersonGlyph } from './icons'

export function Launcher({
  state,
  project,
  agentKey,
  onAgent,
  draft,
  onDraft,
  onSubmit,
  onSwitchProject,
  onAddProject,
}: {
  state: ViewState
  project: ViewProject
  agentKey: string
  onAgent: (key: string) => void
  draft: string
  onDraft: (text: string) => void
  onSubmit: (task: string) => void
  onSwitchProject: (id: string) => void
  onAddProject: () => void
}) {
  const [projectMenu, setProjectMenu] = useState(false)
  const [agentMenu, setAgentMenu] = useState(false)
  const area = useRef<HTMLTextAreaElement | null>(null)

  useEffect(() => {
    area.current?.focus()
  }, [project.id])

  const autoGrow = () => {
    const el = area.current
    if (!el) return
    el.style.height = 'auto'
    el.style.height = Math.min(Math.max(64, el.scrollHeight), 220) + 'px'
  }
  useEffect(autoGrow, [draft])

  const submit = () => {
    if (state.agents.length === 0) return
    onSubmit(draft)
  }

  return (
    <div className="launcher">
      <h1 className="launcher-title">What do you want to build in {project.name}?</h1>
      <div className="launcher-card">
        <textarea
          ref={area}
          className="launcher-prompt"
          placeholder="Type anything…"
          value={draft}
          onChange={(e) => {
            onDraft(e.target.value)
            autoGrow()
          }}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey && !e.ctrlKey && !e.metaKey && !e.altKey) {
              e.preventDefault()
              submit()
            }
          }}
        />
        <div className="launcher-actions">
          <div className="chip-wrap">
            <button className="chip" onClick={() => setProjectMenu((v) => !v)}>
              <span className="chip-glyph"><NotebookGlyph size={12} /></span>
              <span className="chip-text">{project.name}</span>
              <span className="chip-caret"><ChevronGlyph size={9} open /></span>
            </button>
            {projectMenu && (
              <div className="chip-menu" onMouseLeave={() => setProjectMenu(false)}>
                {state.projects.filter((p) => !p.builtin).map((p) => (
                  <button
                    key={p.id}
                    className="chip-menu-item"
                    onClick={() => {
                      setProjectMenu(false)
                      onSwitchProject(p.id)
                    }}
                  >
                    {p.id === project.id ? '✓ ' : ''}
                    {p.name}
                  </button>
                ))}
                <div className="chip-menu-sep" />
                <button
                  className="chip-menu-item"
                  onClick={() => {
                    setProjectMenu(false)
                    onAddProject()
                  }}
                >
                  Add project…
                </button>
              </div>
            )}
          </div>

          <div className="chip-wrap">
            <button className="chip" onClick={() => setAgentMenu((v) => !v)}>
              <span className="chip-glyph"><PersonGlyph /></span>
              <span className="chip-text">{agentKey}</span>
              <span className="chip-caret"><ChevronGlyph size={9} open /></span>
            </button>
            {agentMenu && (
              <div className="chip-menu" onMouseLeave={() => setAgentMenu(false)}>
                {state.agents.map((a) => (
                  <button
                    key={a.key}
                    className="chip-menu-item"
                    disabled={!a.usable || !a.detected}
                    onClick={() => {
                      setAgentMenu(false)
                      onAgent(a.key)
                    }}
                  >
                    {a.key}
                    {!a.usable || !a.detected ? ' (unavailable)' : ''}
                  </button>
                ))}
              </div>
            )}
          </div>

          <span className="spacer" />
          <button className="submit-btn" title="Dispatch manager (Enter)" onClick={submit}>
            <ArrowUpGlyph />
          </button>
        </div>
        {state.detected.length === 0 && (
          <div className="launcher-warning">
            No claude / codex / opencode CLI detected — install one and restart Vigil, or set the
            bin path manually in agents.json under the settings directory
          </div>
        )}
      </div>
    </div>
  )
}
