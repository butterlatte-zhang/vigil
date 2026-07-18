import XCTest
import SwiftUI
import ViewInspector
@testable import VigilApp
@testable import VigilCore
@testable import VigilRuntime

// Covers "settings as files" + agent-driven onboarding. Two families:
//   1) ConfigStore — the file layer: first-run detection, default install (README +
//      per-concern JSONs), tolerant load, file-watch hot reload;
//   2) AppModel onboarding — first run opens the "user config" workspace with the
//      prefilled prompt; later runs apply the files silently; the launcher seeds its
//      selections from the file-loaded defaults; ⌘, reconfigure reuses the workspace.
// Same seams as WiringTests: VIGIL_UITEST isolates persistence, cells run the fake
// agent stub, and each test gets its own throwaway config dir.

@MainActor
final class ConfigTests: XCTestCase {

    /// SHARED with WiringTests: UITestSupport.env freezes on first read, so every test
    /// class must export the SAME stub path — a second path would trip the other class's
    /// seam guard depending on suite order.
    static var stubScript: String { WiringTests.stubScript }

    override func setUp() {
        super.setUp()
        setenv("VIGIL_UITEST", "1", 1)
        setenv("VIGIL_FAKE_AGENT_CMD", Self.stubScript, 1)
    }

    private var apps: [AppModel] = []
    private var stores: [ConfigStore] = []

    override func tearDown() {
        for app in apps { for s in app.allSessions { s.shutdown() } }
        apps.removeAll()
        for s in stores { s.stopWatching() }
        stores.removeAll()
        super.tearDown()
    }

    // MARK: - fixtures

    /// A fresh, NOT-created directory path — the true first-run shape.
    private func freshDir() -> String {
        NSTemporaryDirectory() + "vigil-cfg-\(UUID().uuidString.prefix(8))"
    }

    private func makeStore(_ dir: String) -> ConfigStore {
        let s = ConfigStore(dir: dir)
        stores.append(s)
        return s
    }

    /// A fake OS-appearance source so follow-system theme is deterministic in tests instead of
    /// reading the CI machine's System Settings. Flipping `isDark` fires onChange (the live
    /// light⇄dark switch the KVO source would deliver in production).
    @MainActor
    final class FakeAppearanceSource: SystemAppearanceSource {
        var isDark: Bool { didSet { if isDark != oldValue { onChange?() } } }
        var onChange: (() -> Void)?
        init(isDark: Bool) { self.isDark = isDark }
    }

    /// Default = dark so every existing app-level test that expects a dark default stays
    /// deterministic; new follow-system tests use `makeAppTracking`.
    private func makeApp(configDir: String, isDark: Bool = true) -> AppModel {
        makeAppTracking(configDir: configDir, isDark: isDark).app
    }

    /// Same, but hands back the fake so a test can flip the OS scheme live.
    private func makeAppTracking(configDir: String, isDark: Bool = true)
        -> (app: AppModel, appearance: FakeAppearanceSource) {
        let fake = FakeAppearanceSource(isDark: isDark)
        let app = AppModel(configStore: makeStore(configDir), appearanceSource: fake)
        apps.append(app)
        return (app, fake)
    }

    private func write(_ dir: String, _ name: String, _ content: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? content.write(toFile: (dir as NSString).appendingPathComponent(name),
                           atomically: true, encoding: .utf8)
    }

    /// Read the production orchestrator's root cell_launch record. The forensic field is
    /// intentionally capped at 80 characters; exact/full-payload assertions use the
    /// SessionVM.rootLaunchTask value that Orchestrator.start consumes.
    private func loggedRootTaskPrefix(_ vm: SessionVM) -> String? {
        guard let raw = try? String(contentsOfFile: vm.archiveDir + "/orchestration.jsonl",
                                    encoding: .utf8) else { return nil }
        for line in raw.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let event = object as? [String: Any],
                  event["event"] as? String == "cell_launch",
                  event["node"] as? String == "root" else { continue }
            return event["task"] as? String
        }
        return nil
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func pumpUntil(_ what: String, timeout: TimeInterval = 3,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ cond: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !cond() && Date() < deadline { pump(0.02) }
        XCTAssertTrue(cond(), "pumpUntil timeout: \(what)", file: file, line: line)
    }

    // MARK: - 1) ConfigStore: first-run detection

    func testFirstRun_dirMissingOrNoJSON() {
        let dir = freshDir()
        let store = makeStore(dir)
        XCTAssertTrue(store.isFirstRun, "missing dir = first run")

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        XCTAssertTrue(store.isFirstRun, "empty dir = still first run")

        write(dir, "README.md", "just a readme")
        XCTAssertTrue(store.isFirstRun, "no *.json = still first run")

        store.ensureInstalled()
        XCTAssertFalse(store.isFirstRun, "installed defaults end the first run")
    }

    // MARK: - 1) ConfigStore: default install

