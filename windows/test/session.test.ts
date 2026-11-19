import { describe, expect, it } from 'vitest'
import {
  configOnboardingPrompt,
  configTaskPreamble,
  sessionNameForTask,
  taskForConfigWorkspace,
} from '../src/shared/session.js'

describe('launcher naming', () => {
  it('uses the first 13 characters of the task, or New task', () => {
    expect(sessionNameForTask('')).toBe('New task')
    expect(sessionNameForTask('   ')).toBe('New task')
    expect(sessionNameForTask('Fix login')).toBe('Fix login')
    expect(sessionNameForTask('Fix the login bug today')).toBe('Fix the login…')
  })
})

describe('Settings workspace tasks', () => {
  it('wraps a plain task with the README preamble', () => {
    const out = taskForConfigWorkspace('set the theme to dark')
    expect(out.startsWith(configTaskPreamble)).toBe(true)
    expect(out).toContain('User request:\nset the theme to dark')
  })

  it('does not double-wrap the onboarding prompt or an already-wrapped task', () => {
    expect(taskForConfigWorkspace(configOnboardingPrompt)).toBe(configOnboardingPrompt)
    const wrapped = taskForConfigWorkspace('x')
    expect(taskForConfigWorkspace(wrapped)).toBe(wrapped)
    expect(taskForConfigWorkspace('')).toBe(configTaskPreamble)
  })
})
