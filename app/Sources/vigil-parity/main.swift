// vigil-parity — renderScreen parity between the two terminal backends (Tier-2, MANUAL;
// never run by `swift test` — needs a window server + Metal, same class as vigil-smoke).
// The same script is fed to HeadlessBackend (HostPTY + the
// libghostty-vt VtScreen, kept for tests/vigil-smoke) and to GhosttyViewBackend
// (the app's on-screen core). GhosttyViewBackend's scrape source
// is a host-side VtScreen parser (HostScreenParser) fed by Vigil's own PTY — the SAME libghostty
// engine HeadlessBackend uses, so renderScreen parity holds by construction.
// This still cross-checks two distinct process/render paths (headless HostPTY+parser vs surface
// HostPTY+parser+ghostty session). Asserts what both sides share:
//   • key lines appear verbatim ("Do you trust …" style matching stays greppable)
//   • word gaps are REAL spaces
//   • send("1\r") — the trust-watcher injection — round-trips through the PTY
//   • cold-window send lands immediately (host injection, no queue)
//   • multi-line body → ONE bracketed paste + ONE CR
//   • terminate() fires onEnd exactly once
//   • normal exit: waitpid takes the real code, NO login(1) wrapper file
//
// Run:  cd app && swift run vigil-parity

import AppKit
import Foundation
import VigilRuntime

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ msg: String) -> Never { print("PARITY FAIL: \(msg)"); exit(1) }
func pass(_ msg: String) { print("PARITY PASS: \(msg)") }

let workDir = NSTemporaryDirectory() + "vigil_parity_\(getpid())"
try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)

// The probe script: prints a trust-style prompt with multi-space word gaps, waits for a
// line (the "1\r" injection), echoes it back, then idles so the grid stays stable.
let script = workDir + "/probe.sh"
try? ("#!/bin/sh\n"
    + "echo 'Do you trust the files in this folder?'\n"
    + "echo 'GAP_CHECK alpha beta gamma'\n"
    // §12.3 ORIGINAL shape — TUI cursor positioning leaves the cells
    // between the two columns UNWRITTEN (NUL in the grid), not space-typed. CHA to
    // column 20 after an 8-char prefix leaves columns 9–19 (11 cells) untouched.
    + "printf 'NULGAP:A\\033[20GB\\n'\n"
    + "read answer\n"
    + "echo \"ANSWERED:$answer\"\n"
    + "sleep 300\n")
    .write(toFile: script, atomically: true, encoding: .utf8)
chmod(script, 0o755)

let KEY1 = "Do you trust the files in this folder?"
let KEY2 = "GAP_CHECK alpha beta gamma"
// "NULGAP:A" fills columns 1–8, B lands on column 20 → 11 never-written cells between.
let NUL_GAP_LINE = "NULGAP:A" + String(repeating: " ", count: 11) + "B"

// Unwritten grid cells must scrape as REAL spaces (§12.3) — the line
// must be greppable as A…B with a plain-space gap, and both backends must agree.
@MainActor
func checkNulGap(_ backend: TerminalBackend, _ name: String) -> String {
    let screen = backend.renderScreen()
    guard let line = screen.split(separator: "\n", omittingEmptySubsequences: false)
        .first(where: { $0.contains("NULGAP:A") }) else {
        fail("\(name): NULGAP line missing\n---\n\(screen)\n---")
    }
    guard !line.contains("\0") else {
        fail("\(name): NUL bytes leaked into renderScreen() gap (issue #5)")
    }
    guard line.contains(NUL_GAP_LINE) else {
        fail("\(name): unwritten cells not rendered as real spaces (issue #5): [\(line)]")
    }
    // canonical form for the cross-backend comparison (trailing pad may differ)
    var trimmed = String(line)
    while trimmed.hasSuffix(" ") { trimmed.removeLast() }
    return trimmed
}

@MainActor
func waitFor(_ timeout: TimeInterval, _ predicate: () -> Bool) async -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    return false
}

