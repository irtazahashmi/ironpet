import AppKit
import ImageIO
import IronPetCore
import enum IronPetKit.BuiltInQuickFilters
import enum IronPetKit.QuickFilterSelection
import SwiftUI
import UniformTypeIdentifiers

/// `--render-previews <dir> [--sprite <sheet.png>] [--background <id>]`: renders the main UI with made-up sample data to PNGs, plus an
/// animated `pet.gif` of Ghost reacting to an agent, for checking the design without clicking through it and for the
/// README (`scripts/screenshots.sh`).
/// Nothing here reads your sessions, alerts or chats.
@MainActor
enum PreviewRenderer {
    static func run(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--render-previews"), arguments.count > index + 1 else { return }
        let dir = URL(fileURLWithPath: arguments[index + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sprite = arguments.firstIndex(of: "--sprite").flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil }
        // Default settings (the pet is called Ghost), whatever is in your config.json.
        var config = Config()
        config.pet.sprite = sprite
        if let id = arguments.firstIndex(of: "--background").flatMap({ arguments.count > $0 + 1 ? arguments[$0 + 1] : nil }) {
            config.chat.background = id
        }
        ConfigStore.shared.usePreview(config)
        let atlas = Atlas.loadDefault(sprite: sprite)
        let name = config.pet.name

        for (file, preview) in [("chat", ChatSession.Preview.done), ("chat-approval", .approval), ("chat-markdown", .markdown), ("chat-form", .form), ("chat-rows", .rows)] {
            let session = ChatSession(restore: false)
            session.loadPreview(preview)
            render(ChatView(session: Self.chatModel(session)).frame(width: 520, height: 640).panel(), to: dir, file)
        }
        // The composer while a voice note records.
        for (suffix, scheme) in [("", ColorScheme.dark), ("-light", .light)] {
            let session = ChatSession(restore: false)
            session.loadPreview(.done)
            let model = Self.chatModel(session)
            model.voice.loadPreview()
            render(ChatView(session: model).frame(width: 520, height: 640).panel(), to: dir, "chat-voice-recording" + suffix, scheme: scheme)
        }
        // The dictation bar over another app, in two accent colours and both appearances.
        for (accent, color) in [("pink", Color.pink), ("blue", Color.blue), ("green", Color.green)] {
            for (suffix, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
                let voice = VoiceController()
                voice.loadPreview()
                let backdrop = scheme == .dark ? Color(white: 0.07) : Color(white: 0.93)
                render(DictationPill(voice: voice, accent: color).padding(24).background(backdrop), to: dir, "dictation-bar-\(accent)-\(suffix)", scheme: scheme)
            }
        }
        // The reply markdown sample at the narrow chat width and a wider one, in both appearances, and with find open.
        for width in [420.0, 520.0] {
            for (suffix, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
                for (label, find) in [("", ChatFind.RowHighlight?.none), ("-find", ChatFind.RowHighlight(query: "item", current: ChatFind.Match(item: UUID(), segment: 3, occurrence: 0)))] {
                    let view = MarkdownView(text: ChatSession.sampleMarkdown, find: find)
                        .font(.system(size: 13.5))
                        .padding(16)
                        .frame(width: width, alignment: .leading)
                        .background(Color(nsColor: .windowBackgroundColor))
                    render(view, to: dir, "markdown-\(Int(width))\(label)-\(suffix)", scheme: scheme)
                }
            }
        }
        // Selection from another app waiting in the composer as context.
        for (suffix, scheme) in [("", ColorScheme.dark), ("-light", .light)] {
            let session = ChatSession(restore: false)
            session.loadPreview(.done)
            let model = Self.chatModel(session)
            model.attachedSelection = FrontSelection(
                text: "Can we ship the selection chip this week?\nLooks good on my side.",
                appName: "Slack", windowTitle: "ana (DM)")
            model.input = "summarize this"
            render(ChatView(session: model).frame(width: 520, height: 640).panel(), to: dir, "chat-selection-context" + suffix, scheme: scheme)
        }
        // A ~60 KB crash log pasted into the chat: over the paste limits, so the input shows an attachment chip.
        let pasted = ChatSession(restore: false)
        pasted.loadPreview(.done)
        let log = (0..<1_800).map { "0x\(String($0, radix: 16)) frame \($0) in IronPet.crash()" }.joined(separator: "\n")
        let pasteDir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-preview-paste-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pasteDir) }
        let pastedModel = Self.chatModel(pasted)
        pastedModel.attach(PasteIntake.importPaste(pasteboardHolding(log), imageDirectory: pasteDir, textDirectory: pasteDir))
        render(ChatView(session: pastedModel).frame(width: 520, height: 640).panel(), to: dir, "chat-pasted-text")
        let settings = ChatSession(restore: false)
        settings.loadPreview(.done)
        settings.receiveModes(current: "bypassPermissions", modes: [
            AgentMode(id: "default", name: "Default"), AgentMode(id: "acceptEdits", name: "Accept Edits"), AgentMode(id: "plan", name: "Plan Mode"),
            AgentMode(id: "auto", name: "Auto"), AgentMode(id: "bypassPermissions", name: "Bypass Permissions")])
        render(ChatView(session: Self.chatModel(settings), settingsOnly: true).panel(), to: dir, "chat-settings")

