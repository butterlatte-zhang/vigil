# Vigil for Windows

A Windows implementation of Vigil's design: a manager agent at the root of a live tree of
worker agents, with every node keeping its own native CLI terminal, rollups flowing up,
and the manager's context staying lean.

The macOS app in `app/` is Swift + SwiftUI + libghostty. None of those exist on Windows,
so this directory is a **design-faithful port**, not a build of the Swift sources:

| macOS (Swift) | Windows (TypeScript) |
|---|---|
| `VigilCore/Domain.swift`, `Tree.swift`, `SessionStore.swift` | `src/core/domain.ts`, `src/core/store.ts` — the same tree invariants, Command-in / Effect-out direction, attention-priority derivation |
| `VigilCore/ConfigFiles.swift` | `src/core/config.ts` — agents / roles / prompts / runtime / launcher JSON |
| `VigilRuntime/Orchestrator.swift`, `RealCell.swift` | `src/main/orchestrator.ts`, `src/main/cell.ts` — per-session orchestration, injection hold, closed-loop submit |
| `libghostty-vt` headless screen | `@xterm/headless` (`src/main/screen.ts`) — same input-line probe rules |
| `GhosttyViewBackend` (libghostty surface) | `xterm.js` in the renderer + ConPTY (`node-pty`) |
| Unix-domain sockets (`UDSListener`, shims) | Windows named pipes (`\\.\pipe\...`) + `bin/vigil-mcp.js`, `bin/vigil-hook.js` |
| `MCPToolServer.swift`, `HookGateway.swift` | `src/main/mcp-server.ts`, `src/main/hook-gateway.ts` — same JSON-RPC subset, same role-scoped tool surface |
| `ClaudeCodeHarness.swift`, `CodexHarness.swift`, `OpenCodeHarness.swift` | `src/main/harness/{claude,codex,opencode}.ts` |
| `SessionArchive.swift` | `src/main/archive.ts` — same `orchestration.jsonl` + `meta.json` formats |
| SwiftUI shell | React renderer (`src/renderer/`) in an Electron window |

## Status

| Agent | Status |
|---|---|
| Claude Code | Wired end to end and verified: MCP handshake, spawn, worker `report`, rollup delivery, turn lifecycle hooks, transcript capture, resume, auto-naming. |
| Codex | Wired and verified: per-node `CODEX_HOME`, MCP, hooks (`hooks.json`), rollout capture (sid + transcript pointer), first-prompt naming. |
| OpenCode | Wired following the original design (inline `OPENCODE_CONFIG_CONTENT` + per-node plugin), but **not verified here** — opencode is not installed on the development machine. It only appears in the launcher when the prober actually finds it. |

The core is deliberately split the same way as the Swift app: `src/core` is pure and
unit-tested; `src/main` owns processes, pipes, PTYs and files; `src/renderer` only reads
state and sends commands.

## Requirements

- Windows 10/11
- Node.js 20+ (`node` on PATH is required — the MCP/hook shims are Node scripts)
- At least one agent CLI on `PATH`: `claude`, `codex`, or `opencode`

## Build and run

```bat
cd windows
npm install
npm start
```