    func testEnsureInstalled_writesDefaultsAndSingleAgentNeutralReadme() {
        let dir = freshDir()
        let store = makeStore(dir)
        store.ensureInstalled()

        let fm = FileManager.default
        let expectedFiles: Set<String> = [
            "appearance.json", "launcher.json", "agents.json", "roles.json",
            "prompts.json", "runtime.json", "README.md",
        ]
        for f in expectedFiles {
            XCTAssertTrue(fm.fileExists(atPath: dir + "/" + f), "missing default file \(f)")
        }
        XCTAssertEqual(Set((try? fm.contentsOfDirectory(atPath: dir)) ?? []), expectedFiles,
                       "fresh settings must contain exactly six JSON files and one README")
        XCTAssertFalse(fm.fileExists(atPath: dir + "/CLAUDE.md"),
                       "settings must have one agent-neutral README, not a Claude-only guide")
        let markdowns = (try? fm.contentsOfDirectory(atPath: dir))?
            .filter { $0.lowercased().hasSuffix(".md") }.sorted()
        XCTAssertEqual(markdowns, ["README.md"], "README must be the only shipped guide")
        XCTAssertFalse(fm.fileExists(atPath: dir + "/agent.json"),
                       "the legacy agent.json must not be shipped any more (launcher.json)")
        XCTAssertEqual(store.load(), VigilConfig.defaults,
                       "shipped defaults must parse back to the built-in defaults")
        let runtimeData = fm.contents(atPath: dir + "/runtime.json") ?? Data()
        let runtimeObject = (try? JSONSerialization.jsonObject(with: runtimeData))
            as? [String: Any]
        let runtimeFields = Set(Mirror(reflecting: RuntimeTuning.defaults).children
            .compactMap(\.label))
        XCTAssertEqual(Set(runtimeObject?.keys ?? Dictionary<String, Any>().keys),
                       runtimeFields,
                       "every RuntimeTuning field must be shipped and therefore documented")
        // README must document every schema, including the file split, the role matrix,
        // and the runtime knobs, so the onboarding agent can work from it.
        let readme = (try? String(contentsOfFile: dir + "/README.md", encoding: .utf8)) ?? ""
        XCTAssertEqual(readme, ConfigStore.readmeDoc,
                       "the on-disk README must be the canonical universal guide")
        for key in ["appearance.json", "launcher.json", "agents.json", "roles.json",
                    "runtime.json", "detected.json", "prompts.json", ".vigil"] {
            XCTAssertTrue(readme.contains(key), "README does not document \(key)")
        }
        // prompts.json is seeded in full on first run, every key set to the literal
        // sentinel "default" — the same string skill()'s resolution logic treats as
        // "unset" (PromptTable.load), so the seeded file starts semantically identical
        // to an absent one while still surfacing every editable key to the user.
        let promptsData = fm.contents(atPath: dir + "/prompts.json") ?? Data()
        let promptsObject = (try? JSONSerialization.jsonObject(with: promptsData)) as? [String: Any]
        XCTAssertEqual(promptsObject?["root"] as? String, "default")
        XCTAssertEqual(promptsObject?["subManager"] as? String, "default")
        XCTAssertEqual(promptsObject?["worker"] as? String, "default")
        let promptsExtras = promptsObject?["extras"] as? [String: Any]
        XCTAssertEqual(promptsExtras?["claude"] as? String, "default")
        XCTAssertEqual(promptsExtras?["codex"] as? String, "default")
        XCTAssertEqual(promptsExtras?["opencode"] as? String, "default")
        XCTAssertEqual(promptsExtras?["rename"] as? String, "default")
        // Reviewed schema manifest: every currently decoded or Vigil-written JSON path has
        // an explicit prose entry in its own section—not merely an example/other section.
        // Runtime's manifest is additionally derived from the production type above; the
        // other manifests remain explicit so reviewers can see the public contract.
        func proseSection(for file: String) -> String {
            guard let start = readme.range(of: "## \(file) ") else { return "" }
            let tail = readme[start.lowerBound...]
            let end = tail.dropFirst().range(of: "\n## ")?.lowerBound ?? tail.endIndex
            let section = String(tail[..<end])
            return section.components(separatedBy: "```").enumerated()
                .compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
                .joined()
        }
        let documentedFieldPaths: [String: [String]] = [
            "agents.json": [
                "agents", "agents.<entry-key>", "agents.<entry-key>.bin",
                "agents.<entry-key>.kind", "agents.<entry-key>.models",
                "agents.<entry-key>.defaultModel", "agents.<entry-key>.extraArgs",
                "agents.<entry-key>.env",
            ],
            "roles.json": [
                "root", "subManager", "worker", "<role>.agent", "<role>.model",
                "<role>.access", "<role>.promptAppend", "<role>.promptOverride",
            ],
            "launcher.json": ["agent"],
            "appearance.json": [
                "theme", "accent", "terminal", "terminal.fontFamily", "terminal.fontSize",
                "terminal.cursorStyle", "terminal.padding", "terminal.background",
                "terminal.foreground", "terminal.cursorColor", "terminal.palette",
                "terminal.palette.dark", "terminal.palette.light",
            ],
            "runtime.json": [
                "harvestAfterMinutes", "maxLiveSessions", "harvestStuckAfterHours",
                "injectHoldTimeoutSeconds", "historyTailCapMB", "sidebarCollapseThreshold",
                "autoName", "permDogfoodLog", "spawnStallSeconds",
                "initialPromptReadyTimeoutSeconds", "deliveryMaxAttempts",
                "deliveryReinjectGraceSeconds", "orchestrationToasts", "bottomShellCommand",
                "terminalDebugLog", "reportWatchdog",
            ],
            "detected.json": ["probedAt", "found", "found[].kind", "found[].bin", "notFound"],
            "prompts.json": [
                "root", "subManager", "worker", "extras", "extras.claude", "extras.codex",
                "extras.opencode", "extras.rename",
            ],
        ]
        for (file, paths) in documentedFieldPaths {
            let prose = proseSection(for: file)
            XCTAssertFalse(prose.isEmpty, "README has no section for \(file)")
            for path in paths {
                XCTAssertTrue(prose.contains("`\(path)`"),
                              "README \(file) prose has no explicit field entry for \(path)")
            }
        }
        // The README must carry the roles.json model MAP form (the only way to give
        // different CLI families different models), the read-only→plan alias truth,
        // and keep flagging the deprecated launcher keys.
        XCTAssertTrue(readme.contains(#"{"claude": "opus", "codex": "<codex model id>"}"#),
                      "README must document the roles.json model map form (with a placeholder id, not a rot-prone real one)")
        XCTAssertTrue(readme.contains("`read-only` maps to **plan**"),
                      "README must not sell read-only as an independent level")
        XCTAssertTrue(readme.contains("deprecated and silently ignored"),
                      "README must keep warning about launcher.json model/access")
        for typeContract in [
            "required non-empty string", "optional array of strings; default `[]`",
            "optional string or `null`; default `null`",
            "optional string-to-string object; default `{}`",
            "no shell and no PATH lookup",
            "omitted **or set to an unrecognized string**",
            "Codex's `resume <session-id>` path intentionally omits them",
            "Vigil overwrites its launch-reserved keys",
            "continues to the session model and entry `defaultModel`",
            "all-empty map is treated",
        ] {
            XCTAssertTrue(readme.contains(typeContract),
                          "README is missing agents.json type/default contract: \(typeContract)")
        }
        // The same README must also guide every agent family through onboarding: it reads
        // detected.json, never probes independently, and never uses deprecated launcher keys.
        XCTAssertTrue(readme.contains("Instructions for any agent configuring Vigil"))
        XCTAssertTrue(readme.contains("Claude Code, Codex, OpenCode"),
                      "the one guide must explicitly be agent-neutral")
        XCTAssertTrue(readme.contains("do not run detection commands yourself"))
        XCTAssertTrue(readme.contains("never write `model`/`access` there"),
                      "README must route model/access to roles.json, not launcher.json")
        // The universal onboarding rules must be present — (①) keep defaults, (②)
        // per-family model choices (root high / workers low), (③) decide from
        // detected.json, (④) ask the user + brief them on defaults.
        XCTAssertTrue(readme.contains("has a sensible default"),
                      "guide must say most settings keep their defaults (rule ①)")
        XCTAssertTrue(readme.contains("highest-capability model"),
                      "guide must give root the top model (rule ②)")
        XCTAssertTrue(readme.contains("cheaper-but-capable"),
                      "guide must give sub-manager/worker a lower model (rule ②)")
        XCTAssertTrue(readme.contains("family namespace") && readme.contains("family MAP"),
                      "guide must steer to the #47 per-family model map (rule ②)")
        XCTAssertTrue(readme.contains("ASK the user whether they want to change anything"),
                      "guide must have the agent confirm with the user at the end (rule ④)")
        // The README must document the newly exposed knobs.
        for key in ["orchestrationToasts", "bottomShellCommand", "cursorColor",
                    "background", "foreground"] {
            XCTAssertTrue(readme.contains(key), "README must document \(key)")
        }
        XCTAssertTrue(readme.contains(#""dark": "auto""#),
                      "README must document the palette 'auto' side")
    }

    /// Docs are app-managed (schema truth): a stale README from an older build must be
    /// refreshed on install; JSONs stay untouched (the neighboring test pins that).
    func testEnsureInstalled_refreshesStaleDocs() {
        let dir = freshDir()
        let store = makeStore(dir)
        let customAppearance = #"{ "theme": "light", "accent": "teal" }"#
        write(dir, "appearance.json", customAppearance)
        write(dir, "README.md", "old docs")
        write(dir, "CLAUDE.md", "old app-managed Claude-only guide")
        store.ensureInstalled()
        store.ensureInstalled() // migration is idempotent
        let readme = (try? String(contentsOfFile: dir + "/README.md", encoding: .utf8)) ?? ""
        XCTAssertEqual(readme, ConfigStore.readmeDoc, "stale README must be refreshed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/CLAUDE.md"),
                       "upgrade must remove the legacy vendor-specific guide")
        XCTAssertEqual(try? String(contentsOfFile: dir + "/appearance.json", encoding: .utf8),
                       customAppearance, "doc migration must not rewrite user JSON")
    }

    func testEnsureInstalled_keepsLegacyGuideIfCanonicalReadmeCannotBeWritten() {
        let dir = freshDir()
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir + "/README.md", withIntermediateDirectories: true)
        write(dir, "CLAUDE.md", "last readable legacy guide")

        makeStore(dir).ensureInstalled()

        XCTAssertTrue(fm.fileExists(atPath: dir + "/CLAUDE.md"),
                      "a failed README install must not leave the directory with no guide")
    }

