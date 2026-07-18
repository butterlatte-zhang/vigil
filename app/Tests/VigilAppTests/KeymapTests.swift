import XCTest
import SwiftUI
import AppKit
import VigilGhosttyTerminal
@testable import VigilApp
@testable import VigilCore

// T1a keyboard-system tests. Three families, all
// deterministic and event-loop-free:
//   A) launcher Return semantics (PromptNSTextView.returnAction, pure) — the highest-priority
//      reversal: Enter=submit, ⇧/⌘/⌥+Enter=newline;
//   B) the global keymap contract (VigilKeymap) — key/modifiers/uniqueness/⌘-only red line
//      + GhosttyTheme unbind mirror;
//   C) navigation semantics on real seeded sessions (same fake-agent seam as WiringTests):
//      session / node adjacency, jump-to-attention, close, manual rename lock.
@MainActor
final class KeymapTests: XCTestCase {

    override func setUp() {
        super.setUp()
        setenv("VIGIL_UITEST", "1", 1)
        setenv("VIGIL_FAKE_AGENT_CMD", WiringTests.stubScript, 1)
        AgentNotice.permissionGrace = 2.5
    }

    private var apps: [AppModel] = []
    override func tearDown() {
        for app in apps { for s in app.allSessions { s.shutdown() } }
        apps.removeAll()
        super.tearDown()
    }

    // MARK: - A. launcher Return semantics (highest-priority product decision)

    private typealias RA = PromptNSTextView.ReturnAction

    func testReturn_plainEnter_submits() {
        XCTAssertEqual(PromptNSTextView.returnAction(keyCode: 36, modifiers: []), RA.submit)
    }
    func testReturn_keypadEnter_submits() {
        XCTAssertEqual(PromptNSTextView.returnAction(keyCode: 76, modifiers: []), RA.submit)
    }
    func testReturn_shiftEnter_newline() {
        XCTAssertEqual(PromptNSTextView.returnAction(keyCode: 36, modifiers: .shift), RA.newline)
    }
    func testReturn_commandEnter_newline() {
        XCTAssertEqual(PromptNSTextView.returnAction(keyCode: 36, modifiers: .command), RA.newline)
    }
    func testReturn_optionEnter_newline() {
        XCTAssertEqual(PromptNSTextView.returnAction(keyCode: 36, modifiers: .option), RA.newline)
    }
    func testReturn_commandShiftEnter_newline() {
        XCTAssertEqual(PromptNSTextView.returnAction(keyCode: 36, modifiers: [.command, .shift]),
                       RA.newline)
    }
    func testReturn_nonReturnKey_passthrough() {
        // keyCode 0 = 'a' — normal typing must not be intercepted.
        XCTAssertEqual(PromptNSTextView.returnAction(keyCode: 0, modifiers: []), RA.passthrough)
    }

    // MARK: - B. keymap contract

    /// The exact map the Session menu registers (id → char, EventModifiers). Pinned so a
    /// silent drift (wrong key/modifier) fails here.
    func testKeymap_bindingsMatchSpec() {
        let expected: [String: (Character, EventModifiers)] = [
            "toggleBottomTerminal": ("j", .command),
            "toggleSidebar": ("b", .command),
            "prevSession":   ("[", [.command, .control]),
            "nextSession":   ("]", [.command, .control]),
            "jumpAttention": ("u", [.command, .shift]),
            "prevNode":      ("[", [.command, .shift]),
            "nextNode":      ("]", [.command, .shift]),
            "renameSession": ("r", [.command, .shift]),
            "closeSession":  ("w", [.command, .shift]),
        ]
        XCTAssertEqual(VigilKeymap.all.count, expected.count)
        for b in VigilKeymap.all {
            guard let (ch, mods) = expected[b.id] else {
                XCTFail("unexpected binding \(b.id)"); continue
            }
            XCTAssertEqual(b.key.character, ch, "\(b.id) key")
            XCTAssertEqual(b.modifiers.rawValue, mods.rawValue, "\(b.id) modifiers")
        }
    }