`npm start` compiles the core (`tsc`), builds the renderer (`vite build`), and launches
the Electron shell. The shell spawns the core as a plain Node process (so `node-pty` runs
against the Node ABI, not Electron's).

For development:

```bat
npm run dev        :: build, launch, open DevTools
npm test           :: unit tests (vitest)
npm run typecheck
```

> npm 11 blocks install scripts by default. The `allowScripts` block in `package.json`
> approves exactly the three packages that need one (`node-pty`, `esbuild`, `electron`).

The renderer is also a normal web app: `npm run build:core && npm run build:renderer`,
then `node dist/main/index.js` prints a loopback URL with a per-process token.

## How a session runs

1. The launcher probes `PATH` for agent CLIs and seeds `~/.config/vigil/` on first run.
2. Starting a session creates `%APPDATA%\Vigil\sessions\<session>\` and launches the
   selected agent in a ConPTY with:
   - `--append-system-prompt <role identity + Vigil tool list>` (claude/opencode via
     config, codex as the first prompt),
   - a per-node `settings.json` / `mcp.json` / `CODEX_HOME` pointing at two per-session
     named pipes: one for MCP tools, one for observation hooks,
   - the first task delivered by PTY injection (never argv).
3. The manager calls `spawn` / `send` / `kill` / `report` / `rename` through the MCP
   server; the tree, rollups, permission cards, queue cards and turn status all update
   from those real signals.
4. The session dir records `orchestration.jsonl` + `meta.json`; conversation content stays
   a pointer into the CLI's own transcript. Closing a session leaves it replayable; the
   History pane resumes it in place through the CLI's native `--resume` / `resume` /
   `--session`.

## Configuration

Same files, same tolerances, same directory as macOS unless overridden:

| File | What it controls |
|---|---|
| `agents.json` | the registry (launcher dropdown): bin, kind, models, extraArgs, env |
| `roles.json` | per-role agent/model/access/prompt append or override; `<project>\.vigil\roles.json` overlays |
| `prompts.json` | user-owned role identity text; `"default"` keeps the built-in line |
| `launcher.json` | default agent |
| `runtime.json` | spawn-stall window, inject hold valve, report watchdog, auto-naming, etc. |
| `detected.json` | rewritten every launch by the prober |
| `projects.json` | the sidebar's project directories (Windows addition) |

Environment overrides: `VIGIL_CONFIG_DIR`, `VIGIL_ARCHIVE_ROOT`, `VIGIL_NODE_BIN`,
`VIGIL_PROBE_DIRS`.

Sessions live under `%APPDATA%\Vigil\sessions\` (`VIGIL_ARCHIVE_ROOT` overrides).

## Keyboard shortcuts

Every shortcut is `Ctrl+Shift`-modified so plain keys, Escape, Enter and the Ctrl-series
still reach the agent's TUI untouched. (`⌘` does not exist on Windows; this is the one
deliberate deviation from the macOS table.)

| Shortcut | Action |
|---|---|
| Ctrl+Shift+T | New session (launcher) |
| Ctrl+Shift+W | Close session |
| Ctrl+Shift+B | Show / hide sidebar |
| Ctrl+Shift+J | Show / hide the tree panel |
| Ctrl+Shift+U | Jump to the latest node needing attention |
| Ctrl+Shift+] / [ | Next / previous session |

## Windows-specific notes

- **Named pipes instead of UDS.** Pipe names use forward slashes (`//./pipe/vigil-…`)
  because the path is embedded in a shell command in the hook config: claude runs hooks
  through Git Bash (which collapses `\\` in double quotes) and codex runs them through
  cmd.exe (which mis-parses a leading quoted token). Hook commands are therefore emitted
  quote-free whenever possible.
- **The terminal is xterm.js + ConPTY**, not libghostty. Injection decisions read a
  headless `@xterm/headless` mirror of each cell. The same claude dim-rule probe, codex
  `›` composer probe, opencode `┃` probe and `│ > │` fallback are ported; long pastes
  into a horizontally scrolled composer are recognised by prefix/suffix/length.
- **No Sparkle auto-update, no bottom scratch shell panel, no Xcode thin shell.** The
  scrape fallbacks for denied permissions (`PermWatcher`) and ESC-ended turns
  (`TurnWatcher`) are not ported; hook-driven turn state and the API-error transcript scan
  are. These are honest current limitations, not hidden behaviour.
- **Windows has no reliable unprivileged symlinks**, so codex passthrough files
  (`auth.json`, `AGENTS.md`, `prompts/`) are copied into the per-node home each launch
  instead of symlinked.
- **Trust prompts**: the orchestrator watches the first two minutes of every cell for
  claude's "Do you trust the files" box and answers it in the CLI's own UI, as the macOS
  app does.

## Security

The core binds `127.0.0.1` only, and the WebSocket upgrade requires the per-process token
that the shell passes in the URL. Agent CLIs are spawned with the user's own environment
and their own permission mechanism (`--permission-mode`, codex approval policy, opencode
`--auto`); Vigil never answers a keystroke on an agent's behalf except the trust-dialog
watcher described above.
