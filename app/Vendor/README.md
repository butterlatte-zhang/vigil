# Vendored binaries

## ghostty-vt.xcframework — libghostty-vt (headless VT emulator)

The headless terminal parser that backs `HostScreenParser` and `HeadlessBackend`
(the `renderScreen()` / `renderAttributed()` scrape source, PLAN invariant ⑦ single-source).
Replaced SwiftTerm's `HeadlessTerminal`/`Terminal` in issue #39 so the view and headless
stacks parse from **one** engine (libghostty), retiring the SwiftTerm dependency entirely.

- **Upstream**: https://github.com/ghostty-org/ghostty  (MIT — see `GHOSTTY-VT-LICENSE`)
- **Pinned SHA**: `b14d9238366f87e1792a4363d60523ced10e310f`
- **Build toolchain**: zig `0.15.2` (pin from ziglang.org — NOT brew's 0.16; `build.zig.zon`
  declares `.minimum_zig_version = "0.15.2"`).
- **Module**: `GhosttyVt` (umbrella header `ghostty/vt.h`; C ABI — `⚠️ upstream marks the vt
  API "not yet stable, breaking changes expected"`, so a SHA bump is a manual C-ABI review, §below).
- **Form**: single macOS slice `macos-arm64_x86_64` (x86_64+arm64 static `.a`, ~18 MB). The
  iOS slices upstream emits are stripped — Vigil ships macOS only. `consume` side needs **no
  zig** (prebuilt static archive, exactly like the GhosttyKit surface xcframework).

### Rebuild recipe (only when bumping the SHA)

```sh
GHOSTTY_VT_SHA=b14d9238366f87e1792a4363d60523ced10e310f
# 1. zig 0.15.2 (pin — https://ziglang.org/download/0.15.2/)
# 2. clone ghostty at the SHA, then:
zig build -Demit-lib-vt=true -Doptimize=ReleaseFast        # ~35s, zero patches
# 3. strip to the macOS slice:
xcodebuild -create-xcframework \
  -library zig-out/lib/ghostty-vt.xcframework/macos-arm64_x86_64/libghostty-vt.a \
  -headers zig-out/lib/ghostty-vt.xcframework/macos-arm64_x86_64/Headers \
  -output ghostty-vt.xcframework
# 4. strip debug entries — the archive otherwise embeds absolute build-dir paths
#    (N_OSO/comp_dir), leaking the build machine's username/paths into the repo:
strip -S ghostty-vt.xcframework/macos-arm64_x86_64/libghostty-vt.a
strings - ghostty-vt.xcframework/macos-arm64_x86_64/libghostty-vt.a | grep -c '/Users/' # must be 0
nm -gU ghostty-vt.xcframework/macos-arm64_x86_64/libghostty-vt.a | grep -c ghostty_     # sanity: >0 exports
# 5. drop it here; copy upstream LICENSE → GHOSTTY-VT-LICENSE; update the SHA above.
```

### C-ABI review on a SHA bump (the one manual gate)

`diff` the old vs new `Headers/ghostty/vt/{terminal,screen,grid_ref,style,modes,point,types}.h`.
`VtScreen.swift` depends on: `ghostty_terminal_new/free/vt_write/resize/mode_get`,
`ghostty_terminal_grid_ref` + `ghostty_grid_ref_cell/_style`, `ghostty_cell_get`
(`CODEPOINT`/`HAS_TEXT`/`WIDE`/`CONTENT_TAG`), `ghostty_grid_ref_graphemes`,
`GhosttyStyle.faint`, `ghostty_mode_new(2004,false)`. If any of those signatures/enums move,
fix `VtScreen.swift` and re-run `swift test` + `swift run vigil-parity`.
