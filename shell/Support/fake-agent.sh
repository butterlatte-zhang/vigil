#!/bin/bash
# fake-agent.sh — scriptable stand-in for a real claude cell (T2 golden flows, worker D).
#
# Launched by ScriptHarness as `/bin/bash fake-agent.sh` inside the cell's PTY, with the
# session's REAL channel endpoints in env (see app/Sources/VigilRuntime/ScriptHarness.swift):
#   VIGIL_NODE        this cell's node id           VIGIL_TASK      the task text
#   VIGIL_HOOK_SOCK   hook UDS (observation feed)   VIGIL_MCP_SOCK  MCP UDS (spawn/… gate)
#
# Scripted behavior (toggled via XCUITest launchEnvironment, inherited through the app):
#   VIGIL_FAKE_SPAWN_CHILD=1    root spawns ONE child through the real MCP gate → rail tree grows
#   VIGIL_FAKE_NOTIFY_AFTER=N   after N seconds, raise a Notification envelope → notif card
#
# Wire formats mirror the real clients (vigil-hook / vigil-mcp): one JSON line over the UDS.
set -u

echo "[fake-agent] node=${VIGIL_NODE-?} task=${VIGIL_TASK-}"

# Children run this same script (the harness is session-wide). Only root performs the
# scripted actions, so a spawned child can never recurse.
if [ "${VIGIL_NODE-}" = "root" ]; then
  if [ "${VIGIL_FAKE_SPAWN_CHILD-}" = "1" ] && [ -n "${VIGIL_MCP_SOCK-}" ]; then
    {
      printf '{"node":"%s"}\n' "$VIGIL_NODE"   # MCPToolServer handshake
      printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"spawn","arguments":{"role":"leaf","task":"fake child"}}}\n'
      sleep 1                                   # keep the pipe open for the reply
    } | /usr/bin/nc -U "$VIGIL_MCP_SOCK" >/dev/null 2>&1
    echo "[fake-agent] spawn requested via MCP"
  fi
  if [ -n "${VIGIL_FAKE_NOTIFY_AFTER-}" ] && [ -n "${VIGIL_HOOK_SOCK-}" ]; then
    sleep "$VIGIL_FAKE_NOTIFY_AFTER"
    # Same envelope vigil-hook sends; HookGateway also accepts a top-level "message".
    printf '{"node":"%s","event":"notification","message":"fake agent is waiting for your input"}\n' "$VIGIL_NODE" \
      | /usr/bin/nc -U "$VIGIL_HOOK_SOCK" >/dev/null 2>&1
    echo "[fake-agent] notification sent"
  fi
fi

# Stay alive like an interactive agent so the terminal pane keeps a live PTY.
while :; do sleep 3600; done
