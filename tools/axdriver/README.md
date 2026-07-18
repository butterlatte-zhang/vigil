# axdriver — macOS Accessibility driver CLI (the agent's hands)

A single-file Swift CLI (269 lines) that lets an AI agent drive the real Vigil app during a dev
session **by element (accessibilityIdentifier) rather than by coordinate** to verify changes.
It's not a test framework (that's what the T1b/T1c/T2 test layers are for) —
it's an ad-hoc verification tool for development time. The id contract is
`app/ACCESSIBILITY_IDS.md` (dotted namespaces).

## Build

```sh
cd tools/axdriver
swiftc -O -o axdriver axdriver.swift
```

No dependencies at all (only system frameworks AppKit / ApplicationServices). The build product
`axdriver` is gitignored and not committed — rebuild it whenever you need it.

## Permissions

- **Accessibility (required)**: System Settings → Privacy & Security → Accessibility → enable
  the toggle for **the terminal running axdriver** (Terminal / iTerm / IDE). Without permission,
  axdriver prints guidance and exits with code 2 — it never fails silently.
- **Screen Recording (only needed for screenshot)**: same path → Screen Recording.

## Subcommands

By default the target app is auto-discovered as the running **VigilApp**; every command accepts
`--app <bundle-id|pid|process-name>` to override this. **When multiple instances share a name**
(e.g. the user already has a Vigil open and an agent starts a test instance), axdriver warns on
stderr and picks the "most recently launched" one — **when in doubt, pass the pid explicitly**
(`--app 12345`) rather than risk driving the instance the user is actually using.

```sh
axdriver tree [<app>] [--max-depth N]   # dump the element tree (role/title/id/frame/value, JSON)
axdriver find <id> [--timeout seconds]  # find an element by id; exact or prefix match; exit 3 if not found
axdriver click <id>                     # click: prefers AXPress, falls back to a click at the element's center
axdriver type <id> <text>               # focus the element then type: prefers writing AXValue directly, falls back to CGEvent key input
axdriver screenshot [--out path]        # screenshot of the target app's front window (screencapture -l; if the window is on another Space, it's auto-activated and retried)
```

id-matching rule (shared by `find`/`click`/`type`): `identifier == query` or
`identifier.hasPrefix(query)` — so a prefix like `rail.node.` matches every dynamic id row;
`find` returns all matches, `click`/`type` take the first one. `find`/`click`/`type` poll for up
to 3 seconds by default (`--timeout` is adjustable), tolerating UI that hasn't finished
rendering yet.

## Typical usage for an agent

```sh
# 0) launch your own test instance (never drive the Vigil instance the user is actually using!)
cd app && swift build && ./.build/debug/VigilApp & APP_PID=$!
sleep 3

# 1) dump the whole tree, check state (launcher state? terminal state? which ids exist?)
axdriver tree $APP_PID | grep '"id"'

# 2) type a prompt into the launcher, click submit, screenshot to verify
axdriver type launcher.prompt "hello" --app $APP_PID
axdriver click launcher.submit --app $APP_PID     # ⚠️ this really dispatches an agent — only click this in your test instance
axdriver screenshot --app $APP_PID --out /tmp/after-submit.png

# 3) kill your own instance when done
kill $APP_PID
```

## Verification record (2026-07-03, macOS 26.5.1 / Swift 6.2.3, real run)

Target: a real VigilApp built with `swift build` (the testfx branch, with Worker A's
identifiers, commit b0407e1) + a minimal SwiftUI test app (with a counter button). Every command
ran successfully:

- **tree**: dumped the complete tree; contract ids
  `launcher.prompt/agentPicker/permissionPicker/branchLabel/submit`, `rail.project.p-vigil`,
  `rail.addProject`, `rail.collapseToggle`, etc. all visible.
- **find**: both exact match (`find launcher.submit` → 1 AXButton) and prefix match
  (`find rail.project.` → 2 project rows) hit; exits 3 when nothing is found.
- **click**: clicked the test app's counter button twice in a row (the AXPress path), then
  `find mini.count` read back `"value": "count: 2"` — click→state change→read-back, a closed
  verification loop.
- **type**: after `type launcher.prompt "axdriver-test-123"` (the AXValue path), `find
  launcher.prompt` read back `"value": "axdriver-test-123"`, and the screenshot visibly showed
  the text in the input box.
- **screenshot**: produced a 2880×1960 PNG, clearly showing the launcher state with its typed
  content.

### Pitfalls hit along the way (real experience — agents take note)

1. **Duplicate-name instances**: during verification, the user's Vigil (an old binary from the
   main repo, no identifiers) and the test instance were both running at once, and the default
   resolution briefly picked the user's instance — none of the contract ids showed up in the
   tree, which looked like "identifiers aren't wired up." It was actually the wrong process.
   axdriver now warns and picks the most recently launched one, but **pid ordering is not
   guaranteed to reflect old vs. new**, so the safe approach is always to pass
   `--app <the pid of the instance you started yourself>`.
2. **SwiftUI's id is directly visible through the AX API**, no need for anything like an
   AXEnhancedUserInterface toggle (verified empirically on both the minimal SwiftUI app and
   VigilApp); if the tree shows no ids, first suspect a stale binary or the wrong process.
3. **A screenshot failure isn't necessarily a permissions issue**: if the window is on a
   different Space, `screencapture -l` can't capture it; axdriver already has a built-in
   "activate the app and retry once" fallback for this.
4. For apps launched with nohup, `launchDate` is nil, so multi-instance selection falls back to
   comparing pids (see pitfall 1).
