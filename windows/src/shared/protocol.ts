// Renderer-side view of the core state. Mirrors SessionManager.state().

export type NodeStatus =
  | 'starting'
  | 'running'
  | 'idle'
  | 'waiting'
  | 'done'
  | 'failed'
  | 'killed'
  | 'stalled'
  | 'queued'
  | 'errored'

export interface ViewNode {
  id: string
  kind: 'cell' | 'observed'
  role: 'leaf' | 'manager'
  parent: string | null
  children: string[]
  status: NodeStatus
  title: string
  lastRollup: string | null
  model: string | null
  startedAt: number | null
  endedAt: number | null
}

export interface ViewNotice {
  id: string
  seq: number
  nodeID: string
  kind: 'permission' | 'inject-queued'
  text: string
  promptID?: string | null
  toolName?: string | null
  inputSummary?: string | null
  arrivedAt: number
  displayAfter: number
}

export interface ViewSession {
  id: string
  createdAt: number
  rootID: string
  name: string | null
  nodes: ViewNode[]
  notices: ViewNotice[]
  log: string[]
  transcripts: Record<string, string>
  sessionIds: Record<string, string>
  nodeKinds: Record<string, string>
  hasLiveCells: string[]
  cwdByNode: Record<string, string>
  projectId: string
  projectName: string | null
  projectCwd: string | null
  agentKey: string
  agentKind: string
  model: string | null
  nameIsCustom: boolean
  shellRunning: boolean
}

export interface ViewProject {
  id: string
  name: string
  cwd: string | null
  builtin: 'chats' | 'settings' | null
  sessionIds: string[]
}

export interface ViewAgent {
  key: string
  kind: string
  bin: string
  usable: boolean
  detected: boolean
}

export interface ViewHistoryRow {
  id: string
  name: string
  projectId: string
  projectName: string | null
  projectCwd: string | null
  agent: string | null
  model: string | null
  createdAt: string | null
  modifiedAt: number | null
  archived: boolean
  live: boolean
  rootSessionId: string | null
}

export interface TerminalPrefsState {
  fontFamily: string[]
  fontSize: number | null
  cursorStyle: string | null
  padding: number | null
  background: string | null
  foreground: string | null
  cursorColor: string | null
}

export interface Appearance {
  theme: 'auto' | 'dark' | 'light'
  accent: 'blue' | 'teal' | 'amber' | 'purple'
  terminal: TerminalPrefsState
}

export interface ViewState {
  home: string
  configDir: string
  archiveRoot: string
  chatsDir: string
  detected: Array<{ kind: string; bin: string }>
  defaultAgent: string | null
  agents: ViewAgent[]
  appearance: Appearance
  projects: ViewProject[]
  sessions: Record<string, ViewSession>
  history: ViewHistoryRow[]
}

export interface HistoryDetail {
  id: string
  rootID: string | null
  nodes: ViewNode[]
  transcripts: Record<string, string>
  sessionIds: Record<string, string>
  nodeKinds: Record<string, string>
  firstEventAt: number | null
  lastEventAt: number | null
  meta: {
    name: string
    model: string | null
    agent: string
    createdAt: string
    rootSessionId: string | null
    projectCwd: string | null
  } | null
}

export type TranscriptItemKind = 'user' | 'assistant' | 'tools' | 'notice'

export interface TranscriptItem {
  id: number
  kind: TranscriptItemKind
  text: string
}

export interface ModelUsage {
  model: string
  input: number
  output: number
  cacheRead: number
  cacheWrite: number
}

export interface TranscriptStats {
  version: string | null
  sessionId: string | null
  wallSeconds: number | null
  models: ModelUsage[]
  sessionName: string | null
}

export interface TranscriptLoad {
  path: string | null
  items: TranscriptItem[] | null
  stats: TranscriptStats | null
}