    /// Red line: every global shortcut is ⌘-modified so it can never steal a key the
    /// terminal's agent TUI needs (only ⌘ combos are GUI-only / unreachable by a PTY).
    func testKeymap_everyBindingIsCommandModified() {
        for b in VigilKeymap.all {
            XCTAssertTrue(b.modifiers.contains(.command), "\(b.id) must be ⌘-modified")
        }
    }

    /// No two shortcuts (VigilKeymap + the system-menu ⌘,/⌘T/⌘O + ⌘1–9) share a
    /// (key, modifiers) pair — a real collision would make one binding dead.
    func testKeymap_noCollisionAcrossTheWholeApp() {
        var pairs: [(Character, Int)] = VigilKeymap.all.map { ($0.key.character, $0.modifiers.rawValue) }
        let cmd = EventModifiers.command.rawValue
        pairs += [(",", cmd), ("t", cmd), ("o", cmd)]
        for n in 1...9 { pairs.append((Character("\(n)"), cmd)) }
        let unique = Set(pairs.map { "\($0.0)|\($0.1)" })
        XCTAssertEqual(unique.count, pairs.count, "duplicate keyboard shortcut across the app")
    }

    /// GhosttyTheme must unbind every combo Vigil claims (changing a shortcut = changing the unbind table too), so a
    /// focused terminal cannot swallow them via keyIsBinding before the menu sees them.
    func testGhosttyUnbinds_coverClaimedCombos() {
        let u = VGGhosttyTheme.vigilUnbinds
        // 3 menu homes (⌘,/⌘T/⌘O) + ⌘1–9 unicode + ⌘1–9 translated (digit_N) + 8 VigilKeymap
        // nav (⌘J/⌘B/⌘⇧U/R/W + ⌘⇧[/] + ⌃⌘[/]) = 3 + 9 + 9 + 9 = 30.
        XCTAssertEqual(u.count, 30)
        for critical in ["super+shift+[", "super+shift+]",       // ⌘⇧[ / ⌘⇧] (prev/next node)
                         "ctrl+super+[", "ctrl+super+]",         // ⌃⌘[ / ⌃⌘] (prev/next session)
                         "super+,", "super+t",                   // ⌘, / ⌘T (menu homes)
                         "super+1", "super+9",                   // ⌘1 / ⌘9 unicode
                         "super+digit_1", "super+digit_9",       // ⌘1 / ⌘9 translated (double-bound)
                         "super+j", "super+b", "super+shift+u", "super+shift+w"] {
            XCTAssertTrue(u.contains(critical), "missing unbind: \(critical)")
        }
    }

    /// vigilUnbinds and VigilKeymap are synced by hand. This derives each binding's ghostty
    /// trigger string from VigilKeymap (super=⌘, ctrl, shift prefixes + key name), then
    /// asserts one by one that it's present in vigilUnbinds — "added a keymap entry, forgot
    /// to add the unbind" goes straight red (a focused terminal would swallow an un-unbound
    /// combo via keyIsBinding).
    private func ghosttyCombo(_ b: VigilKeyBinding) -> String {
        var parts: [String] = []
        // Order = ctrl, super, shift, alt (matches vigilUnbinds' notation:
        // "ctrl+super+[" / "super+shift+u").
        if b.modifiers.contains(.control) { parts.append("ctrl") }
        if b.modifiers.contains(.command) { parts.append("super") }
        if b.modifiers.contains(.shift) { parts.append("shift") }
        if b.modifiers.contains(.option) { parts.append("alt") }
        // LITERAL character form — ghostty keys its defaults by the character, not the W3C key
        // name, so the unbind must be the literal char (see vigilUnbinds' comment).
        parts.append(String(b.key.character))
        return parts.joined(separator: "+")
    }

    func testGhosttyUnbinds_derivedFromKeymapCoverEveryBinding() {
        let u = Set(VGGhosttyTheme.vigilUnbinds)
        for b in VigilKeymap.all {
            let combo = ghosttyCombo(b)
            XCTAssertTrue(u.contains(combo),
                "keymap '\(b.id)' → ghostty trigger '\(combo)' is not in vigilUnbinds — added a keymap entry, forgot the unbind")
        }
    }

