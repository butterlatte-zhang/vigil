import Foundation
import VigilCore

// Settings-as-files: every real setting lives in
// ~/.config/vigil as per-concern JSON files + a README documenting the schemas — no
// settings page. The app only READS the files; writing them is the user's / the
// onboarding agent's business — Vigil does not build its own settings UI.
//
// Read timing splits in two (effective timing = read timing):
//   render-scoped — appearance.json / runtime.json / launcher.json defaults / the
//     agents registry FOR THE LAUNCHER UI: loaded here, file-watched, hot-applied.
//   launch-scoped — agents.json / roles.json AT CELL LAUNCH: the harness point-reads
//     them per launchSpec (ConfigFiles.swift, VigilCore) — edits hit the NEXT spawn.
// launcher.json is the current file (same fields as the legacy agent.json, plus
// "agent"); the legacy file keeps being read when launcher.json is absent (compat
// lives in the LOADER).

// MARK: - The loaded value set

struct VigilConfig: Equatable {
    /// appearance.json `theme` as a PREFERENCE: "dark"/"light" pin, "auto"/
    /// missing/unknown = follow the OS. The resolved VGTheme is derived at the AppModel layer,
    /// where the live system appearance is known and observed — the loader stays scheme-agnostic
    /// (it runs off the watch queue and must not read NSApp). Default = follow-system.
    var themePreference: VGThemePreference = .system
    var accent: VGAccent = .blue
    /// appearance.json `terminal` block: ghostty render knobs —
    /// font chain / size / cursor / padding / ANSI palette. Pure render, hot-applied.
    var terminal: VGTerminalPrefs = .defaults
    /// Launcher default agent (registry key) — only which entry starts selected.
    var agent: String = "claude"
    /// Launcher default for `claude --model` (nil = claude's own default, no flag).
    /// The model tier lives in roles.json per-role (the launcher has no model
    /// picker); this field stays nil (agent default).
    var model: String? = nil
    /// Permission defaults wide-open for every family — the launcher has no tier
    /// picker and launcher.json's `access` key is ignored (tightening = roles.json access).
    var access: PermissionMode = .bypass
    /// runtime.json policy values (render-scoped; applyConfig lands them in RuntimeTuning.current).
    var runtime: RuntimeTuning = .defaults
    /// agents.json as loaded — for the launcher dropdowns. Empty = file absent or an
    /// empty map; the UI falls back to the builtin claude entry either way (upgrade users
    /// and the test path must not lose the agent just because a file is missing).
    var registry: AgentRegistry = AgentRegistry(entries: [])

    static let defaults = VigilConfig()
}

// MARK: - Store (install · load · watch)

/// Owns one config directory. Not @Observable — AppModel holds the applied values;
/// this is the file boundary: first-run detection, default install, tolerant load,
/// and a directory+file watcher for hot reload (agent writes a JSON → app picks it
/// up live).
final class ConfigStore {
    let dir: String

    /// ~/.config/vigil (the audience lives in the terminal); VIGIL_CONFIG_DIR overrides (tests).
    static var defaultDir: String { VigilConfigDir.default }

    init(dir: String) { self.dir = dir }
    deinit { for s in sources { s.cancel() } }

    // MARK: first run & install

