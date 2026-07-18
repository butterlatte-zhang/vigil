# app — Vigil product code

The product implementation of DOCTRINE §10. Currently only **VigilCore** (the orchestration
core, pure logic) has landed.

## Status (2026-06-28)

- **VigilCore ✅ wired up**: `swift test` → **19/19 all green** (8 Tree + 11 SessionStore).
  Pure logic, zero UI / zero SwiftTerm — the brain can be deterministically unit-tested without
  a real agent, replicating the Python PoC's fake_node test approach (§12.5-C); this is
  the same trick in Swift form.
- VigilRuntime / VigilApp / vigil-hook / vigil-mcp: **not yet landed** (DOCTRINE §10 step3+).

## VigilCore contents (Phase-1 minimal scope, DOCTRINE §10.0)

| File | Contents |
|---|---|
| `Domain.swift` | NodeID/Role/NodeKind(cell·observed)/NodeStatus/Node · three request flavors (struct/perm/ask) · InboxEvent · Command/Decision/Effect/Resolution/StructResult |
| `Tree.swift` | single-root/single-parent/acyclic invariant · spawn · kill/sealSubtree (whole dead subtree kept as a death record, #41) · lca/path/subtree |
| `SessionStore.swift` | @MainActor @Observable unidirectional store: minimal gate (everything enqueues) · unified request-response (replyID+deliver) · NodeStatus state machine + symmetric self-death cascade · idempotency (deliver fires only once) · single-level rollup · LCA routing |
| `Protocols.swift` | `CellHandle` / `Harness` / `LaunchSpec` decoupling seams (implemented by Runtime, faked in tests via FakeCell) |

**Verified behavior** (test coverage): gated spawn returns the child id · a leaf cannot
spawn→failed · deny does not change the tree · kill cascades to revoke pending requests +
release blocking + killCells · self-death preserves terminal state / anti-subtree / release ·
nodeExited(0)=done · decide is idempotent, delivered only once · single-level rollup routes to
the parent · perm allow/deny · ask answer returns text · message travels via LCA path.

**Intentionally not built in Phase 1** (DOCTRINE §10.0): the full GatePolicy family
(scope=always/hard-confirm/maxDepth…) · identity authentication (plaintext nodeID) · worktree
salvage · multi-level rollup · ack queue.

## Running the tests
```sh
swift test
```
Requires Swift 6.x / macOS 14+ (`@Observable` uses Observation). Language mode is v5 for now
(DOCTRINE §8).