    /// Load-bearing test #1: the full VGGhosttyTheme config — every unbind line
    /// plus palette/font/cursor — must parse with ZERO ghostty diagnostics. `prepareConfig`
    /// (TerminalController+Config) rejects the ENTIRE generated config on the first diagnostic
    /// and falls back to defaults, so one malformed key name silently drops all unbinds and a
    /// focused terminal keeps swallowing every ⌘ shortcut. Headless: pure config parser, no
    /// surface (which XCTest can't spawn). Ground truth is libghostty 1.2.8's own parser.
    func testGhosttyThemeConfig_hasNoDiagnostics() {
        for vg in [VGTokens.make(.dark, .blue), VGTokens.make(.light, .blue)] {
            let diags = TerminalController.diagnosticsForConfigString(
                VGGhosttyTheme.configuration(for: vg).rendered)
            XCTAssertTrue(diags.isEmpty,
                          "ghostty rejected VGGhosttyTheme config (\(vg.theme)): \(diags)")
        }
    }

    /// Load-bearing test #2: syntactic validity is NOT enough — a well-formed
    /// unbind can still be a no-op if its key form doesn't match ghostty's default (the exact
    /// "pressed but nothing happens" bug: `super+comma`/`super+bracket_left` parse clean yet leave ⌘,/⌘⇧[
    /// swallowed). This asserts BEHAVIOUR via ghostty's own reverse-lookup API: for every
    /// ghostty default that collides with a Vigil ⌘ shortcut, loading the real VGGhosttyTheme
    /// config must CHANGE the action's bound trigger (the colliding binding removed). If a
    /// unbind form were wrong, the trigger would be unchanged and this fails.
    ///
    /// Honest boundary: this proves the config binding TABLE changed; whether a live NSEvent's
    /// keyIsBinding returns false is surface-runtime and stays a manual keypress check.
    func testUnbinds_neutralizeGhosttyDefaultCollisions() {
        let cfg = VGGhosttyTheme.configuration(for: VGTokens.make(.dark, .blue)).rendered
        // ghostty action → the Vigil ⌘ shortcut it collides with (measured against ghostty's defaults).
        let colliding = ["open_config": "⌘,", "new_tab": "⌘T", "close_window": "⌘⇧W",
                         "previous_tab": "⌘⇧[", "next_tab": "⌘⇧]", "last_tab": "⌘9",
                         "goto_tab:1": "⌘1", "goto_tab:2": "⌘2", "goto_tab:8": "⌘8"]
        for (action, shortcut) in colliding {
            let before = TerminalController.triggerForAction(action)
            let after = TerminalController.triggerForAction(action, configContents: cfg)
            XCTAssertTrue(before.contains("super"),
                          "precondition: ghostty '\(action)' should default to a super binding")
            XCTAssertNotEqual(before, after,
                "vigilUnbinds did not neutralise ghostty '\(action)' (collides with \(shortcut)); "
                + "still bound to \(after) — a focused terminal would keep swallowing it")
        }
    }

    // MARK: - B2. scroll-guarantee bindings

    /// The exact scroll map, pinned so a silent drift (wrong trigger/action) fails here.
    /// Mirrors the two conventions documented on `vigilScrollBinds`.
    func testScrollBinds_mapMatchesSpec() {
        let expected: [String: String] = [
            "super+up": "scroll_to_top", "super+down": "scroll_to_bottom",
            "super+home": "scroll_to_top", "super+end": "scroll_to_bottom",
            "super+page_up": "scroll_page_up", "super+page_down": "scroll_page_down",
            "shift+page_up": "scroll_page_up", "shift+page_down": "scroll_page_down",
        ]
        let got = Dictionary(uniqueKeysWithValues:
            VGGhosttyTheme.vigilScrollBinds.map { ($0.trigger, $0.action) })
        XCTAssertEqual(got, expected)
    }