        let sessions = SessionStore()
        sessions.loadPreview(sampleSessions)
        let signals = SignalStore()
        sampleSignals.forEach { signals.add($0, notify: false) }
        let tasks = sampleTasks()
        let chat = ChatSession(restore: false)
        chat.loadPreview(.done)
        let meetingLibrary = MeetingLibrary(root: sampleMeetings())
        meetingLibrary.reload()
        let meetings = MeetingsAPI(recorder: MeetingController(), library: meetingLibrary)
        func list(_ sessions: SessionStore, tasks: TasksAPI, on section: IronPetSection? = nil, height: CGFloat = 560) -> some View {
            let model = IronPetWindowModel(defaults: UserDefaults(suiteName: "ironpet-previews") ?? .standard)
            model.section = section ?? IronPetSection.needingAttention(agents: AgentsAPI(store: sessions), alerts: AlertsAPI(store: signals), tasks: tasks)
            return IronPetWindowView(model: model, agents: AgentsAPI(store: sessions), alerts: AlertsAPI(store: signals), tasks: tasks, chat: Self.chatModel(chat),
                                     meetings: meetings, actions: .none)
                .frame(width: 780, height: height).panel()
        }
        render(list(sessions, tasks: tasks, on: .chat), to: dir, "window-chat")
        render(list(sessions, tasks: tasks, on: .chat), to: dir, "window-chat-light", scheme: .light)
        render(list(sessions, tasks: tasks, on: .transcripts), to: dir, "transcripts")
        // The same section mid-run: the row and the header show the stage, and Regenerate is disabled for the other meeting.
        meetingLibrary.regenerator.loadPreview(active: "2026-11-16-0930", .transcribing(chunk: 2, of: 5))
        render(list(sessions, tasks: tasks, on: .transcripts), to: dir, "transcripts-regenerating")
        meetingLibrary.regenerator.clearPreview()
        render(list(sessions, tasks: tasks), to: dir, "agents")
        // The window opens on Alerts when no agent needs you or is working.
        render(list(SessionStore(), tasks: tasks), to: dir, "alerts")
        render(list(sessions, tasks: tasks, on: .actions), to: dir, "actions")
        // Notifications, from made-up entries: one unread and open with its description and links, one read, one without links.
        let notificationStore = NotificationStore(database: Database.open(path: nil, migrations: NotificationStore.migrations).database)
        _ = notificationStore.add(NotificationDraft(source: "release-notes", type: .backgroundResult, title: "Release notes",
                                                    description: "Drafted the notes for **v2.4**.\n\n- 3 fixes\n- 1 new setting\n\nOne item needs a decision before it ships.",
                                                    links: [NotificationLink(.url, "https://example.com/releases/2.4", label: "Draft on the wiki"),
                                                            NotificationLink(.thread, "preview-thread", label: "Run in chat history")]))
        let readEntry = notificationStore.add(NotificationDraft(source: "water", type: .reminder, title: "Time for water", description: "Drink a glass of water."))
        _ = notificationStore.add(NotificationDraft(source: NotificationItem.systemSource, type: .approval, title: "Ghost wants to: run swift test",
                                                    description: "swift test --filter DemoTests"))
        if let readEntry { notificationStore.markRead(readEntry.id) }
        let notificationsModel = NotificationsModel(api: NotificationsAPI(store: notificationStore))
        notificationsModel.select(notificationStore.list().last { $0.type == .backgroundResult }?.id ?? "")
        func notificationsWindow(scheme: ColorScheme) -> some View {
            let model = IronPetWindowModel(defaults: UserDefaults(suiteName: "ironpet-previews") ?? .standard)
            model.section = .notifications
            return IronPetWindowView(model: model, agents: AgentsAPI(store: sessions), alerts: AlertsAPI(store: signals), tasks: tasks, notifications: notificationsModel, chat: Self.chatModel(chat),
                                     meetings: meetings, actions: .none)
                .frame(width: 780, height: 560).panel()
        }
        render(notificationsWindow(scheme: .dark), to: dir, "notifications")
        render(notificationsWindow(scheme: .light), to: dir, "notifications-light", scheme: .light)
        // The Screen section: recent captures and the search field, with capture on and off, then a search.
        let capturesStore = CaptureStore(database: Database.open(path: nil, migrations: CaptureStore.migrations).database)
        let slack = CaptureApp(bundleId: "com.tinyspeck.slackmacgap", name: "Slack"), browser = CaptureApp(bundleId: "com.apple.Safari", name: "Safari")
        for (app, title, url, lines, ago) in [
            (slack, "ana (DM) - Acme", nil as String?, ["Ana", "Can you review PR 4649 before lunch?", "The deploy waits for it."], 600.0),
            (browser, "Add screen capture by Ana", "https://github.com/acme/app/pull/4649",
             ["Add screen capture", "Ana wants to merge 3 commits into main", "Checks: 12 passed"], 300.0),
            (slack, "ana (DM) - Acme", nil, ["Ana", "Can you review PR 4649 before lunch?", "The deploy waits for it.", "Looks good, merging now."], 60.0),
        ] {
            _ = try? capturesStore.ingest(app: app, title: title, url: url, trigger: .typingPause, lines: lines, now: Date().addingTimeInterval(-ago))
        }
        let screenStatus = CaptureStatusModel()
        screenStatus.captureCount = capturesStore.captureCount
        screenStatus.lastCapture = Date().addingTimeInterval(-60)
        let screenConfig = ConfigStore.shared.config
        var captureOn = screenConfig
        captureOn.screenCapture.enabled = true
        ConfigStore.shared.usePreview(captureOn)
        for (suffix, scheme) in [("", ColorScheme.dark), ("-light", .light)] {
            render(ScreenSection(model: screenStatus, screen: ScreenAPI(service: CaptureService(store: capturesStore, config: { ConfigStore.shared.config.screenCapture }))).frame(width: 900, height: 560).panel(), to: dir, "screen-captures" + suffix, scheme: scheme)
        }
        var captureOff = screenConfig
        captureOff.screenCapture.enabled = false
        ConfigStore.shared.usePreview(captureOff)
        render(ScreenSection(model: CaptureStatusModel()).frame(width: 600, height: 460).panel(), to: dir, "screen-off")
        ConfigStore.shared.usePreview(screenConfig)
        render(list(sessions, tasks: tasks, on: .tasks), to: dir, "tasks")
        render(list(sessions, tasks: tasks, on: .tasks), to: dir, "tasks-light", scheme: .light)
        // Tall enough to show the folded groups at the end: Someday, Deferred and Done.
        render(list(sessions, tasks: tasks, on: .tasks, height: 1200), to: dir, "tasks-all-groups")
        // The Next actions chip, selected: the open tasks grouped under their contexts.
        QuickFilterSelection.save(BuiltInQuickFilters.nextActionsID)
        render(list(sessions, tasks: tasks, on: .tasks, height: 1000), to: dir, "tasks-next-actions")
        QuickFilterSelection.save(nil)
        for (suffix, scheme) in [("", ColorScheme.dark), ("-light", .light)] {
            render(TaskBoardView(columns: TaskBoard.columns(tasks.all, filter: nil, query: ""), onOpen: { _ in }, onDrop: { _, _ in })
                .frame(width: 1240, height: 520).panel(), to: dir, "tasks-board" + suffix, scheme: scheme)
        }
        if let sample = tasks.all.first {
            render(TaskDetailPage(tasks: tasks, id: sample.id, onBack: {}, onOpen: { _ in }).frame(width: 760, height: 1000).panel(), to: dir, "task-detail")
            render(TaskDetailPage(tasks: tasks, id: sample.id, onBack: {}, onOpen: { _ in }).frame(width: 760, height: 1000).panel(), to: dir, "task-detail-light", scheme: .light)
        }
        render(LabelPopover(others: [["merge": "auto", "repo": "app"], ["merge": "manual"]], own: [:], onAdd: { _, _ in nil }, onDone: {})
            .frame(width: 260).padding(8).panel(), to: dir, "task-label-popover")
        let noTasks = TasksAPI(store: TaskStore(database: Database.open(path: nil, migrations: TaskStore.migrations).database))
        render(list(sessions, tasks: noTasks, on: .tasks), to: dir, "tasks-empty")

        // Today, from the same sample stores plus a meeting on the last weekday and a few agent turns from today.
        let briefSource = BriefSource(tasks: tasks, sessions: sessions, signals: signals, meetingsRoot: sampleBriefMeetings(),
                                      activity: FixedBriefActivity(events: sampleActivity))
        let brief = BriefModel(source: TodayAPI(source: briefSource))
        brief.weekdays = { AutomationDefaults.weekdays }
        brief.refresh()
        func today(_ kind: Brief.Kind, _ content: BriefModel) -> some View {
            let model = IronPetWindowModel(defaults: UserDefaults(suiteName: "ironpet-previews") ?? .standard)
            model.todayShown = true
            model.briefKind = kind
            model.section = .today
            return IronPetWindowView(model: model, agents: AgentsAPI(store: sessions), alerts: AlertsAPI(store: signals), tasks: tasks, chat: Self.chatModel(chat),
                                     meetings: meetings, brief: content, actions: .none)
                .frame(width: 780, height: 560).panel()
        }
        render(today(.brief, brief), to: dir, "today-brief")
        render(today(.brief, brief), to: dir, "today-brief-light", scheme: .light)
        render(today(.recap, brief), to: dir, "today-recap")
        render(today(.brief, BriefModel(briefs: [])), to: dir, "today-empty")

