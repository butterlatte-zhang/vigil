// Time/token formatting — port of VGDuration.swift and TranscriptRender.fmtTokens.

export function relativeTime(date: number | string | null | undefined, now: number): string {
  if (date === null || date === undefined) return ''
  const t = typeof date === 'number' ? date : Date.parse(date)
  if (Number.isNaN(t)) return ''
  const s = Math.max(0, Math.floor((now - t) / 1000))
  if (s < 60) return 'just now'
  if (s < 3600) return `${Math.floor(s / 60)} min`
  if (s < 86400) return `${Math.floor(s / 3600)} hr`
  return `${Math.floor(s / 86400)} days`
}

export function runtimeSeconds(startedAt: number | null, endedAt: number | null, now: number): string {
  if (startedAt === null) return '—'
  const end = endedAt ?? now
  const s = Math.max(0, Math.floor((end - startedAt) / 1000))
  return runtimeText(s)
}

export function runtimeText(s: number): string {
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, '0')}s`
  return `${Math.floor(s / 3600)}h ${String(Math.floor((s % 3600) / 60)).padStart(2, '0')}m`
}

export function wallText(s: number): string {
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`
  return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`
}

export function fmtDate(iso: string | null): string {
  if (!iso) return ''
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) +
    ' ' + d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })
}

export function fmtTokens(n: number): string {
  const trim = (v: number) => {
    const s = v.toFixed(1)
    return s.endsWith('.0') ? s.slice(0, -2) : s
  }
  if (n < 1000) return String(n)
  if (n < 1_000_000) return trim(n / 1000) + 'k'
  return trim(n / 1_000_000) + 'm'
}

export function homeAbbrev(p: string | null | undefined, home: string): string {
  if (!p) return ''
  return p.startsWith(home) ? '~' + p.slice(home.length) : p
}