    /// Load-bearing: a single unknown ghostty key name makes `prepareConfig`
    /// reject the WHOLE generated config and fall back to defaults — silently dropping every
    /// unbind AND every scroll bind. This asserts the full config (unbinds + scroll binds +
    /// palette/font) parses with ZERO diagnostics, against libghostty 1.2.8's own parser.
    func testScrollBinds_configHasNoDiagnostics() {
        for vg in [VGTokens.make(.dark, .blue), VGTokens.make(.light, .blue)] {
            let diags = TerminalController.diagnosticsForConfigString(
                VGGhosttyTheme.configuration(for: vg).rendered)
            XCTAssertTrue(diags.isEmpty, "ghostty rejected scroll binds (\(vg.theme)): \(diags)")
        }
    }

    /// Behaviour proof #1: every scroll action our map claims resolves to a REAL trigger once
    /// the VG config is loaded — i.e. the bind actually took (a mistyped action name would
    /// leave the action unbound). Uses ghostty's own reverse lookup (`ghostty_config_trigger`).
    func testScrollBinds_scrollActionsAreBound() {
        let cfg = VGGhosttyTheme.configuration(for: VGTokens.make(.dark, .blue)).rendered
        for action in ["scroll_to_top", "scroll_to_bottom", "scroll_page_up", "scroll_page_down"] {
            let t = TerminalController.triggerForAction(action, configContents: cfg)
            XCTAssertTrue(t.contains("super") || t.contains("shift"),
                "scroll action '\(action)' is not bound after loading VG config (got \(t))")
        }
    }

    /// Behaviour proof #2: our ⌘↑/⌘↓ binds OVERRIDE ghostty's default jump_to_prompt (dead
    /// weight in Vigil — agents emit no OSC-133 marks). ghostty defaults ⌘↑=jump_to_prompt:-1
    /// / ⌘↓=jump_to_prompt:1; after loading VG config those actions must no longer sit on the
    /// super+up/super+down triggers (they've been reclaimed for scroll). If the override
    /// failed, the trigger would be unchanged and this fails.
    func testScrollBinds_overrideGhosttyJumpToPrompt() {
        let cfg = VGGhosttyTheme.configuration(for: VGTokens.make(.dark, .blue)).rendered
        for action in ["jump_to_prompt:-1", "jump_to_prompt:1"] {
            let before = TerminalController.triggerForAction(action)
            let after = TerminalController.triggerForAction(action, configContents: cfg)
            XCTAssertTrue(before.contains("super"),
                "precondition: ghostty '\(action)' should default to a super binding (got \(before))")
            XCTAssertNotEqual(before, after,
                "⌘↑/⌘↓ scroll bind did not reclaim ghostty '\(action)' — still \(after)")
        }
    }

    /// Red line: no scroll trigger may collide with a combo Vigil already claims (vigilUnbinds
    /// menu/nav table + the VigilKeymap-derived triggers). A collision would make one binding
    /// dead. All scroll triggers use arrow/page/home/end keys, which nothing else claims.
    func testScrollBinds_noCollisionWithClaimedCombos() {
        var claimed = Set(VGGhosttyTheme.vigilUnbinds)
        for b in VigilKeymap.all { claimed.insert(ghosttyCombo(b)) }
        for (trigger, _) in VGGhosttyTheme.vigilScrollBinds {
            XCTAssertFalse(claimed.contains(trigger),
                "scroll trigger '\(trigger)' collides with a claimed Vigil combo")
        }
    }

    // MARK: - C. navigation semantics (real sessions, fake agent)

    private func makeApp() -> AppModel { let a = AppModel(); apps.append(a); return a }

    @discardableResult
    private func addProject(_ app: AppModel, name: String = "Demo project") -> ProjectVM {
        let dir = NSTemporaryDirectory() + "vigil-km-proj-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = ProjectVM(id: UUID().uuidString, name: name, cwd: dir)
        app.projects.append(p)
        return p
    }

    @discardableResult
    private func launch(_ app: AppModel, _ p: ProjectVM, task: String) throws -> SessionVM {
        XCTAssertEqual(UITestSupport.fakeAgentCommand, WiringTests.stubScript,
                       "fake-agent seam inactive — refusing to launch a real agent")
        return try XCTUnwrap(app.launchSession(in: p.id, task: task, agent: "claude", access: .standard))
    }