        renderUsage(to: dir)

        var patterned = config
        patterned.chat.background = "paws"
        // The same pages in a real window, so the screenshots show the title bar, selection and glass as they are.
        // Automations needs the app's settings model; this one is built from sample automations in a temp folder.
        let settingsModel = sampleSettings(chat: chat, config: patterned)
        settingsModel.capture = ScreenAPI(service: CaptureService(store: capturesStore, config: { ConfigStore.shared.config.screenCapture }))
        patterned.voiceMode.enabled = true
        ConfigStore.shared.usePreview(patterned)
        for section in IronPetSection.allCases {
            for (suffix, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
                for collapsed in [false, true] {
                    // A throwaway suite, so rendering never changes the user's saved sidebar state.
                    let model = IronPetWindowModel(defaults: UserDefaults(suiteName: "ironpet-previews") ?? .standard)
                    model.sidebarCollapsed = collapsed
                    model.todayShown = true
                    model.section = section
                    let view = IronPetWindowView(model: model, agents: AgentsAPI(store: sessions), alerts: AlertsAPI(store: signals), tasks: tasks, chat: Self.chatModel(chat),
                                                 meetings: meetings, settings: settingsModel, brief: brief, actions: .none)
                    renderWindow(model: model, session: chat, content: view, to: dir,
                                 "real-\(section.rawValue)-\(suffix)\(collapsed ? "-collapsed" : "")", scheme: scheme)
                    if collapsed, section == .agents {
                        // The rail label for Tasks, the fifth icon: 56 pt below the top, then 42 pt per icon.
                        model.hoverRail(RailTip(name: "Tasks", shortcut: "⌘5", frame: CGRect(x: 36, y: 224, width: 40, height: 38)),
                                        hovering: true)
                        renderWindow(model: model, session: chat, content: view, to: dir,
                                     "real-\(section.rawValue)-\(suffix)-collapsed-tip", scheme: scheme)
                        model.clearRailTip()
                    }
                }
            }
        }
        renderMemorySection(chat: chat, sessions: sessions, signals: signals, tasks: tasks, meetings: meetings, settings: settingsModel,
                            brief: brief, to: dir)
        // A reply with every text block, in a real window, to check the markdown in both appearances.
        let markdownChat = ChatSession(restore: false)
        markdownChat.loadPreview(.markdown)
        for (suffix, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
            let model = IronPetWindowModel(defaults: UserDefaults(suiteName: "ironpet-previews") ?? .standard)
            model.sidebarCollapsed = true
            model.section = .chat
            let view = IronPetWindowView(model: model, agents: AgentsAPI(store: sessions), alerts: AlertsAPI(store: signals), tasks: tasks, chat: Self.chatModel(markdownChat),
                                         meetings: meetings, settings: settingsModel, brief: brief, actions: .none)
            renderWindow(model: model, session: markdownChat, content: view, to: dir, "real-chat-markdown-\(suffix)", scheme: scheme)
        }
        // Settings → Screen: the controls only, with a hint that points at the Screen section.
        var screenOn = patterned
        screenOn.screenCapture.enabled = true
        screenOn.screenCapture.ocr = true
        screenOn.screenCapture.excludedApps = ["com.apple.Notes"]
        ConfigStore.shared.usePreview(screenOn)
        for (suffix, scheme) in [("", ColorScheme.dark), ("-light", .light)] {
            render(ScreenSettings(model: settingsModel).frame(width: 560, height: 900).panel(), to: dir, "settings-screen" + suffix, scheme: scheme)
        }
        // Settings → Devices with a QR code on screen and two paired devices.
        if let database = try? Database(path: nil, migrations: AppMigrations.all) {
            var remoteOn = patterned
            remoteOn.remote = .init(enabled: true, port: Config.Remote.defaultPort, address: "", machineName: "Studio Mac")
            ConfigStore.shared.usePreview(remoteOn)
            let service = RemoteService(store: RemoteStore(database: database), identity: RemoteIdentity(storage: MemoryKeyStorage()))
            for (name, ago) in [("Aleksandar's iPhone", 86_400.0 * 3), ("iPad", 3600.0)] {
                let device = RemoteDevice(id: UUID().uuidString, name: name, created: Date().addingTimeInterval(-ago * 4), lastSeen: Date().addingTimeInterval(-ago),
                                          origin: "100.101.102.103", publicKey: nil)
                try? service.store.add(device, tokenHash: RemoteHash.hex(device.id))
            }
            let controller = RemoteController(preview: service, settings: SettingsAPI.live, bubbles: BubbleStore(), status: .listening(port: Config.Remote.defaultPort),
                                            interfaces: [.init(name: "en0", ip: "192.168.68.51"), .init(name: "utun5", ip: "100.96.0.2"), .init(name: "bridge100", ip: "192.168.64.1")])
            controller.startPairing()
            settingsModel.remote = controller
            for (suffix, scheme) in [("", ColorScheme.dark), ("-light", .light)] {
                render(RemoteSettings(model: settingsModel).frame(width: 560, height: 900).panel(), to: dir, "settings-devices" + suffix, scheme: scheme)
            }
        }
        // Settings → Memory with sample notes and recent changes, and with nothing learned yet.
        ConfigStore.shared.usePreview(patterned)
        let memoryFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-preview-memory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: memoryFolder) }
        for (name, sample) in [("settings-memory", true), ("settings-memory-empty", false)] {
            let model = sampleMemory(in: memoryFolder.appendingPathComponent(name), filled: sample)
            for (suffix, scheme) in [("", ColorScheme.dark), ("-light", .light)] {
                render(MemorySettingsBody(memory: model, listsAgents: false).frame(width: 560, height: sample ? 500 : 500).panel(),
                       to: dir, name + suffix, scheme: scheme)
            }
        }
        // Settings → Prompts: the chat context with an edit of the user's and a newer default waiting, so the update notice shows.
        // The prompt files are in a temp folder, and the default is changed for the render only.
        let promptFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-preview-prompts-\(UUID().uuidString)")
        let shippedDefault = PromptStore.defaultText
        let savedFolder = PromptStore.directory
        PromptStore.directory = promptFolder
        if let shipped = Prompts.defaultText("chat-preamble") {
            PromptStore.save("chat-preamble", text: shipped.replacingOccurrences(of: "Be concise", with: "Keep replies short"))
            PromptStore.defaultText = { id in id == "chat-preamble" ? shipped.replacingOccurrences(of: "Be concise", with: "Keep replies brief, one idea each") : shippedDefault(id) }
        }
        for (suffix, scheme) in [("", ColorScheme.dark), ("-light", .light)] {
            render(PromptsSettingsBody(api: PromptsAPI()).frame(width: 560, height: 1000).panel(), to: dir, "settings-prompts" + suffix, scheme: scheme)
        }
        PromptStore.defaultText = shippedDefault
        PromptStore.directory = savedFolder
        try? FileManager.default.removeItem(at: promptFolder)
        // Settings → Voice with spoken replies on, and a reply being read aloud with its Stop button showing.
        var speechOn = patterned
        speechOn.voice.enabled = true
        speechOn.speech.enabled = true
        speechOn.voiceMode.enabled = true
        ConfigStore.shared.usePreview(speechOn)
        for (suffix, scheme) in [("", ColorScheme.dark), ("-light", .light)] {
            render(VoiceSettings(model: settingsModel).frame(width: 560, height: 1500).panel(), to: dir, "settings-voice" + suffix, scheme: scheme)
        }
        // The whole Settings window over the chat background.
        ConfigStore.shared.usePreview(patterned)
        for tab in ["general", "screen"] {
            settingsModel.tab = tab
            for (suffix, scheme) in [("", ColorScheme.dark), ("-light", .light)] {
                render(SettingsView(model: settingsModel).frame(height: 600), to: dir, "settings-window-\(tab)" + suffix, scheme: scheme)
            }
        }
        // The detail pages of Screen, Transcripts and Automations, and the automation log window, as cards.
        let slackCapture = capturesStore.recent(limit: 50).first
        for (suffix, scheme) in [("", ColorScheme.dark), ("-light", .light)] {
            render(ScreenCaptureDetail(title: slackCapture.map { "\($0.appName): \(ScreenSectionText.windowLabel($0))" } ?? "Slack: ana (DM) - Acme",
                                       app: slackCapture?.appName ?? "Slack", at: slackCapture?.at ?? Date(),
                                       text: slackCapture?.text ?? "Ana\nCan you review PR 4649 before lunch?", onBack: {})
                .frame(width: 780, height: 460).panel(), to: dir, "screen-detail" + suffix, scheme: scheme)
            render(TranscriptsView(meetings: meetings, focus: .constant(meetingLibrary.meetings.first?.id))
                .frame(width: 780, height: 560).panel(), to: dir, "transcript-detail" + suffix, scheme: scheme)
            render(AutomationsSettings(model: settingsModel).frame(width: 780, height: 1100).panel(), to: dir, "automations" + suffix, scheme: scheme)
            render(AutomationsSettings(model: settingsModel, open: settingsModel.automations?.automations.first?.id).frame(width: 780, height: 640).panel(),
                   to: dir, "automation-detail" + suffix, scheme: scheme)
            if let api = settingsModel.automations {
                let logModel = AutomationLogModel()
                logModel.api = api
                logModel.reload()
                logModel.selection = logModel.logs.first { $0.outcome == "failed" }?.id
                render(AutomationLogView(model: logModel).frame(width: 860, height: 520).panel(), to: dir, "automation-logs" + suffix, scheme: scheme)
            }
        }
        // Voice mode's pill in each state, with what was heard.
        let pills: [(VoiceConversation.State, VoiceConversation.Mode, String?, String)] = [
            (.listening, .microphone, nil, "listening"), (.thinking, .microphone, "What's going on with my jobs?", "thinking"),
            (.speaking, .microphone, "What's going on with my jobs?", "speaking"), (.listening, .wispr, nil, "wispr"),
        ]
        for (state, mode, heard, name) in pills {
            let conversation = VoiceConversation(frontDesk: FrontDesk())
            conversation.loadPreview(state: state, mode: mode, heard: heard)
            for (suffix, scheme) in [("", ColorScheme.dark), ("-light", .light)] {
                render(VoicePillView(conversation: conversation, petName: "Ghost", onEnd: {}).padding(16),
                       to: dir, "voice-pill-\(name)" + suffix, scheme: scheme)
            }
        }
        let speakingPlayer = SpeechPlayer()
        let speaking = ChatSession(restore: false, speech: speakingPlayer)
        speaking.loadPreview(.done)
        if let reply = speaking.items.last(where: { if case .assistant = $0.kind { true } else { false } }) {
            speakingPlayer.loadPreview(speaking: reply.id)
        }
        for (suffix, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
            let model = IronPetWindowModel(defaults: UserDefaults(suiteName: "ironpet-previews") ?? .standard)
            model.sidebarCollapsed = true
            model.section = .chat
            let view = IronPetWindowView(model: model, agents: AgentsAPI(store: sessions), alerts: AlertsAPI(store: signals), tasks: tasks, chat: Self.chatModel(speaking),
                                         meetings: meetings, settings: settingsModel, brief: brief, actions: .none)
            renderWindow(model: model, session: speaking, content: view, to: dir, "real-chat-speaking-\(suffix)", scheme: scheme)
        }
        ConfigStore.shared.usePreview(config)

        let done = BubbleDraft(id: "done", symbol: AgentStatus.done.symbol, tint: AgentStatus.done.bubbleTint, title: "demo-app: Done",
                          subtitle: "Claude Code", body: "Edited 3 files · Fixed the flaky login test.",
                          actions: [.init("open", "Open in iTerm", style: .primary) {}])
        let approval = BubbleDraft(id: "approval", symbol: "hand.raised.fill", tint: .orange, title: "\(name) wants to: Run this command?",
                              body: "npm test -- login --runInBand",
                              actions: [.init("allow", "Allow", style: .primary) {}, .init("deny", "Deny", style: .destructive) {},
                                        .init("open-chat", "Open chat") {}])
        let water = AutomationMigration.reminders[0]
        let reminder = BubbleDraft(id: "reminder", symbol: water.symbol, tint: .cyan, title: water.title,
                              subtitle: "Your agent is still working, good moment for it.", body: water.body,
                              actions: [.init("done", "Done", style: .primary) {}, .init("snooze", "Snooze 10 min") {}])
        render(PetScene(atlas: atlas, row: .drinking, frame: 3, bubbles: [reminder]), to: dir, "reminder")
        let today = Calendar.current.startOfDay(for: Date())
        let due = [("Fix the flaky login test", today.addingTimeInterval(-86_400)), ("Send the deck to Maya", today),
                   ("Renew the domain before it lapses on Friday", Date().addingTimeInterval(-600))].map { title, date in
            TaskItem(id: title, title: title, notes: "", status: .backlog, source: .chat, due: date, links: [],
                     created: Date(), updated: Date(), closed: nil)
        }
        render(PetScene(atlas: atlas, row: .waiting, frame: 0,
                        bubbles: [Announcer.tasksDueBubble(Array(due.prefix(1)), now: Date(), done: {}, snooze: {}, open: {})]),
               to: dir, "task-due")
        render(PetScene(atlas: atlas, row: .waiting, frame: 0,
                        bubbles: [Announcer.tasksDueBubble(due, now: Date(), done: {}, snooze: {}, open: {})]),
               to: dir, "task-due-several")
        for (kind, automation) in [(Brief.Kind.brief, AutomationDefaults.morningBrief()), (.recap, AutomationDefaults.dayRecap())] {
            let bubble = Announcer.briefBubble(briefSource.build(kind, weekdays: AutomationDefaults.weekdays), automation: automation,
                                               now: Date(), open: {})
            render(PetScene(atlas: atlas, row: .waiting, frame: 0, bubbles: [bubble]), to: dir, "bubble-\(kind.rawValue)")
        }

        let left = Date().addingTimeInterval(-62 * 60)
        let window = DateInterval(start: left, end: Date())
        func event(_ kind: ActivityEvent.Kind, _ ref: String, _ title: String, detail: String = "", minutes: Double,
                   extra: [String: String] = [:]) -> ActivityEvent {
            ActivityEvent(at: left.addingTimeInterval(minutes * 60), kind: kind, ref: ref, title: title, detail: detail,
                          url: kind == .alertOpened ? URL(string: "https://github.com") : nil, extra: extra)
        }
        let away = [
            event(.sessionNeedsInput, "claude:1", "demo-app", minutes: 40),
            event(.alertOpened, "automation:gh:84", "Fix the login redirect", detail: "irtaza/ironpet #84", minutes: 22,
                  extra: ["label": "CI failed"]),
            event(.sessionDone, "codex:2", "api", minutes: 10),
            event(.sessionDone, "claude:3", "website", minutes: 30),
            event(.taskDue, "renew", "Renew the domain before it lapses on Friday", minutes: 1),
            event(.meetingSummary, "/m/summary.md", "2026-11-17 10-00 Standup", minutes: 50),
        ]
        func welcome(_ events: [ActivityEvent]) -> BubbleDraft {
            Announcer.digestBubble(ActivityDigest.build(events: events, window: window), id: WelcomeBack.bubbleID,
                                   title: "Welcome back", subtitle: Announcer.awayText(window.duration), petName: "Ghost",
                                   open: { _ in }, showAll: {})
        }
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "" : "-light"
            render(PetScene(atlas: atlas, row: .waving, frame: 2, bubbles: [welcome(away)]), to: dir, "welcome-back\(suffix)", scheme: scheme)
            render(PetScene(atlas: atlas, row: .idle, frame: 0, bubbles: [welcome([away[2], away[3]])]),
                   to: dir, "welcome-back-single\(suffix)", scheme: scheme)
        }

        // Ghost works, finishes, asks before running a command, then takes a water break; then it loops.
        var shots: [(row: AtlasRow, frame: Int, bubbles: [BubbleDraft], delay: Double)] = []
        func play(_ row: AtlasRow, loops: Int = 1, _ bubbles: [BubbleDraft], holdLast: Double = 0) {
            for _ in 0..<loops {
                for (i, d) in row.durations.enumerated() { shots.append((row, i, bubbles, d)) }
            }
            if holdLast > 0, let last = shots.indices.last { shots[last].delay += holdLast }
        }
        play(.running, loops: 2, [])
        play(.jumping, [done])
        play(.review, loops: 2, [done])
        play(.waiting, loops: 4, [done, approval])
        play(.drinking, [reminder], holdLast: 1.2)
        let canvas = PetScene(atlas: atlas, row: .waiting, frame: 0, bubbles: [done, approval]).fittingSize
        let frames = shots.compactMap { shot in
            snapshot(PetScene(atlas: atlas, row: shot.row, frame: shot.frame, bubbles: shot.bubbles, canvas: canvas, solid: true),
                     wait: 0.02).flatMap { downscale($0, width: 640) }.map { ($0, shot.delay) }
        }
        writeGIF(frames, to: dir.appendingPathComponent("pet.gif"))
    }

    private static func pasteboardHolding(_ text: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("ironpet-preview-\(UUID().uuidString)"))
        board.clearContents()
        board.setString(text, forType: .string)
        return board
    }

    private static func render(_ view: some View, to dir: URL, _ name: String, scheme: ColorScheme = .dark) {
        guard let rep = snapshot(view, scheme: scheme) else { return }
        let file = dir.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        print("wrote \(file.path)")
    }

    /// The Usage tab with a week of made-up events: cost mode, requests mode and the hourly Today range.
    private static func renderUsage(to dir: URL) {
        guard let database = try? Database(path: nil, migrations: AppMigrations.all) else { return }
        let store = UsageStore(database: database)
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.startOfDay(for: now)
        let features: [(UsageFeature, String, Double)] = [(.chat, "claude-opus", 0.9), (.automations, "claude-sonnet", 0.2),
                                                            (.meetingSummary, "claude-sonnet", 0.35)]
        for back in 0..<7 {
            for (index, item) in features.enumerated() {
                guard let day = calendar.date(byAdding: .day, value: -back, to: start) else { continue }
                for turn in 0...(index + back % 3) {
                    let at = min(now, day.addingTimeInterval(Double(8 + index * 3 + turn) * 3600))
                    store.record(UsageEvent(at: at, feature: item.0, model: item.1, duration: 20, inputTokens: 4000, outputTokens: 600,
                                            cost: item.2 * Double(1 + (back + turn) % 3), currency: "USD"))
                }
            }
        }
        // One day with every feature, so the tooltip is rendered at its tallest.
        for (index, feature) in UsageFeature.allCases.enumerated() where !features.contains(where: { $0.0 == feature }) && feature != .voiceTranscription {
            store.record(UsageEvent(at: min(now, start.addingTimeInterval(Double(2 + index) * 3600)), feature: feature, model: "demo-model", duration: 5,
                                    inputTokens: 500, outputTokens: 100, cost: 0.05 * Double(index + 1), currency: "USD"))
        }
        store.record(UsageEvent(at: now.addingTimeInterval(-60), feature: .voiceTranscription, model: "whisper-1", audioSeconds: 12))
        for (name, days, hourly, cost) in [("usage-cost", 7, false, true), ("usage-requests", 30, false, false), ("usage-today", 1, true, true)] {
            let summary = store.summary(days: days, hourly: hourly, now: now, calendar: calendar)
            render(UsageSettings(range: days, sample: summary, showCost: cost).frame(width: 560, height: 700).panel(),
                   to: dir, name)
            // Hovering the newest column (rightmost, so the tooltip flips left) and the oldest (leftmost).
            if !hourly, let newest = summary.days.last?.day, let oldest = summary.days.first?.day {
                for (suffix, hovered) in [("hover-last", newest), ("hover-first", oldest)] {
                    render(UsageSettings(range: days, sample: summary, showCost: cost, hoveredDay: hovered).frame(width: 560, height: 700).panel(),
                           to: dir, "\(name)-\(suffix)")
                }
            }
        }
    }

    /// The Memory section over invented pages (the names of the design mockups): the list, a search, a page, a page reached from it, a
    /// search with no match. The empty state is the `real-memory` render above, which runs with no memory attached.
    private static func renderMemorySection(chat: ChatSession, sessions: SessionStore, signals: SignalStore, tasks: TasksAPI,
                                            meetings: MeetingsAPI, settings: SettingsModel, brief: BriefModel?, to dir: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-preview-memory-section-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        EntityMemoryStore.exportDirectory = folder
        let store = EntityMemoryStore(database: Database.open(path: nil, migrations: MemoryIndex.migrations).database)
        let project = ProjectKey(key: "git.northwind.example/lighthouse", name: "Lighthouse", isRepo: true, workspace: URL(fileURLWithPath: "/Users/you/Projects/lighthouse"))
        var clock = Date().addingTimeInterval(-5 * 86_400)
        store.now = { clock }
        func learn(_ days: Double, _ text: String, _ scope: MemoryScope, _ person: String? = nil, _ source: String = "chat:3f2a9c1d") {
            clock = Date().addingTimeInterval(-days * 86_400)
            _ = store.remember(text, scope: scope, person: person, project: project, source: source)
        }
        learn(4, "Works from Lisbon, one hour behind Berlin.", .me)
        learn(4, "Database migrations are one-way: after a build with new migrations is installed, older builds refuse the database.", .project)
        learn(3, "The CI size limit for the app bundle is 64 MB. Size is measured on CI, since local builds come out larger.", .project, nil, "screen")
        learn(2, "Auto-update for the desktop app is tracked in LH-283.", .project, nil, "tasks")
        learn(2, "Owns the Lighthouse repository and reviews every release build.", .people, "Maya Chen", "tasks")
        learn(1, "Asked that whoever picks up a Lighthouse issue assigns it to themselves.", .people, "Maya Chen", "screen")
        learn(1, "Maya is working with the team to track Lighthouse work as issues instead of a board.", .people, "Maya")
        learn(0, "Said overlapping intents caused most of the misclassification.", .people, "Maya Cheng")
        learn(0, "Wrote the retry queue for failed uploads (LH-412).", .people, "Sam Rivera", "meeting:2026-11-23-1005")
        if let lighthouse = store.entities().first(where: { $0.name == "Lighthouse" }), let maya = store.entities().first(where: { $0.name == "Maya Chen" }) {
            store.link(from: maya.id, to: lighthouse.id, type: "works_on", source: "chat:3f2a9c1d")
        }
        if let pinned = store.entities().first(where: { $0.name == "Lighthouse" }).flatMap({ store.claims(of: $0.id).last }) { store.setPinned(pinned.id, true) }
        let saved = MemoryAPI.live
        MemoryAPI.live = MemoryAPI(services: { nil }, pages: { store })
        defer { MemoryAPI.live = saved; MemorySectionModel.shared.showList(); MemorySectionModel.shared.reload() }
        let lighthouse = store.entities().first { $0.name == "Lighthouse" }?.id
        let maya = store.entities().first { $0.name == "Maya Chen" }?.id
        let steps: [(String, (MemorySectionModel) -> Void)] = [
            ("list", { _ in }),
            ("people-search", { $0.select(.people); $0.query = "maya"; $0.applyQuery() }),
            ("project", { m in if let lighthouse { m.open(lighthouse) } }),
            ("person", { m in if let lighthouse, let maya { m.open(lighthouse); m.open(maya) } }),
            ("no-results", { $0.select(.projects); $0.query = "maya"; $0.applyQuery() }),
        ]
        for (name, setup) in steps {
            for (suffix, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
                let m = MemorySectionModel.shared
                m.filter = .all; m.clearSearch(); m.showList(); m.reload()
                setup(m)
                let model = IronPetWindowModel(defaults: UserDefaults(suiteName: "ironpet-previews") ?? .standard)
                model.section = .memory
                let view = IronPetWindowView(model: model, agents: AgentsAPI(store: sessions), alerts: AlertsAPI(store: signals), tasks: tasks,
                                             chat: Self.chatModel(chat), meetings: meetings, settings: settings, brief: brief, actions: .none)
                renderWindow(model: model, session: chat, content: view, to: dir, "memory-\(name)-\(suffix)", scheme: scheme)
            }
        }
    }

    /// A memory folder with a few notes learned over the last days, one of them undone, or an empty one.
    private static func sampleMemory(in folder: URL, filled: Bool) -> MemorySettingsModel {
        EntityMemoryStore.exportDirectory = folder
        let store = EntityMemoryStore(database: Database.open(path: nil, migrations: MemoryIndex.migrations).database)
        let api = MemoryAPI(services: { nil }, pages: { store })
        guard filled else { return MemorySettingsModel(api: api) }
        var clock = Date().addingTimeInterval(-3 * 86_400)
        store.now = { clock }
        let project = ProjectKey(key: "github.com/you/demo-app", name: "demo-app", isRepo: true, workspace: URL(fileURLWithPath: "/Users/you/code/demo-app"))
        let notes: [(String, MemoryScope, String?, String, TimeInterval)] = [
            ("Prefers pnpm over npm.", .me, nil, "chat:3f2a9c1d", 0),
            ("Tests run with `swift test`; e2e needs the installed app.", .project, nil, "chat:3f2a9c1d", 3600),
            ("Leads the payments team and reviews API changes.", .people, "Ana", "meeting:2026-11-17-1000", 86_400),
            ("Writes commit messages in the conventional style.", .me, nil, "chat:8b1e77c0", 2 * 86_400),
            ("Works from Lisbon, one hour behind Helsinki.", .me, nil, "chat:8b1e77c0", 2 * 86_400 + 3000),
            ("Reviews release PRs on Thursdays.", .people, "Bo", "automation:release-watch", 3 * 86_400 - 600),
        ]
        for (text, scope, person, source, offset) in notes {
            clock = Date().addingTimeInterval(-3 * 86_400 + offset)
            _ = store.remember(text, scope: scope, person: person, project: project, source: source)
        }
        clock = Date().addingTimeInterval(-300)
        _ = store.remember("Uses Vim keybindings everywhere.", scope: .me, source: "chat:c41d09aa")
        if let added = store.recentChanges(limit: 1).first { _ = store.undo(added) }
        return MemorySettingsModel(api: api)
    }

    private static func sampleSettings(chat: ChatSession, config: Config) -> SettingsModel {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-preview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paths = AutomationPaths(file: folder.appendingPathComponent("automations.json"),
                                    directory: folder.appendingPathComponent("automations"))
        let store = AutomationStore(paths: paths, defaults: { AutomationMigration.defaults(from: config, sentryConfigured: false) },
                                    builtIns: AutomationDefaults.builtIns, watch: false)
        let telegram = TelegramBridge(
            client: TelegramAPI(token: { nil }), host: ChatAPI(session: chat), tokens: MemoryTokenStore(),
            storage: .init(users: { [] }, add: { _ in }, remove: { _ in }, offset: { 0 }, setOffset: { _ in }))
        let model = SettingsModel(actions: .init(suspendHotKeys: { _ in }, buildPet: { _ in }),
                                  announcer: Announcer(notifier: Notifier()), telegram: telegram)
        let service = AutomationService(store: store, engine: AutomationEngine(env: .init()))
        let api = AutomationsAPI(service: service)
        let sample = api.automations.first?.id ?? AutomationDefaults.githubID
        service.log(sample, "failed", "gh: could not reach api.github.com", detail: "gh pr list --author @me\nerror connecting to api.github.com\ncheck your internet connection", duration: 1.25)
        service.log(sample, "fired", "2 pull requests changed", detail: "#4649 Add screen capture: approved\n#4651 Fix the flaky login test: checks passed", duration: 0.8)
        service.log(sample, "baseline", "First look at your pull requests", duration: 0.6)
        model.automations = api
        return model
    }

    /// The Mac chat state over a sample session, built the way the app builds it, from the API's own snapshot.
    @MainActor
    static func chatModel(_ session: ChatSession) -> ChatViewModel {
        ChatViewModel(api: ChatAPI(session: session), voiceAPI: .standalone(settings: .live), events: APIEventBus(), persists: false)
    }

    /// Draws the ironpet window in a real `IronPetPanel` (traffic lights, sidebar selection and the blur of its
    /// materials) and captures that window from the window server. The offscreen `snapshot` cannot: a borderless
    /// window has no title bar, draws the sidebar selection black and does not blur materials.
    /// Falls back to nil when the window server gives no image (no display), and the caller skips the file.
    static func renderWindow(model: IronPetWindowModel, session: ChatSession?, content: some View, to dir: URL,
                             _ name: String, scheme: ColorScheme) {
        let panel = IronPetPanel(model: model, session: session.map { Self.chatModel($0) }, content: content)
        panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        panel.setContentSize(CGSize(width: 780, height: 560))
        panel.setFrameOrigin(CGPoint(x: 60, y: 60))
        // An inactive app draws the traffic lights grey.
        NSApp.setActivationPolicy(.regular)
        panel.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        panel.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        defer { panel.orderOut(nil) }
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else {
            print("no window image for \(name)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        let file = dir.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        print("wrote \(file.path)")
    }

    private static func snapshot(_ view: some View, wait: TimeInterval = 0.5, scheme: ColorScheme = .dark) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Retina snapshots make a GIF several times larger than it needs to be.
    private static func downscale(_ rep: NSBitmapImageRep, width: Int) -> CGImage? {
        guard let image = rep.cgImage else { return nil }
        let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private static func writeGIF(_ frames: [(CGImage, Double)], to file: URL) {
        guard let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (image, delay) in frames {
            CGImageDestinationAddImage(dest, image, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay,
            ]] as CFDictionary)
        }
        if CGImageDestinationFinalize(dest) { print("wrote \(file.path) (\(frames.count) frames)") }
    }

    private static var sampleSessions: [AgentSession] {
        func session(_ id: String, _ source: AgentSource, _ status: AgentStatus, _ project: String, prompt: String,
                     detail: String? = nil, edited: [String] = [], reply: String? = nil, minutes: Double,
                     iTerm: Bool = false) -> AgentSession {
            var s = AgentSession(id: id, source: source, status: status, prompt: prompt, detail: detail)
            s.origin = SessionOrigin(workspace: "/Users/you/code/\(project)", termProgram: iTerm ? "iTerm.app" : nil,
                                     itermSessionID: iTerm ? "w0t0p0" : nil)
            s.turnStartedAt = Date().addingTimeInterval(-minutes * 60)
            s.updatedAt = s.turnStartedAt
            s.editedFiles = edited
            s.lastResponse = reply
            return s
        }
        return [
            session("1", .claude, .needsInput, "api-server", prompt: "Add rate limiting to the public endpoints",
                    detail: "Run `npm install express-rate-limit`?", minutes: 3, iTerm: true),
            session("2", .cursor, .running, "web-app", prompt: "Make the settings page work on mobile",
                    detail: "Editing SettingsPage.tsx", minutes: 2),
            session("job-k3m9qa", .job, .running, "ironpet", prompt: "Write up last week's merged PRs",
                    detail: "Run gh pr list --state merged", minutes: 4),
            session("3", .claude, .done, "demo-app", prompt: "Why is the login test flaky?",
                    edited: ["a", "b", "c"], reply: "Fixed the flaky login test.", minutes: 6, iTerm: true),
            session("4", .cursor, .failed, "docs-site", prompt: "Upgrade to the new docs theme",
                    reply: "The build fails because the theme needs Node 20.", minutes: 11),
        ]
    }

    /// Agent turns that ended earlier today, as the activity log would list them.
    private static var sampleActivity: [BriefActivity] {
        func turn(_ ref: String, _ kind: BriefActivity.Kind, _ project: String, _ summary: String, minutes: Double) -> BriefActivity {
            BriefActivity(kind: kind, at: Date().addingTimeInterval(-minutes * 60), ref: ref, title: project, detail: summary,
                          agent: "Claude Code", workspace: "/Users/you/code/\(project)", bundleID: nil)
        }
        return [
            turn("claude:a", .sessionDone, "demo-app", "Fixed the flaky login test", minutes: 6),
            turn("claude:b", .sessionDone, "api-server", "Added rate limiting to the public endpoints", minutes: 45),
            turn("cursor:c", .sessionFailed, "docs-site", "The build needs Node 20", minutes: 11),
            BriefActivity(kind: .alertResolved, at: Date().addingTimeInterval(-30 * 60), ref: "5", title: "Fix flaky login test",
                          detail: "CI failed", agent: nil, workspace: nil, bundleID: nil),
        ]
    }

    /// A meeting on the last weekday with open action items, and one from this morning, for the Today previews.
    private static func sampleBriefMeetings() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-preview-brief-meetings")
        try? FileManager.default.removeItem(at: root)
        let calendar = Calendar.current
        let since = BriefBuilder.meetingsSince(weekdays: AutomationDefaults.weekdays, now: Date(), calendar: calendar)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let meetings = [
            (since.addingTimeInterval(15 * 3600), """
             # Summary

             Planning for the 2.4 release.

             ## Action items
             - [ ] Send the design review notes to the team (owner: Me, due: Friday)
             - [ ] Book the room for the launch review (owner: Me)
             - [x] Share the load test results (owner: Me)
             - [ ] Update the pricing page (owner: Priya)
             """),
            (min(Date().addingTimeInterval(-90 * 60), calendar.startOfDay(for: Date()).addingTimeInterval(10 * 3600)), """
             # Summary

             Weekly sync with the platform team.

             ## Action items
             None.
             """),
        ]
        for (date, summary) in meetings {
            let url = root.appendingPathComponent(formatter.string(from: date))
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? summary.write(to: url.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        }
        return root
    }

    /// An in-memory list with one task in each state, created at made-up times.
    /// Two made-up meetings in a temporary folder, for the Transcripts section.
    private static func sampleMeetings() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-preview-meetings")
        try? FileManager.default.removeItem(at: root)
        let meetings = [
            ("2026-11-16-0930", "# Summary\n\n- **Ship** the one-window layout on Friday; Settings stays its own window.\n",
             "**You:** Shall we keep Settings separate?\n\n**Them:** Yes, it matches what Mac apps do.\n"),
            ("2026-11-13-1400", "# Summary\n\n- Tasks get due dates next; reminders come from Automations.\n",
             "**You:** What is after tasks?\n\n**Them:** Due dates.\n"),
        ]
        for (folder, summary, transcript) in meetings {
            let url = root.appendingPathComponent(folder)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? summary.write(to: url.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
            try? transcript.write(to: url.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        }
        // One second of a made-up tone, so the newest meeting has audio and Regenerate is enabled; the other has none.
        if let first = meetings.first {
            let tone = (0..<WAV.sampleRate).map { Int16($0 / 20 % 2 == 0 ? 6000 : -6000) }
            try? WAV.encode(tone).write(to: root.appendingPathComponent(first.0).appendingPathComponent("mic-001.wav"))
        }
        return root
    }

    private static func sampleTasks() -> TasksAPI {
        var clock = Date()
        let store = TaskStore(database: Database.open(path: nil, migrations: TaskStore.migrations).database, now: { clock })
        let day: TimeInterval = 86_400
        func add(_ title: String, _ status: TaskStatus, _ source: TaskSource, ago: TimeInterval, due: Date? = nil,
                 notes: String = "", links: [TaskLink] = [], waitingOn: String? = nil) {
            clock = Date().addingTimeInterval(-ago)
            _ = try? store.create(title: title, notes: notes, status: status, source: source, due: due, links: links,
                                  waitingOn: waitingOn, by: "agent:mcp")
        }
        let today = Calendar.current.startOfDay(for: Date())
        add("Approve the staging deploy for the rate limiter", .needsYou, .agent, ago: 600,
            notes: "## Why now\n\nThe canary has been **green for an hour**. Steps:\n\n- check the `rate_limit` dashboard\n- read https://example.com/runbook\n- ask ops@example.com if unsure\n\nSee [the PR](https://github.com/you/api-server/pull/17).",
            links: [TaskLink(kind: .url, ref: "https://github.com/you/api-server/pull/17", label: "PR #17"),
                    TaskLink(kind: .thread, ref: "t1", label: nil), TaskLink(kind: .file, ref: "/Users/you/notes/deploy.md", label: nil)])
        _ = try? store.update(store.ordered[0].id, addLabels: ["merge": "auto", "repo": "api-server", "area": "payments", "context": "mac"], by: "agent:mcp")
        add("Fix the flaky login test", .inProgress, .chat, ago: 1500, due: today.addingTimeInterval(-day),
            links: [TaskLink(kind: .session, ref: "3", label: nil), TaskLink(kind: .thread, ref: "t1", label: nil)])
        add("Make the settings page work on mobile", .inProgress, .telegram, ago: 3 * 3600,
            due: today.addingTimeInterval(2 * day + 17 * 3600))
        add("Write the release notes for 2.4", .backlog, .meeting, ago: day, due: today.addingTimeInterval(4 * day),
            links: [TaskLink(kind: .file, ref: "/Users/you/.ironpet/meetings/2026-11-15-1000", label: "Meeting")])
        add("Upgrade the docs site to Node 20", .backlog, .cli, ago: 2 * day)
        add("Send the updated pricing deck", .backlog, .meeting, ago: day + 1800, due: today.addingTimeInterval(3 * day),
            links: [TaskLink(kind: .file, ref: "/Users/you/.ironpet/meetings/2026-11-15-1000", label: "Meeting")], waitingOn: "Ana")
        add("Rotate the Sentry token", .done, .user, ago: 2 * 3600)
        add("Answer Maya about the onboarding copy", .done, .meeting, ago: day + 3600)
        add("Remove the old feature flags", .done, .agent, ago: 3 * day)
        add("Learn to bake sourdough", .someday, .chat, ago: 5 * day)
        add("Renew the domain", .backlog, .user, ago: day)
        if let renew = store.tasks.first(where: { $0.title == "Renew the domain" }) {
            _ = try? store.update(renew.id, deferUntil: .some(today.addingTimeInterval(10 * day)), by: "agent:mcp")
        }
        for (title, context) in [("Make the settings page work on mobile", "phone"), ("Fix the flaky login test", "mac"),
                                 ("Upgrade the docs site to Node 20", "agent")] {
            if let task = store.tasks.first(where: { $0.title == title }) {
                _ = try? store.update(task.id, addLabels: ["context": context], by: "agent:mcp")
            }
        }
        clock = Date().addingTimeInterval(-900)
        store.suggest([("Send the design review notes to the team", "Friday", nil), ("Share the load test results", nil, "Priya")],
                      meeting: URL(fileURLWithPath: "/Users/you/.ironpet/meetings/2026-11-16-1500"))
        clock = Date().addingTimeInterval(-300)
        store.suggest([TaskSuggestion.Draft(key: "msg-1", title: "Reply to Sam about the Q4 budget", due: nil,
                                            url: URL(string: "https://mail.google.com/mail/u/0/#inbox/1"))],
                      automation: "gmail-watch", name: "Gmail watcher")
        // What the task scan files: a new task, and a change to a task that exists.
        clock = Date().addingTimeInterval(-120)
        store.suggest(scan: [TaskSuggestion.Draft(key: "scan", title: "Send Tom the deck", due: "2026-11-26")])
        if let target = store.tasks.first(where: { $0.title == "Send the updated pricing deck" }) {
            store.suggest(scanUpdates: [(TaskSuggestion.Update(target: target.id, targetTitle: target.title, note: "Sent on Tuesday, Ana confirmed.",
                                                               markDone: true), nil)])
        }
        clock = Date()
        let api = TasksAPI(store: store)
        _ = try? api.upsertQuickFilter(id: nil, name: "Open", query: ["not": ["status": "done"]])
        _ = try? api.upsertQuickFilter(id: nil, name: "Needs me", query: ["status": "needs_you"])
        _ = try? api.upsertQuickFilter(id: nil, name: "Due soon", query: ["and": [["due": ["before": "2099-01-01"]], ["not": ["status": "done"]]]])
        return api
    }

    private static var sampleSignals: [Signal] {
        let url = URL(string: "https://github.com/you/web-app/pull/42")!
        return [
            Signal(id: "1", title: "Make the settings page responsive", subtitle: "you/web-app #42 · build", url: url,
                   date: Date().addingTimeInterval(-119.5), label: "CI failed", symbol: "xmark.octagon.fill", mood: .failed, ask: "Why is CI failing?"),
            Signal(id: "2", title: "Add rate limiting to public endpoints", subtitle: "you/api-server #17", url: url,
                   date: Date().addingTimeInterval(-899.5), label: "Review requested", symbol: "eye.fill", mood: .needsInput, ask: "Summarize this PR."),
            Signal(id: "3", title: "Fix flaky login test", subtitle: "you/demo-app #8", url: url,
                   date: Date().addingTimeInterval(-1799.5), label: "Approved", symbol: "hand.thumbsup.fill", mood: .done),
        ].reversed()
    }
}

private extension View {
    /// Rounded window look, since the real panels' blur and shadow don't render offscreen.
    func panel() -> some View {
        background { ChatBackdrop() }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12), lineWidth: 1))
            .padding(1)
    }
}