@MainActor
func run() async {
    // --- libghostty-vt headless side ---
    let headless = HeadlessBackend(cols: 120, rows: 32)
    headless.start(executable: "/bin/sh", args: [script], env: ["TERM": "xterm-256color"],
                   cwd: workDir) { _ in }
    let hReady = await waitFor(15) {
        let s = headless.renderScreen()
        return s.contains(KEY1) && s.contains(KEY2) && s.contains("NULGAP:A")
    }
    guard hReady else { fail("headless: key lines never appeared\n\(headless.renderScreen())") }
    let hNulLine = checkNulGap(headless, "headless")
    headless.send("1\r")
    let hAnswered = await waitFor(10) { headless.renderScreen().contains("ANSWERED:1") }
    guard hAnswered else { fail("headless: ANSWERED:1 missing after send(\"1\\r\")") }
    pass("headless (libghostty-vt): keys + gaps + send(\"1\\r\") round-trip")
    pass("headless: NUL gap (cursor-positioned, §12.3) scrapes as real spaces (issue #5)")

    // --- ghostty side ---
    let ghostty = GhosttyViewBackend(cols: 120, rows: 32)
    ghostty.start(executable: "/bin/sh", args: [script], env: ["TERM": "xterm-256color"],
                  cwd: workDir) { _ in }
    let gReady = await waitFor(20) {
        let s = ghostty.renderScreen()
        return s.contains(KEY1) && s.contains(KEY2) && s.contains("NULGAP:A")
    }
    guard gReady else { fail("ghostty: key lines never appeared\n---\n\(ghostty.renderScreen())\n---") }
    let gNulLine = checkNulGap(ghostty, "ghostty")
    guard gNulLine == hNulLine else {
        fail("NUL-gap line differs across backends (issue #5): headless=[\(hNulLine)] ghostty=[\(gNulLine)]")
    }
    ghostty.send("1\r")
    let gAnswered = await waitFor(10) { ghostty.renderScreen().contains("ANSWERED:1") }
    guard gAnswered else { fail("ghostty: ANSWERED:1 missing after send(\"1\\r\")") }
    pass("ghostty: keys + gaps + send(\"1\\r\") round-trip — scrape semantics match")
    pass("ghostty: NUL gap matches headless verbatim (issue #5)")

    // --- Send during the cold window (before any surface builds) — the MCP
    // send(node,message)-right-after-spawn shape. Injection goes host-side (session.sendInput
    // → HostPTY.write), surface-independent, so there is no pending queue and no attach-time
    // flush — the write lands on the PTY immediately whether or not a surface ever exists.
    // Assert the echo.
    let cold = GhosttyViewBackend(cols: 120, rows: 32)
    cold.start(executable: "/bin/sh", args: [script], env: ["TERM": "xterm-256color"],
               cwd: workDir) { _ in }
    cold.send("1\r")   // no surface yet — host injection writes the PTY directly, not queued
    let coldAnswered = await waitFor(20) { cold.renderScreen().contains("ANSWERED:1") }
    guard coldAnswered else {
        fail("cold-window send was dropped (issue #4)\n---\n\(cold.renderScreen())\n---")
    }
    pass("cold-window send: host injection lands immediately, no surface needed (issue #4)")

    // --- Attribute (dim) parity. The ghostty SURFACE read_text carries NO
    // per-cell attributes (PLAN invariant ⑦: attribute scrape has a single source = the host VtScreen parser), so
    // it does NOT participate here — only the two libghostty-vt VtScreen sources do:
    // HeadlessBackend (its own Terminal) vs GhosttyViewBackend.renderAttributed (which
    // delegates to HostScreenParser). Both must read the SGR-2 dim bit identically, column
    // for column: DIMWORD = dim, " NORMAL" = not dim.
    let dimScript = workDir + "/dim.sh"
    try? "#!/bin/sh\nprintf '\\033[2mDIMWORD\\033[0m NORMAL\\n'\nsleep 300\n"
        .write(toFile: dimScript, atomically: true, encoding: .utf8)
    chmod(dimScript, 0o755)

    func attrLine(_ backend: TerminalBackend, _ name: String) async -> AttributedLine {
        let up = await waitFor(20) { backend.renderScreen().contains("DIMWORD") }
        guard up else { fail("\(name): DIMWORD never appeared\n---\n\(backend.renderScreen())\n---") }
        let scr = backend.renderAttributed()
        guard let l = scr.lines.first(where: { $0.text.contains("DIMWORD") }) else {
            fail("\(name): DIMWORD line missing from renderAttributed")
        }
        return l
    }

    let dHeadless = HeadlessBackend(cols: 120, rows: 32)
    dHeadless.start(executable: "/bin/sh", args: [dimScript], env: ["TERM": "xterm-256color"],
                    cwd: workDir) { _ in }
    let dGhostty = GhosttyViewBackend(cols: 120, rows: 32)
    dGhostty.start(executable: "/bin/sh", args: [dimScript], env: ["TERM": "xterm-256color"],
                   cwd: workDir) { _ in }
    let hAttr = await attrLine(dHeadless, "headless")
    let gAttr = await attrLine(dGhostty, "ghostty")

    // Per-cell truth on the headless side: DIMWORD dim, "space + NORMAL" not dim.
    guard let dimStart = hAttr.text.range(of: "DIMWORD") else { fail("headless: DIMWORD substring gone") }
    let chars = Array(hAttr.text)
    let dwStart = hAttr.text.distance(from: hAttr.text.startIndex, to: dimStart.lowerBound)
    guard hAttr.text.count == hAttr.dim.count else {
        fail("headless: text/dim misaligned (\(hAttr.text.count) vs \(hAttr.dim.count))")
    }
    for k in dwStart..<(dwStart + 7) where !hAttr.dim[k] {
        fail("headless: DIMWORD cell \(chars[k]) not dim")
    }
    for k in (dwStart + 7)..<hAttr.text.count where hAttr.dim[k] {
        fail("headless: non-DIMWORD cell \(chars[k]) unexpectedly dim")
    }
    // Column-for-column parity between the two libghostty-vt sources.
    guard hAttr.text == gAttr.text && hAttr.dim == gAttr.dim else {
        fail("dim parity differs across libghostty-vt sources:\n headless text=[\(hAttr.text)] dim=\(hAttr.dim)\n ghostty  text=[\(gAttr.text)] dim=\(gAttr.dim)")
    }
    dHeadless.terminate(); dGhostty.terminate()
    pass("#31-A: dim bit reads true for DIMWORD, false for NORMAL — column-aligned across both libghostty-vt sources")

    // --- A multi-line body must arrive as ONE bracketed paste + ONE
    // trailing CR (the RealCell.inject shape: send(body) … send("\r")), never as one
    // submission per line. Probe enables 2004h (like claude's TUI), decodes the paste
    // block and prints a canonical verdict line both backends must scrape identically.
    let multiProbe = workDir + "/multi_probe.py"
    try? ("""
    import os, sys, select, tty, time
    tty.setcbreak(0)
    sys.stdout.write("\\x1b[?2004h")
    sys.stdout.write("MULTI_READY\\r\\n"); sys.stdout.flush()
    buf = b""
    while True:
        r, _, _ = select.select([0], [], [], 30)
        if not r: break
        d = os.read(0, 4096)
        if not d: break
        buf += d
        s = buf.decode("latin1")
        # NB: the pty's ICRNL (cbreak leaves iflag untouched) turns the submission CR
        # into LF on arrival — accept either byte after the closing paste marker.
        tail = s.split("\\x1b[201~")[-1] if "\\x1b[201~" in s else ""
        if "\\x1b[201~" in s and ("\\r" in tail or "\\n" in tail):
            body = s.split("\\x1b[200~", 1)[1].split("\\x1b[201~", 1)[0]
            sys.stdout.write("\\r\\nMULTILINE=[" + body.replace("\\n", "|") + "]SUBMIT=OK\\r\\n")
            sys.stdout.flush()
            break
    time.sleep(300)
    """).write(toFile: multiProbe, atomically: true, encoding: .utf8)

    let VERDICT = "MULTILINE=[line-a|line-b|line-c]SUBMIT=OK"
    for (name, backend) in [("headless", HeadlessBackend(cols: 120, rows: 32) as TerminalBackend),
                            ("ghostty", GhosttyViewBackend(cols: 120, rows: 32))] {
        backend.start(executable: "/usr/bin/python3", args: [multiProbe],
                      env: ["TERM": "xterm-256color"], cwd: workDir) { _ in }
        let up = await waitFor(20) { backend.renderScreen().contains("MULTI_READY") }
        guard up else { fail("\(name): multi-line probe never came up") }
        backend.send("line-a\nline-b\nline-c")   // body: \n stays inside the paste
        backend.send("\r")                        // submission: separate CR (inject shape)
        let ok = await waitFor(15) { backend.renderScreen().contains(VERDICT) }
        guard ok else {
            fail("\(name): multi-line send split/mangled (issue #13)\n---\n\(backend.renderScreen())\n---")
        }
        backend.terminate()
        pass("\(name): multi-line body → ONE bracketed paste + ONE CR (issue #13)")
    }

    // --- terminate fires onEnd exactly once ---
    let victim = GhosttyViewBackend(cols: 120, rows: 32)
    var endCount = 0
    var endCode: Int32? = -99
    victim.start(executable: "/bin/sh", args: [script], env: [:], cwd: workDir) { code in
        endCount += 1; endCode = code
    }
    let vUp = await waitFor(20) { victim.renderScreen().contains(KEY1) }
    guard vUp else { fail("victim cell never came up") }
    victim.terminate()
    try? await Task.sleep(nanoseconds: 2_000_000_000)   // window for any double CHILD_EXITED
    guard endCount == 1 else { fail("terminate(): onEnd fired \(endCount)× (want exactly 1)") }
    guard endCode == nil else { fail("terminate(): expected nil code (signal death), got \(String(describing: endCode))") }
    pass("terminate(): surface teardown → onEnd(nil) exactly once (G-g)")

    // --- Normal-exit code recovery: host-managed waitpid takes the REAL code directly ---
    // HostPTY's waitpid thread reads WIFEXITED(status)→WEXITSTATUS = 5 and hands it straight
    // to onEnd. No `runDir/exit` file is written or read anywhere. Assert both: onEnd sees 5,
    // AND no wrapper artifact.
    let exiter = GhosttyViewBackend(cols: 120, rows: 32)
    var exitCode: Int32? = -99
    var exitFired = 0
    let exitScript = workDir + "/exit5.sh"
    try? "#!/bin/sh\necho bye\nexit 5\n".write(toFile: exitScript, atomically: true, encoding: .utf8)
    chmod(exitScript, 0o755)
    let exitArtifacts = Set(((try? FileManager.default.contentsOfDirectory(atPath: workDir)) ?? []))
    exiter.start(executable: "/bin/sh", args: [exitScript], env: [:], cwd: workDir) { code in
        exitFired += 1; exitCode = code
    }
    let exited = await waitFor(20) { exitFired > 0 }
    guard exited else { fail("normal exit: onEnd never fired") }
    guard exitCode == 5 else { fail("normal exit: expected code 5 via waitpid, got \(String(describing: exitCode))") }
    // No wrapper file was created — the workDir gained no `exit`/launch.sh-style artifact.
    let afterExit = Set(((try? FileManager.default.contentsOfDirectory(atPath: workDir)) ?? []))
    let leaked = afterExit.subtracting(exitArtifacts)
    guard leaked.isEmpty else {
        fail("normal exit: host-managed must write NO wrapper file, found: \(leaked.sorted())")
    }
    pass("normal exit: real exit code (5) via waitpid — no login(1), no wrapper file")

    print("PARITY: ALL GREEN")
    try? FileManager.default.removeItem(atPath: workDir)
    exit(0)
}

// Ghostty needs a running AppKit loop (main-queue ticks + display link).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no dock icon; parity runs headless-ish (no windows)
Task { @MainActor in await run() }
app.run()