    func testEnsureInstalled_neverRecursivelyDeletesDirectoryNamedLikeLegacyGuide() {
        let dir = freshDir()
        let sentinelDir = dir + "/CLAUDE.md"
        try? FileManager.default.createDirectory(atPath: sentinelDir,
                                                 withIntermediateDirectories: true)
        write(sentinelDir, "keep.txt", "not an app-managed guide file")

        makeStore(dir).ensureInstalled()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelDir + "/keep.txt"),
                      "migration must never recursively delete an unexpected directory")
    }

    func testEnsureInstalled_neverOverwritesUserEdits() {
        let dir = freshDir()
        let store = makeStore(dir)
        store.ensureInstalled()
        write(dir, "appearance.json", #"{ "theme": "light", "accent": "teal" }"#)

        store.ensureInstalled()   // e.g. reconfigure entry re-runs the install

        XCTAssertEqual(store.load().themePreference, .pinned(.light), "install overwrote a user edit")
        XCTAssertEqual(store.load().accent, .teal)
    }

    func testEnsureInstalled_neverRewritesExistingPromptsJSONEvenWhenStale() {
        // prompts.json is a JSON file (not a doc like README.md), so ensureInstalled's
        // existing "only write missing JSON files" rule already covers it — this test
        // pins that down explicitly for prompts.json, including the case where the
        // on-disk content is stale/outdated relative to what a fresh seed would write.
        let dir = freshDir()
        let store = makeStore(dir)
        let staleContent = #"{ "root": "a user's own long-since-customized text" }"#
        write(dir, "prompts.json", staleContent)

        store.ensureInstalled()   // first run for every OTHER file, but prompts.json pre-exists
        XCTAssertEqual(try? String(contentsOfFile: dir + "/prompts.json", encoding: .utf8),
                       staleContent, "an existing prompts.json must never be touched, stale or not")

        store.ensureInstalled()   // a second pass (e.g. reconfigure) must not touch it either
        XCTAssertEqual(try? String(contentsOfFile: dir + "/prompts.json", encoding: .utf8),
                       staleContent)
    }

    // MARK: - 1) ConfigStore: load

    func testLoad_missingDirGivesDefaults() {
        XCTAssertEqual(makeStore(freshDir()).load(), VigilConfig.defaults)
    }

    func testLoad_readsRealSettings() {
        let dir = freshDir()
        write(dir, "appearance.json", #"{ "theme": "light", "accent": "purple" }"#)
        // (the review-pipeline `review` key must be tolerated — ignored, never fatal)
        write(dir, "launcher.json", """
        { "agent": "relay", "model": "opus", "access": "bypassPermissions",
          "review": { "enabled": true, "timeoutSeconds": 300 } }
        """)
        let c = makeStore(dir).load()
        XCTAssertEqual(c.themePreference, .pinned(.light))
        XCTAssertEqual(c.accent, .purple)
        XCTAssertEqual(c.agent, "relay")
        XCTAssertNil(c.model, "C3: launcher.json model key ignored")
        XCTAssertEqual(c.access, .bypass, "C3: launcher.json access key ignored → wide-open default")
    }

    /// Compatibility lives in the LOADER, not in migration: an un-upgraded dir (legacy agent.json, no launcher.json)
    /// keeps its AGENT; once launcher.json exists its agent wins. model/access
    /// keys are ignored either way.
    func testLoad_legacyAgentJSONFallback() {
        let dir = freshDir()
        write(dir, "agent.json", #"{ "agent": "relay", "model": "opus", "access": "plan" }"#)
        var c = makeStore(dir).load()
        XCTAssertEqual(c.agent, "relay", "legacy agent carried over")
        XCTAssertNil(c.model, "C3: model ignored")
        XCTAssertEqual(c.access, .bypass, "C3: access ignored → wide-open")

        write(dir, "launcher.json", #"{ "agent": "claude" }"#)
        c = makeStore(dir).load()
        XCTAssertEqual(c.agent, "claude", "launcher.json agent shadows the legacy one")
    }

    /// Upgrade install over a dir that has ONLY the legacy agent.json: the shipped
    /// launcher.json must not write the deprecated `model`/`access` keys any more —
    /// writing load-ignored keys would be self-documented misinformation for the
    /// settings agent.
    func testEnsureInstalled_seedsLauncherFromLegacyAgentJSON() throws {
        let dir = freshDir()
        write(dir, "agent.json", """
        { "model": "opus", "access": "acceptEdits",
          "review": { "enabled": true, "timeoutSeconds": 60 } }
        """)
        let store = makeStore(dir)
        store.ensureInstalled()
        let c = store.load()
        XCTAssertNil(c.model, "C3: launcher.json model key ignored")
        XCTAssertEqual(c.access, .bypass, "C3: launcher.json access key ignored → wide-open")
        // The written file carries the ONE live key and nothing else.
        let data = try XCTUnwrap(FileManager.default.contents(atPath: dir + "/launcher.json"))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Array(obj.keys), ["agent"],
                       "shipped launcher.json must contain only `agent`")
    }

    func testLoad_runtimeTuning() {
        let dir = freshDir()
        write(dir, "runtime.json", """
        { "harvestAfterMinutes": 0, "maxLiveSessions": 0,
          "harvestStuckAfterHours": 0, "injectHoldTimeoutSeconds": 45,
          "historyTailCapMB": 2, "sidebarCollapseThreshold": 3,
          "autoName": false, "permDogfoodLog": false }
        """)
        let r = makeStore(dir).load().runtime
        XCTAssertEqual(r.harvestAfterMinutes, 0, "0 = harvest disabled, a valid value")
        XCTAssertEqual(r.maxLiveSessions, 0, "0 = unlimited live sessions, a valid value")
        XCTAssertEqual(r.harvestStuckAfterHours, 0, "0 = blind-spot fallback off, a valid value")
        XCTAssertEqual(r.injectHoldTimeoutSeconds, 45)
        XCTAssertEqual(r.historyTailCapMB, 2)
        XCTAssertEqual(r.sidebarCollapseThreshold, 3)
        XCTAssertFalse(r.autoName)
        XCTAssertFalse(r.permDogfoodLog)
        // High-tier default values: 60 / 10 / 24 / 300 / 8 / 5.
        let d = RuntimeTuning.defaults
        XCTAssertEqual(d.harvestAfterMinutes, 60)
        XCTAssertEqual(d.maxLiveSessions, 10)
        XCTAssertEqual(d.harvestStuckAfterHours, 24)
        XCTAssertEqual(d.injectHoldTimeoutSeconds, 300)
        XCTAssertEqual(d.historyTailCapMB, 8)
        XCTAssertEqual(d.sidebarCollapseThreshold, 5)
        XCTAssertEqual(d.spawnStallSeconds, 15)
        XCTAssertEqual(d.initialPromptReadyTimeoutSeconds, 30)
        XCTAssertEqual(d.deliveryMaxAttempts, 3)
        XCTAssertEqual(d.deliveryReinjectGraceSeconds, 4)
        // terminal debug log defaults off (zero telemetry, zero cost).
        XCTAssertEqual(d.terminalDebugLog, .off)
        // the report watchdog is on by default.
        XCTAssertTrue(d.reportWatchdog)
    }

    /// runtime.json can switch the report watchdog off.
    func testLoad_runtimeTuning_reportWatchdog() {
        let dir = freshDir()
        write(dir, "runtime.json", #"{ "reportWatchdog": false }"#)
        XCTAssertFalse(makeStore(dir).load().runtime.reportWatchdog)
        write(dir, "runtime.json", #"{ "reportWatchdog": true }"#)
        XCTAssertTrue(makeStore(dir).load().runtime.reportWatchdog)
    }

    /// terminalDebugLog parses the three modes; any other/absent string is `.off`.
    func testLoad_runtimeTuning_terminalDebugLog() {
        let dir = freshDir()
        func mode(_ json: String) -> TerminalDebugLogMode {
            write(dir, "runtime.json", json)
            return makeStore(dir).load().runtime.terminalDebugLog
        }
        XCTAssertEqual(mode(#"{ "terminalDebugLog": "metrics" }"#), .metrics)
        XCTAssertEqual(mode(#"{ "terminalDebugLog": "standard" }"#), .standard)
        XCTAssertEqual(mode(#"{ "terminalDebugLog": "off" }"#), .off)
        XCTAssertEqual(mode(#"{ "terminalDebugLog": "METRICS" }"#), .metrics, "case-insensitive")
        XCTAssertEqual(mode(#"{ "terminalDebugLog": "verbose" }"#), .off, "unknown → default off")
        XCTAssertEqual(mode(#"{ }"#), .off, "absent → default off")
    }

    /// The four dispatch/delivery knobs parse, and follow the
    /// "only > 0 applies" convention (0/negative silently keeps the default).
    func testLoad_runtimeTuning_dispatchAndDeliveryKnobs() {
        let dir = freshDir()
        write(dir, "runtime.json", """
        { "spawnStallSeconds": 25, "initialPromptReadyTimeoutSeconds": 90,
          "deliveryMaxAttempts": 5, "deliveryReinjectGraceSeconds": 10 }
        """)
        var r = makeStore(dir).load().runtime
        XCTAssertEqual(r.spawnStallSeconds, 25)
        XCTAssertEqual(r.initialPromptReadyTimeoutSeconds, 90)
        XCTAssertEqual(r.deliveryMaxAttempts, 5)
        XCTAssertEqual(r.deliveryReinjectGraceSeconds, 10)

        write(dir, "runtime.json", """
        { "spawnStallSeconds": 0, "initialPromptReadyTimeoutSeconds": -1,
          "deliveryMaxAttempts": 0, "deliveryReinjectGraceSeconds": -4 }
        """)
        r = makeStore(dir).load().runtime
        XCTAssertEqual(r.spawnStallSeconds, 15, "0/negative silently keeps the default")
        XCTAssertEqual(r.initialPromptReadyTimeoutSeconds, 30)
        XCTAssertEqual(r.deliveryMaxAttempts, 3)
        XCTAssertEqual(r.deliveryReinjectGraceSeconds, 4)
    }

    /// appearance.json `terminal` block parses field-tolerantly.
    func testLoad_appearanceTerminalPrefs() {
        let dir = freshDir()
        write(dir, "appearance.json", """
        { "theme": "light",
          "terminal": { "fontFamily": ["JetBrains Mono", "Menlo"], "fontSize": 14,
                        "cursorStyle": "bar", "padding": 8,
                        "palette": { "dark": ["#000000"] } } }
        """)
        let c = makeStore(dir).load()
        XCTAssertEqual(c.terminal.fontFamily, ["JetBrains Mono", "Menlo"])
        XCTAssertEqual(c.terminal.fontSize, 14)
        XCTAssertEqual(c.terminal.cursorStyle, "bar")
        XCTAssertEqual(c.terminal.padding, 8)
        XCTAssertEqual(c.terminal.paletteDark, ["#000000"],
                       "raw value lands; the 16-entry validation is the use site's job")
        XCTAssertNil(c.terminal.paletteLight)

        // No terminal block (and garbage) = defaults; never fatal.
        write(dir, "appearance.json", #"{ "theme": "dark" }"#)
        XCTAssertEqual(makeStore(dir).load().terminal, .defaults)
        write(dir, "appearance.json", #"{ "terminal": "not-an-object" }"#)
        XCTAssertEqual(makeStore(dir).load().terminal, .defaults,
                       "a mistyped terminal block degrades to appearance defaults")
    }

    /// Base colors (background/foreground/cursorColor) and the palette "auto" string
    /// all parse, and "auto" resolves to nil (= theme built-in) so it can't take the
    /// file down.
    func testLoad_appearanceTerminalAutoColors() {
        let dir = freshDir()
        // "auto" as an explicit palette side + a real light array + hex base colors.
        write(dir, "appearance.json", """
        { "terminal": { "background": "#101010", "foreground": "auto",
                        "cursorColor": "#00ff00",
                        "palette": { "dark": "auto", "light": ["#ffffff"] } } }
        """)
        var c = makeStore(dir).load()
        XCTAssertEqual(c.terminal.background, "#101010")
        XCTAssertEqual(c.terminal.foreground, "auto", "raw 'auto' lands; use site resolves it")
        XCTAssertEqual(c.terminal.cursorColor, "#00ff00")
        XCTAssertNil(c.terminal.paletteDark, "'auto' palette side → nil (theme built-in)")
        XCTAssertEqual(c.terminal.paletteLight, ["#ffffff"])
        // "auto" at the use site == the theme token (no override).
        XCTAssertEqual(VGGhosttyTheme.effectiveColorHex(c.terminal.foreground,
                                                        fallback: NSColor(hex: 0x161719)),
                       "#161719")

        // A garbage palette side (object/number) collapses to auto without throwing —
        // the sibling fields must still land (per-field tolerance, not whole-file loss).
        write(dir, "appearance.json", """
        { "theme": "light",
          "terminal": { "palette": { "dark": { "nonsense": 1 }, "light": 42 },
                        "fontSize": 15 } }
        """)
        c = makeStore(dir).load()
        XCTAssertEqual(c.themePreference, .pinned(.light))
        XCTAssertNil(c.terminal.paletteDark)
        XCTAssertNil(c.terminal.paletteLight)
        XCTAssertEqual(c.terminal.fontSize, 15, "garbage palette must not poison siblings")
    }

    /// runtime.json `orchestrationToasts` / `bottomShellCommand` parse, default
    /// correctly, and "auto"/empty shell normalizes.
    func testLoad_runtimeTuning_toastAndBottomShell() {
        // Defaults: toasts OFF, shell = "" (follow $SHELL).
        XCTAssertFalse(RuntimeTuning.defaults.orchestrationToasts, "toasts default off")
        XCTAssertEqual(RuntimeTuning.defaults.bottomShellCommand, "")

        let dir = freshDir()
        write(dir, "runtime.json", """
        { "orchestrationToasts": true, "bottomShellCommand": "/opt/homebrew/bin/fish" }
        """)
        var r = makeStore(dir).load().runtime
        XCTAssertTrue(r.orchestrationToasts)
        XCTAssertEqual(r.bottomShellCommand, "/opt/homebrew/bin/fish")

        // "auto" (any case, padded) is the explicit synonym for "follow $SHELL" → "".
        write(dir, "runtime.json", #"{ "bottomShellCommand": "  AUTO  " }"#)
        r = makeStore(dir).load().runtime
        XCTAssertEqual(r.bottomShellCommand, "", "'auto' normalizes to the follow-$SHELL sentinel")
        XCTAssertFalse(r.orchestrationToasts, "absent key keeps the default (off)")
    }

    /// The ⌘J scratch shell honors runtime.json `bottomShellCommand`; empty = follow
    /// $SHELL, argv is always an interactive login shell.
    func testBottomShell_respectsConfiguredCommand() {
        let saved = RuntimeTuning.current
        defer { RuntimeTuning.current = saved }

        RuntimeTuning.current = RuntimeTuning()                 // default: empty → $SHELL
        let (autoShell, autoArgs) = BottomShell.loginShell()
        XCTAssertEqual(autoArgs, ["-l", "-i"])
        XCTAssertEqual(autoShell, ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")

        var t = RuntimeTuning(); t.bottomShellCommand = "/opt/homebrew/bin/fish"
        RuntimeTuning.current = t
        XCTAssertEqual(BottomShell.loginShell().0, "/opt/homebrew/bin/fish",
                       "a configured shell overrides $SHELL")
    }

    func testLoad_agentRegistry() {
        let dir = freshDir()
        write(dir, "agents.json", """
        { "agents": {
            "zed":    { "bin": "/x/claude2", "kind": "claude" },
            "claude": { "bin": "~/.local/bin/claude", "models": ["sonnet"] },
            "codex":  { "bin": "/x/codex" },
            "broken": { "kind": "claude" } } }
        """)
        let r = makeStore(dir).load().registry
        // bin is the only required field (broken is dropped); kind falls back to inference from the key name (codex→codex, zed→claude is declared explicitly);
        // order = usable-first, then by key name (both claude+codex are usable, so all three land in the usable segment).
        XCTAssertEqual(r.entries.map(\.key), ["claude", "codex", "zed"])
        XCTAssertEqual(r["claude"]?.models, ["sonnet"])
        XCTAssertEqual(r["codex"]?.kind, .codex)
        XCTAssertTrue(r["codex"]!.usable, "#34: codex is wired up and usable")
        XCTAssertNil(r["broken"])
    }

    /// Field-level tolerance: unknown enum strings fall back per FIELD; a corrupt file
    /// falls back per FILE; neither may poison the other file's values.
    func testLoad_toleratesGarbage() {
        let dir = freshDir()
        write(dir, "appearance.json", #"{ "theme": "solarized", "accent": "teal" }"#)
        write(dir, "agent.json", "not json at all {{{")
        let c = makeStore(dir).load()
        XCTAssertEqual(c.themePreference, .system,
                       "#4: an unknown theme value now degrades to follow-system, not a hard dark")
        XCTAssertEqual(c.accent, .teal, "the valid sibling field must still land")
        XCTAssertEqual(c.model, nil)
        XCTAssertEqual(c.access, .bypass, "C3: wide-open default")
    }

    // MARK: - 1) ConfigStore: hot reload (the file watcher)

    func testWatch_pickupsFileChanges_repeatedly() {
        let dir = freshDir()
        let store = makeStore(dir)
        store.ensureInstalled()

        var seen: [VigilConfig] = []
        store.startWatching { seen.append($0) }

        write(dir, "appearance.json", #"{ "theme": "light", "accent": "blue" }"#)
        pumpUntil("first change lands") { seen.last?.themePreference == .pinned(.light) }

        // A second, different file must also be picked up (watcher re-arms).
        // (After install, launcher.json shadows the legacy agent.json — write the new file.
        //  launcher.json only has agent left in effect; model/access are ignored — watch the agent field change.)
        write(dir, "launcher.json", #"{ "agent": "relay" }"#)
        pumpUntil("second change lands") { seen.last?.agent == "relay" }
        XCTAssertEqual(seen.last?.themePreference, .pinned(.light),
                       "earlier change must persist in later loads")
    }

    // MARK: - 2) AppModel: first-run onboarding

    func testFirstRun_opensConfigWorkspaceWithPrefill() {
        let dir = freshDir()
        let app = makeApp(configDir: dir)
        app.bootstrapIfNeeded()

        // config workspace = the built-in "settings" pseudo-project (no ad-hoc
        // "user config" row under "projects"), launcher focused.
        XCTAssertEqual(app.settingsProject.cwd, dir)
        XCTAssertEqual(app.settingsProject.name, "Settings")
        XCTAssertEqual(app.currentProjectID, app.settingsProject.id)
        XCTAssertNil(app.projects.first { $0.cwd == dir },
                     "config dir must NOT appear as a user project")
        XCTAssertNil(app.activeSessionID, "launcher, not a session, must be showing")
        XCTAssertEqual(app.launcherPrefill, AppModel.configOnboardingPrompt)
        XCTAssertTrue(app.launcherPrefill?.contains("README.md") == true,
                      "every agent family must be explicitly directed to the shared guide")
        XCTAssertFalse(app.configStore.isFirstRun, "defaults must be installed by now")

        // The launcher actually renders with the prefilled prompt (the input is an
        // NSTextView representable — assert on the prompt model the field renders;
        // model→NSTextView sync is pinned by LauncherPromptTests).
        let launcher = LauncherView(app: app, project: app.settingsProject)
        let field = try? launcher.inspect()
            .find(LauncherPromptField.self).actualView()
        XCTAssertEqual(field?.model.text, AppModel.configOnboardingPrompt)
    }

    func testSecondRun_appliesFilesSilently() {
        let dir = freshDir()
        write(dir, "appearance.json", #"{ "theme": "light", "accent": "amber" }"#)
        write(dir, "agent.json", """
        { "model": "opus", "access": "acceptEdits",
          "review": { "enabled": true, "timeoutSeconds": 60 } }
        """)
        let app = makeApp(configDir: dir)
        app.bootstrapIfNeeded()

        XCTAssertEqual(app.theme, .light)                 // restart-persistence acceptance line
        XCTAssertEqual(app.accent, .amber)
        XCTAssertNil(app.defaultModel, "C3: model key ignored")
        XCTAssertEqual(app.defaultAccess, .bypass, "C3: access key ignored → wide-open default")
        XCTAssertNil(app.launcherPrefill, "no onboarding on a configured machine")
        XCTAssertNil(app.projects.first { $0.cwd == dir },
                     "no config workspace forced on a configured machine")
    }

    func testHotReload_reachesAppModel() {
        let dir = freshDir()
        // Fresh dir installs the shipped "auto" default → resolves via the (fake dark) system.
        let app = makeApp(configDir: dir)
        app.bootstrapIfNeeded()
        XCTAssertEqual(app.theme, .dark)

        // A pinned "light" wins over the system scheme, hot.
        write(dir, "appearance.json", #"{ "theme": "light", "accent": "teal" }"#)
        pumpUntil("theme hot-reloads into the running app") { app.theme == .light }
        XCTAssertEqual(app.accent, .teal)
    }

    // MARK: - 2) AppModel: follow-system appearance

    /// The shipped default (and any "auto"/absent theme) follows the OS scheme and re-resolves
    /// live when the system flips — while a pin stays deaf to the flip.
    func testFollowSystem_liveSwitchAndPin() {
        let dir = freshDir()
        let (app, sys) = makeAppTracking(configDir: dir, isDark: true)
        app.bootstrapIfNeeded()
        // Shipped default = "auto" → follows the fake system (dark).
        XCTAssertEqual(app.themePreference, .system)
        XCTAssertEqual(app.theme, .dark)

        // System flips to light → the app tracks it, no config edit.
        sys.isDark = false
        XCTAssertEqual(app.theme, .light, "follow-system must track a live OS flip")
        sys.isDark = true
        XCTAssertEqual(app.theme, .dark)

        // Pin to light: now the preference ignores the system.
        write(dir, "appearance.json", #"{ "theme": "light", "accent": "blue" }"#)
        pumpUntil("pin lands") { app.themePreference == .pinned(.light) }
        XCTAssertEqual(app.theme, .light)
        sys.isDark = true   // a dark OS must NOT flip a light pin
        XCTAssertEqual(app.theme, .light, "a pin is deaf to system flips")

        // Back to "auto": follow-system resumes and re-resolves immediately.
        write(dir, "appearance.json", #"{ "theme": "auto", "accent": "blue" }"#)
        pumpUntil("auto resumes") { app.themePreference == .system }
        XCTAssertEqual(app.theme, .dark, "auto re-resolves against the current (dark) system")
        sys.isDark = false
        XCTAssertEqual(app.theme, .light)
    }

    // MARK: - 2) launcher seeding + reconfigure

    /// The launcher no longer carries model/access — a launched session runs wide-open
    /// (bypass) with no seeded model (that tier = roles.json per-role now). The legacy
    /// agent.json model/access keys are ignored.
    func testLauncherSubmit_launchesAllOpenNoModelSeed() throws {
        guard UITestSupport.fakeAgentCommand == Self.stubScript else {
            XCTFail("fake-agent seam inactive — refusing to launch a real agent")
            return
        }
        let dir = freshDir()
        write(dir, "agent.json", """
        { "model": "opus", "access": "default",
          "review": { "enabled": true, "timeoutSeconds": 300 } }
        """)
        let app = makeApp(configDir: dir)
        app.bootstrapIfNeeded()

        let projDir = NSTemporaryDirectory() + "vigil-cfg-proj-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: projDir, withIntermediateDirectories: true)
        let p = ProjectVM(id: UUID().uuidString, name: "Demo Project", cwd: projDir)
        app.projects.append(p)

        let launcher = LauncherView(app: app, project: p, initialTask: "Task")
        try launcher.inspect()
            .find(ViewType.Button.self,
                  where: { (try? $0.accessibilityIdentifier()) == "launcher.submit" })
            .tap()

        let vm = try XCTUnwrap(p.sessions.first)
        XCTAssertNil(vm.model, "C3: no model seed (agent.json model ignored)")
        XCTAssertEqual(vm.access, .bypass, "C3: wide-open default (agent.json access ignored)")
    }

    /// ⌘, reconfigure: lands on the built-in "settings" workspace (never creates or
    /// duplicates a project row), reopens its launcher BLANK — the onboarding prefill is
    /// first-run only. The acceptEdits seed is gone (settings agent now runs wide-open
    /// like every session).
    func testReconfigure_reusesConfigWorkspace() {
        let dir = freshDir()
        let app = makeApp(configDir: dir)
        app.bootstrapIfNeeded()                            // first run opened the workspace
        let count = app.projects.count

        app.select(session: "nonexistent")                 // noop; leave launcher state
        app.launcherPrefill = nil
        app.openConfigWorkspace()

        XCTAssertEqual(app.projects.count, count, "reconfigure must not add a project row")
        XCTAssertEqual(app.currentProjectID, app.settingsProject.id)
        XCTAssertNil(app.activeSessionID)
        XCTAssertNil(app.launcherPrefill, "prefill is first-run only (0709)")
    }

    func testEverySettingsTaskDiscoversTheUniversalReadme() {
        let request = "Change the terminal font to Menlo"
        let wrapped = AppModel.taskForConfigWorkspace(request)
        XCTAssertTrue(wrapped.hasPrefix(AppModel.configTaskPreamble))
        XCTAssertTrue(wrapped.hasSuffix(request), "the user's request must remain intact")
        XCTAssertEqual(AppModel.taskForConfigWorkspace(AppModel.configOnboardingPrompt),
                       AppModel.configOnboardingPrompt,
                       "onboarding already names README and must not get a duplicate preamble")
        XCTAssertEqual(AppModel.taskForConfigWorkspace(""), AppModel.configTaskPreamble)
        for misleadingMention in [
            "Do not read README.md; only change the font",
            "Rename README.md after editing the JSON",
            "The attachment is /tmp/README.md",
        ] {
            XCTAssertTrue(AppModel.taskForConfigWorkspace(misleadingMention)
                .hasPrefix(AppModel.configTaskPreamble),
                "a mere README.md mention must not bypass universal guide discovery")
        }
    }

    func testLaunchSessionInjectsReadmeIntoSettingsButNotOrdinaryProjects() throws {
        guard UITestSupport.fakeAgentCommand == Self.stubScript else {
            XCTFail("fake-agent seam inactive — refusing to launch a real agent")
            return
        }
        let dir = freshDir()
        let app = makeApp(configDir: dir)
        app.bootstrapIfNeeded()

        let request = "Do not read README.md; only change the font"
        let settingsVM = try XCTUnwrap(app.launchSession(
            in: app.settingsProject.id, task: request, agent: "claude"))
        XCTAssertEqual(settingsVM.rootLaunchTask,
                       AppModel.taskForConfigWorkspace(request),
                       "the production launch path must preserve the entire user request")
        XCTAssertEqual(loggedRootTaskPrefix(settingsVM),
                       String(AppModel.configTaskPreamble.prefix(80)),
                       "the production Settings launch path must pass the preamble to root")

        let projectDir = NSTemporaryDirectory() + "vigil-normal-proj-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: projectDir,
                                                withIntermediateDirectories: true)
        let project = ProjectVM(id: UUID().uuidString, name: "Normal", cwd: projectDir)
        app.projects.append(project)
        let normalVM = try XCTUnwrap(app.launchSession(
            in: project.id, task: request, agent: "claude"))
        XCTAssertEqual(normalVM.rootLaunchTask, request)
        XCTAssertEqual(loggedRootTaskPrefix(normalVM), request,
                       "ordinary projects must receive the user's task byte-for-byte")
    }

    func testMountedOnboardingPrefillDoesNotFollowSidebarProjectSwitch() throws {
        let dir = freshDir()
        let app = makeApp(configDir: dir)
        app.bootstrapIfNeeded()
        XCTAssertEqual(app.launcherPrefill, AppModel.configOnboardingPrompt)

        let projectDir = NSTemporaryDirectory() + "vigil-prefill-proj-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: projectDir,
                                                withIntermediateDirectories: true)
        let project = ProjectVM(id: UUID().uuidString, name: "Normal", cwd: projectDir)
        app.projects.append(project)

        // Host the real center hierarchy so LauncherView's @State and Views.swift's
        // project-id identity participate. Sidebar project rows call selectProject—not
        // openLauncher—so use that exact path for the regression.
        let body = AppBody(app: app)
        ViewHosting.host(view: body)
        defer { ViewHosting.expel() }
        pump(0.05)
        var field = try body.inspect().find(LauncherPromptField.self).actualView()
        XCTAssertEqual(field.model.text, AppModel.configOnboardingPrompt)

        app.selectProject(project.id)
        pump(0.05)

        XCTAssertEqual(app.launcherPrefill, AppModel.configOnboardingPrompt,
                       "this path intentionally proves project binding, not incidental clearing")
        field = try body.inspect().find(LauncherPromptField.self).actualView()
        XCTAssertEqual(field.model.text, "",
                       "the mounted ordinary-project launcher must not inherit Settings onboarding")
    }

    /// Prefill is one-shot: submitting the onboarding task consumes it, so the next
    /// launcher opens blank.
    func testPrefill_consumedBySubmit() throws {
        guard UITestSupport.fakeAgentCommand == Self.stubScript else {
            XCTFail("fake-agent seam inactive — refusing to launch a real agent")
            return
        }
        let dir = freshDir()
        let app = makeApp(configDir: dir)
        app.bootstrapIfNeeded()
        let p = app.settingsProject                        // D-g: settings = built-in pseudo-project

        let launcher = LauncherView(app: app, project: p)
        try launcher.inspect()
            .find(ViewType.Button.self,
                  where: { (try? $0.accessibilityIdentifier()) == "launcher.submit" })
            .tap()

        let vm = try XCTUnwrap(p.sessions.first)
        // Session name = 13-char prefix of the task — enough to prove the prefilled
        // onboarding prompt is what actually launched.
        let expectedName = String(AppModel.configOnboardingPrompt.prefix(13)) + "…"
        XCTAssertEqual(vm.name, expectedName,
                       "the README-directed onboarding task must be launched")
        XCTAssertEqual(vm.rootLaunchTask, AppModel.configOnboardingPrompt,
                       "the full onboarding task must reach SessionVM/Orchestrator unchanged")
        XCTAssertEqual(loggedRootTaskPrefix(vm),
                       String(AppModel.configOnboardingPrompt.prefix(80)),
                       "the production root launch must receive the onboarding task verbatim")
        XCTAssertNil(app.launcherPrefill, "prefill must be consumed by submit")
    }

    // MARK: - CLI prober (claude→codex→opencode, real binaries only)

    /// A fake bin dir with the named entries; executables get +x, others stay plain.
    private func makeBinDir(executables: [String], plain: [String] = []) -> String {
        let dir = NSTemporaryDirectory() + "vigil-cfg-bins-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for name in executables {
            let p = dir + "/" + name
            try? "#!/bin/sh\n".write(toFile: p, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p)
        }
        for name in plain {
            try? "not a cli".write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
        }
        return dir
    }

    func testProbe_orderAndExecutableOnly() {
        // dirA: codex executable + claude non-executable; dirB: claude/opencode executable.
        // Assertion: results are ordered claude→codex→opencode; claude skips dirA's fake file and picks up dirB's;
        // each CLI takes the first hit directory.
        let dirA = makeBinDir(executables: ["codex"], plain: ["claude"])
        let dirB = makeBinDir(executables: ["claude", "opencode"])
        let found = CLIProber.probe(dirs: [dirA, dirB])
        XCTAssertEqual(found.map(\.kind), ["claude", "codex", "opencode"])
        XCTAssertEqual(found[0].bin, dirB + "/claude", "a non-executable file is not a hit")
        XCTAssertEqual(found[1].bin, dirA + "/codex")
    }

    func testCandidateDirsEnumeratesNvmVersionsWithoutHardcoding() {
        // A Dock-launched app has no shell PATH; codex/opencode under nvm must still be
        // found. Every installed node version's bin is GLOBBED (no hardcoded version/home).
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "vigil-nvm-\(UUID().uuidString.prefix(8))"
        for v in ["v18.20.0", "v20.19.6"] {
            try? fm.createDirectory(atPath: home + "/.nvm/versions/node/\(v)/bin",
                                    withIntermediateDirectories: true)
        }
        addTeardownBlock { try? fm.removeItem(atPath: home) }
        // Explicit env WITHOUT VIGIL_PROBE_DIRS so the real candidate table (with the glob)
        // is exercised rather than the test seam.
        let dirs = CLIProber.candidateDirs(env: ["PATH": ""], home: home)
        XCTAssertTrue(dirs.contains(home + "/.nvm/versions/node/v18.20.0/bin"))
        XCTAssertTrue(dirs.contains(home + "/.nvm/versions/node/v20.19.6/bin"))
        XCTAssertTrue(dirs.contains(home + "/.deno/bin"), "deno bin listed")
        XCTAssertTrue(dirs.contains(home + "/.volta/bin"), "volta bin listed")
        XCTAssertTrue(dirs.contains(home + "/.bun/bin"), "bun bin still there")
    }

    /// Detection (CLIProber, GUI startup probe) and execution
    /// (GhosttyViewBackend.ensuredPATH, child-process PATH) must never drift apart —
    /// a CLI CLIProber can find must be a CLI the forked child can exec. With no process
    /// PATH and no inherited PATH, every dir CLIProber offers must also be in ensuredPATH's
    /// output (both must be reading the same VigilCore.ToolchainPaths table).
    func testCandidateDirsAndEnsuredPATHShareOneSource() {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "vigil-samesource-\(UUID().uuidString.prefix(8))"
        try? fm.createDirectory(atPath: home + "/.nvm/versions/node/v20.19.6/bin",
                                withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(atPath: home) }

        let detectionDirs = CLIProber.candidateDirs(env: ["PATH": ""], home: home)
        let executionDirs = Set(GhosttyViewBackend.ensuredPATH(nil, home: home)
            .split(separator: ":").map(String.init))

        for d in detectionDirs {
            XCTAssertTrue(executionDirs.contains(d),
                         "\(d) is detectable but not on the execution PATH — a CLI found " +
                         "here would fork into an environment that can't resolve it")
        }
    }

    func testFirstRun_probeSeedsAgentsAndLauncherAndDetected() throws {
        let bins = makeBinDir(executables: ["codex", "claude"])
        setenv("VIGIL_PROBE_DIRS", bins, 1)
        addTeardownBlock { unsetenv("VIGIL_PROBE_DIRS") }

        let dir = freshDir()
        let app = makeApp(configDir: dir)
        app.bootstrapIfNeeded()

        XCTAssertEqual(app.cliProbe?.map(\.kind), ["claude", "codex"])
        // agents.json: one entry per hit, bin = the real detected path; launcher default = the first hit.
        let reg = app.configStore.load().registry
        XCTAssertEqual(reg["claude"]?.bin, bins + "/claude")
        XCTAssertEqual(reg["codex"]?.bin, bins + "/codex")
        XCTAssertEqual(app.defaultAgent, "claude")
        // The probe cannot authoritatively invent a provider's changing model catalog,
        // so fresh installs leave `models` empty. User-supplied catalogs remain useful
        // to the cross-agent spawn-model misuse guard.
        XCTAssertEqual(reg["claude"]?.models, [],
                       "probe-based install must not fabricate a model catalog")
        // detected.json: the facts file lands on disk (the settings agent reads it, never probes itself).
        let detected = try XCTUnwrap(
            FileManager.default.contents(atPath: dir + "/detected.json"))
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: detected) as? [String: Any])
        XCTAssertEqual((obj["found"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(obj["notFound"] as? [String], ["opencode"])
    }

    func testZeroHit_bannerShowsAndBuiltinClaudeFallbackHolds() throws {
        let empty = makeBinDir(executables: [])
        setenv("VIGIL_PROBE_DIRS", empty, 1)
        addTeardownBlock { unsetenv("VIGIL_PROBE_DIRS") }

        let dir = freshDir()
        let app = makeApp(configDir: dir)
        app.bootstrapIfNeeded()

        XCTAssertEqual(app.cliProbe?.isEmpty, true)
        // agents.json ends up an empty table, but the UI surface must not be empty: the builtin claude fallback entry is still there.
        XCTAssertEqual(app.agentEntries.map(\.key), ["claude"])
        let launcher = LauncherView(app: app, project: app.settingsProject)
        XCTAssertNoThrow(try launcher.inspect()
            .find(viewWithAccessibilityIdentifier: "launcher.noAgentBanner"),
            "zero hits must surface the install-guidance banner")
    }

    func testProbeSkipped_noBanner() throws {
        // UITest with VIGIL_PROBE_DIRS unset → no probing (machine-dependent scanning must not enter deterministic tests),
        // cliProbe = nil → no warning banner.
        let dir = freshDir()
        let app = makeApp(configDir: dir)
        app.bootstrapIfNeeded()
        XCTAssertNil(app.cliProbe)
        let launcher = LauncherView(app: app, project: app.settingsProject)
        XCTAssertThrowsError(try launcher.inspect()
            .find(viewWithAccessibilityIdentifier: "launcher.noAgentBanner"))
    }

    // MARK: - the whole family defaults wide-open — the settings agent is bypass too

    func testOnboarding_launchesAllOpenAndPrefillConsumed() throws {
        guard UITestSupport.fakeAgentCommand == Self.stubScript else {
            XCTFail("fake-agent seam inactive — refusing to launch a real agent")
            return
        }
        let dir = freshDir()
        let app = makeApp(configDir: dir)
        app.bootstrapIfNeeded()                            // first run → onboarding workspace

        XCTAssertEqual(app.defaultAccess, .bypass, "C3: wide-open by default")

        let launcher = LauncherView(app: app, project: app.settingsProject)
        try launcher.inspect()
            .find(ViewType.Button.self,
                  where: { (try? $0.accessibilityIdentifier()) == "launcher.submit" })
            .tap()
        let vm = try XCTUnwrap(app.settingsProject.sessions.first)
        XCTAssertEqual(vm.access, .bypass, "the onboarding session runs wide-open too (reversing 0709 acceptEdits)")
        XCTAssertNil(app.launcherPrefill, "prefill is one-shot")

        // A regular project's launcher is likewise wide-open.
        let projDir = NSTemporaryDirectory() + "vigil-cfg-proj2-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: projDir,
                                                withIntermediateDirectories: true)
        let p = ProjectVM(id: UUID().uuidString, name: "Plain Project", cwd: projDir)
        app.projects.append(p)
        let launcher2 = LauncherView(app: app, project: p, initialTask: "Task")
        try launcher2.inspect()
            .find(ViewType.Button.self,
                  where: { (try? $0.accessibilityIdentifier()) == "launcher.submit" })
            .tap()
        XCTAssertEqual(try XCTUnwrap(p.sessions.first).access, .bypass)
    }
}