    @discardableResult
    private func spawnChild(_ vm: SessionVM, task: String) throws -> NodeID {
        let root = vm.store.tree.rootID
        let before = Set(vm.store.tree.root.children)
        vm.store.send(.requestStruct(.spawn(parent: root, role: .leaf, task: task),
                                     from: root, replyID: UUID()))
        let new = vm.store.tree.root.children.filter { !before.contains($0) }
        return try XCTUnwrap(new.first)
    }

    func testSelectAdjacentSession_wrapsInSidebarOrder() throws {
        let app = makeApp()
        let p = addProject(app)
        let a = try launch(app, p, task: "alpha")
        let b = try launch(app, p, task: "bravo")
        let c = try launch(app, p, task: "charlie")   // launchSession inserts at head
        // allSessions = newest-first: [c, b, a]
        XCTAssertEqual(app.allSessions.map(\.id), [c.id, b.id, a.id])

        app.select(session: c.id)
        app.selectAdjacentSession(1)
        XCTAssertEqual(app.activeSessionID, b.id)   // c → next → b
        app.selectAdjacentSession(-1)
        XCTAssertEqual(app.activeSessionID, c.id)   // b → prev → c
        app.selectAdjacentSession(-1)
        XCTAssertEqual(app.activeSessionID, a.id)   // c → prev → wrap to a
    }

    func testSelectAdjacentNode_walksTreeOrder() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p, task: "task")
        let root = vm.store.tree.rootID
        let c1 = try spawnChild(vm, task: "child one")
        let c2 = try spawnChild(vm, task: "child two")
        app.select(session: vm.id)
        XCTAssertEqual(vm.selectedID, root)

        app.selectAdjacentNode(1)
        XCTAssertEqual(vm.selectedID, c1)
        app.selectAdjacentNode(1)
        XCTAssertEqual(vm.selectedID, c2)
        app.selectAdjacentNode(1)
        XCTAssertEqual(vm.selectedID, root)   // wrap
        app.selectAdjacentNode(-1)
        XCTAssertEqual(vm.selectedID, c2)     // wrap backward
    }

    func testJumpToLatestAttention_targetsWaitingNode() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p, task: "task")
        let child = try spawnChild(vm, task: "child")
        app.openLauncher(in: p.id)                 // no session focused
        XCTAssertTrue(app.attentionTargets().isEmpty)

        // Seed a permission notice → node .waiting + badge>0 (mirrors WiringTests).
        AgentNotice.permissionGrace = 0
        vm.store.send(.permRequested(from: child, info: PermNoticeInfo(
            promptID: "p1", toolName: "Bash", toolInput: "{}",
            inputSummary: "git push", text: "waiting for approval")))

        let targets = app.attentionTargets()
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first?.session, vm.id)
        XCTAssertEqual(targets.first?.node, child)

        app.jumpToLatestAttention()
        XCTAssertEqual(app.activeSessionID, vm.id)
        XCTAssertEqual(vm.selectedID, child)
    }

    func testJumpToLatestAttention_emptyToasts() throws {
        let app = makeApp()
        let p = addProject(app)
        _ = try launch(app, p, task: "task")
        app.toast = nil
        app.jumpToLatestAttention()
        XCTAssertEqual(app.toast, "No pending alerts")
    }

    func testCloseActiveSession_dropsIt() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p, task: "task")
        app.select(session: vm.id)
        XCTAssertEqual(app.allSessions.count, 1)
        app.closeActiveSession()
        XCTAssertTrue(app.allSessions.isEmpty)
        XCTAssertNil(app.activeSessionID)          // last one → back to launcher
    }

    func testRenameByUser_locksAutoNamerAndSetsName() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p, task: "original name")
        XCTAssertFalse(vm.userNamed)
        vm.renameByUser("  my session  ")
        XCTAssertEqual(vm.name, "my session")         // trimmed
        XCTAssertTrue(vm.userNamed)
        vm.renameByUser("   ")                       // empty → ignored
        XCTAssertEqual(vm.name, "my session")
    }

    func testFocusTerminalInput_noActiveSessionIsNoOp() {
        let app = makeApp()
        app.focusTerminalInput()                     // must not crash with no session
    }
}