    /// First run = the directory holds no config JSON at all (missing dir included).
    /// detected.json doesn't count — it is Vigil-written probe fact, not a setting.
    var isFirstRun: Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir)
        else { return true }
        return !items.contains { $0.hasSuffix(".json") && $0 != "detected.json" }
    }

    /// Create the dir and write every shipped default that is MISSING — never overwrite
    /// a JSON: user/agent edits are the source of truth once they exist. README.md is
    /// app-managed and refreshed when stale — it must describe the schemas this build
    /// actually reads, or a configuring agent works from lies. A legacy Claude-specific
    /// CLAUDE.md guide is removed below, since README is the single, agent-neutral
    /// source of truth.
    ///
    /// `detected` (the CLI probe) shapes the FIRST agents.json
    /// (one entry per found CLI) and launcher.json's default agent. The legacy
    /// agent.json does not seed launcher.json — its only surviving key is `agent`,
    /// which the loader still reads directly as a fallback.
    func ensureInstalled(detected: [DetectedCLI] = []) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, content) in shippedFiles(detected: detected) {
            let p = path(name)
            let isDoc = !name.hasSuffix(".json")
            if !fm.fileExists(atPath: p) {
                try? content.write(toFile: p, atomically: true, encoding: .utf8)
            } else if isDoc,
                      (try? String(contentsOfFile: p, encoding: .utf8)) != content {
                try? content.write(toFile: p, atomically: true, encoding: .utf8)
            }
        }
        // This file was app-owned and auto-refreshed, never a user settings surface.
        // Only remove a regular-file/symlink legacy guide after the canonical README is
        // definitely present with this build's full content. A failed README write must
        // not leave an upgraded config directory with no guide, and a surprising directory
        // named CLAUDE.md must never be recursively deleted.
        let readmePath = path("README.md")
        let legacyGuidePath = path("CLAUDE.md")
        var legacyGuideIsDirectory: ObjCBool = false
        if (try? String(contentsOfFile: readmePath, encoding: .utf8)) == Self.readmeDoc,
           fm.fileExists(atPath: legacyGuidePath, isDirectory: &legacyGuideIsDirectory),
           !legacyGuideIsDirectory.boolValue {
            try? fm.removeItem(atPath: legacyGuidePath)
        }
    }

    // MARK: load (tolerant: unreadable/type-invalid file → file defaults; validated value → field default)

    func load() -> VigilConfig {
        var c = VigilConfig.defaults
        if let dto: AppearanceDTO = read("appearance.json") {
            // "dark"/"light" pin; "auto"/absent/unknown → follow-system (tolerant parse).
            c.themePreference = VGThemePreference(configValue: dto.theme)
            if let v = dto.accent.flatMap(VGAccent.init(rawValue:)) { c.accent = v }
            if let t = dto.terminal {
                // Field-level tolerant: values land raw here; range/whitelist validation
                // happens at the use site (VGGhosttyTheme.effective*), so a bad value
                // degrades to the built-in default without dragging its siblings down.
                // A palette side of "auto" (or absent) resolves to nil = the theme built-in.
                c.terminal = VGTerminalPrefs(fontFamily: t.fontFamily ?? [],
                                             fontSize: t.fontSize,
                                             cursorStyle: t.cursorStyle,
                                             padding: t.padding,
                                             paletteDark: t.palette?.dark?.colorsOrNil,
                                             paletteLight: t.palette?.light?.colorsOrNil,
                                             background: t.background,
                                             foreground: t.foreground,
                                             cursorColor: t.cursorColor)
            }
        }
        // launcher.json first; the legacy agent.json read as a fallback so an
        // un-upgraded dir keeps its values (compat is in the LOADER, not a migration).
        if let dto: LauncherDTO = read("launcher.json") ?? read("agent.json") {
            if let a = dto.agent, !a.isEmpty { c.agent = a }
            // `model` / `access` keys are silently ignored (compat convention) — model tier
            // moved to roles.json per-role, permission defaults wide-open. Only `agent` survives.
        }
        c.runtime = RuntimeTuning.load(dir: dir)
        c.registry = AgentRegistry.load(dir: dir) ?? AgentRegistry(entries: [])
        return c
    }

    private struct AppearanceDTO: Decodable {
        var theme: String?; var accent: String?
        var terminal: TerminalDTO?
        struct TerminalDTO: Decodable {
            var fontFamily: [String]?; var fontSize: Double?
            var cursorStyle: String?; var padding: Int?
            var palette: PaletteDTO?
            // Base colors: "auto" | "#rrggbb". Plain strings — tolerated the same
            // coarse way as fontSize etc. (a mistyped value throws → the whole terminal
            // block degrades to defaults, pinned by testLoad_appearanceTerminalPrefs).
            var background: String?; var foreground: String?; var cursorColor: String?
            struct PaletteDTO: Decodable { var dark: PaletteSide?; var light: PaletteSide? }
        }
    }

    /// A palette side is either an explicit 16-entry color array or the string "auto"
    /// (the theme built-in). Decoding NEVER throws — a string or any other garbage shape
    /// collapses to `.auto`, so "auto" can't take the surrounding appearance file down.
    private enum PaletteSide: Decodable {
        case auto
        case colors([String])
        /// nil (absent), "auto", or garbage → built-in; a real array → the override.
        var colorsOrNil: [String]? { if case .colors(let a) = self { return a } else { return nil } }
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let a = try? c.decode([String].self) { self = .colors(a) } else { self = .auto }
        }
    }
    private struct LauncherDTO: Decodable {
        var agent: String?; var model: String?; var access: String?
        // (a legacy `review` key in the file is simply ignored — adjudication is not implemented)
    }

    private func read<T: Decodable>(_ name: String) -> T? {
        guard let data = FileManager.default.contents(atPath: path(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func path(_ name: String) -> String {
        (dir as NSString).appendingPathComponent(name)
    }

    // MARK: watch (hot reload)

    private let queue = DispatchQueue(label: "vigil.config-watch")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounce: DispatchWorkItem?
    private var lastSeen: VigilConfig?
    private var onChange: ((VigilConfig) -> Void)?

    /// Every config JSON the watcher must track (legacy agent.json included — an
    /// un-upgraded dir edits THAT file). detected.json is Vigil-written, not watched.
    static let watchedJSONs = ["appearance.json", "launcher.json", "agent.json",
                               "agents.json", "roles.json", "runtime.json"]

    /// Watch the directory AND each config file; any event → debounce → reload → fire
    /// on main iff values changed. Sources re-arm after every event because editors and
    /// agents replace files by rename (new inode — a stale fd would go silent).
    func startWatching(_ onChange: @escaping (VigilConfig) -> Void) {
        self.onChange = onChange
        lastSeen = load()
        // arm() must finish BEFORE startWatching returns: callers write the first config
        // change immediately after (the ConfigTests watcher tests, and any real first edit
        // right after boot). An async arm races that write — the fds aren't open yet, the
        // one-shot atomic-rename FS event is missed with no re-fire, and the change is
        // never delivered (a pumpUntil-timeout flake under CPU load). Sync arming closes
        // the race; arm() only opens fds + resumes sources, so this can't deadlock.
        queue.sync { self.arm() }
    }

    func stopWatching() {
        queue.sync {
            for s in sources { s.cancel() }
            sources.removeAll()
            debounce?.cancel()
            onChange = nil
        }
    }

    private func arm() {   // queue only
        for s in sources { s.cancel() }
        sources.removeAll()
        let paths = [dir] + Self.watchedJSONs.map { path($0) }
        for p in paths {
            let fd = open(p, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .delete, .rename],
                queue: queue)
            src.setEventHandler { [weak self] in self?.scheduleReload() }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources.append(src)
        }
    }

    private func scheduleReload() {   // queue only
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.arm()
            let cfg = self.load()
            guard cfg != self.lastSeen else { return }
            self.lastSeen = cfg
            if let cb = self.onChange {
                DispatchQueue.main.async { cb(cfg) }
            }
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: shipped defaults (compiled-in; missing files written on install)

    private func shippedFiles(detected: [DetectedCLI]) -> [(name: String, content: String)] {
        [("appearance.json", """
          {
            "theme": "auto",
            "accent": "blue"
          }
          """),
         ("launcher.json", shippedLauncherJSON(detected: detected)),
         ("agents.json", Self.shippedAgentsJSON(detected: detected)),
         ("roles.json", """
          {
            "root":       { "model": null, "access": null, "promptAppend": "" },
            "subManager": { "agent": null, "model": null, "access": null, "promptAppend": "" },
            "worker":     { "agent": null, "model": null, "access": null, "promptAppend": "" }
          }
          """),
         ("prompts.json", """
          {
            "root": "default",
            "subManager": "default",
            "worker": "default",
            "extras": {
              "claude": "default",
              "codex": "default",
              "opencode": "default",
              "rename": "default"
            }
          }
          """),
         ("runtime.json", """
          {
            "harvestAfterMinutes": 60,
            "maxLiveSessions": 10,
            "harvestStuckAfterHours": 24,
            "injectHoldTimeoutSeconds": 300,
            "historyTailCapMB": 8,
            "sidebarCollapseThreshold": 5,
            "autoName": true,
            "permDogfoodLog": true,
            "spawnStallSeconds": 15,
            "initialPromptReadyTimeoutSeconds": 30,
            "deliveryMaxAttempts": 3,
            "deliveryReinjectGraceSeconds": 4,
            "orchestrationToasts": false,
            "bottomShellCommand": "auto",
            "terminalDebugLog": "off",
            "reportWatchdog": true
          }
          """),
         ("README.md", Self.readmeDoc)]
    }

    /// launcher.json defaults — `agent` seeded from the probe's first hit. The
    /// `model`/`access` keys are not written here: the loader ignores them, so
    /// carrying a legacy agent.json's values over would be pure noise.
    private func shippedLauncherJSON(detected: [DetectedCLI]) -> String {
        Self.prettyJSON(["agent": detected.first?.kind ?? "claude"])
    }

    /// First agents.json: one entry per detected CLI (the probe only trusts real binaries, CLIProber).
    /// Nothing found → an empty map: the UI falls back to the builtin claude entry and
    /// the launcher shows the zero-hit banner; the user fills `bin` in by hand or the
    /// settings agent does.
    static func shippedAgentsJSON(detected: [DetectedCLI]) -> String {
        var agents: [String: Any] = [:]
        for d in detected {
            var e: [String: Any] = ["bin": d.bin, "kind": d.kind]
            if d.kind == AgentCLIKind.claude.rawValue {
                // `models` is not seeded because Vigil cannot authoritatively enumerate a
                // provider's changing catalog. Existing user-supplied lists are still useful
                // to the spawn model-family misuse guard and are documented in README.md.
                e["defaultModel"] = NSNull()
                e["env"] = [String: String]()
            }
            agents[d.kind] = e
        }
        return prettyJSON(["agents": agents])
    }

    private static func prettyJSON(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: docs (app-managed, refreshed on drift — don't hand-edit, change settings via JSON only)

    static let readmeDoc = fieldReferenceDoc + "\n\n" + agentInstructionsDoc + "\n"

    private static let fieldReferenceDoc = """
    # Vigil user configuration

    Every Vigil setting lives in this directory: one concern per JSON file — save the file
    and it takes effect. A missing or unparseable file falls back to that file's defaults,
    so config cannot crash the app. Omitted fields keep their own defaults; an out-of-range
    or unrecognized value of the documented JSON type follows the field-specific fallback
    below. A wrong JSON type can make the whole containing file fall back. Every supported
    field, including nested and Vigil-written fields, is listed below with both its meaning
    and its use.

    Two effect timings (marked on each file's section below):

    - **immediate**: the app picks the change up live (appearance, runtime policy).
    - **next dispatch**: the file is re-read every time an agent is dispatched (a
      "dispatch" = starting a new agent session — a root session from the launcher, or a
      worker spawned by a manager). Agents already running are untouched; the next
      dispatch uses the new values. That is the hot-edit semantics — no restart, ever.

    > This README is the single app-managed guide for users and for every agent family
    > (Claude Code, Codex, OpenCode, and future integrations). It is auto-refreshed on
    > upgrade, so don't hand-edit it; settings live in the JSONs only.
    > detected.json is probe fact rewritten by Vigil on every launch; editing it does nothing.

    ## Quick reference — want to change X?

    | Change what | Where |
    |---|---|
    | Appearance (theme / accent color) | appearance.json |
    | Terminal font / cursor / colors / ANSI palette | appearance.json · `terminal` |
    | Which agent the launcher starts selected | launcher.json · `agent` |
    | A role's model / permission level / injected prompt | roles.json · per-role `model` / `access` / `promptAppend` |
    | A role's base identity text (replacing the built-in default) | prompts.json · per-role `root` / `subManager` / `worker` |
    | Available CLIs, binary paths, relay/proxy endpoints | agents.json (`bin`, `env`) |
    | Harvesting, live-session caps, injection valve, sidebar threshold | runtime.json |
    | Bottom (⌘J) scratch-shell program, spawn/kill toasts | runtime.json · `bottomShellCommand` / `orchestrationToasts` |

    ## agents.json — agent registry (effect: next dispatch)

    Which agent CLIs exist, where their binaries live, and which endpoint they talk to.
    Keys = the launcher's dropdown entries. The same CLI may be registered more than once
    (official endpoint + relay/proxy endpoints).

    ```json
    { "agents": {
        "claude":  { "bin": "~/.local/bin/claude", "kind": "claude",
                     "models": [], "defaultModel": null, "extraArgs": [], "env": {} },
        "relay":   { "bin": "~/.local/bin/claude", "kind": "claude",
                     "env": { "ANTHROPIC_BASE_URL": "https://relay.example",
                              "ANTHROPIC_AUTH_TOKEN": "sk-..." } } } }
    ```

    - `agents`: required object; default when the file is absent/unreadable is one built-in
      Claude entry. Its purpose is to give Vigil the complete registry of agent entries.
    - `agents.<entry-key>`: object for one registry entry. The key is its stable string ID:
      it is shown in the launcher and is referenced by launcher.json / roles.json `agent`.
      Use multiple keys with the same `kind` for different providers or endpoints.
    - `agents.<entry-key>.bin` (required non-empty string): executable path to launch. Use
      an absolute path or a `~`-relative path; Vigil expands `~` but launches directly with
      no shell and no PATH lookup. First run writes a verified absolute path. An entry with
      an absent/empty `bin` is dropped.
    - `agents.<entry-key>.kind` (optional string): `"claude"` | `"codex"` | `"opencode"` |
      `"custom"`.
      When omitted **or set to an unrecognized string**, it is inferred from the entry's
      key name; a key that matches no family falls back to `custom`. **claude / codex /
      opencode are all wired and usable**; a `custom` entry shows disabled in the launcher
      until it is actually wired.
    - `agents.<entry-key>.models` (optional array of strings; default `[]`): model-name
      catalog for this entry. It creates neither a picker nor a general allow-list. When
      this entry's catalog is non-empty, its current use is to reject a spawn model absent
      here but listed under a different registered agent, catching cross-agent mistakes.
    - `agents.<entry-key>.defaultModel` (optional string or `null`; default `null`): fallback
      when neither the session nor role picked a model. `null` / omitted passes no model
      flag, so the CLI chooses its own default.
    - `agents.<entry-key>.extraArgs` (optional array of strings; default `[]`): extra CLI
      arguments appended verbatim to new launches. Claude and OpenCode also keep them on
      resume; Codex's `resume <session-id>` path intentionally omits them.
    - `agents.<entry-key>.env` (optional string-to-string object; default `{}`): **endpoints
      live here** — base URLs, tokens, proxies… Entry values override inherited process
      values, then Vigil overwrites its launch-reserved keys: `TERM` for every family;
      `CODEX_HOME` for Codex; and `OPENCODE_CONFIG_CONTENT`, `VIGIL_HOOK_BIN`, `VIGIL_NODE`,
      `VIGIL_SOCK` for OpenCode when applicable. Do not use those keys for provider config.
    - Whole file missing/unreadable = the built-in Claude fallback entry. An explicit empty
      `agents` object decodes as empty, but the app still exposes its built-in Claude entry
      so the launcher remains usable. The no-CLI-detected banner comes from the launch-time
      probe in detected.json, not from whether this object is empty.

    ## roles.json — role matrix (effect: next dispatch)

    What agent, model, permission level and injected prompt each of the three identities
    (root / subManager / worker) uses.

    ```json
    { "root":       { "model": null, "access": null, "promptAppend": "" },
      "subManager": { "agent": null, "model": null, "access": null, "promptAppend": "" },
      "worker":     { "agent": null, "model": "<model-alias>", "access": "acceptEdits",
                      "promptAppend": "@prompts/worker.md" } }
    ```

    - `root`: settings for the user-facing root manager. The launcher always chooses its
      executable; the effective merged `root.agent` value only supplies the family anchor
      when a layer declares a bare-string `root.model`.
    - `subManager`: settings for manager nodes spawned below root. Use it to give delegated
      planning/coordinating work its own agent, model, permissions, or prompt.
    - `worker`: settings for leaf nodes. Use it to tune the agents doing bounded tasks.
    - `<role>.agent`: optional registry-key string. For subManager/worker it selects the
      entry; an absent/unusable entry falls back to the session entry. **The root's agent is
      chosen in the launcher**, so this field never selects the root executable; when the
      merged root settings declare a bare-string `model`, it only anchors that model to a
      CLI family.
    - `<role>.model`: two accepted shapes —
      - a bare string (`"<model-alias>"`): applies to the CLI family of the agent effective at the
        layer that declares it (no agent declared anywhere = claude). It never crosses
        into another family's command line.
      - a family map (`{"claude": "<claude model alias>", "codex": "<codex model id>"}`): the value is
        picked by the resolved agent's kind. A family not listed skips this role-level
        source, then continues to the session model and entry `defaultModel`; only when
        those are also absent does the CLI receive no model flag. Prefer leaving codex /
        opencode out over pinning a dated id when no later fallback is configured (ids
        churn; the CLI default is always current). The map is the only way to give
        different CLI families different role models in one tree.
      A non-empty string, or a map containing at least one non-empty value, replaces the
      inherited `model` field as a whole. `null`, `""`, `{}`, or an all-empty map is treated
      as unset and **does not clear** a lower-layer value. Model chain:
      worker/subManager — spawn parameter > this field > session default > entry
      `defaultModel`; root — launcher pick > this field > entry `defaultModel`. All empty
      = no model flag at all; the CLI uses its own default (Vigil never picks for you).
    - `<role>.access`: this role's permission level, overriding the session default
      (**wide-open by default**). Canonical values `"default" | "acceptEdits" | "plan" |
      "bypassPermissions"`; accepted aliases: `bypass`/`full`/`all`/`yolo` →
      bypassPermissions, `standard`/`ask` → default, `edits`/`accept-edits` →
      acceptEdits, `read-only`/`readonly` → plan. Note `read-only` maps to **plan** — it
      is not an independent read-only level. Unrecognized values / null = inherit the
      wide-open default. Family mapping: claude → `--permission-mode`; codex →
      approval_policy/sandbox_mode; opencode → `--auto` (bypass only).
    - `<role>.promptAppend`: free text appended AFTER Vigil's identity+tools section (the safe
      injection surface). `"@relative/path.md"` = read that file's content (relative to
      the file that declares it).
    - `<role>.promptOverride` (advanced — think twice): replaces Vigil's identity+tools section
      wholesale. You become responsible for keeping the tool wording mirrored to the real
      MCP tool surface. If you get it wrong, the agent's tool instructions no longer match
      the tools it actually has and the orchestration can break down as a whole — when
      unsure, don't use it.
    - **Project-level override**: `<project>/.vigil/roles.json`, same schema, overrides
      field-by-field — prompts travel with the repo and can be committed and shared.

    ## prompts.json — base identity text (effect: next dispatch)

    The text Vigil injects to give a node its identity: the three role bases (`root` /
    `subManager` / `worker` — the paragraph that states the role and lists its Vigil
    tools) plus `extras`, four shorter mechanically-appended lines (a tool-search
    self-heal hint, a lazy-tools recovery hint, and a session-rename hint).

    > **Every key ships written as the literal string `"default"`.** That is Vigil's way of
    > saying "this is currently using the built-in text" without hiding the key from you —
    > the built-in wording evolves across versions, so `"default"` always tracks whatever
    > the CURRENT build actually falls back to, instead of freezing a copy that could go
    > stale. **To customize one line, replace its `"default"` with your own text — nothing
    > else.** To go back to the built-in text later, either restore `"default"` (or blank
    > `""`) or delete the key outright; the file is only written once, on first launch, so
    > from then on it is entirely yours to edit.

    ```json
    { "root": "default",
      "subManager": "default",
      "worker": "default",
      "extras": { "claude": "default", "codex": "default",
                  "opencode": "default", "rename": "default" } }
    ```

    - **Resolution rule (same for all seven fields, root/subManager/worker AND the four
      `extras` keys)**: after trimming whitespace, a value that is empty OR exactly
      `"default"` means "use Vigil's built-in text for this line" — the same as the key
      being absent from the file, or explicit JSON `null`. Any other text is used
      VERBATIM as the replacement (not itself trimmed). Config can never leave a role with
      no identity text at all, and `"default"` can never collide with a real override,
      because it is treated as the sentinel regardless of what you intended.
    - `root` / `subManager` / `worker` (each an optional string): the full replacement text
      for that role's base identity.
    - `extras.claude` (optional string): appended to every claude-kind launch, in place of
      the built-in tool-search recovery hint (the one that tells the agent to reload a
      `mcp__vigil__*` schema that came back unavailable).
    - `extras.codex` (optional string): appended to every codex-kind launch, in place of the
      built-in lazy-tools recovery hint (codex may defer Vigil's MCP schemas the same way).
    - `extras.opencode` (optional string): appended to every opencode-kind launch. Unlike the
      other three keys, there is no built-in text to fall back to here — opencode loads MCP
      tools upfront and has never needed a recovery hint — so `"default"`/blank/absent all
      mean "no line at all," and any other value is the only way to add one.
    - `extras.rename` (optional string): appended to every root identity, regardless of CLI
      kind, in place of the built-in hint that nudges the agent to name its own session.
    - **Where this sits in the assembly order**: `roles.json`'s per-role `promptOverride`
      still replaces the ENTIRE Vigil-owned assembly — the role base and all four `extras`
      lines together — if you set both, `promptOverride` wins outright. `promptAppend`
      still appends last, after everything else.
    - **You own the mirror law when you override text here**: Vigil's own MCP tool surface
      is scoped per role (a worker holds only `report`, a root holds `spawn`/`send`/`kill`,
      and so on), and the built-in text for each role is written to match exactly what that
      role can call. If you replace a role's base text, keep it describing the tools that
      role actually has — the same responsibility `roles.json`'s `promptOverride` already
      carries. None of these seven fields change which MCP tools a node actually holds —
      that surface is still enforced server-side regardless — but getting the wording wrong
      can leave the agent's own understanding of its tools out of step with reality.

    ## launcher.json — launcher defaults (effect: next time the launcher opens)

    The launcher starts with this `agent` selected; you can still change it on the spot.
    (Supersedes the old agent.json; a legacy file is still read when launcher.json is
    absent, and its value carries over on upgrade.)

    ```json
    { "agent": "claude" }
    ```

    - `agent`: the registry entry selected by default.
    - **`model` / `access` keys here are deprecated and silently ignored** —
      permissions default to wide-open (tighten via roles.json per-role `access`), models
      are per-role in roles.json / per-entry `defaultModel` in agents.json. The launcher
      no longer has model/permission dropdowns.

    ## appearance.json — appearance (effect: immediate)

    ```json
    { "theme": "auto", "accent": "blue",
      "terminal": {
        "fontFamily": ["JetBrains Mono", "Menlo"],
        "fontSize": 13,
        "cursorStyle": "block",
        "padding": 0,
        "background": "auto",
        "foreground": "auto",
        "cursorColor": "auto",
        "palette": { "dark": "auto", "light": ["#32323e", "…14 more…", "#ffffff"] }
      } }
    ```

    - `theme`: `"auto"` | `"dark"` | `"light"` (default `"auto"`). `"auto"` (or an absent /
      unrecognized value) follows the system appearance and switches live when you flip
      macOS between light and dark; `"dark"` / `"light"` pin one scheme regardless of the OS.
    - `accent`: `"blue"` | `"teal"` | `"amber"` | `"purple"` (default `"blue"`)
    - `terminal` (optional — omit for the built-in look; every sub-field is optional;
      an out-of-range or unrecognized value of the documented type keeps that field's default):
      - `terminal.fontFamily`: ordered fallback chain of font family names (first resolvable
        wins). Default: SF Mono → Menlo → PingFang SC.
      - `terminal.fontSize`: points, accepted 6–72. Default 12.5.
      - `terminal.cursorStyle`: `"block"` | `"bar"` | `"underline"` | `"block_hollow"`.
        Default `"block"`.
      - `terminal.padding`: inner padding of the terminal surface in px, accepted 0–64.
        Default 0.
      - `terminal.background` / `terminal.foreground` / `terminal.cursorColor`: the base
        terminal colors. Each is
        `"auto"` (default) = follow the app theme's built-in color, or a `"#rrggbb"`
        override. `"auto"`, omitted, or any invalid value all resolve to the theme color.
      - `terminal.palette`: groups ANSI 16-color overrides by effective app theme.
      - `terminal.palette.dark` / `terminal.palette.light`: each is either the string
        `"auto"` (default — that theme's built-in 16 colors) or an array of exactly 16
        `"#rrggbb"` strings. Any other shape resolves to `"auto"`.

    ## runtime.json — runtime policy (effect: immediate)

    ```json
    { "harvestAfterMinutes": 60, "maxLiveSessions": 10,
      "harvestStuckAfterHours": 24, "injectHoldTimeoutSeconds": 300,
      "historyTailCapMB": 8, "sidebarCollapseThreshold": 5,
      "autoName": true, "permDogfoodLog": true,
      "spawnStallSeconds": 15, "initialPromptReadyTimeoutSeconds": 30,
      "deliveryMaxAttempts": 3, "deliveryReinjectGraceSeconds": 4,
      "orchestrationToasts": false, "bottomShellCommand": "auto",
      "terminalDebugLog": "off", "reportWatchdog": true }
    ```

    - `harvestAfterMinutes`: minutes after which a resting (no attention, nothing
      running), unfocused session gets its process silently shut down (the row stays in
      the sidebar; click to revive). `0` or negative = never harvest. Default 60.
    - `maxLiveSessions`: cap on live sessions (live trees). Dispatching a new manager
      over the cap evicts the longest-idle resting tree (silent shutdown, row stays,
      click to revive); busy trees and trees waiting on you are never evicted — when
      nothing is evictable the new dispatch still goes through, with a notice. `0` or
      negative = unlimited. Default 10.
    - `harvestStuckAfterHours`: an unfocused tree stuck waiting/stalled with nothing
      running gets force-harvested after this many hours (covers the rest harvester's
      blind spot); a live tree is never touched. `0` or negative = off. Default 24.
    - `injectHoldTimeoutSeconds`: the safety valve when a manager's message injection
      finds you typing — after this many seconds it injects anyway (fail-open). Default 300.
    - `historyTailCapMB`: how much of a transcript's tail the history view reads. Default 8.
    - `sidebarCollapseThreshold`: a sidebar group collapses past this many rows. Default 5.
    - `autoName`: auto-name sessions from the transcript's ai-title. Default on.
    - `permDogfoodLog`: log approval-prompt frequency to perm_dogfood.jsonl. Default on.
    - `spawnStallSeconds`: how long a fresh spawn may go silent (no agent connect)
      before its node is honestly shown as stalled. Default 15.
    - `initialPromptReadyTimeoutSeconds`: how long a new cell waits for the agent's
      input line to be ready before injecting the first prompt anyway (fail-open; too
      low can drop the first prompt). Applies to the next dispatched cell. Default 30.
    - `deliveryMaxAttempts`: how many times an unconfirmed manager message is
      re-injected after the target's turn died, before the failure is reported back
      to the sender. Default 3.
    - `deliveryReinjectGraceSeconds`: how long an unconfirmed delivery waits after
      the turn dies before re-injecting. Default 4.
    - `orchestrationToasts`: show the fleeting bottom-right "spawned … / killed …"
      float when the tree changes shape. Off by default — notification cards are
      reserved for approvals; this is opt-in structural noise. Default false.
    - `bottomShellCommand`: the executable the ⌘J scratch terminal launches (always as
      an interactive login shell). `"auto"` (default) or empty = follow `$SHELL`
      (fallback /bin/zsh); set e.g. `"/opt/homebrew/bin/fish"` to override. Read the
      next time you open the panel.
    - `terminalDebugLog`: terminal geometry diagnostics to
      `<sessionDir>/terminal-debug.log` (the focused session's dir; append, wraps at
      10 MB). `"off"` (default) writes nothing and costs nothing. `"metrics"` records
      terminal resize geometry — the PTY window size Vigil pushes to each agent and the
      surface's fed-pixels → read-back-grid commit verdicts (the narrow-cell repro
      channel). `"standard"` adds surface lifecycle. No terminal *content* is ever
      logged — geometry and event metadata only. Any other string is treated as `"off"`.
    - `reportWatchdog`: when true (default), a non-root node that ends a turn without
      calling `report()` receives one reminder so its result is not silently lost. Set
      false only when deliberately running child agents that must not report to a parent.
    - Note on defaults vs off-switches: for `harvestAfterMinutes` /
      `maxLiveSessions` / `harvestStuckAfterHours`, `0` or negative is a real setting
      ("off" / "unlimited"). For every other numeric key here, only values > 0 apply —
      `0` or negative is silently ignored and the default stays.

    ## detected.json — probe facts (Vigil-written, read-only)

    The result of scanning common install paths + PATH for claude → codex → opencode on
    every launch. This is fact for users and configuring agents, not a settings input.

    - `probedAt`: ISO-8601 timestamp of the probe that produced this file. Use it to tell
      whether the facts came from the current launch.
    - `found`: array of installed, executable CLI records in probe-priority order. Its
      first item seeds launcher.json on a fresh install.
    - `found[].kind`: CLI family name (`"claude"`, `"codex"`, or `"opencode"`). Use it
      as the registry key / agents.json entry `kind` when registering the hit.
    - `found[].bin`: absolute executable path verified by Vigil. It can be copied directly
      into the matching agents.json entry's `bin`.
    - `notFound`: array of CLI family-name strings that the probe did not find. It explains
      absent families; it is not a list of paths and editing it cannot install anything.

    ## What is NOT configurable (and why there is no field for it)

    These are internal mechanism contracts, not settings — a wrong value would break
    things silently, so they are not exposed; don't look for a field: hook/MCP channel
    wiring and socket layout; each role's MCP tool surface (mirrored with the skill
    text); the five parent-session env vars stripped at launch; the orchestration.jsonl
    event format; the approval interaction itself (approvals always happen in the
    agent's own TUI — Vigil only observes).

    Keyboard shortcuts are also fixed, on purpose. Every Vigil shortcut is ⌘-modified so
    it can pass through a focused terminal to the menu, and each one is mirrored into the
    terminal's key-unbinding table; a user-editable keymap would have to preserve both
    invariants or the shortcut would be swallowed by the agent's TUI. The bottom-panel
    terminal always opens closed (⌘J) — only its default height (dragged, remembered
    per machine) and its shell program (runtime.json `bottomShellCommand`) are tunable.
    """

    private static let agentInstructionsDoc = """
    ## Instructions for any agent configuring Vigil

    These instructions are deliberately agent-neutral: follow the same process whether
    you are Claude Code, Codex, OpenCode, or another future integration. The JSON field
    reference above is authoritative; do not infer behavior from agent-specific filenames
    or invent fields that are not documented there.

    ## If the user asks you to set Vigil up for them (onboarding / reconfiguring)

    The whole point: every setting already has a sensible default and Vigil works with
    zero configuration. Your job is NOT to fill in every field — it is to leave the good
    defaults alone and make only the few decisions that genuinely need a machine-specific
    answer (which is really just: which agent CLIs and models this machine should use).

    1. **Read the JSON field reference in this README first** — what each setting means,
       its legal values, its concrete use, and when it takes effect. Do not invent fields.

    2. **Leave most settings at their defaults.** Appearance (theme/accent, terminal
       font/colors), runtime policy (harvesting, caps, valves, `orchestrationToasts`,
       `bottomShellCommand`, `terminalDebugLog`) and the launcher default are all fine
       out of the box. Only change one of these if the user explicitly asks. Do not touch
       a file just to "complete" it. (`terminalDebugLog` is a geometry-only terminal
       diagnostics toggle — `off`/`metrics`/`standard`, default off, never logs terminal
       content — leave it off unless the user is chasing a terminal-rendering bug.)

    3. **The agent/model choices are yours to make — this is the one part you decide.**
       Read `detected.json`: which agent CLIs this machine has (claude / codex /
       opencode) is a fact Vigil probed at launch.
       Use what it says and **do not run detection commands yourself**.
       If `found` is empty, help the user install a CLI first, restart Vigil, then come
       back. Using the detected CLIs as your basis, set each role's model in `roles.json`:
       - **root**: the highest-capability model available.
       - **subManager / worker**: a cheaper-but-capable model — the tree does the bulk work
         through these, so keep them economical.
       - **Prefer stable aliases over dated ids.** claude ships stable tier aliases that
         always resolve to the current model of that tier, so they never go stale — always
         use one of those for claude rather than a dated `claude-*-YYYYMMDD` id. Confirm
         the alias names with the user or the claude CLI itself — never write one from
         memory without checking.
       - **For codex and opencode, leave the model UNSET** — do not add a `codex` /
         `opencode` key. An empty model means Vigil passes NO model flag, so the CLI runs its
         OWN default, which is by definition the latest that CLI ships. Do NOT hardcode a
         codex/opencode model id from memory: those ids churn fast and a stale/wrong one is a
         hard launch failure. Only pin a specific codex/opencode model when the user
         explicitly asks for a non-default one, and then confirm the exact current id WITH
         them (or from that CLI's own docs) — never guess it.
       - Model shape (family namespace): the `model` field is a bare string (bound to the
         declaring layer's family) or a family MAP (e.g. `{"claude": "<claude model alias>"}`)
         keyed by the resolved agent's family. A value never crosses into another CLI's
         command line, so with claude set and codex/opencode left out, each family does the
         right thing on its own. Never give one family another family's model name.

       **Which CLI family runs each role** is the other half of this decision, and it is how
       Vigil's headline heterogeneous-tree feature becomes visible. By default every non-root
       role leaves its `agent` UNSET and inherits the launcher's agent, so the whole tree runs
       one CLI (homogeneous — perfectly fine, and the right default when only one CLI was
       detected). But when `detected.json` found MORE THAN ONE family (e.g. both claude and
       codex), do NOT silently wire a mixed tree — PROPOSE one and let the user choose. Explain
       it plainly: a role's `agent` key in `roles.json` pins that role to a specific detected
       CLI, so you could run, say, claude for `root`/`subManager` and codex for `worker` —
       different CLIs cooperating in one tree. Make clear it is optional and that leaving
       `agent` unset keeps a single-CLI tree. Only write `agent` keys after the user agrees; if
       they decline, or only one CLI exists, leave every `agent` unset. Whenever you DO set a
       role's `agent`, make sure that role's model MAP carries a key for that family (a codex
       worker reads the map's `codex` entry, not claude's).

    4. **Where each thing goes** (only write what you actually decided): each role's model
       and permission level → `roles.json` per-role `model` / `access`; a role's CLI family
       (the heterogeneous tree — only if the user opted in above) → `roles.json` per-role
       `agent` (root ignores it — root's CLI is the launcher choice); prompts injected
       into workers → `roles.json` `promptAppend`; the launcher's default agent →
       `launcher.json` `agent` (the ONLY key that file has; never write `model`/`access` there —
       those keys are deprecated and silently ignored); relay/proxy endpoints →
       `agents.json` `env`; appearance → `appearance.json`; runtime policy → `runtime.json`.

    5. **Close by presenting the full settings picture — and, on first-time onboarding,
       let the tree produce it.** The deliverable is a table of the app-level settings
       with the value now in effect (mark which rows are still defaults, and include the
       role model / tree-makeup decisions from step 3). It must be the LAST thing the
       user sees — presented at the end, after any demo, never only mid-conversation
       where it scrolls away.
       - **First-time onboarding**: this is also the moment to show what Vigil is
         actually for. Everything above was a handful of one-line edits; it needed NONE
         of Vigil's orchestration. Be honest about it — one line like "Your setup was
         trivial and used none of this; here's a 20-second demo of what Vigil is really
         for." Then spawn EXACTLY 1 leaf worker (short descriptive `name`, strictly
         READ-ONLY — nothing that writes files or needs approval) whose task is the real
         deliverable: survey `README.md` plus the current JSON files and report the
         settings table — setting, value in effect, owning file — flagging which values
         differ from the defaults. Always delegate via the Vigil spawn tool, never an
         agent CLI's private delegation mechanism — only Vigil workers appear in the node
         tree the user is watching in the sidebar. While it runs, point the user at the sidebar:
         the worker is a node — watch it appear, work, report, and settle. When its
         `report()` rollup arrives, that IS the demo: delegation, rollup, and you never
         touched the detail yourself.
       - **Re-configure visits** (the user came back to tweak a setting): skip the
         worker and present the table yourself, unless they ask to see the demo.
       - Either way, VERIFY the table before showing it — you own what you present, the
         worker's report is input, not gospel. It must cover at least these rows
         (defaults shown for reference):

       | Setting | Default | File |
       |---|---|---|
       | Root / subManager / worker model | unset (CLI's own default) | roles.json `model` |
       | Theme / accent | auto (follow system) / blue | appearance.json |
       | Terminal font / size / cursor | SF Mono→Menlo→PingFang SC / 12.5 / block | appearance.json |
       | Terminal colors + ANSI palette | auto (follow theme) | appearance.json |
       | Launcher default agent | first detected CLI | launcher.json |
       | Permission level | wide-open (bypass) | roles.json `access` |
       | Rest-harvest / max live sessions | 60 min / 10 | runtime.json |
       | Sidebar collapse threshold | 5 rows | runtime.json |
       | Spawn/kill toasts | off | runtime.json `orchestrationToasts` |
       | Bottom (⌘J) shell | auto ($SHELL) | runtime.json `bottomShellCommand` |
       | Terminal debug log | off | runtime.json `terminalDebugLog` |

       Tell them saving is enough — appearance and runtime policy apply immediately;
       agents/roles/launcher apply on the next dispatch (running agents are untouched).
       Do not spawn more than 1 worker, do not let it modify anything.

    6. **Finally, ASK the user whether they want to change anything.** Do NOT treat setup as
       finished silently. Adjust only what they then ask for.
    """
}
