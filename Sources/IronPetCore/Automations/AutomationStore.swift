#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(Combine)
import Combine
#endif

/// Where automations live on disk. `~/.ironpet/automations.json` is the list, and `~/.ironpet/automations/` holds
/// state that is not meant for hand editing. Runtime state is in `ironpet.db`. Tests point both elsewhere.
package struct AutomationPaths {
    package init(file: URL, directory: URL) {
        self.file = file
        self.directory = directory
    }

    package var file: URL
    package var directory: URL

    package static let standard = AutomationPaths(file: Paths.root.appendingPathComponent("automations.json"),
                                          directory: Paths.root.appendingPathComponent("automations"))

    package var schema: URL { file.deletingLastPathComponent().appendingPathComponent("automations.schema.json") }
    /// The app's common database. Automations keep their runtime state in it, in `automation_*` tables.
    package var database: URL { file.deletingLastPathComponent().appendingPathComponent("ironpet.db") }
    /// The folder a `prompt` action's agent works in.
    package var workspace: URL { directory.appendingPathComponent("workspace") }
}

/// The automations list, kept in step with the file. A hand edit or an agent's write is picked up within two
/// seconds. A file that does not validate is ignored: the last good list stays active and `onInvalid` is called once
/// per distinct problem.
@MainActor
package final class AutomationStore {
    /// Fires before `automations` or `error` changes.
    package let changes = ChangeSignal()
    package private(set) var automations: [Automation] = [] {
        willSet { changes.send() }
        didSet { if automations != oldValue { events?.publish(.automationsChanged) } }
    }
    /// Where `automations.changed` is published for API clients.
    package weak var events: APIEventBus?
    package private(set) var error: String? {
        willSet { changes.send() }
    }
    package let paths: AutomationPaths
    /// Called with the problems when the file on disk is invalid.
    package var onInvalid: ((String) -> Void)?
    /// Called after the list changed, from a write or a reload.
    package var onChange: (([Automation]) -> Void)?

    private var stamp: Date?
    private var lastReported: String?
    private var timer: Timer?

    /// `builtIns` are added when the list has no automation with that id, for a new file and an existing one. One that
    /// is there stays as the user left it, including switched off.
    package init(paths: AutomationPaths = .standard, defaults: () -> [Automation], builtIns: [Automation] = [], watch: Bool = true) {
        self.paths = paths
        if FileManager.default.fileExists(atPath: paths.file.path) {
            reload(force: true)
            // An invalid file keeps the list empty and is left alone.
            if error == nil {
                let missing = builtIns.filter { built in !automations.contains { $0.id == built.id } }
                if !missing.isEmpty { try? replace(automations + missing) }
            }
        } else {
            let base = defaults()
            automations = base + builtIns.filter { built in !base.contains { $0.id == built.id } }
            try? write(automations)
        }
        writeSchema()
        if watch {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    /// Reads the file if it changed. Keeps the current list when the new one is invalid.
    package func reload(force: Bool = false) {
        let current = Self.modificationDate(paths.file)
        guard force || current != stamp else { return }
        stamp = current
        guard var data = try? Data(contentsOf: paths.file) else { return }
        // The task list is gone, and so are the built-in automations that worked on it.
        if let upgraded = AutomationDefaults.removingRetired(in: data) {
            try? upgraded.write(to: paths.file, options: .atomic)
            stamp = Self.modificationDate(paths.file)
            data = upgraded
        }
        // An earlier build stored GitHub and Sentry as built-in sources. They are scripts now.
        if let upgraded = AutomationDefaults.replacingBuiltins(in: data) {
            try? upgraded.write(to: paths.file, options: .atomic)
            stamp = Self.modificationDate(paths.file)
            data = upgraded
        }
        let (list, errors) = AutomationValidator.parse(data)
        if errors.isEmpty {
            error = nil
            lastReported = nil
            if list != automations {
                automations = list
                onChange?(list)
            }
        } else {
            let message = errors.prefix(3).joined(separator: "; ") + (errors.count > 3 ? " (+\(errors.count - 3) more)" : "")
            error = message
            if message != lastReported {
                lastReported = message
                onInvalid?(message)
            }
        }
    }

    /// Replaces the list and writes the file. The caller validated it.
    package func replace(_ list: [Automation]) throws {
        try write(list)
        automations = list
        onChange?(list)
    }

    package func update(_ id: String, _ change: (inout Automation) -> Void) throws {
        var list = automations
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
        guard list != automations else { return }
        try replace(list)
    }

    private func write(_ list: [Automation]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: paths.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // `$schema` first would need ordered keys. A sibling schema file is enough for editors that look for it.
        try encoder.encode(AutomationFile(automations: list)).write(to: paths.file, options: .atomic)
        stamp = Self.modificationDate(paths.file)
    }

    private func writeSchema() {
        let text = AutomationSchema.json
        if (try? String(contentsOf: paths.schema, encoding: .utf8)) != text {
            try? text.write(to: paths.schema, atomically: true, encoding: .utf8)
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

extension AutomationStore {
    /// Whether an enabled digest automation exists.
    package var hasEnabledDigest: Bool { automations.contains { $0.enabled && $0.action.type == "digest" } }

    /// Calls `apply` with the current value now, then again whenever it changes. The signal fires before the list changes, so the
    /// value is read one main-actor turn later. An unrelated automation changing does not call `apply`.
    package func observeDigestShown(_ apply: @escaping @MainActor (Bool) -> Void) -> ChangeToken {
        var applied = hasEnabledDigest
        apply(applied)
        return changes.observe { [weak self] in
            DispatchQueue.main.async {
                // Safe: `DispatchQueue.main` runs this block on the main thread, which is the main actor's executor.
                MainActor.assumeIsolated {
                    guard let self, self.hasEnabledDigest != applied else { return }
                    applied = self.hasEnabledDigest
                    apply(applied)
                }
            }
        }
    }
}

#if canImport(Combine)

extension AutomationStore: ObservableObject {
    package nonisolated var objectWillChange: ObservableObjectPublisher { changes.objectWillChange }
}
#endif

/// What the old `config.json` reminders and integrations become on the first launch with automations.
package enum AutomationMigration {
    package struct Reminder {
        package init(id: String, name: String, title: String, body: String, symbol: String, mood: PetMood) {
            self.id = id
            self.name = name
            self.title = title
            self.body = body
            self.symbol = symbol
            self.mood = mood
        }

        package let id: String, name: String, title: String, body: String, symbol: String, mood: PetMood
    }

    package static let reminders: [Reminder] = [
        Reminder(id: "water", name: "Drink water", title: "Drink some water", body: "Have a glass of water.", symbol: "drop.fill", mood: .drinking),
        Reminder(id: "stretch", name: "Stretch", title: "Stretch a bit", body: "Stand up, roll your shoulders, stretch your back.",
                 symbol: "figure.flexibility", mood: .stretching),
        Reminder(id: "eyes", name: "Eye break", title: "Rest your eyes", body: "Look at something 6 m away for 20 seconds.", symbol: "eye.fill", mood: .listening),
    ]

    package static let githubID = AutomationDefaults.githubID
    package static let sentryID = AutomationDefaults.sentryID

    /// The three reminders, from the old settings. GitHub and Sentry alerts are added only for someone who already had them on
    /// (`integrations.githubAlerts`, or a `sentry.json`), so a fresh install starts with the reminders only.
    package static func defaults(from config: Config, sentryConfigured: Bool) -> [Automation] {
        let items: [String: Config.Reminders.Item] = ["water": config.reminders.water, "stretch": config.reminders.stretch, "eyes": config.reminders.eyes]
        var list = reminders.map { r in
            Automation(id: r.id, name: r.name, enabled: items[r.id]?.enabled ?? true,
                       trigger: .init(type: "interval", minutes: items[r.id]?.minutes ?? 45, clock: "active"),
                       action: .init(type: "bubble", title: r.title, body: r.body),
                       presentation: .init(mood: r.mood.rawValue, symbol: r.symbol, buttons: ["done", "snooze"]),
                       createdBy: "user")
        }
        if config.integrations.githubAlerts { list.append(AutomationDefaults.github(enabled: true)) }
        if sentryConfigured { list.append(AutomationDefaults.sentry(enabled: true)) }
        return list
    }
}

/// JSON Schema for `automations.json`, written next to it as `automations.schema.json`.
package enum AutomationSchema {
    package static let json = #"""
    {
      "$schema": "http://json-schema.org/draft-07/schema#",
      "title": "ironpet automations",
      "type": "object",
      "required": ["automations"],
      "properties": {
        "automations": { "type": "array", "items": { "$ref": "#/definitions/automation" } }
      },
      "definitions": {
        "automation": {
          "type": "object",
          "required": ["id", "name", "trigger"],
          "additionalProperties": false,
          "properties": {
            "id": { "type": "string", "pattern": "^[a-z0-9][a-z0-9-]{0,63}$" },
            "name": { "type": "string", "minLength": 1 },
            "enabled": { "type": "boolean", "default": true },
            "createdBy": { "type": "string", "description": "\"user\" or the name of the agent that wrote it. Anything else needs approval before a shell command or prompt runs." },
            "note": { "type": "string" },
            "agentId": { "type": "string", "description": "The agent that owns the automation. Its runs use that agent's CLI, model and permissions and report to its chat. Missing means agent 1 (agent_default)." },
            "until": { "enum": ["success", "once"], "description": "Deletes the automation after a run. success: after the first run whose action succeeded (a shell command that exits 0), once: after the first completed run. Not for script triggers, which return done: true." },
            "trigger": { "$ref": "#/definitions/trigger" },
            "action": { "$ref": "#/definitions/action" },
            "presentation": { "$ref": "#/definitions/presentation" }
          }
        },
        "trigger": {
          "type": "object",
          "required": ["type"],
          "additionalProperties": false,
          "properties": {
            "type": { "enum": ["interval", "daily", "once", "poll", "script", "stream", "inbox"] },
            "minutes": { "type": "number", "minimum": 1, "description": "interval: minutes between runs. poll: minutes between polls." },
            "clock": { "enum": ["active", "wall"], "description": "active counts keyboard time only. wall counts clock time." },
            "times": { "type": "array", "items": { "type": "string", "pattern": "^[0-2]?[0-9]:[0-5][0-9]$" } },
            "weekdays": { "type": "array", "items": { "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"] } },
            "at": { "type": "string", "description": "ISO 8601 date and time" },
            "source": { "$ref": "#/definitions/source" },
            "mode": { "enum": ["json", "lines", "text", "exit_code"], "description": "poll: json, lines, text or exit_code (default json). stream: lines or json (default lines)." },
            "script": { "type": "string", "description": "script trigger: JavaScript defining poll(state), which returns {state, actions}. Has sh(command) and console.log. No fetch, files or modules. A script automation has no action field." },
            "items": { "type": "string", "description": "JMESPath expression that yields the items, such as data.runs[?conclusion=='failure']. Default @" },
            "id": { "type": "string", "description": "JMESPath expression on one item that yields its id" },
            "version": { "type": "string", "description": "JMESPath expression on one item. A new value for a known id fires again." },
            "cooldownMinutes": { "type": "number", "minimum": 0 },
            "command": { "type": "string", "description": "stream: a shell command that keeps running. Each line it prints is an event. Needs the user's approval when an agent writes it." },
            "when": { "type": "string", "description": "stream: JMESPath expression on one item. The event fires only when the result is truthy." },
            "debounceSeconds": { "type": "number", "minimum": 0, "maximum": 3600, "description": "stream: fire once after this many seconds without a new event, with the latest one. {{count}} is how many events were merged." },
            "throttleSeconds": { "type": "number", "minimum": 0, "maximum": 3600, "description": "stream: fire at most once in this many seconds." },
            "catchUpMinutes": { "type": "number", "minimum": 0, "maximum": 720, "description": "daily: a slot missed while the Mac slept or ironpet was not running still fires when it is at most this many minutes late; 0 fires on time only. Only the latest missed slot fires." }
          }
        },
        "source": {
          "type": "object",
          "required": ["type"],
          "additionalProperties": false,
          "properties": {
            "type": { "enum": ["shell", "http"] },
            "command": { "type": "string" },
            "timeoutSeconds": { "type": "number" },
            "url": { "type": "string" },
            "headers": { "type": "object", "additionalProperties": { "type": "string", "pattern": "^\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}$" } }
          }
        },
        "action": {
          "type": "object",
          "required": ["type"],
          "additionalProperties": false,
          "properties": {
            "type": { "enum": ["bubble", "prompt", "shell", "digest"] },
            "title": { "type": "string" },
            "body": { "type": "string" },
            "prompt": { "type": "string", "description": "Runs in the user's chat with the chat's tools. A prompt that uses {{item.*}} runs in a restricted background session instead." },
            "agent": { "type": "string", "description": "Only for the restricted background run. A prompt that runs in the chat uses the chat's agent." },
            "model": { "type": "string", "description": "The model for a session new or own run; leave it out to keep the skill's or the agent's own. Also used by the restricted background run. A prompt that runs in the chat uses the chat's model." },
            "command": { "type": "string" },
            "timeoutSeconds": { "type": "number", "minimum": 1, "maximum": 600 },
            "quiet": { "type": "string", "description": "prompt action, or shell action with report chat: a reply or output that means nothing happened. A run whose final reply is exactly this text is hidden from the chat and recorded as no changes." },
            "report": { "enum": ["bubble", "chat"], "description": "prompt action with a background session, or shell action: bubble shows the result as a bubble, chat posts it to the main chat as a system notice that the chat's agent reads. A shell action posts the command, exit code and the last 4 KB of output. Not for bubble or digest actions." },
            "session": { "enum": ["chat", "new", "own"], "description": "prompt action: chat (default) posts into the open chat. new runs in a fresh agent session every time. own reuses one thread for this automation and moves to a fresh agent session, with a handoff summary, when its transcript passes chat.sessionRolloverMB (agents other than Claude Code start a fresh thread after 50 runs). new and own runs show up in the thread list as automation runs, and have the agent's full tools minus disallowedTools. A prompt that uses {{item.*}} stays read-only whatever session says." },
            "allowedTools": { "type": "array", "items": { "type": "string" }, "description": "prompt action with session new or own: tools the agent may use without asking, such as Bash(gh pr list:*)." },
            "disallowedTools": { "type": "array", "items": { "type": "string" }, "description": "prompt action with session new or own: tools the agent may not use, such as Bash(rm:*) or WebFetch." },
            "digest": { "enum": ["brief", "recap"], "description": "digest action: brief lists what needs you today, recap what happened today, review prepares the weekly review. Built from data on this Mac; no agent runs." }
          }
        },
        "presentation": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "mood": { "enum": ["idle", "working", "needsInput", "done", "failed", "listening", "sleeping", "drinking", "stretching", "attentive"] },
            "symbol": { "type": "string" },
            "buttons": { "type": "array", "items": { "enum": ["done", "snooze"] } },
            "notification": { "type": "boolean" },
            "expiresSeconds": { "type": "number", "minimum": 3 }
          }
        }
      }
    }
    """#
}
