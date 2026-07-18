import XCTest

// T2 golden flows. Element handles are
// accessibilityIdentifiers per app/ACCESSIBILITY_IDS.md (the authoritative list).
// No real claude is ever launched: the app swaps in ScriptHarness (fake-agent.sh)
// whenever VIGIL_FAKE_AGENT_CMD is set, and VIGIL_UITEST=1 isolates persistence.
final class GoldenFlowTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - helpers

    private var fakeAgentScript: String {
        guard let p = Bundle(for: GoldenFlowTests.self)
            .path(forResource: "fake-agent", ofType: "sh") else {
            XCTFail("fake-agent.sh missing from the UI test bundle resources")
            return ""
        }
        return p
    }

    /// A real directory for the seeded project (the app only needs it to exist;
    /// branch label falls back to "main" when it is not a git repo).
    private var seedDir: String {
        let dir = "/private/tmp/vigil-uitest-seedproj"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func launch(seed: Bool, fakeAgent: Bool = false,
                        spawnChild: Bool = false, notifyAfter: Int? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        var env: [String: String] = ["VIGIL_UITEST": "1"]
        if seed { env["VIGIL_SEED_PROJECT"] = seedDir }
        if fakeAgent { env["VIGIL_FAKE_AGENT_CMD"] = fakeAgentScript }
        if spawnChild { env["VIGIL_FAKE_SPAWN_CHILD"] = "1" }
        if let n = notifyAfter { env["VIGIL_FAKE_NOTIFY_AFTER"] = String(n) }
        app.launchEnvironment = env
        app.launch()
        return app
    }

    /// Identifier lookup across ALL element types — SwiftUI's macOS role mapping varies
    /// (TextField may surface as textField or textView, cards as groups, …).
    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func waitGone(_ e: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"),
                               evaluatedWith: e)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// Launcher → type a task → submit (agent picker stays on its default, claude).
    private func submitSession(_ app: XCUIApplication, task: String) {
        let prompt = el(app, "launcher.prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "launcher should be on screen")
        prompt.click()
        app.typeText(task)
        el(app, "launcher.submit").click()
    }

    // MARK: - golden flows

    /// G1 cold start (no project) → the "add project" empty state appears, the launcher does not.
    func test1_coldStart_showsEmptyState() {
        let app = launch(seed: false)
        XCTAssertTrue(el(app, "center.empty.addProject").waitForExistence(timeout: 10),
                      "empty state (add-project) should appear on a cold start")
        XCTAssertFalse(el(app, "launcher.prompt").exists,
                       "no project ⇒ no launcher")
    }

    /// G2 launch env injects a seed project (bypassing NSOpenPanel) → a project row appears in the rail + the full launcher start screen.
    func test2_seedProject_railRowAndLauncher() {
        let app = launch(seed: true)
        XCTAssertTrue(el(app, "rail.project.seedproj").waitForExistence(timeout: 10),
                      "seeded project must show as a rail row")
        XCTAssertTrue(el(app, "launcher.prompt").waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "launcher.agentPicker").exists)
        XCTAssertTrue(el(app, "launcher.modelPicker").exists)
        XCTAssertTrue(el(app, "launcher.permissionPicker").exists)
        XCTAssertTrue(el(app, "launcher.submit").exists)
    }

    /// G3 fill the launcher prompt and submit (agent=claude default, fake harness) → the center
    /// switches to the terminal state, and the top-right node-tree panel (UI-0704, expanded by
    /// default) shows the root node + child node n1 spawned by the fake agent through the real MCP gate.
    func test3_submit_terminalStateAndTreeNodes() {
        let app = launch(seed: true, fakeAgent: true, spawnChild: true)
        submitSession(app, task: "golden flow")
        XCTAssertTrue(el(app, "center.terminal").waitForExistence(timeout: 10),
                      "center must switch to the terminal pane")
        XCTAssertTrue(el(app, "center.breadcrumb").exists)
        XCTAssertTrue(el(app, "tree.node.root").waitForExistence(timeout: 10),
                      "root manager node must show in the tree panel")
        XCTAssertTrue(el(app, "tree.node.n1").waitForExistence(timeout: 15),
                      "fake agent's MCP spawn must add child n1 to the tree panel")
    }

    /// G4 fake agent fires a Notification hook → a notification card appears top-right; clicking it → jumps to the node + the card disappears (D13: handled on arrival).
    func test4_notification_cardAppears_clickJumpsAndClears() {
        let app = launch(seed: true, fakeAgent: true, notifyAfter: 2)
        submitSession(app, task: "notify me")
        let card = el(app, "notif.card.root")
        XCTAssertTrue(card.waitForExistence(timeout: 20),
                      "Notification over the hook UDS must raise a card")
        card.click()
        XCTAssertTrue(waitGone(card, timeout: 5),
                      "clicking the card must clear it (D13: arriving IS the handling)")
        XCTAssertTrue(el(app, "center.terminal").exists,
                      "after the jump we are still on the node's terminal")
    }
}
