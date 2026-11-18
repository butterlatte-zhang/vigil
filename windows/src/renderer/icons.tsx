// Icon glyphs traced from the macOS SwiftUI views (SidebarView / Views / CenterView2).

export function SidebarGlyph({ size = 15 }: { size?: number }) {
  return (
    <svg width={size} height={size * 0.8} viewBox="0 0 15 12" fill="none" aria-hidden>
      <rect x="0.75" y="0.75" width="13.5" height="10.5" rx="2.25" stroke="currentColor" strokeWidth="1.5" />
      <path d="M1 3.2a1.5 1.5 0 0 1 1.5-1.5H5v8.6H2.5A1.5 1.5 0 0 1 1 8.8V3.2Z" fill="currentColor" />
    </svg>
  )
}

export function NotebookGlyph({ open = false, size = 17 }: { open?: boolean; size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 17 17"
      fill="none"
      aria-hidden
      style={{ transform: open ? 'rotate(-10deg)' : 'none', transition: 'transform 150ms ease' }}
    >
      <rect x="3.95" y="2.95" width="11.2" height="12.6" rx="2.8" stroke="currentColor" strokeWidth="1.4" />
      <rect x="1.7" y="5.6" width="1.5" height="1.4" fill="currentColor" />
      <rect x="1.7" y="8.5" width="1.5" height="1.4" fill="currentColor" />
      <rect x="1.7" y="11.4" width="1.5" height="1.4" fill="currentColor" />
    </svg>
  )
}

export function ComposeGlyph({ size = 14 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" aria-hidden>
      <path d="M9.2 2.4 13.6 6.8 6.1 14.3l-4.4-4.4 7.5-7.5Z" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round" />
      <path d="M11.4 1.1a1.5 1.5 0 0 1 2.1 0l1.4 1.4a1.5 1.5 0 0 1 0 2.1l-.5.5-3.5-3.5.5-.5Z" fill="currentColor" />
    </svg>
  )
}

export function SearchGlyph({ size = 13 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" aria-hidden>
      <circle cx="7" cy="7" r="4.6" stroke="currentColor" strokeWidth="1.6" />
      <path d="M10.6 10.6 14 14" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
    </svg>
  )
}

export function FolderPlusGlyph({ size = 13 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" aria-hidden>
      <path d="M1.5 4.2A1.7 1.7 0 0 1 3.2 2.5h2.9l1.4 1.6h5.3a1.7 1.7 0 0 1 1.7 1.7v5.5a1.7 1.7 0 0 1-1.7 1.7H3.2a1.7 1.7 0 0 1-1.7-1.7V4.2Z" stroke="currentColor" strokeWidth="1.35" strokeLinejoin="round" />
      <path d="M8 6.9v3.6M6.2 8.7h3.6" stroke="currentColor" strokeWidth="1.35" strokeLinecap="round" />
    </svg>
  )
}

export function PersonGlyph({ size = 12 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 12 12" fill="none" aria-hidden>
      <circle cx="6" cy="3.3" r="2.1" stroke="currentColor" strokeWidth="1.5" />
      <path d="M1.2 11c.4-2.3 2.3-3.8 4.8-3.8s4.4 1.5 4.8 3.8" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    </svg>
  )
}

export function TreeGlyph({ size = 15 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 15 15" fill="none" aria-hidden>
      <rect x="2" y="1.5" width="5" height="5" rx="1.6" fill="currentColor" />
      <rect x="4" y="6.5" width="1.5" height="6.5" fill="currentColor" />
      <rect x="4" y="11.5" width="5.5" height="1.5" fill="currentColor" />
      <circle cx="12.8" cy="12.25" r="2.3" fill="currentColor" />
    </svg>
  )
}

export function TerminalGlyph({ size = 14 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" aria-hidden>
      <rect x="1.4" y="2.2" width="13.2" height="11.6" rx="2.2" stroke="currentColor" strokeWidth="1.4" />
      <path d="m4.3 6.3 2.2 2-2.2 2" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M8.3 10.4h3.2" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
    </svg>
  )
}

