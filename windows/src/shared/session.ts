// Session/launcher constants shared by the core and the renderer.

export const configOnboardingPrompt =
  'Read README.md in this Settings directory, then follow its agent-neutral setup instructions to set up Vigil for me.'

export const configTaskPreamble =
  'Before editing Vigil settings, read README.md in this Settings directory and follow its field definitions and agent-neutral instructions.'

/** The macOS launcher's row name: first 13 chars of the task, "…" when longer. */
export function sessionNameForTask(task: string): string {
  const t = task.trim()
  if (t === '') return 'New task'
  return t.length > 13 ? t.slice(0, 13) + '…' : t
}

export function taskForConfigWorkspace(task: string): string {
  if (task === configOnboardingPrompt || task.startsWith(configTaskPreamble)) return task
  if (task.trim() === '') return configTaskPreamble
  return `${configTaskPreamble}

User request:
${task}`
}