/// The pet with its speech bubbles on a plain backdrop, laid out the way they sit on screen.
private struct PetScene: View {
    let atlas: Atlas?
    let row: AtlasRow
    let frame: Int
    /// A fixed size keeps the pet in place while bubbles come and go (GIF frames).
    var canvas: CGSize?
    /// A flat backdrop; gradients band badly in a GIF's 256 colours.
    var solid = false
    private let store = BubbleStore()

    init(atlas: Atlas?, row: AtlasRow, frame: Int, bubbles: [BubbleDraft], canvas: CGSize? = nil, solid: Bool = false) {
        self.atlas = atlas
        self.row = row
        self.frame = frame
        self.canvas = canvas
        self.solid = solid
        bubbles.forEach(store.show)
    }

    @MainActor var fittingSize: CGSize { NSHostingView(rootView: self.environment(\.colorScheme, .dark)).fittingSize }

    var body: some View {
        let size = CGSize(width: Atlas.cell.width * 0.9, height: Atlas.cell.height * 0.9)
        HStack(alignment: .bottom, spacing: -30) {
            BubbleStackView(api: BubblesAPI(store: store))
                .padding(.bottom, size.height * 0.62 - BubbleStackView.tailFromBottom)
            Group {
                if let image = atlas?.frame(row, frame) {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                } else {
                    Image(systemName: "pawprint.fill").resizable().scaledToFit().padding(40)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .padding(28)
        .frame(width: canvas?.width, height: canvas?.height, alignment: .bottomTrailing)
        .background {
            if solid {
                Color(red: 0.12, green: 0.14, blue: 0.21)
            } else {
                LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.3), Color(red: 0.09, green: 0.1, blue: 0.16)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}
