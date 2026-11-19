// Top bar — port of Views.swift TopBar (h50 · title · tree/terminal toggles).

import { SidebarGlyph, TerminalGlyph, TreeGlyph } from './icons'

export function TopBar({
  title,
  newTask,
  sidebarCollapsed,
  onExpandSidebar,
  showShell,
  shellOpen,
  onToggleShell,
  showTree,
  treeOpen,
  onToggleTree,
}: {
  title: string
  newTask: boolean
  sidebarCollapsed: boolean
  onExpandSidebar: () => void
  showShell: boolean
  shellOpen: boolean
  onToggleShell: () => void
  showTree: boolean
  treeOpen: boolean
  onToggleTree: () => void
}) {
  return (
    <header className="topbar drag">
      {sidebarCollapsed && (
        <>
          <button className="icon-btn no-drag" title="Expand sidebar" onClick={onExpandSidebar}>
            <SidebarGlyph />
          </button>
          <span className="topbar-divider" />
        </>
      )}
      <span className="topbar-title">{title}</span>
      {newTask && <span className="topbar-sub">· New task</span>}
      <span className="spacer" />
      {showShell && (
        <button
          className={`toggle-btn no-drag ${shellOpen ? 'open' : ''}`}
          title="Toggle bottom terminal"
          onClick={onToggleShell}
        >
          <TerminalGlyph />
        </button>
      )}
      {showTree && (
        <button
          className={`toggle-btn no-drag ${treeOpen ? 'open' : ''}`}
          title="Toggle node tree"
          onClick={onToggleTree}
        >
          <TreeGlyph />
        </button>
      )}
    </header>
  )
}