export function ArchiveGlyph({ size = 12 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" aria-hidden>
      <rect x="1.8" y="2.6" width="12.4" height="3.2" rx="1.1" stroke="currentColor" strokeWidth="1.35" />
      <path d="M2.8 5.8h10.4v6.1a1.5 1.5 0 0 1-1.5 1.5H4.3a1.5 1.5 0 0 1-1.5-1.5V5.8Z" stroke="currentColor" strokeWidth="1.35" />
      <path d="M6.3 8.5h3.4" stroke="currentColor" strokeWidth="1.35" strokeLinecap="round" />
    </svg>
  )
}

export function UnarchiveGlyph({ size = 12 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" aria-hidden>
      <path d="M2.8 5.8h10.4v6.1a1.5 1.5 0 0 1-1.5 1.5H4.3a1.5 1.5 0 0 1-1.5-1.5V5.8Z" stroke="currentColor" strokeWidth="1.35" />
      <path d="M8 11V6.4M6.2 8.2 8 6.3l1.8 1.9" stroke="currentColor" strokeWidth="1.35" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

export function ArrowUpGlyph({ size = 15 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" aria-hidden>
      <path d="M8 13V3.6M4 7.5 8 3.4l4 4.1" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

export function ChevronGlyph({ size = 11, open = false }: { size?: number; open?: boolean }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 12 12"
      fill="none"
      aria-hidden
      style={{ transform: `rotate(${open ? 90 : 0}deg)`, transition: 'transform 180ms ease' }}
    >
      <path d="m4.2 2.4 4 3.6-4 3.6" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

export function XGlyph({ size = 10 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 12 12" fill="none" aria-hidden>
      <path d="M2.4 2.4l7.2 7.2M9.6 2.4 2.4 9.6" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
    </svg>
  )
}

export function ClaudeBadge({ size = 38 }: { size?: number }) {
  const rays: Array<[number, number, number, number]> = [
    [13.3, 12.0, 20.0, 12.0], [13.1, 11.3, 17.9, 8.2], [12.5, 10.8, 15.3, 4.5],
    [11.9, 10.7, 11.4, 5.4], [11.2, 11.0, 7.0, 6.0], [10.8, 11.6, 5.9, 10.0],
    [10.7, 12.3, 4.4, 14.0], [11.1, 13.0, 7.6, 16.9], [11.8, 13.3, 10.6, 20.0],
    [12.5, 13.2, 14.9, 18.2], [13.1, 12.7, 18.5, 16.1],
  ]
  return (
    <div className="agent-badge claude-badge" style={{ width: size, height: size }}>
      <svg width={size * 0.66} height={size * 0.66} viewBox="0 0 24 24" fill="none" aria-hidden>
        {rays.map((r, i) => (
          <line key={i} x1={r[0]} y1={r[1]} x2={r[2]} y2={r[3]} stroke="#fff" strokeWidth="2.3" strokeLinecap="round" />
        ))}
      </svg>
    </div>
  )
}

export function CodexBadge({ size = 38 }: { size?: number }) {
  return (
    <div className="agent-badge codex-badge" style={{ width: size, height: size }}>
      <svg width={size * 0.74} height={size * 0.74} viewBox="0 0 24 24" fill="none" aria-hidden>
        <defs>
          <linearGradient id="codex-g" x1="12" y1="3" x2="12" y2="21" gradientUnits="userSpaceOnUse">
            <stop stopColor="#9BA0EC" />
            <stop offset="1" stopColor="#4B50CE" />
          </linearGradient>
        </defs>
        {[
          [12, 12, 6], [17.2, 12, 3.5], [15.68, 8.32, 3.5], [12, 6.8, 3.5], [8.32, 8.32, 3.5],
          [6.8, 12, 3.5], [8.32, 15.68, 3.5], [12, 17.2, 3.5], [15.68, 15.68, 3.5], [12, 12, 3.5],
        ].map(([x, y, r], i) => (
          <circle key={i} cx={x} cy={y} r={r} fill="url(#codex-g)" />
        ))}
        <path d="M8.3 9.5 11.8 12l-3.5 2.5" stroke="#fff" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
        <path d="M13.7 14.5h3.5" stroke="#fff" strokeWidth="2" strokeLinecap="round" />
      </svg>
    </div>
  )
}
