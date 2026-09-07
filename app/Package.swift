// swift-tools-version:6.0
import PackageDescription

// Vigil — the product (DOCTRINE §4 module layout). Boundaries enforced by target deps:
//   VigilCore    pure orchestration logic, ZERO UI / ZERO terminal (the testable brain)
//   VigilRuntime real I/O: RealCell (libghostty backends), MCP/hook gateways, harness, registry
//   VigilApp     SwiftUI shell: three panes subscribing one SessionStore
//   vigil-hook   tiny fire-and-forget UDS hook client (observation channel, D13)
//   vigil-mcp    tiny stdio↔UDS pipe (MCP channel)
//   VigilShimCore UDS client boilerplate shared by the two shims (Foundation/Darwin only)
//   vigil-smoke  real-claude end-to-end smoke (Tier-2, manual — NEVER run by `swift test`)
// Language mode v5 for now (DOCTRINE §8); tighten to v6 with the terminal-backend boundary work.
// Issue #39: terminal stack is now single-engine libghostty (GhosttyKit surface + libghostty-vt
// headless); SwiftTerm retired.
let package = Package(
    name: "Vigil",
    platforms: [.macOS(.v14)],          // Observation (@Observable) needs macOS 14
    products: [
        // Library product so the Xcode thin shell (shell/VigilShell.xcodeproj, T2 XCUITest)
        // can link the app body without copying sources. Run locally: `swift run Vigil`.
        .library(name: "VigilApp", targets: ["VigilApp"]),
        // For spike/ghostty (M0 harness keeps working against the product copy).
        .library(name: "VigilGhosttyTerminal", targets: ["VigilGhosttyTerminal"]),
    ],
    dependencies: [
        // libghostty core: prebuilt GhosttyKit.xcframework via libghostty-spm, pinned
        // exact (D14; self-built pipeline deferred to M4).
        .package(url: "https://github.com/Lakr233/libghostty-spm", exact: "1.2.8"),
        .package(url: "https://github.com/Lakr233/MSDisplayLink.git", from: "2.1.0"),
        // Auto-update engine (issue: Sparkle integration). Pinned exact, same discipline as
        // libghostty-spm above; bump deliberately alongside the vendored CLI tools in
        // .claude/skills/release-package/.sparkle-tools/ (those aren't SPM products, see SKILL.md).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
        // Test-only (VigilAppTests): T1b view wiring + T1c snapshots
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        .target(name: "VigilCore"),
        // libghostty-vt — headless VT emulator (issue #39). Self-built from ghostty-org/ghostty
        // @ b14d923 with `zig build -Demit-lib-vt=true` (zig 0.15.2), stripped to the macOS
        // slice, vendored in-tree (MIT, app/Vendor/GHOSTTY-VT-LICENSE). Backs VtScreen →
        // HostScreenParser/HeadlessBackend, retiring SwiftTerm. consume side needs NO zig
        // (prebuilt static archive). Rebuild recipe: app/Vendor/README.md.
        .binaryTarget(name: "GhosttyVT", path: "Vendor/ghostty-vt.xcframework"),
        // Vendored from Lakr233/libghostty-spm 1.2.8 (MIT, LICENSE in-tree) with
        // Vigil modifications marked `// VIGIL:` — per-surface command/env, viewport
        // scrape, synthesized keys, CHILD_EXITED exit surface, wakeup fan-out.
        .target(
            name: "VigilGhosttyTerminal",
            dependencies: [
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                "MSDisplayLink",
            ],
            exclude: ["LICENSE"]),
        .target(
            name: "VigilRuntime",
            dependencies: [
                "VigilCore", "GhosttyVT", "VigilGhosttyTerminal",
                .product(name: "Sparkle", package: "Sparkle"),
            ]),
        // Library (not executable) so BOTH entry shells can link it: the SwiftPM stub
        // `Vigil` and the Xcode thin shell `shell/VigilShell` (T2).
        .target(
            name: "VigilApp",
            dependencies: ["VigilCore", "VigilRuntime"],
            resources: [.copy("Resources/vigil-app-icon.png")]),
        // App executable named `Vigil` (was `vigil-app`, mac-flow audit #3). `swift run Vigil`
        // builds a BARE executable (no .app bundle), so macOS derives the App menu's
        // About/Hide/Quit strings from the executable FILENAME — filename `Vigil` makes them
        // read "About Vigil" / "Quit Vigil" deterministically (verified real-machine, AX read).
        // The embedded Info.plist below only fixes the bold menu-bar title (CFBundleName) and
        // is LaunchServices-cache/timing dependent for About/Hide/Quit, so the FILENAME is the
        // real fix and the plist is reinforcement + bundle identity. (Full .app packaging with
        // an icon is a separate backlog item.)
        .executableTarget(
            name: "Vigil",
            dependencies: ["VigilApp"],
            path: "Sources/Vigil",
            // Embed Info.plist into the Mach-O `__TEXT,__info_plist` section so Bundle.main
            // reports CFBundleName/CFBundleIdentifier="Vigil"/"dev.vigil.Vigil" WITHOUT a
            // bundle (fixes the bold App-menu title). Path is relative to the package root (app/).
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Vigil-Info.plist",
                ])
            ]),
        // Zero-dependency (Foundation/Darwin only) UDS client boilerplate shared by the
        // two shims — extracted from two drifted verbatim copies (R1, review-0708).
        .target(name: "VigilShimCore"),
        .executableTarget(
            name: "vigil-hook", dependencies: ["VigilShimCore"], path: "Sources/vigil-hook"),
        .executableTarget(
            name: "vigil-mcp", dependencies: ["VigilShimCore"], path: "Sources/vigil-mcp"),
        .executableTarget(
            name: "vigil-smoke",
            dependencies: ["VigilCore", "VigilRuntime"],
            path: "Sources/vigil-smoke"),
        // Tier-2 manual (needs window server + Metal): libghostty-vt headless vs ghostty
        // surface renderScreen parity + send/terminate semantics (#39).
        .executableTarget(
            name: "vigil-parity",
            dependencies: ["VigilCore", "VigilRuntime"],
            path: "Sources/vigil-parity"),
        // issue #44 winsize timing diagnostic (Tier-2 manual, like vigil-parity): drives the
        // real GhosttyViewBackend → surface → HostPTY path through an off-screen window to
        // trace resize events + the forkpty winsize. Needs AppKit + a window server; never
        // run by `swift test`. See Sources/vigil-winrepro/main.swift for scenarios.
        .executableTarget(
            name: "vigil-winrepro",
            dependencies: ["VigilRuntime", "VigilGhosttyTerminal"],
            path: "Sources/vigil-winrepro"),
        // 2026-07-27 theme-flip-residue investigation (Tier-2 manual, like vigil-winrepro):
        // drives the real TerminalController.setColorScheme broadcast against a MOUNTED
        // GhosttyViewBackend surface with a synthetic mode-2031-subscribed PTY child, to test
        // whether a live surface's own broadcast actually delivers CSI ?997/a redraw nudge.
        // See Sources/vigil-colorflip/main.swift.
        .executableTarget(
            name: "vigil-colorflip",
            dependencies: ["VigilRuntime", "VigilGhosttyTerminal"],
            path: "Sources/vigil-colorflip"),
        .testTarget(name: "VigilCoreTests", dependencies: ["VigilCore"]),
        .testTarget(name: "VigilShimCoreTests", dependencies: ["VigilShimCore"]),
        .testTarget(name: "VigilRuntimeTests", dependencies: ["VigilRuntime", "VigilCore"],
                    resources: [.copy("Resources/claude-2.1.206-input-nondim.raw"),
                                .copy("Resources/claude-2.1.206-input-dim.raw"),
                                .copy("Resources/codex-0.144-composer-empty.raw"),
                                .copy("Resources/codex-0.144-composer-typed.raw"),
                                .copy("Resources/opencode-composer-empty.raw"),
                                .copy("Resources/opencode-composer-typed.raw"),
                                // #65: REAL claude 2.1.263 startup stream (pty harness answering
                                // DA/OSC 11, trusted cwd; plan-tier text blanked) — alt screen +
                                // mouse tracking + focus reporting. Guards attach synthesis
                                // against losing the input regime a background-born node needs.
                                .copy("Resources/claude-2.1.263-startup-altscreen-mouse.raw"),
                                // #57: REAL codex 0.144.1 rollouts (base_instructions redacted) —
                                // a MAIN session (thread_source=user) + a task-spawned SUB-AGENT
                                // (thread_source=subagent), same codex-home. Guards the sub-agent
                                // exclusion in newestRollout against format drift.
                                .copy("Resources/rollout-codex-0.144.1-main-sample.jsonl"),
                                .copy("Resources/rollout-codex-0.144.1-subagent-sample.jsonl"),
                                // One proven false-idle form (not necessarily n43's): a REAL claude
                                // 2.1.209 running frame scraped at a narrow 58-col pane — the footer
                                // is truncated to "… · esc to…", so the running anchor is off-screen
                                // mid-turn. Guards TurnWatcher's activity-based liveness vs regression.
                                .copy("Resources/claude-2.1.209-narrow58-truncated-footer.raw")]),
        // @testable import of an executable target is supported since Swift 5.5.
        .testTarget(
            name: "VigilAppTests",
            dependencies: [
                "VigilApp", "VigilCore", "VigilGhosttyTerminal",
                "ViewInspector",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            // #50: a REAL codex 0.144.1 rollout (base_instructions trimmed) — guards
            // parseCodex/codexStats against live format drift (#46 gold pattern).
            // Snapshot goldens + the T1c conventions README live in the source tree
            // (SnapshotTesting locates __Snapshots__ via #filePath, not the bundle) —
            // exclude them so SPM stops warning about unhandled files.
            exclude: ["__Snapshots__", "README.md"],
            // #50/#55: REAL codex rollout + opencode export samples — guard
            // parseCodex/parseOpenCode against live format drift (#46 gold pattern).
            resources: [.copy("Resources/rollout-codex-0.144.1-sample.jsonl"),
                        .copy("Resources/opencode-1.17.18-export-sample.json")]),
    ],
    swiftLanguageModes: [.v5]
)
