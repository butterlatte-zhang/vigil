#!/usr/bin/env node
// node-pty 1.1.0 — make the ConPTY console-list agent tolerate a shell that is already gone.
//
// WindowsPtyAgent.kill() forks conpty_console_list_agent and kills the pty in the same
// tick. The forked node takes ~50 ms to boot, so by the time the agent calls the native
// AttachConsole(shellPid) the shell has already been terminated — the call throws an
// uncaught "AttachConsole failed" (stderr spam on every pty kill) and the parent then
// waits out its 5 s timeout before falling back to the shell pid.
//
// This patch catches that failure and reports [shellPid] right away, which is exactly
// what the timeout fallback resolves to. It is idempotent and runs from `postinstall`;
// pass a node-pty directory as the first argument to patch a packaged copy.
//
// Remove it once node-pty upstream handles the dead-shell case itself.

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const winRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const ptyRoot = path.resolve(process.argv[2] ?? path.join(winRoot, 'node_modules', 'node-pty'))
const MARKER = 'vigil: tolerate a shell that is already gone'

const edits = [
  {
    file: path.join(ptyRoot, 'lib', 'conpty_console_list_agent.js'),
    from: 'var consoleProcessList = getConsoleProcessList(shellPid);',
    to: [
      'var consoleProcessList;',
      'try {',
      '    consoleProcessList = getConsoleProcessList(shellPid);',
      '}',
      'catch (e) {',
      `    // ${MARKER} — node-pty kills the pty in the same tick this`,
      '    // agent is forked, so AttachConsole() usually runs after the shell has exited.',
      "    // Report the shell pid, exactly like windowsPtyAgent's 5 s timeout fallback.",
      '    consoleProcessList = [shellPid];',
      '}',
    ].join('\n'),
  },
  {
    file: path.join(ptyRoot, 'src', 'conpty_console_list_agent.ts'),
    // Packaged installs only ship lib/; keep src/ in sync when it is there.
    optional: true,
    from: 'const consoleProcessList = getConsoleProcessList(shellPid);',
    to: [
      'let consoleProcessList: number[];',
      'try {',
      '  consoleProcessList = getConsoleProcessList(shellPid);',
      '} catch {',
      `  // ${MARKER} — node-pty kills the pty in the same tick this`,
      '  // agent is forked, so AttachConsole() usually runs after the shell has exited.',
      "  // Report the shell pid, exactly like windowsPtyAgent's 5 s timeout fallback.",
      '  consoleProcessList = [shellPid];',
      '}',
    ].join('\n'),
  },
]

if (!fs.existsSync(ptyRoot)) {
  console.log(`patch-node-pty: no node-pty at ${ptyRoot}, skipping`)
  process.exit(0)
}

for (const edit of edits) {
  const rel = path.relative(winRoot, edit.file)
  if (!fs.existsSync(edit.file)) {
    if (edit.optional) {
      console.log(`patch-node-pty: no ${rel} (packaged copy), skipping`)
      continue
    }
    console.warn(`patch-node-pty: missing ${rel}`)
    process.exitCode = 1
    continue
  }
  const original = fs.readFileSync(edit.file, 'utf8')
  if (original.includes(MARKER)) {
    console.log(`patch-node-pty: already patched ${rel}`)
    continue
  }
  if (!original.includes(edit.from)) {
    console.warn(`patch-node-pty: pattern not found in ${rel} — node-pty changed? not patched`)
    process.exitCode = 1
    continue
  }
  fs.writeFileSync(edit.file, original.replace(edit.from, edit.to))
  console.log(`patch-node-pty: patched ${rel}`)
}
