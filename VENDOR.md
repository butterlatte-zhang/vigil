# Third-Party Dependencies

Vigil is licensed under **GPL-3.0-or-later** (see [`LICENSE`](./LICENSE)). This file
inventories the third-party code Vigil bundles, links, or otherwise depends on, together
with each component's upstream license. All licenses listed below are compatible with
GPL-3.0-or-later.

Two kinds of components are tracked:

- **Runtime / distributed** — linked into the shipped app; their licenses travel with any
  binary distribution of Vigil.
- **Test-only** — used by `swift test` and CI; never linked into the shipped app.

## Vendored in-tree

These are checked into this repository directly (not resolved by SwiftPM).

### libghostty-vt (headless VT emulator)

- **Path**: `app/Vendor/ghostty-vt.xcframework` (license: `app/Vendor/GHOSTTY-VT-LICENSE`)
- **Upstream**: [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty)
- **Pinned SHA**: `b14d9238366f87e1792a4363d60523ced10e310f`
- **License**: **MIT** (Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors)
- **Usage**: The headless terminal parser backing `HostScreenParser` / `HeadlessBackend`
  (the `renderScreen()` / `renderAttributed()` scrape source). Built from the pinned SHA with
  `zig build -Demit-lib-vt=true` (zig 0.15.2), stripped to the macOS slice
  (`macos-arm64_x86_64`), and vendored as a prebuilt static archive — the consume side needs
  no zig toolchain. Replaced SwiftTerm in issue #39 so the view and headless stacks parse from
  one engine. Rebuild recipe and C-ABI review gate: `app/Vendor/README.md`.

### VigilGhosttyTerminal (libghostty-spm source fork)

- **Path**: `app/Sources/VigilGhosttyTerminal/` (license: `app/Sources/VigilGhosttyTerminal/LICENSE`)
- **Upstream**: [Lakr233/libghostty-spm](https://github.com/Lakr233/libghostty-spm) 1.2.8
- **License**: **MIT** (Copyright (c) 2026 @Lakr233)
- **Usage**: Vendored from libghostty-spm 1.2.8 with Vigil modifications marked `// VIGIL:`
  (per-surface command/env, viewport scrape, synthesized keys, `CHILD_EXITED` exit surface,
  wakeup fan-out). Wraps the GhosttyKit surface for the on-screen terminal view.

## Resolved via SwiftPM

Pinned in `app/Package.resolved`. Versions below are the resolved pins at time of writing.

### Runtime / distributed

| Component | Version | License | Upstream | Usage |
|---|---|---|---|---|
| libghostty-spm (GhosttyKit) | 1.2.8 | MIT | [Lakr233/libghostty-spm](https://github.com/Lakr233/libghostty-spm) | Prebuilt `GhosttyKit.xcframework` — the libghostty surface (on-screen terminal rendering + PTY). Pinned `exact`. |
| MSDisplayLink | 2.1.0 | MIT | [Lakr233/MSDisplayLink](https://github.com/Lakr233/MSDisplayLink) | Display-link driver used by the GhosttyKit surface render loop. |

### Test-only

Linked only into test targets (`VigilAppTests`); not present in the shipped app.

| Component | Version | License | Upstream | Usage |
|---|---|---|---|---|
| swift-snapshot-testing | 1.19.2 | MIT | [pointfreeco/swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) | T1c snapshot tests. |
| ViewInspector | 0.10.3 | MIT | [nalexn/ViewInspector](https://github.com/nalexn/ViewInspector) | T1b SwiftUI view-wiring tests. |
| swift-custom-dump | 1.6.1 | MIT | [pointfreeco/swift-custom-dump](https://github.com/pointfreeco/swift-custom-dump) | Transitive dependency of swift-snapshot-testing. |
| xctest-dynamic-overlay | 1.10.1 | MIT | [pointfreeco/xctest-dynamic-overlay](https://github.com/pointfreeco/xctest-dynamic-overlay) | Transitive dependency of swift-snapshot-testing. |
| swift-syntax | 603.0.2 | Apache-2.0 | [swiftlang/swift-syntax](https://github.com/swiftlang/swift-syntax) | Transitive dependency (snapshot-testing macros). |

## External agent CLIs (not bundled)

Vigil drives third-party agent CLIs as separate processes discovered on the host (`claude`,
`codex`, `opencode`). These are **not** bundled, linked, or redistributed with Vigil — they
are invoked as external binaries the user installs independently — so their licenses are not
carried by a Vigil distribution. They are listed here only to document the runtime
integration surface.
