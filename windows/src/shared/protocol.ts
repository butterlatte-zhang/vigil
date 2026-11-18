// Renderer-side view of the core state. Mirrors Orchestrator.publicState()/SessionManager.state().

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
}

export interface ViewProject {
  id: string
  name: string
  cwd: string | null
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
  projectName: string | null
  agent: string | null
  createdAt: string | null
  modifiedAt: number | null
  archived: boolean
  live: boolean
  rootSessionId: string | null
}

export interface ViewState {
  configDir: string
  archiveRoot: string
  detected: Array<{ kind: string; bin: string }>
  defaultAgent: string | null
  agents: ViewAgent[]
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
}
