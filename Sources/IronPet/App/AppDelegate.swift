import AppKit
import enum IronPetKit.SharedSymbols
import IronPetCore
import IronPetKit
import SwiftUI
import Carbon
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The one set of platform adapters, built here and handed to everything that spawns a process or reads a secret.
    lazy var platform = Platform.mac(meetings: meeting, speech: chat.speech,
                                             presence: MacPresenceSource(ignoredMicApps: { ConfigStore.shared.config.meetings.ignoredMicApps }))
    /// The presence source the away checks read. Test mode moves its idle time with `/test/idle`; the automation clock keeps the real one.
    private lazy var awayPresence = MacPresenceSource(ignoredMicApps: { ConfigStore.shared.config.meetings.ignoredMicApps })
    /// Every client connected to the core: this app as the local client, and each paired phone with its event socket open.
    private let clients = ClientRegistry()
    private lazy var voiceKey = VoiceKey(store: platform.secrets)
    /// The bot token's store. Memory in `--test-mode`, where a Keychain approval dialog would block an automated run.
    private lazy var telegramTokens: TelegramTokenStore = TelegramAPI.testMode ? MemoryTokenStore() : TelegramToken(secrets: platform.secrets)
    let store = SessionStore()
    let signals = SignalStore()
    /// Permission requests from background jobs and automation sessions.
    private lazy var backgroundPermissions = BackgroundPermissions(signals: signals, timeout: {
        TimeInterval(ConfigStore.shared.config.jobs.permissionTimeoutMinutes * 60)
    })
    let chat = ChatSession(speech: SpeechPlayer())
    private lazy var recordingKeys = RecordingKeys(voice: chatModel.voice, heldModifiers: {
        Shortcut(ConfigStore.shared.config.hotkeys.voice)?.modifiers ?? 0
    })
    /// Dictation into other apps. It records with its own `VoiceController`, so the chat's voice note is untouched.
    private lazy var dictation: DictationController = {
        let controller = DictationController(delivery: DictationDelivery(focus: AXFocusReader(), board: .general, sendPaste: PasteKeystroke.send))
        controller.voice.voiceKey = voiceKey
        controller.canStart = { [weak self] in !(self?.chatModel.voice.isBusy ?? false) }
        controller.onNotice = { [weak self] title, body in
            self?.announcer.automation(AutomationNotice(id: "dictation", symbol: "mic.fill", tint: .warn, title: title, body: body, expires: 8))
        }
        return controller
    }()
    private lazy var dictationKeys = RecordingKeys(voice: dictation.voice)
    /// Fn hold-to-talk for dictation. Installs its event tap only while the dictation shortcut is "fn".
    private lazy var dictationFn = FnDictationTrigger(
        access: SystemInputMonitoringAccess(), source: FnEventTap(),
        detector: FnKeyDetector(isRecording: { [weak self] in self?.dictation.voice.isBusy ?? false })
    ) { [weak self] action in
        // Safe: FnEventTap adds its run loop source to the main run loop, so this closure runs on the main thread.
        MainActor.assumeIsolated {
            switch action {
            case .start, .stop: self?.dictation.shortcutPressed()
            case .cancel: self?.dictation.cancel()
            }
        }
    }
    private let notifier = Notifier()
    private let installer = HookInstaller()
    var automations: AutomationService!
    /// Runs one chat process for each enabled agent. See `AppDelegate+Agents.swift`.
    var supervisor: AgentSupervisor?
    var agentPets: AgentPets?
    var agentSessionTokens: [String: ChangeToken] = [:]
    /// Follows the active agent, so the highlight moves when the user selects another pet.
    var activeAgentToken: ChangeToken?
    var spokenSpeechToken: ChangeToken?
    private var capture: CaptureService?
    private var desktop: DesktopService?
    private var desktopApprovals: DesktopApprovals?
    /// Nil until the database is open, a moment after launch.
    private var jobs: JobService?
    private lazy var assistant = makeAssistantContext()
    lazy var spokenMessages = makeSpokenMessages()
    /// A job `jobs_open` asked for while the chat was running the turn that asked. Opened when that turn ends.
    private var jobToOpen: String?
    /// Ghost's memory: the background reflection pass and the search index. Nil until the database is open.
    private var memory: MemoryReflector?
    private var inboxScanner: InboxScanner?
    /// Nil until the database is open, a moment after launch.
    private var activity: ActivityLog?
    private var remote: RemoteController?
    private var welcomeBack: WelcomeBack?
    private var brief: TodayAPI?
    /// The inbox store, for the meeting suggestions and the test endpoints. Everything else uses `api.tasks`.
    private var taskStore: TaskStore?
    /// The Mac chat window's state, on top of `ChatAPI`. Built with the API.
    var chatModel: ChatViewModel!
    private lazy var logWindow = AutomationLogWindow(api: { [weak self] in self?.api?.automations })
    /// Moves the automation clock in test mode (`POST /test/automations/advance`). Zero otherwise.
    private var testClockOffset: TimeInterval = 0
    lazy var announcer = Announcer(notifier: notifier)
    private let updates = UpdateController()
    private var bubblePanel: BubblePanel!
    private var server: EventServer?
    var pet: PetController!
    private let dockIcon = DockIconController()
    private let meetings = MeetingLibrary()
    private let meeting = MeetingController()
    private var meetingPanel: MeetingPanel!
    private var meetingBubbleHidden = false
    private lazy var callPrompt = CallPrompt(
        isEnabled: { ConfigStore.shared.config.meetings.enabled && ConfigStore.shared.config.meetings.offerToRecordCalls },
        isBusy: { [weak self] in self?.meeting.isBusy ?? true })
    private var callMonitor: CallMonitor?
    /// Watches for calls while spoken replies are on, so a reply is not read aloud over one.
    private lazy var micIgnore = MicIgnoreModel(
        entries: { ConfigStore.shared.config.meetings.ignoredMicApps },
        save: { list in ConfigStore.shared.update { $0.meetings.ignoredMicApps = list } })
    private let speechMic = MicWatch(ignored: { ConfigStore.shared.config.meetings.ignoredMicApps })
    private var meetingBubbleRemoving = false
    private var hotKeys: [HotKey] = []
    private var previousApp: NSRunningApplication?
    private let wispr = WisprBridge()
    private var testControl: TestControl?
    private var timers: [Timer] = []
    private var cancellables: Set<AnyCancellable> = []
    private var chatStateToken: ChangeToken?
    private var lastChatState: ChatSession.State = .idle
    private var changeTokens: [ChangeToken] = []
    private var shownAppearance: String?
    private var appliedConfig = Config()
    private let config = ConfigStore.shared
    /// Stores publish their changes here. It exists before the API, which needs the database.
    let events = APIEventBus()
    /// The in-process API, built once the database is open.
    var api: IronPetAPI!
    private var setupWindow: SetupWindow?
    private lazy var telegram = TelegramBridge(
        client: TelegramAPI(token: { [telegramTokens] in telegramTokens.load() }), host: api.chat, tokens: telegramTokens,
        storage: .init(
            users: { ConfigStore.shared.config.telegram.allowedUsers },
            add: { user in ConfigStore.shared.update { $0.telegram.allowedUsers.append(user) } },
            remove: { id in ConfigStore.shared.update { $0.telegram.allowedUsers.removeAll { $0.id == id } } },
            offset: { UserDefaults.standard.integer(forKey: "telegramOffset") },
            setOffset: { UserDefaults.standard.set($0, forKey: "telegramOffset") }),
        voiceEnabled: { ConfigStore.shared.config.voice.enabled },
        transcribe: { [weak self] audio, name in
            guard let self else { throw APIError.unavailable("ironpet is not ready") }
            return try await self.api.voice.transcribe(TranscribeRequest(audio: audio, fileName: name, mime: TelegramVoice.mime(for: name)))
        },
        petName: { ConfigStore.shared.config.pet.name })
    private lazy var settingsWindow = SettingsWindow(model: settingsModel)
    lazy var settingsModel = SettingsModel(actions: .init(
        suspendHotKeys: { [weak self] suspended in suspended ? self?.unregisterHotKeys() : self?.registerHotKeys() },
        buildPet: { [weak self] description in self?.requestPet(description) }
    ), announcer: announcer, telegram: telegram)

    /// Hands the platform adapters to the objects built before the database opens. The rest get theirs where they are built.
    private func wirePlatform() {
        store.appInfo = platform.appInfo
        chat.spawner = platform.processes
        announcer.urlOpener = platform.opener
        chat.speech.voiceKey = voiceKey
        let keyCache = MeetingController.KeyCache(voiceKey: voiceKey)
        let voiceStore = VoiceStore(url: VoiceStore.defaultURL, key: { [secrets = platform.secrets] in VoiceStoreKey(store: secrets).load() })
        for owner in [meeting] {
            owner.spawner = platform.processes
            owner.keyCache = keyCache
            owner.voiceStore = voiceStore
        }
        meetings.regenerator.spawner = platform.processes
        meetings.regenerator.keyCache = keyCache
        meetings.regenerator.diarizer = meeting.diarizer
        meetings.regenerator.speakerModelsReady = { MainActor.assumeIsolated { SpeakerModels.shared.isReady } }
        meetings.regenerator.voiceStore = voiceStore
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        config.events = events
        // Light or dark from Settings → General, applied app-wide. "System" clears the override and follows macOS.
        // The signal fires before `config` changes, so the new value is read one main-actor turn later.
        let applyAppearance = { [weak self] in
            guard let self, config.config.window.appearance != shownAppearance else { return }
            let name = config.config.window.appearance
            shownAppearance = name
            NSApp.appearance = name == "light" ? NSAppearance(named: .aqua)
                : name == "dark" ? NSAppearance(named: .darkAqua) : nil
        }
        applyAppearance()
        changeTokens.append(config.changes.observe { DispatchQueue.main.async { applyAppearance() } })
        store.events = events
        signals.events = events
        announcer.bubbles.events = events
        meeting.events = events
        wirePlatform()

        announcer.openSession = { [weak self] id in self?.openSession(id) }
        announcer.openChat = { [weak self] in self?.showChat() }
        announcer.ask = { [weak self] prompt in self?.ask(prompt) }
        announcer.decide = { [weak self] id, allow in
            guard let self else { return }
            if backgroundPermissions.has(id) { backgroundPermissions.answer(id, allow: allow) } else if !(api?.chats.decide(id: id, allow: allow) ?? false) { chat.decide(id: id, allow: allow) }
        }
        _ = backgroundPermissions.observe(raised: { [weak self] request in
            self?.announcer.backgroundPermission(request) { option in self?.backgroundPermissions.answer(request.id, optionID: option) }
        }, resolved: { [weak self] id, _ in self?.announcer.clearApproval(id: id) })
        announcer.automationAction = { [weak self] ids, snooze in self?.automations.notificationAction(ids: ids, snooze: snooze) }
        notifier.start()
        // Resolving the login-shell PATH runs the user's shell, so do it before the first chat needs it.
        LoginShell.prepare(spawner: platform.processes)
        store.onAttention = { [weak self] session in
            if let event = ActivityEvent.session(session) { self?.activity?.record(event) }
            // A job waits for input only on an approval, which has its own bubble.
            guard session.source != .job || session.status != .needsInput else { return }
            self?.announcer.session(session)
            self?.testControl?.recordAttention(session)
        }

        signals.onNew = { [weak self] signal in
            self?.announcer.signal(signal)
            self?.testControl?.recordNotified(signal)
        }

        pet = PetController(store: store, signals: signals)
        pet.onAsk = { [weak self] prompt in self?.ask(prompt) }
        pet.onSay = { [weak self] text in self?.announcer.say(text) }
        pet.onTellGhost = { [weak self] text in self?.sendToChat(text, show: true, title: "Tasks", busyBody: "Send it to the chat?") }
        pet.onOpenThread = { [weak self] id in
            guard let self, let thread = ThreadStore.load(id) else { return }
            self.chat.open(thread)
            self.showChat()
        }
        pet.onOpenSession = { [weak self] id in self?.openSession(id) }
        pet.onOpenJob = { [weak self] id in self?.openJob(id) }
        bubblePanel = BubblePanel(store: announcer.bubbles, meetings: { [weak self] in self?.api.meetings })
        pet.extraMenuItems = { [weak self] in self?.hookMenuItems() ?? [] }
        pet.chatMood = { [weak self] in self?.chat.mood }
        pet.voiceMood = { [weak self] in self?.spokenMessages.recorder.mood }
        pet.onChatToggle = { [weak self] in self?.toggleChat() }
        pet.onCapture = { [weak self] region in self?.captureScreen(region: region) }
        pet.chat = chat
        // Once the app is up: delete old session transcripts past their retention, and move an oversized chat to a fresh session.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.chat.pruneOldSessions()
            self?.chat.rolloverIfDue()
        }
        pet.show()
        dockIcon.update(sprite: config.config.pet.sprite)

        wispr.onDictation = { [weak self] text in self?.chatModel.receiveDictation(text) }
        pet.onChatShown = { [weak self] shown in self?.chatShown(shown) }
        pet.onWindowClosed = { [weak self] in self?.restorePreviousApp() }
        meeting.onLabelSpeakers = { [weak self] in self?.showSettings(tab: "meetings") }
        announcer.bubbles.onDismissed = { [weak self] id in self?.meetingBubbleClosed(id) }
        pet.onRecordingClick = { [weak self] in self?.showMeetingBubble() }
        meeting.onSummaryReady = { [weak self] url in
            self?.memorySawMeeting(url.deletingLastPathComponent(), agent: self?.meeting.lastSummaryRequest?.agent)
            self?.activity?.record(.meetingSummary(url))
            self?.announcer.meetingSummary(url)
            self?.meetings.reload()
            self?.testControl?.recordMeetingNotified(url)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                self?.suggestTasks(fromSummary: text, meeting: url.deletingLastPathComponent())
            }
        }
        meeting.onOpenInChat = { [weak self] files in self?.openMeetingInChat(files) }
        meetings.onDeleted = { folder in EntityMemoryStore.shared.index.removeMeeting(folder) }
        meetings.regenerator.onReplaced = { [weak self] replaced in
            self?.memorySawMeeting(replaced.folder, agent: replaced.agent)
            self?.meetings.reload()
            // Only items the old summary did not have: the user may have skipped the others.
            self?.offerTasks(ActionItems.newSuggestions(old: replaced.previousSummary, new: replaced.summary), meeting: replaced.folder)
        }
        meeting.regenerateSummaryOf = { [weak self] folder in
            guard let self, let record = MeetingLibrary.record(folder) else { return false }
            return await self.meetings.regenerator.regenerate(record, mode: .summaryOnly)
        }
        if TestControl.isEnabled {
            // No dialog may block an automated run.
            meeting.confirmConsent = { true }
        }
        startCallMonitor()
        let quiet = Presence(
            meetingActive: { [weak self] in self?.meeting.isRecording ?? false },
            detectedCalls: { [weak self] in self?.callMonitor.flatMap { $0.isRunning ? $0.detector.activeApps : nil } },
            micCalls: speechMic.calls)
        chat.isQuiet = quiet.isPresent
        syncSpeechQuiet()
        chat.onAttention = { [weak self] title in
            self?.activity?.record(.chatFinished(title))
            self?.announcer.chat(title)
        }
        chat.onApprovalNeeded = { [weak self] approval in
            self?.announcer.approval(id: approval.id, title: approval.title, detail: approval.detail)
        }
        chat.onFormNeeded = { [weak self] title, detail in self?.announcer.chat(title, detail: detail) }
        chat.onApprovalResolved = { [weak self] id in self?.announcer.clearApproval(id: id) }
        chat.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pet.refreshMood() }
            .store(in: &cancellables)
        appliedConfig = config.config
        changeTokens.append(config.changes.observe { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.config.config != self.appliedConfig else { return }
                let previous = self.appliedConfig
                self.appliedConfig = self.config.config
                self.apply(config: self.config.config, previous: previous)
            }
        })

        setUpAutomations()
        // After the API exists: the hotkeys read the settings model, which builds the Telegram bridge over `api.chat`.
        registerHotKeys()
        _ = recordingKeys // Starts following the recording phase.
        _ = dictationKeys
        setUpAgents()
        // These read `api`, which `setUpAutomations()` builds.
        settingsModel.voice = api.voice
        telegram.onPairingRequest = { [weak self] request in
            self?.announcer.telegramPairing(request, allow: { self?.telegram.allow(request.id) },
                                            deny: { self?.telegram.deny(request.id) })
        }
        telegram.onPairingResolved = { [weak self] id in self?.announcer.clearTelegramPairing(id: id) }
        if config.config.telegram.enabled { telegram.setEnabled(true) }
        do {
            try startServer()
        } catch {
            showError("ironpet could not start the agent watcher", error)
        }
        if SetupWindow.isNeeded {
            showSetup()
        } else {
            // Refresh the chosen hooks so they match this version of the app.
            setHooks(installed: hookAgents(in: config.config), quietly: true)
        }
        pet.setAgentsTracked(config.config.integrations.trackAgents)

        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pet.tick()
                self.bubblePanel.follow(self.pet.panel.frame)
                self.bubblePanel.isSuppressed = self.pet.suppressesBubbles
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.sweep() }
        })

    }

    /// Builds the automation service: the file, the clock and the places an automation can show or run something.
    private func setUpAutomations() {
        // Before the engine and the away checks: they read the idle time from this client's session.
        registerLocalClient()
        let store = AutomationStore()
        HeartbeatRemoval.runOnce(store: store)
        let engine = AutomationEngine(env: .init(
            now: { [weak self] in Date().addingTimeInterval(self?.testClockOffset ?? 0) },
            presence: SessionPresence(registry: clients, local: platform.presence),
            isAgentWorking: { [weak self] in
                guard let self else { return false }
                return self.chat.state == .running || self.store.sessions.values.contains { $0.status == .running }
            },
            isBusy: { [weak self] in
                guard let self else { return false }
                return self.chat.isVisible || !self.chat.approvals.isEmpty || self.store.summary.status == .needsInput
            },
            spawner: platform.processes))
        engine.timing = { [config] in
            let r = config.config.reminders
            return .init(idleResetMinutes: r.idleResetMinutes, snoozeMinutes: r.snoozeMinutes)
        }
        // The app's one database. Features add their migrations to this list, in version order.
        let database = Database.open(path: Paths.root.appendingPathComponent("ironpet.db"), migrations: AppMigrations.all).database
        UsageStore.shared = UsageStore(database: database)
        let log = ActivityLog(database: database)
        activity = log
        let tasks = TaskStore(database: database)
        taskStore = tasks
        let service = AutomationService(store: store, engine: engine, database: database)
        tasks.onAdded = { [weak service] items in service?.inboxItemsAdded(items) }
        let notificationStore = NotificationStore(database: database)
        // Agent 1 takes over the chat settings an older build kept in UserDefaults and config.json, once, before anything reads them.
        let agentRegistry = AgentRegistry(database: database)
        agentRegistry.adoptLegacySettings(pet: config.config.pet)
        chat.attach(registry: agentRegistry)
        api = IronPetAPI(stores: .init(tasks: tasks, automations: service, signals: signals, bubbles: announcer.bubbles, notifications: notificationStore, sessions: self.store, chat: chat, meeting: platform.meetings, meetingLibrary: meetings, config: config, speech: platform.speech, petAssets: platform.pets, files: platform.files, usage: UsageStore.shared, permissions: backgroundPermissions, nodeID: NodeIdentity.nodeID(in: database), agents: agentRegistry, dashboards: DashboardStore(), spawner: platform.processes), events: events, clients: clients)
        // After `api`: it reads `settingsModel`, whose Telegram bridge needs `api.chat`.
        startUpdates(database: database)
        pet.tasks = api.tasks
        pet.dashboards = api.dashboards
        pet.notifications = NotificationsModel(api: api.notifications, events: events)
        announcer.notifications = notificationStore
        announcer.openNotification = { [weak self] id in self?.pet.openNotification(id) }
        pet.alerts = api.alerts
        api.attach(assistant: assistant)
        api.session.serverVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        api.attach(memory: { [weak self] in self?.memoryServices })
        api.attach(records: RecordRefs(database: database))
        pet.agents = api.agents
        chatModel = ChatViewModel(api: api.chat, voiceAPI: api.voice, events: events)
        chatModel.voice.voiceKey = voiceKey
        chatModel.voice.isEnabled = { [weak self] in ConfigStore.shared.config.voice.enabled && !(self?.dictation.voice.isBusy ?? false) }
        api.voice.voiceKey = voiceKey
        api.voice.transcoder = platform.audio
        // The settings model needs the API (through the Telegram bridge), so it is wired here and not in `wirePlatform`.
        settingsModel.platform = platform
        pet.chatModel = chatModel
        pet.meetingsAPI = api.meetings
        pet.events = events
        api.pet.stateProvider = { [weak pet] in pet?.state ?? PetState(mood: PetMood.idle.rawValue, badge: 0) }
        api.pet.accentProvider = { MacAccent.current() }
        api.pet.trickNames = { PetController.Trick.allCases.map(\.rawValue) }
        api.pet.trickHandler = { [weak pet] name in
            guard let trick = PetController.Trick(rawValue: name), let pet else { return false }
            pet.perform(trick)
            return true
        }
        settingsModel.pets.api = api.pet
        let remoteController = RemoteController(api: api, settings: api.settings, database: database, bubbles: announcer.bubbles,
                                                chime: { NSSound(named: "Pop")?.play() }, activity: log)
        remote = remoteController
        settingsModel.remote = remoteController
        remoteController.reconcile()
        api.meetings.askHandler = { [weak self] files in self?.openMeetingInChat(files) }
        meetingPanel = MeetingPanel(controller: api.meetings)
        meeting.onChange = { [weak self] in self?.syncMeetingPanel() }
        settingsModel.meeting = api.meetings
        api.agents.focusHandler = { [weak pet] session in pet?.jump(to: session) }
        api.agents.askHandler = { [weak self] prompt in self?.ask(prompt) }
        api.alerts.askHandler = { [weak self] prompt in self?.ask(prompt) }
        setUpWelcomeBack(log, tasks: tasks)
        pet.settings = settingsModel
        pet.onSettings = { [weak self] in self?.showSettings(tab: nil) }
        pet.onScreenSettings = { [weak self] in self?.showSettings(tab: "screen") }
        pet.onMemorySettings = { [weak self] in self?.showSettings(tab: "memory") }
        settingsModel.showScreenSection = { [weak self] in self?.pet.showWindow(.screen) }
        settingsModel.showMemorySection = { [weak self] in self?.pet.showWindow(.memory) }
        setUpScreenCapture(database)
        setUpDesktopControl()
        setUpMemory(database)
        setUpInboxScan(tasks)
        setUpJobs(database, tasks: tasks)
        service.notifications = notificationStore
        service.latestThread = { ThreadStore.latest(automation: $0)?.id }
        service.notice = { [weak self] notice in
            if let event = ActivityEvent.automationNotice(notice) { self?.activity?.record(event) }
            self?.announcer.automation(notice)
        }
        service.dismissNotice = { [weak self] id in self?.announcer.bubbles.dismiss(id) }
        service.alert = { [weak self] signal, notify in
            if notify { self?.activity?.record(.alertOpened(signal)) }
            self?.signals.add(signal, notify: notify)
        }
        service.resolveAlert = { [weak self] id in
            guard let self else { return }
            if let signal = signals.signals.first(where: { $0.id == id }) { activity?.record(.alertResolved(signal)) }
            signals.dismiss(id)
        }
        // Alerts the user has not dismissed come back after a restart, quietly. Dismissing one clears its stored payload.
        signals.restore(service.engine.state.openAlerts())
        signals.onDismiss = { [state = service.engine.state] id in state.closeAlert(signalID: id) }
        signals.reportIfUnavailable(database)
        service.nudge = { [weak self] moods in self?.pet.nudge(moods, each: moods == [.done] ? 3 : 4) }
        service.suggested = { [weak self] added in self?.offerSuggestions(added) }
        let workspace = store.paths.workspace
        // Not read by memory: this restricted run is for prompts with item text from outside, and its answer is built from that text.
        let spawner = platform.processes
        service.runPrompt = { automation, prompt in await AutomationPrompt.run(automation, prompt: prompt, workspace: workspace, spawner: spawner) }
        service.forkSource = { [weak self] automation in
            guard let chat = self?.chat, chat.agent.id == AutomationPrompt.agentID(automation) else { return nil }
            return chat.sessionID
        }
        service.postNotice = { [weak self] kind, title, text, triggers in
            self?.chat.postSystemNotice(kind: kind, text: text, title: title, triggersTurn: triggers)
        }
        service.runSession = { [weak self, weak service] automation, prompt, fork in
            let agent = AutomationPrompt.agentID(automation)
            let result = await AutomationSession.run(automation, prompt: prompt, workspace: workspace, spawner: spawner, fork: fork,
                                                     onNote: { service?.record(automation.id, "warning", $0) },
                                                     permissions: self?.backgroundPermissions)
            self?.chat.refreshHistory()
            if case .success(let answer) = result { self?.memorySawAutomation(automation.id, answer: answer, agent: agent) }
            return result
        }
        chat.onAutomationAnswer = { [weak self] id, answer in
            guard let self else { return }
            self.memorySawAutomation(id, answer: answer, agent: self.chat.agent.id)
        }
        chat.quietReply = { [weak store] id in store?.automations.first { $0.id == id }?.action.quietReplies }
        setUpBrief(service, tasks: tasks)
        service.sendToChat = { [weak self] id, message in self?.chat.submitFromAutomation(message, automation: id) ?? false }
        service.chatRunPending = { [weak self] id in self?.chat.hasAutomationRun(id) ?? false }
        chat.onAutomation = { [weak service] id, event in service?.chatOutcome(id, event) }
        automations = service
        settingsModel.automations = api.automations
        settingsModel.agentRecords = api.agentRecords
        settingsModel.prompts = api.prompts
        settingsModel.showLogs = { [weak self] id in
            // The log is a normal window, so it would open behind the floating ironpet window.
            self?.pet.closeWindow()
            self?.logWindow.show(automation: id)
        }
        service.logRetentionDays = { [config] in config.config.automations.logRetentionDays }
        service.autoFixEnabled = { [config] in config.config.automations.autoFix }
        service.autoApproveEnabled = { [config] in config.config.automations.autoApprove }
        service.autoApproveBubblesEnabled = { [config] in config.config.automations.autoApproveBubbles }
        service.requestFix = { [weak self] automation, trigger, error in
            self?.sendToChat(AutomationAgentPrompts.fix(automation, trigger: trigger, error: error), show: false,
                             title: "\(automation.name) failed", busyBody: "Ask \(self?.chat.agent.name ?? "the agent") to fix it?")
        }
        settingsModel.createWithAgent = { [weak self] request in
            self?.sendToChat(AutomationAgentPrompts.newAutomation(request), show: true, title: "New automation", busyBody: "Send it to the chat?")
        }
        service.start()
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.automations.engine.tick()
                // Pet sheets and the custom background change on disk: tell clients that cache them.
                self?.api.pet.checkAssets()
            }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.automations.engine.tick() }
        // Update installed skills, and offer the others once the first-run window is out of the way.
        if !TestControl.isEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkSkills() }
        }
    }

    /// Background jobs (`jobs_start`): rows in the Agents section, Allow and Deny bubbles for their approvals, and their
    /// threads in the chat.
    private func setUpJobs(_ database: Database, tasks: TaskStore) {
        let service = JobService(database: database)
        service.spawner = platform.processes
        service.currentAgent = { [weak self] in self.map { ($0.chat.agent, $0.chat.model) } }
        service.onChange = { [weak self, weak service] job in
            self?.store.setJob(Job.sessionKey(job.id), job.agentSession)
            self?.spokenMessages.jobChanged(job)
            if let service { self?.chat.syncJobs(service.jobs) }
        }
        chat.jobStopper = { [weak service] id in _ = try? service?.stop(id) }
        service.onThreadSaved = { [weak self] thread in self?.chat.threadSaved(thread) }
        service.permissions = backgroundPermissions
        service.sessionBusy = { [weak self] thread in self.map { $0.chat.isRunning && $0.chat.threadID == thread } ?? false }
        // The signal fires before `state` changes, so the handler reads it on the next main-actor turn.
        lastChatState = chat.state
        chatStateToken = chat.changes.observe { [weak self] in
            DispatchQueue.main.async {
                // Only a state change counts, as with the `$state` publisher; every other chat change also fires the signal.
                guard let self, self.chat.state != self.lastChatState else { return }
                self.lastChatState = self.chat.state
                guard self.chat.state != .running, let id = self.jobToOpen else { return }
                self.jobToOpen = nil
                self.openJob(id)
            }
        }
        chat.speakRepliesSetting = { ConfigStore.shared.config.speech.speakReplies }
        chat.jobFollowUp = { [weak service] thread, text in
            guard let service, let job = service.job(thread: thread), job.state.isActive else { return false }
            return (try? service.followUp(job.id, message: text)) != nil
        }
        jobs = service
        chat.syncJobs(service.jobs)
    }

    /// Spoken messages for the primary chat. It stays quiet during calls and meeting recordings, and job updates are not
    /// spoken to an empty room.
    private func makeSpokenMessages() -> SpokenMessageController {
        let controller = SpokenMessageController()
        controller.voiceKey = voiceKey
        controller.petFrame = { [weak self] in self?.pet.panel.frame ?? .zero }
        controller.quietReason = { [weak self] in
            guard let self else { return nil }
            if [.recording, .finishing].contains(meeting.phase) { return "a meeting recording" }
            let calls = callMonitor.flatMap { $0.isRunning ? $0.detector.activeApps : nil } ?? speechMic.calls()
            return calls.isEmpty ? nil : "a call"
        }
        controller.isAway = { [weak self] in
            (self?.awayPresence.idleOrZero() ?? 0) >= ConfigStore.shared.config.reminders.idleResetMinutes * 60
        }
        controller.send = { [weak self] text in self?.chatModel.sendSpoken(text) }
        controller.interruptSpeech = { [weak self] in
            guard let speech = self?.chat.speech, speech.isSpeaking else { return false }
            speech.stop()
            return true
        }
        controller.spokenTurnRunning = { [weak self] in self?.chat.readsReply ?? false }
        // Listening resumes after the reply, once the pet has stopped reading it: its own voice must not reach the microphone.
        controller.recorder.isSpeaking = { [weak self] in self?.chat.speech.isSpeaking ?? false }
        chat.onSpokenTurnEnded = { [weak controller] failed in controller?.turnEnded(failed: failed) }
        spokenSpeechToken = chat.speech.changes.observe { [weak controller] in
            DispatchQueue.main.async { MainActor.assumeIsolated { controller?.speechChanged() } }
        }
        controller.recorder.onFailure = { [weak self] message in
            self?.announcer.automation(AutomationNotice(id: "voice-message", symbol: "mic.slash.fill", tint: .warn, title: "Voice",
                                                        body: message, expires: 15))
        }
        controller.onStateChange = { [weak self] in self?.pet.refreshMood() }
        return controller
    }

    /// What the `jobs_*`, `status_*`, `memory_*` and `projects_resolve` tools read.
    private func makeAssistantContext() -> AssistantContext {
        let context = AssistantContext()
        context.jobs = { [weak self] in self?.jobs }
        context.sessions = { [weak self] in self?.store.ordered.filter { $0.source != .job } ?? [] }
        context.resolveAgent = { [weak self] id in try AgentOwner.resolve(id, registry: self?.api?.agentRecords?.registry) }
        context.alerts = { [weak self] in self?.signals.signals ?? [] }
        context.brief = { [weak self] kind in self?.brief?.brief(BriefRequest(kind: kind)) }
        context.meetings = { [weak self] in
            guard let self else { return [] }
            if meetings.meetings.isEmpty { meetings.reload() }
            return meetings.meetings
        }
        context.projects = { [weak self] in
            guard let self else { return [] }
            let front = NSWorkspace.shared.frontmostApplication
            let app = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previousApp : front
            // Only Cursor's window: iTerm's folder needs an Apple Event, which could block here and prompt mid tool call.
            // A terminal agent's folder comes in through its session instead.
            let frontmost = app?.bundleIdentifier == SourceJumper.cursorBundleID ? WorkspaceDetector.workspace(of: app) : nil
            let sessions = store.sessions.values.sorted { $0.updatedAt > $1.updatedAt }.compactMap { $0.origin.workspace }
            return ProjectResolver.candidates(frontmost: frontmost, chat: chat.workspace, cursor: WorkspaceDetector.cursorOpenFolders(),
                                              sessions: sessions.map { URL(fileURLWithPath: $0) }, recents: chat.recents,
                                              scratch: ChatSession.scratchWorkspace)
        }
        context.openJob = { [weak self] id in
            guard let self else { return .failure(JobError(message: "ironpet is quitting")) }
            // Opening a thread replaces the chat's, which would end the turn that asked, so it waits for that turn.
            guard chat.isRunning else {
                openJob(id)
                return .success("Opened the job's thread in the chat.")
            }
            jobToOpen = id
            return .success("The job's thread opens in the chat when this reply ends.")
        }
        return context
    }

    /// Opens a job's thread in the chat, and shows its waiting approvals again. A job with no thread yet opens the Agents section.
    func openJob(_ id: String) {
        guard let jobs, let job = jobs.job(id) else { return pet.showWindow(.agents) }
        jobs.showApprovals(id)
        guard let thread = job.thread.flatMap(ThreadStore.load) else { return pet.showWindow(.agents) }
        chat.open(thread)
        showChat()
    }

    /// The morning brief and the recap: built from the stores for `digest` automations and the Today page. The Today row is
    /// listed while one of those automations is on.
    private func setUpBrief(_ service: AutomationService, tasks: TaskStore) {
        let source = api.today
        source.activity = activity
        source.now = { [weak self] in Date().addingTimeInterval(self?.testClockOffset ?? 0) }
        let model = BriefModel(source: source)
        let automations = service.store
        model.weekdays = { [weak automations] in
            automations?.automations.first { $0.action.type == "digest" && $0.action.digest == Brief.Kind.brief.rawValue }?.trigger.weekdays
        }
        brief = source
        pet.brief = model
        service.digest = { kind, a, slot in source.brief(BriefRequest(kind: kind, weekdays: kind == .brief ? a.trigger.weekdays : nil, day: slot)) }
        service.showDigest = { [weak self] brief, a, _ in
            self?.announcer.brief(brief, automation: a) { [weak self] in
                self?.announcer.bubbles.dismiss(Announcer.briefID(brief.kind))
                self?.pet.showBrief(brief.kind, day: brief.window.start)
            }
        }
        changeTokens.append(automations.observeDigestShown { [weak self] shown in self?.pet.setTodayShown(shown) })
    }

    /// Builds Ghost's memory on the shared database: the entity store, the one-time move of the old note files onto pages, the background
    /// indexing of saved chats and meetings, and the hourly digest that learns from them.
    private func setUpMemory(_ database: Database) {
        let store = EntityMemoryStore(database: database)
        EntityMemoryStore.shared = store
        MemoryMigration.run(into: store)
        let index = store.index
        ThreadStore.didSave = { [index] thread in index.indexThread(thread) }
        store.index.backfill(threads: { ThreadStore.recent(limit: .max, automationLimit: 0) }, meetings: Paths.meetings)
        let reflector = MemoryReflector(store: store, index: store.index, spawner: platform.processes)
        reflector.automatic = !TestControl.isEnabled
        reflector.onChange = { [weak self] in self?.settingsModel.memory?.reload() }
        reflector.seedIfNeeded()
        reflector.captures = { [weak self] in self?.capture?.store.recent(limit: 200) ?? [] }
        reflector.digestAgent = { [weak self] in self?.chat.agent.id }
        // A name that stays ambiguous is asked once, not again with a notification every digest.
        reflector.post = { [weak self] signal in
            guard let self else { return }
            signals.add(signal, notify: !signals.signals.contains { $0.id == signal.id })
        }
        memory = reflector
        api.memory?.cleanupClassifier = { [weak reflector] in
            guard let reflector, let agent = reflector.digestReaderAgent() else { return nil }
            return reflector.cleanupClassifier(agent: agent)
        }
        let memorySettings = MemorySettingsModel(api: api.memory ?? MemoryAPI(services: { nil }), reflector: reflector)
        memorySettings.spawner = platform.processes
        settingsModel.memory = memorySettings
        // Every minute the digest checks whether `memory.digestMinutes` have passed. A minute after launch it runs once, so the agents are
        // not started while the app is still coming up. An automated run reads only what it sends.
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak reflector] _ in
            MainActor.assumeIsolated { reflector?.tick() }
        })
        if !TestControl.isEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak reflector] in reflector?.tick() }
        }
    }

    /// The Inbox scan: every `tasks.inboxScanMinutes` it reads the new chat messages and, when asked, the new screen text, and files what the
    /// user committed to. It reads nothing while `tasks.inboxScan` is off.
    private func setUpInboxScan(_ tasks: TaskStore) {
        let scanner = InboxScanner(store: tasks, spawner: platform.processes)
        scanner.automatic = !TestControl.isEnabled
        scanner.config = { [config] in config.config.tasks }
        scanner.captures = { [weak self] in self?.capture?.store.recent(limit: 200) ?? [] }
        scanner.digestAgent = { [weak self] in self?.chat.agent.id }
        scanner.added = { [weak self] added in
            guard let self else { return }
            offerSuggestions(added, bubble: config.config.tasks.inboxScanBubbles)
        }
        scanner.seedIfNeeded()
        inboxScanner = scanner
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak scanner] _ in
            MainActor.assumeIsolated { scanner?.tick() }
        })
        if !TestControl.isEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak scanner] in scanner?.tick() }
        }
    }

    /// A summary was written or regenerated. `agent` wrote it; nil is the summary agent in Settings, which regeneration uses.
    private func memorySawMeeting(_ folder: URL, agent: String?) {
        EntityMemoryStore.shared.index.indexMeeting(folder)
        let writer = agent ?? config.config.meetings.summaryAgent
        memory?.meetingSummaryWritten(folder, agent: writer)
    }

    private func memorySawAutomation(_ id: String, answer: String, agent: String) {
        let automation = automations?.store.automations.first { $0.id == id }
        memory?.automationFinished(id: id, name: automation?.name ?? id, answer: answer, agent: agent, quiet: automation?.action.quietReplies ?? [])
    }

    /// Registers this app as the local client, or refreshes its capabilities. They are the platform's real adapters, plus the desktop tools
    /// once those exist. Screen capture and desktop control start after launch, so this runs again when each one attaches.
    private func registerLocalClient() {
        clients.registerLocal(name: Host.current().localizedName ?? "This Mac", kind: .mac, platform: platform,
                              extra: desktop == nil ? [] : [.desktop])
    }

    /// Builds screen capture on the shared database and applies the switch. With the switch off nothing starts.
    private func setUpScreenCapture(_ database: Database) {
        let captureStore = CaptureStore(database: database)
        CaptureStore.restrictPermissions(of: database)
        var dependencies = CaptureService.Dependencies()
        // An automated run must not raise the macOS Accessibility prompt or read the real screen.
        if TestControl.isEnabled {
            dependencies.requestAccessibility = { false }
            dependencies.requestScreenRecording = { false }
            dependencies.makeSource = { IdleCaptureSource() }
        }
        let service = CaptureService(store: captureStore, config: { ConfigStore.shared.config.screenCapture }, dependencies: dependencies)
        capture = service
        platform.capture = service
        api.attach(capture: platform.capture)
        registerLocalClient()
        settingsModel.capture = api.screen
        service.refreshModel()
        service.apply()
    }

    /// Builds the desktop tools on the capture privacy rules. They do nothing until the user turns Desktop control on.
    private func setUpDesktopControl() {
        guard let capture else { return }
        let approvals = DesktopApprovals(present: { [weak self] request, decide in
            self?.announcer.automation(AutomationNotice(
                id: Self.desktopApprovalID(request), symbol: SharedSymbols.approval, tint: .warn, title: request.title,
                subtitle: "An agent wants to act on your Mac.", body: request.detail,
                buttons: [.init(title: "Approve", primary: true) { decide(true) }, .init(title: "Reject", destructive: true) { decide(false) }],
                systemNotification: true, macOnly: true))
        }, dismiss: { [weak self] request in self?.announcer.bubbles.dismiss(Self.desktopApprovalID(request)) })
        desktopApprovals = approvals
        var dependencies = DesktopService.Dependencies(privacy: capture.privacy)
        dependencies.ax = LiveDesktopAX()
        dependencies.opener = LiveDesktopOpener()
        // An automated run must not read or operate the real screen.
        if TestControl.isEnabled {
            dependencies.ax = IdleDesktopAX()
            dependencies.opener = IdleDesktopOpener()
        }
        dependencies.enabled = { ConfigStore.shared.config.desktopControl.enabled }
        dependencies.approve = { request in await approvals.ask(request) }
        dependencies.record = { [weak self] record in
            DispatchQueue.main.async { self?.activity?.record(.desktopAction(record)) }
        }
        let service = DesktopService(dependencies)
        desktop = service
        api.attach(desktop: service)
        registerLocalClient()
        settingsModel.desktopLog = { [weak self] in
            self?.activity?.events(in: DateInterval(start: Date().addingTimeInterval(-ActivityLog.retention), end: Date().addingTimeInterval(60)), kinds: [.desktopAction]).reversed() ?? []
        }
    }

    private static func desktopApprovalID(_ request: DesktopApproval) -> String { "desktop-approval:\(request.id.uuidString)" }

    @objc private func showScreenSection() { pet.showWindow(.screen) }

    @objc private func captureMenuAction(_ sender: NSMenuItem) {
        guard let capture else { return }
        switch sender.representedObject as? String {
        case "pause15": capture.privacy.pause(for: 15 * 60)
        case "pause60": capture.privacy.pause(for: 3600)
        case "pauseTomorrow": capture.privacy.pauseUntilTomorrow()
        case "resume": capture.privacy.resume()
        default: break
        }
        capture.refreshModel()
    }

    /// The pause controls, shown only while screen capture is on.
    private func captureMenuItem() -> NSMenuItem? {
        guard let capture, config.config.screenCapture.enabled else { return nil }
        let submenu = NSMenu()
        func add(_ title: String, _ key: String, on: Bool = false) {
            let item = NSMenuItem(title: title, action: #selector(captureMenuAction(_:)), keyEquivalent: "")
            item.representedObject = key
            item.target = self
            item.state = on ? .on : .off
            submenu.addItem(item)
        }
        if capture.privacy.isPaused() {
            add("Resume capture", "resume")
        } else {
            add("Pause for 15 minutes", "pause15")
            add("Pause for 1 hour", "pause60")
            add("Pause until tomorrow", "pauseTomorrow")
        }
        submenu.addItem(.separator())
        let captures = NSMenuItem(title: "Show captures…", action: #selector(showScreenSection), keyEquivalent: "")
        captures.target = self
        submenu.addItem(captures)
        let settings = NSMenuItem(title: "Screen settings…", action: #selector(showScreenSettings), keyEquivalent: "")
        settings.target = self
        submenu.addItem(settings)
        let state = capture.privacy.isPaused() ? "paused" : "on"
        let item = NSMenuItem(title: "Screen capture (\(state))", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// With the switch on, installs and updates the skills for the agents found on this Mac and says so in one bubble. With it off, offers instead.
    private func checkSkills() {
        let manager = SkillManager.standard
        if config.config.skills.autoUpdate { manager.updateInstalled() }
        NotificationCenter.default.post(name: .skillsChanged, object: nil)
        guard setupWindow == nil else { return }
        let pending = SkillPrompt.pending(manager.entries(), dismissed: SkillPrompt.dismissed())
        guard !pending.isEmpty else { return }
        // The switch in Settings → Skills also covers skills that are not installed yet, for the agents found on this Mac.
        if config.config.skills.autoUpdate {
            installSkills(pending)
            return
        }
        let message = SkillPrompt.message(pending)
        announcer.automation(AutomationNotice(
            id: "skill-install", symbol: "sparkles", tint: .info, title: message.title, body: message.body,
            buttons: [.init(title: message.button, primary: true) { [weak self] in self?.installSkills(pending) },
                      .init(title: "Not now") { SkillPrompt.dismiss(pending) }]))
    }

    private func installSkills(_ pending: [SkillManager.Entry]) {
        defer { NotificationCenter.default.post(name: .skillsChanged, object: nil) }
        do {
            let results = try SkillManager.standard.install(names: pending.map(\.skill.name))
            let outcomes = results.flatMap { $0.outcomes }
            let problems = outcomes.filter { $0.result == "failed" || $0.result == "skipped" }
            let linked = outcomes.filter { $0.result == "linked" || $0.result == "copied" }
            let agents = Set(linked.map { $0.agent.name }).sorted()
            var body = "Installed in ~/.agents/skills."
            if !problems.isEmpty { body = SkillInstaller.describe(problems) }
            else if !agents.isEmpty { body = "Installed for " + agents.joined(separator: ", ") + "." }
            announcer.automation(AutomationNotice(
                id: "skill-install", symbol: problems.isEmpty ? "checkmark.seal.fill" : SharedSymbols.warning,
                tint: problems.isEmpty ? .good : .warn, title: problems.isEmpty ? "Skills installed" : "Skills installed with problems",
                body: body, expires: 15))
        } catch {
            announcer.automation(AutomationNotice(id: "skill-install", symbol: SharedSymbols.warning, tint: .bad,
                                                  title: "Could not install the skills", body: error.localizedDescription, expires: 20))
        }
    }

    /// What the `memory_*` tools work on. The chat that is running names the note's source and the default project.
    private var memoryServices: MemoryMCP.Services? {
        guard memory != nil else { return nil }
        let store = EntityMemoryStore.shared
        return MemoryMCP.Services(store: store, index: store.index, screen: capture?.store,
                                  context: { [weak self] in (self?.chat.threadID, self?.chat.workspace) },
                                  jobFolder: { [weak self] id in self?.jobs?.job(id).map { URL(fileURLWithPath: $0.folder) } })
    }

    /// The tools Ghost's chat agents get: ironpet's automations, tasks, screen captures and memory, over a stdio bridge to the loopback server.
    private func registerMCPServer() {
        guard let executable = Bundle.main.executablePath else { return }
        var env: [JSON] = []
        if Paths.isIsolated { env.append(["name": "IRONPET_ROOT", "value": Paths.root.path]) }
        let entry: JSON = ["name": "ironpet", "command": executable, "args": ["mcp"], "env": env]
        ACPBackend.defaultMCPServers = { [entry] }
    }

    /// Applies settings that need more than being read at the point of use.
    private func apply(config new: Config, previous old: Config) {
        updates.apply(new.updates)
        let (newAgents, oldAgents) = (hookAgents(in: new), hookAgents(in: old))
        setHooks(installed: newAgents.filter { !oldAgents.contains($0) })
        setHooks(removed: oldAgents.filter { !newAgents.contains($0) })
        if old.integrations.trackAgents, !new.integrations.trackAgents {
            // Tracking off leaves nothing of ironpet in any agent's config, including hooks an older version left behind.
            setHooks(removed: HookInstaller.Agent.allCases.filter { installer.isInstalled($0) })
        }
        pet.setAgentsTracked(new.integrations.trackAgents)
        if new.hotkeys != old.hotkeys || new.voice.enabled != old.voice.enabled || new.meetings.enabled != old.meetings.enabled { registerHotKeys() }
        if new.telegram.enabled != old.telegram.enabled { telegram.setEnabled(new.telegram.enabled) }
        if !new.voice.enabled { chatModel.voice.cancel(); dictation.cancel(); spokenMessages.recorder.cancel() }
        if old.speech.speakReplies != .never, new.speech.speakReplies == .never { chat.speech.stop() }
        if !new.meetings.enabled { meeting.dismiss() }
        startCallMonitor()
        syncSpeechQuiet()
        if new.pet.sprite != old.pet.sprite {
            pet.reloadAtlas()
            dockIcon.update(sprite: new.pet.sprite)
        }
        if new.screenCapture != old.screenCapture { capture?.apply(new.screenCapture) }
    }

    private func registerHotKeys() {
        hotKeys = [] // Unregister first: the same combination can't be registered twice.
        let hotkeys = config.config.hotkeys
        let bindings: [(String, UInt32, () -> Void)] = [
            (hotkeys.chat, 1, { [weak self] in self?.toggleChat() }),
            (hotkeys.captureWindow, 2, { [weak self] in self?.captureScreen(region: false) }),
            (hotkeys.captureRegion, 3, { [weak self] in self?.captureScreen(region: true) }),
            (hotkeys.copyVersion, 12, { [weak self] in self?.copyVersion(nil) }),
        ]
        var failed: Set<String> = []
        for (text, id, action) in bindings where !text.isEmpty {
            guard let shortcut = Shortcut(text) else {
                failed.insert(text)
                continue
            }
            let hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: id) {
                MainActor.assumeIsolated { action() }
            }
            if hotKey.isRegistered { hotKeys.append(hotKey) } else { failed.insert(text) }
        }
        // Voice shortcut (hold to talk or press to toggle). Only registered with voice notes on, so a disabled feature owns no key.
        if let text = VoiceController.hotkey(in: config.config), let shortcut = Shortcut(text) {
            // The mode is read on every press, so flipping the switch in Settings applies to the next one.
            let hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: 4, onRelease: { [weak self] in
                MainActor.assumeIsolated {
                    self?.chatModel.voice.shortcutReleased(holdToTalk: ConfigStore.shared.config.voice.holdToTalk)
                }
            }, handler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.showActiveChat()
                    self.chatModel.voice.shortcutPressed()
                }
            })
            if hotKey.isRegistered { hotKeys.append(hotKey) } else { failed.insert(text) }
        } else if config.config.voice.enabled, !config.config.hotkeys.voice.isEmpty {
            failed.insert(config.config.hotkeys.voice)
        }
        // Dictation into the focused field of any app. Only registered with voice notes on; a press while recording stops.
        let dictationText = DictationController.hotkey(in: config.config)
        dictationFn.update(shortcut: dictationText)
        if let text = dictationText, text.lowercased() != FnDictationTrigger.configValue {
            if let shortcut = Shortcut(text) {
                let hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: 13) { [weak self] in
                    MainActor.assumeIsolated { self?.dictation.shortcutPressed() }
                }
                if hotKey.isRegistered { hotKeys.append(hotKey) } else { failed.insert(text) }
            } else {
                failed.insert(text)
            }
        }
        // Start or stop a meeting transcript. Only registered with meetings on, and unbound by default.
        if let text = MeetingController.hotkey(in: config.config) {
            if let shortcut = Shortcut(text) {
                let hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: 5) { [weak self] in
                    MainActor.assumeIsolated { self?.toggleMeeting() }
                }
                if hotKey.isRegistered { hotKeys.append(hotKey) } else { failed.insert(text) }
            } else {
                failed.insert(text)
            }
        }
        // Record a spoken message for the chat, or send what has been said so far. Only registered with voice notes on.
        if let text = SpokenMessageController.hotkey(in: config.config) {
            if let shortcut = Shortcut(text) {
                let hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: 10) { [weak self] in
                    MainActor.assumeIsolated { self?.spokenMessages.press() }
                }
                if hotKey.isRegistered { hotKeys.append(hotKey) } else { failed.insert(text) }
            } else {
                failed.insert(text)
            }
        }
        settingsModel.failedHotKeys = failed
    }

    private func unregisterHotKeys() {
        dictationFn.update(shortcut: nil)
        hotKeys = []
    }

    private func hookAgents(in config: Config) -> [HookInstaller.Agent] {
        config.integrations.activeAgents
    }

    private func setHooks(installed agents: [HookInstaller.Agent], quietly: Bool = false) {
        // A copy of the app with its own IRONPET_ROOT must not rewrite the user's real Cursor and Claude Code configs.
        guard !Paths.isIsolated else { return }
        do {
            try installer.install(agents)
        } catch {
            quietly ? NSLog("ironpet: could not refresh hooks: \(error)") : showError("Could not install agent hooks", error)
        }
    }

    private func setHooks(removed agents: [HookInstaller.Agent]) {
        guard !Paths.isIsolated else { return }
        do { try installer.uninstall(agents) } catch { showError("Could not remove agent hooks", error) }
    }

    private func showSetup() {
        let setup = SetupWindow { [weak self] choices in
            self?.setupWindow = nil
            self?.finishSetup(choices)
        }
        setupWindow = setup
        setup.show()
    }

    /// Applies the welcome window's choices. "Not now" still writes config.json so the defaults are visible.
    private func finishSetup(_ choices: SetupWindow.Choices?) {
        guard let choices else {
            if !FileManager.default.fileExists(atPath: Config.file.path) { try? config.config.save() }
            return
        }
        config.update {
            $0.pet.name = choices.name
            $0.integrations.trackAgents = choices.trackAgents
            for agent in HookInstaller.Agent.allCases { $0.integrations.setWatches(choices.trackAgents && choices.agents.contains(agent), agent) }
            $0.integrations.githubAlerts = choices.githubAlerts
        }
        // The welcome choices add the reminders and the GitHub watcher the user ticked. ironpet adds no automation on its own.
        var added: [Automation] = []
        if choices.reminders {
            let items = ["water": config.config.reminders.water, "stretch": config.config.reminders.stretch, "eyes": config.config.reminders.eyes]
            added += AutomationMigration.reminderAutomations(minutes: items.mapValues { Double($0.minutes) })
                .filter { new in !automations.store.automations.contains { $0.id == new.id } }
        } else {
            for reminder in AutomationMigration.reminders {
                try? automations.store.update(reminder.id) { $0.enabled = false }
            }
        }
        if automations.store.automations.contains(where: { $0.id == AutomationMigration.githubID }) {
            try? automations.store.update(AutomationMigration.githubID) { $0.enabled = choices.githubAlerts }
        } else if choices.githubAlerts {
            added.append(AutomationDefaults.github(enabled: true))
        }
        if !added.isEmpty { try? automations.store.replace(automations.store.automations + added) }
        if !FileManager.default.fileExists(atPath: Config.file.path) { try? config.config.save() }
        // Hooks left by an older version that the user unticked.
        setHooks(removed: HookInstaller.Agent.allCases.filter { !(choices.trackAgents && choices.agents.contains($0)) && installer.isInstalled($0) })
        if choices.launchAtLogin != LoginItem.isEnabled { LoginItem.set(choices.launchAtLogin) }
        Task { await chat.refreshAgents() }
    }

    @objc func showSettings(_ sender: Any?) {
        showSettings(tab: nil)
    }

    /// Opens the Settings window, on `tab` when given, else on the last tab shown.
    func showSettings(tab: String?) {
        if let tab { settingsModel.tab = tab }
        if !pet.isChatVisible { pet.closeWindow() }
        settingsWindow.show()
    }

    @objc private func showScreenSettings() { showSettings(tab: "screen") }

    @objc private func showAutomationSettings(_ sender: Any?) {
        pet.showWindow(.automations)
    }

    func applicationWillTerminate(_ notification: Notification) {
        spokenMessages.recorder.cancel()
        meeting.prepareForQuit()
        agentPets?.stop()
        supervisor?.stopAll()
        chat.persistForRelaunch()
        chat.shutdown()
        jobs?.shutdownAll()
        automations?.stop()
        try? FileManager.default.removeItem(at: Paths.portFile)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        pet.show()
        return false
    }

    /// `ironpet://<id>` opens the record the id names. Other links, such as the pairing link for the phone, are not for the Mac.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let id = RecordLinks.id(from: url) else { continue }
            guard let records = api.records else { return }
            switch records.resolve(id) {
            case .success(let found):
                openRecord(found)
            case .failure(let error):
                showError("Could not open \(id)", error)
            }
        }
    }

    /// Shows a record in the section that owns it. A record with no page of its own opens the nearest one.
    private func openRecord(_ found: RecordResolver.Found) {
        switch found.kind {
        case .job:
            openJob(found.key)
        case .auto, .run:
            pet.showWindow(.automations)
        case .notif:
            pet.openNotification(found.key)
        case .meeting:
            pet.windowModel.focusMeeting = found.key
            pet.showWindow(.transcripts)
        case .chat:
            pet.onOpenThread?(found.key)
        case .msg:
            // A message opens its thread; the message itself is not scrolled to yet.
            pet.onOpenThread?(String(found.key.prefix { $0 != "/" }))
        case .screen:
            pet.showWindow(.screen)
        case .page, .claim:
            pet.showWindow(.memory)
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        hookMenuItems().forEach(menu.addItem)
        return menu
    }

    /// Starts the self-update check. A dev build never starts Sparkle (`UpdatePolicy`). A ready update waits while an agent turn,
    /// a voice note or a meeting recording is running, and installs when they end or when the user clicks the pet's badge.
    private func startUpdates(database: Database) {
        updates.localSchemaVersion = { database.schemaVersion }
        updates.activity = { [weak self] in
            guard let self else { return UpdatePolicy.Activity() }
            return UpdatePolicy.Activity(agentTurnRunning: chat.isRunning, voiceRecording: chatModel.voice.phase == .recording,
                                         meetingRecording: [.recording, .finishing].contains(meeting.phase))
        }
        updates.onStateChange = { [weak self] in
            guard let self else { return }
            pet.view.updateReady = updates.isReady
        }
        updates.onReadyAndWaiting = { [weak self] version, busy in
            guard let self else { return }
            let name = config.config.pet.name
            announcer.automation(AutomationNotice(
                id: "update-ready", symbol: "arrow.down.circle.fill", tint: .info, title: "ironpet \(version) is ready",
                body: busy.map { "\(name) will restart to install it once \($0) is done, or now if you click Restart." }
                    ?? "\(name) restarts to install it in a moment.",
                buttons: [.init(title: "Restart now", primary: true) { [weak self] in self?.updates.installNow() },
                          .init(title: "Later") {}],
                systemNotification: true))
        }
        pet.view.onUpdateClick = { [weak self] in self?.updates.installNow() }
        settingsModel.updates = updates
        updates.start(config: config.config.updates)
    }

    @objc func checkForUpdates(_ sender: Any?) { updates.checkNow() }

    private func startServer() throws {
        try Paths.ensureRoot()
        let token = try loadToken()
        let server = EventServer(token: token) { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        if TestControl.isEnabled {
            let control = TestControl(chat: chat, actions: TestControl.Actions(
                showChat: { [weak self] in self?.showChat() },
                buildPet: { [weak self] description in self?.requestPet(description) },
                chatWindowID: { [weak self] in self?.pet.windowNumber ?? 0 },
                chatFrame: { [weak self] in
                    guard let frame = self?.pet.window.frame, let screen = NSScreen.screens.first else { return .zero }
                    return CGRect(x: frame.minX, y: screen.frame.height - frame.maxY, width: frame.width, height: frame.height)
                },
                openSession: { [weak self] id in self?.openSession(id) },
                scrollChat: { [weak self] fraction, path in
                    // The transcript is the tallest scroll view; the composer's text view has one too.
                    @MainActor func find(_ view: NSView?) -> [NSScrollView] {
                        guard let view else { return [] }
                        return (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap { find($0) }
                    }
                    let scrolls = find(self?.pet.window.contentView)
                    guard let scroll = scrolls.max(by: { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }), let doc = scroll.documentView else { return [String: Any]() }
                    let visible = scroll.contentView.bounds
                    if let fraction {
                        let maxTop = max(0, doc.bounds.height - visible.height)
                        scroll.contentView.scroll(to: NSPoint(x: visible.minX, y: maxTop * fraction))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    let now = scroll.contentView.bounds
                    let result: [String: Any] = ["top": now.minY, "bottomGap": doc.bounds.height - now.maxY, "content": doc.bounds.height, "viewport": now.height]
                    if let path {
                        if let view = self?.pet.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                        }
                    }
                    return result
                },
                showSettings: { [weak self] tab, snapshot in
                    guard let self else { return 0 }
                    // A section of the ironpet window, such as "automations", opens that window instead.
                    if let section = tab.flatMap(IronPetSection.init(rawValue:)) {
                        pet.showWindow(section)
                        if let snapshot { _ = pet.snapshotWindow(to: URL(fileURLWithPath: snapshot)) }
                        return pet.windowNumber
                    }
                    showSettings(tab: tab)
                    if let snapshot { _ = settingsWindow.snapshot(to: URL(fileURLWithPath: snapshot)) }
                    return settingsWindow.windowNumber
                },
                capture: { [weak self] region in self?.captureScreen(region: region) },
                notificationAction: { [weak self] id, allow in self?.notifier.onApprovalAction?(id, allow) },
                signals: signals,
                meeting: meeting,
                meetingFrame: { [weak self] in
                    guard let screen = NSScreen.screens.first else { return .zero }
                    let showsBubble = self?.announcer.bubbles.bubbles.contains { $0.id == Self.meetingBubbleID } == true
                    let window: NSWindow? = self?.meetingPanel.isVisible == true ? self?.meetingPanel
                        : showsBubble && self?.bubblePanel.panel.isVisible == true ? self?.bubblePanel.panel : nil
                    guard let frame = window?.frame else { return .zero }
                    return CGRect(x: frame.minX, y: screen.frame.height - frame.maxY, width: frame.width, height: frame.height)
                },
                meetingMenuTitle: { [weak self] in self?.meetingMenuItem()?.title ?? "" },
                meetingRoomMenuTitle: { [weak self] in self?.roomMenuItem()?.title ?? "" },
                meetingUI: { [weak self] in
                    ((self?.announcer.bubbles.bubbles.contains { $0.id == Self.meetingBubbleID }) == true,
                     self?.pet.view.recording == .hidden)
                },
                meetingBubble: { [weak self] show in
                    if show { self?.showMeetingBubble() } else { self?.announcer.bubbles.dismiss(Self.meetingBubbleID) }
                },
                telegram: telegram,
                simulateCall: { [weak self] app, event in self?.simulateCall(app, event) },
                callOffer: { [weak self] in
                    self?.announcer.bubbles.bubbles.first { $0.id == Self.callBubbleID }?.title ?? ""
                },
                automations: automations,
                advanceClock: { [weak self] seconds in self?.testClockOffset += seconds },
                bubbles: { [weak self] in
                    (self?.announcer.bubbles.bubbles ?? []).map {
                        ["id": $0.id, "title": $0.title, "body": $0.body ?? "", "buttons": $0.actions.map(\.title), "lines": $0.lines.map(\.text)]
                    }
                },
                pressBubbleButton: { [weak self] id, title in
                    guard let store = self?.announcer.bubbles,
                          let action = store.bubbles.first(where: { $0.id == id })?.actions.first(where: { $0.title == title }) else { return false }
                    return (try? store.actions.runAction(bubble: id, action: action.id)) != nil
                }
            ))
            control.onMeetingSummaryText = { [weak self] text, meeting in self?.suggestTasks(fromSummary: text, meeting: meeting) }
            control.screen = capture
            control.tasks = taskStore
            control.remote = remote
            control.clients = clients
            control.chatModel = chatModel
            control.welcomeBack = welcomeBack
            control.setIdleSeconds = { [weak self] seconds in self?.awayPresence.idleOverride = seconds }
            control.showInspector = { [weak self] in
                self?.pet.showWindow(.screen)
                return self?.pet.windowNumber ?? 0
            }
            control.buildBrief = { [weak self] kind in
                let weekdays = self?.automations.store.automations.first { $0.action.digest == kind.rawValue }?.trigger.weekdays
                return self?.brief?.brief(BriefRequest(kind: kind, weekdays: kind == .brief ? weekdays : nil))
            }
            control.windowState = { [weak self] in self?.pet.windowState ?? [:] }
            control.openBrief = { [weak self] target in self?.pet.openBrief(target) }
            control.spokenMessages = spokenMessages
            control.jobs = { [weak self] in self?.jobs }
            control.memory = memory
            control.memorySettings = settingsModel.memory
            testControl = control
            server.onTest = { request, respond in
                DispatchQueue.main.async { respond(control.handle(request)) }
            }
            NSLog("ironpet: test mode enabled")
        }
        let snapshot = StatusSnapshot()
        server.status = { snapshot.data }
        pet.onRefresh = { [weak self] mood in
            guard let self else { return }
            let service = self.automations
            snapshot.update(store: self.store, mood: mood, automations: (service?.store.automations ?? []).map { a in
                var entry = service!.summary(a)
                entry["recentRuns"] = service!.history(a.id, limit: 5)
                return entry
            })
        }
        server.onAgentAPI = { [weak self] request, respond in
            MCPEndpoint.route(request, automations: { self?.api?.automations }, tasks: { self?.api?.tasks }, screen: { self?.api?.screen },
                              desktop: { self?.api?.desktop }, memory: { self?.api?.memory }, assistant: { self?.api?.assistant },
                              notifications: { self?.api?.notifications }, records: { self?.api?.records }, agentRecords: { self?.api?.agentRecords },
                              chat: { self?.api?.chat }, dashboards: { self?.api?.dashboards }, respond: respond)
        }
        try server.start()
        self.server = server
        registerMCPServer()
        try String(server.port).write(to: Paths.portFile, atomically: true, encoding: .utf8)
        NSLog("ironpet: listening on 127.0.0.1:\(server.port)")
    }

    private func handle(_ event: HookEvent) {
        // With tracking off, a hook that is still installed (an agent started before the hooks were removed) is ignored.
        guard config.config.integrations.trackAgents else { return }
        // Cursor replays its events through Claude Code hooks too; keep only the Cursor copy.
        if event.source == .claude, event.payload["cursor_version"] != nil { return }
        store.apply(event)
    }

    private func loadToken() throws -> String {
        if let existing = try? String(contentsOf: Paths.tokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), existing.count >= 32 {
            return existing
        }
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        try token.write(to: Paths.tokenFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.tokenFile.path)
        return token
    }

    private func toggleChat() {
        pet.isChatVisible && pet.window.isKeyWindow && NSApp.isActive ? pet.closeWindow() : showChat()
    }

    /// Opening the chat never changes its session or folder. Only the user does, with New Chat, the folder picker,
    /// a saved thread or the agent switch.
    func showChat() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
            // Read before ironpet activates, so focus has not left the other app. No selection clears any previous chip.
            chatModel.attachedSelection = FrontSelectionReader.read(from: front)
        }
        pet.showWindow(.chat)
    }

    /// The Chat section came on screen (the hotkey, a click on Ghost, the sidebar) or left it.
    private func chatShown(_ shown: Bool) {
        guard shown else {
            wispr.stop()
            chat.isVisible = false
            pet.refreshMood()
            return
        }
        chat.prepareForShow()
        chat.isVisible = true
        wispr.start()
        pet.refreshMood()
        pet.window.focusInput()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, pet.isChatVisible else { return }
            // Cooperative activation can be refused for a background app; force it so Wispr Flow
            // sees ironpet as the frontmost app.
            if !NSApp.isActive { NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps]) }
            pet.window.makeKeyAndOrderFront(nil)
            pet.window.focusInput()
        }
    }

    /// Captures the front window (or a dragged region) before ironpet activates, then opens the chat with it.
    private func captureScreen(region: Bool) {
        guard ScreenCapture.hasPermission else {
            ScreenCapture.requestPermission()
            announcer.chat("Allow Screen Recording for ironpet, then try again",
                           detail: "System Settings → Privacy & Security → Screen Recording.")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        let target = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previousApp : front
        if pet.isWindowVisible { pet.window.orderOut(nil) }
        pet.isCapturing = true
        Task { @MainActor in
            defer { pet.isCapturing = false }
            let shot = region ? await ScreenCapture.captureRegion() : await ScreenCapture.captureWindow(of: target)
            if let shot { chatModel.attach(shot) }
            if shot != nil || chat.isVisible { showChat() }
        }
    }

    /// Hands focus back to the app the user was in before opening the chat.
    private func restorePreviousApp() {
        if NSApp.isActive { previousApp?.activate() }
        previousApp = nil
    }

    func openSession(_ id: String) {
        guard let session = store.sessions[id] else { return }
        pet.jump(to: session)
    }

    /// Sends `prompt` to the agent in the current chat and folder. Without `show`, the chat stays hidden and Ghost says when the agent
    /// needs something. When the chat is busy with a turn or an approval, nothing is replaced: a bubble offers to send it.
    func sendToChat(_ prompt: String, show: Bool, title: String, busyBody: String) {
        if chat.isRunning || !chat.approvals.isEmpty {
            announcer.automation(AutomationNotice(
                id: "automation-chat:\(title)", symbol: "wrench.and.screwdriver.fill", tint: .warn, title: title, body: busyBody,
                buttons: [.init(title: "Send", primary: true) { [weak self] in self?.sendToChat(prompt, show: true, title: title, busyBody: busyBody) },
                          .init(title: "Not now") {}]))
            return
        }
        let sent = sendInCurrentChat(prompt)
        // Without a folder the prompt waits in the input, so show the chat for the user to pick one.
        if show || !sent { showChat() } else {
            announcer.automation(AutomationNotice(
                id: "automation-chat:\(title)", symbol: "wrench.and.screwdriver.fill", tint: .info, title: title,
                body: "Asked \(chat.agent.name) to fix it.", buttons: [.init(title: "Open chat", primary: true) { [weak self] in self?.showChat() }], expires: 20))
        }
    }

    /// "Ask Ghost": opens the chat in the current session and folder with the prompt ready to send. A draft the user
    /// was typing stays below the prompt, separated by a blank line.
    func ask(_ prompt: String) {
        showChat()
        let draft = chatModel.input.trimmingCharacters(in: .whitespacesAndNewlines)
        // A second press on the same Ask leaves the input as it is.
        if draft.hasPrefix(prompt) { return }
        chatModel.prefill(draft.isEmpty ? prompt : prompt + "\n\n" + draft)
    }

    /// Sends `prompt` in the current session and folder. A draft the user was typing and any attachments come back
    /// after the send. If the send does not go through (no folder chosen yet), the prompt waits in the input above
    /// the draft, and prefill keeps the dictation auto-send from firing on it.
    @discardableResult
    private func sendInCurrentChat(_ prompt: String) -> Bool {
        // The prompt goes in as its own message, so the draft and its attachments are never touched when it is taken.
        switch chat.submitLocal(prompt, files: [], reply: nil) {
        case .sent, .queued, .toJob:
            return true
        case .needsFolder, .ignored:
            let draft = chatModel.input
            chatModel.prefill(draft.isEmpty ? prompt : prompt + "\n\n" + draft)
            return false
        }
    }

    /// "Build a new pet": opens the chat and sends the request in the current thread. The session and folder stay as
    /// they are. A draft the user was typing comes back after the send. While the agent is running, or before a folder
    /// is chosen, the request waits in the input box instead.
    private func requestPet(_ description: String) {
        showChat()
        PetPrompt.ensureSkillInstalled()
        sendInCurrentChat(PetPrompt.build(description: description))
    }

    // MARK: Meetings

    /// Shows the panel while a meeting is being set up, recorded or wrapped up, and hides it otherwise.
    ///
    /// The picker is a small window. Once recording starts, the status lives in a pet bubble. The user can hide that
    /// bubble, and the pet then shows a Recording button that brings it back.
    /// Offers the action items from a meeting summary as tasks: the user's own, and the ones they wait on from others. The
    /// text stays data: it is stored as suggestions and shown, never sent to an agent.
    private func suggestTasks(fromSummary text: String, meeting: URL) {
        offerTasks(ActionItems.suggestions(text), meeting: meeting)
    }

    private func offerTasks(_ items: [(title: String, due: String?, waitingOn: String?)], meeting: URL) {
        guard config.config.tasks.meetingSuggestions, let tasks = taskStore, !items.isEmpty else { return }
        offerSuggestions(tasks.suggest(items, meeting: meeting))
    }

    /// One info bubble for suggestions that just arrived, from a meeting, a watcher or screen capture. They wait in the Inbox
    /// until the user or an agent marks them done or removes them.
    /// `bubble` overrides the switch the origin implies, for the scan, which has its own.
    private func offerSuggestions(_ added: [TaskSuggestion], bubble: Bool? = nil) {
        guard !added.isEmpty else { return }
        for suggestion in added { activity?.record(.taskSuggested(suggestion)) }
        announcer.taskSuggestions(added, review: { [weak self] in self?.showTasks() },
                                  bubble: bubble ?? Self.showsSuggestionBubble(for: added, config: config.config))
    }

    /// A meeting's bubble follows its own switch. Suggestions from an automation always get theirs.
    static func showsSuggestionBubble(for added: [TaskSuggestion], config: Config) -> Bool {
        guard let first = added.first else { return false }
        if case .meeting = first.origin { return config.tasks.meetingSuggestionBubbles }
        return true
    }

    private func showTasks() {
        pet.showWindow(.inbox)
    }

    /// Sums up what happened when the user comes back after being away. Samples the idle time every 2 s, because the
    /// automation clock's 30 s tick would leave the user waiting for the summary.
    private func setUpWelcomeBack(_ log: ActivityLog, tasks: TaskStore) {
        var env = WelcomeBack.Environment()
        env.presence = SessionPresence(registry: clients, local: awayPresence)
        let presence = Presence(
            meetingActive: { [weak self] in self.map { [.recording, .finishing, .summarizing].contains($0.meeting.phase) } ?? false },
            detectedCalls: { [weak self] in self?.callMonitor.flatMap { $0.isRunning ? $0.detector.activeApps : nil } },
            micCalls: awayPresence.micCalls)
        env.isPresent = presence.isPresent
        env.presenceNotNeeded = awayPresence.stopMicWatch
        env.isEnabled = { ConfigStore.shared.config.welcomeBack.enabled }
        env.threshold = { ConfigStore.shared.config.reminders.idleResetMinutes * 60 }
        let welcome = WelcomeBack(log: log, bubbles: announcer.bubbles, env: env)
        welcome.live = { [weak self, tasks] in
            guard let self else { return .init() }
            return WelcomeBack.liveState(sessions: Array(store.sessions.values), signals: signals.signals,
                                         suggestions: tasks.suggestions, now: Date())
        }
        welcome.show = { [weak self] digest, away in
            self?.announcer.welcomeBack(digest, away: away, open: { self?.open($0) }, showAll: { self?.pet.showWindow(nil) })
        }
        welcomeBack = welcome
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak welcome] _ in
            MainActor.assumeIsolated { welcome?.tick() }
        })
    }

    /// A line of a summary bubble. A session that has ended since is opened from what the activity log kept about it.
    private func open(_ target: ActivityDigest.Target) {
        switch target {
        case .session(let id, let workspace, let app, let iterm):
            if store.sessions[id] != nil { return openSession(id) }
            if let job = Job.id(fromSessionKey: id) { return openJob(job) }
            guard let source = AgentSource(rawValue: String(id.prefix { $0 != ":" })) else { return pet.showWindow(.agents) }
            var session = AgentSession(id: id, source: source)
            session.origin = SessionOrigin(workspace: workspace, itermSessionID: iterm, ownerBundleID: app)
            SourceJumper.jump(to: session)
        case .agents: pet.showWindow(.agents)
        case .alerts: pet.showWindow(.alerts)
        case .tasks: showTasks()
        case .automations: pet.showWindow(.automations)
        case .chat: showChat()
        case .url(let url), .file(let url): NSWorkspace.shared.open(url)
        }
    }

    private func syncMeetingPanel() {
        let bubbles = announcer.bubbles
        switch meeting.phase {
        case .idle:
            meetingPanel.dismiss()
            meetingBubbleHidden = false
            removeMeetingBubble()
        case .choosing:
            meetingBubbleHidden = false
            removeMeetingBubble()
            meetingPanel.present(near: pet.panel.frame)
        default:
            meetingPanel.dismiss()
            if !meetingBubbleHidden, !bubbles.bubbles.contains(where: { $0.id == Self.meetingBubbleID }) {
                bubbles.show(BubbleDraft(id: Self.meetingBubbleID, symbol: "record.circle", tint: .red, title: "Meeting",
                                         contentKind: .meeting))
            }
        }
        pet.setRecording(meeting.phase == .recording || meeting.phase == .finishing || meeting.phase == .summarizing
                         ? (meetingBubbleHidden ? .hidden : .shown) : .none)
        pet.refreshMood()
    }

    static let meetingBubbleID = "meeting"
    static let callBubbleID = "meeting-call"

    // MARK: Call detection

    /// The first poll answers empty, so polling starts when spoken replies are turned on rather than when a reply ends.
    /// While the meeting call monitor runs, it answers instead and this watch stays off.
    private func syncSpeechQuiet() {
        // Automatic speaks only after a spoken message, which needs voice notes. Without them, polling would run for everyone by default.
        let speaks = config.config.speech.speakReplies == .always || (config.config.speech.speakReplies == .automatic && config.config.voice.enabled)
        if speaks, callMonitor?.isRunning != true { _ = speechMic.calls() } else { speechMic.stop() }
    }

    /// Watches the microphone while meetings and call offers are on, and stops otherwise.
    private func startCallMonitor() {
        let meetings = config.config.meetings
        let on = meetings.enabled && meetings.offerToRecordCalls
        if on, callMonitor == nil {
            let detector = CallDetector(source: { [] }, ignored: { ConfigStore.shared.config.meetings.ignoredMicApps })
            detector.onStarted = { [weak self] app in self?.callEvent(app, started: true) }
            detector.onEnded = { [weak self] app in self?.callEvent(app, started: false) }
            callMonitor = CallMonitor(detector: detector)
        }
        if on { callMonitor?.start() } else {
            callMonitor?.stop()
            announcer.bubbles.dismiss(Self.callBubbleID)
        }
    }

    private func callEvent(_ app: String, started: Bool) {
        let action = started ? callPrompt.callStarted(app) : callPrompt.callEnded(app)
        if !started, case .none = action { announcer.bubbles.dismiss(Self.callBubbleID) }
        switch action {
        case .offerRecord(let id): showCallBubble(id, stop: false)
        case .offerStop(let id): showCallBubble(id, stop: true)
        case nil: break
        }
    }

    private func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }?.localizedName
            ?? (bundleID == "net.whatsapp.WhatsApp" ? "WhatsApp" : bundleID)
    }

    private func showCallBubble(_ bundleID: String, stop: Bool) {
        let name = appName(bundleID)
        let close: () -> Void = { [weak self] in self?.announcer.bubbles.dismiss(Self.callBubbleID) }
        let actions: [BubbleDraft.Button] = stop
            ? [.init("stop", "Stop recording", style: .primary) { [weak self] in
                    self?.meeting.stop()
                    close()
                },
               .init("keep", "Keep recording") { close() }]
            : CallOffer.recordActions(
                bundleID: bundleID, name: name, ignore: micIgnore,
                record: { [weak self] in self?.recordCall(bundleID, name: name) },
                notNow: { [weak self] in self?.callPrompt.notNow(bundleID) },
                close: close)
        announcer.bubbles.show(BubbleDraft(id: Self.callBubbleID, symbol: "phone.fill", tint: .red,
                                      title: stop ? "Call ended. Stop recording?" : "Looks like a call in \(name). Record it?",
                                      actions: actions))
    }

    /// Opens the picker with the call's app chosen and starts, like the user pressing Start there.
    private func recordCall(_ bundleID: String, name: String) {
        guard meeting.phase == .idle || meeting.phase == .done else { return }
        meeting.showPicker()
        guard meeting.phase == .choosing else { return }
        callPrompt.accepted(bundleID)
        meeting.choice = .app(AudioApp(bundleID: bundleID, name: name))
        meeting.start()
    }

    private func simulateCall(_ bundleID: String, _ event: String) {
        switch event {
        case "record": recordCall(bundleID, name: appName(bundleID))
        case "not-now":
            callPrompt.notNow(bundleID)
            announcer.bubbles.dismiss(Self.callBubbleID)
        case "ended": callEvent(bundleID, started: false)
        default: callEvent(bundleID, started: true)
        }
    }

    private func removeMeetingBubble() {
        meetingBubbleRemoving = true
        announcer.bubbles.dismiss(Self.meetingBubbleID)
        meetingBubbleRemoving = false
    }

    /// The user closed the meeting bubble. Closing "Meeting saved" ends the meeting view; closing it while recording
    /// only hides it, and the pet's Recording button shows it again.
    private func meetingBubbleClosed(_ id: String) {
        guard id == Self.meetingBubbleID, !meetingBubbleRemoving else { return }
        if meeting.phase == .done {
            meeting.dismiss()
        } else {
            meetingBubbleHidden = true
            syncMeetingPanel()
        }
    }

    private func showMeetingBubble() {
        meetingBubbleHidden = false
        syncMeetingPanel()
    }

    private func toggleMeeting() {
        if meeting.phase == .recording {
            meeting.stop()
        } else {
            meeting.showPicker()
        }
    }

    @objc private func startMeeting(_ sender: Any?) {
        meeting.showPicker()
    }

    /// Opens the picker with Room chosen. The user still presses Start recording.
    @objc private func startRoomMeeting(_ sender: Any?) {
        meeting.showPicker()
        guard meeting.phase == .choosing else { return }
        meeting.choice = .room
    }

    @objc private func stopMeeting(_ sender: Any?) {
        meeting.stop()
    }

    private func roomMenuItem() -> NSMenuItem? {
        guard config.config.meetings.enabled, meeting.phase != .recording else { return nil }
        let item = NSMenuItem(title: "Record meeting in the room", action: #selector(startRoomMeeting), keyEquivalent: "")
        item.target = self
        item.isEnabled = !meeting.isBusy
        return item
    }

    private func meetingMenuItem() -> NSMenuItem? {
        guard config.config.meetings.enabled else { return nil }
        if meeting.phase == .recording {
            let item = NSMenuItem(title: "Stop meeting transcript", action: #selector(stopMeeting), keyEquivalent: "")
            item.target = self
            return item
        }
        let item = NSMenuItem(title: "Start meeting transcript…", action: #selector(startMeeting), keyEquivalent: "")
        item.target = self
        item.isEnabled = !meeting.isBusy
        return item
    }

    /// Adds the transcript, and the summary if there is one, to the current chat. Never changes the chat's
    /// session or folder.
    private func openMeetingInChat(_ files: [URL]) {
        chatModel.attach(files)
        showChat()
    }

    func hookMenuItems() -> [NSMenuItem] {
        let system = NSMenuItem(title: "Also show macOS notifications", action: #selector(toggleSystemNotifications), keyEquivalent: "")
        system.state = announcer.alsoSystemNotifications ? .on : .off
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.state = LoginItem.isEnabled ? .on : .off
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        for item in [system, login, settings] { item.target = self }
        return [meetingMenuItem(), roomMenuItem(), captureMenuItem(), settings, automationsMenuItem(), integrationsMenuItem(), system, login]
            .compactMap { $0 } + versionMenuItems()
    }

    private static let appVersion = AppVersion(info: Bundle.main.infoDictionary)

    /// A disabled line with the version, then "Copy version" with its shortcut, if one is set.
    private func versionMenuItems() -> [NSMenuItem] {
        let line = NSMenuItem(title: Self.appVersion.label, action: nil, keyEquivalent: "")
        line.isEnabled = false
        let shortcut = Shortcut.display(config.config.hotkeys.copyVersion)
        let copy = NSMenuItem(title: shortcut.map { "Copy version  \($0)" } ?? "Copy version", action: #selector(copyVersion(_:)), keyEquivalent: "")
        copy.target = self
        let check = NSMenuItem(title: "Check for updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        check.target = self
        check.isEnabled = updates.canCheck
        return [.separator(), line, copy, check]
    }

    @objc func copyVersion(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.appVersion.copyText, forType: .string)
    }

    @objc private func showAbout(_ sender: Any?) {
        let version = Self.appVersion
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "ironpet",
            .applicationVersion: version.isDev ? "\(version.version) dev" : version.version,
        ]
        if let build = version.build { options[.version] = build }
        if let commit = version.commit {
            options[.credits] = NSAttributedString(string: "Commit \(commit)", attributes: [.font: NSFont.systemFont(ofSize: 11)])
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    private func integrationsMenuItem() -> NSMenuItem {
        let config = config.config.integrations
        let mcp = NSMenuItem(title: "Share MCP sign-ins across folders…", action: #selector(toggleMCPSharing), keyEquivalent: "")
        mcp.state = config.shareMCPSignIns ? .on : .off
        let submenu = NSMenu()
        for item in [mcp] {
            item.target = self
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Integrations", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// Every automation with a switch.
    private func automationsMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        for a in automations.store.automations {
            let item = NSMenuItem(title: a.name, action: #selector(toggleAutomation(_:)), keyEquivalent: "")
            item.representedObject = a.id
            item.state = a.enabled ? .on : .off
            item.target = self
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let logs = NSMenuItem(title: "Show logs…", action: #selector(showAutomationLogs), keyEquivalent: "")
        logs.target = self
        submenu.addItem(logs)
        let more = NSMenuItem(title: "Edit automations…", action: #selector(showAutomationSettings(_:)), keyEquivalent: "")
        more.target = self
        submenu.addItem(more)
        let item = NSMenuItem(title: "Automations", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func showAutomationLogs() {
        pet.closeWindow()
        logWindow.show()
    }

    @objc private func toggleAutomation(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        try? automations.store.update(id) { $0.enabled.toggle() }
    }

    @objc private func toggleMCPSharing() {
        if !config.config.integrations.shareMCPSignIns, !IntegrationsSettings.confirmMCPSharing() { return }
        config.update { $0.integrations.shareMCPSignIns.toggle() }
    }

    @objc private func toggleSystemNotifications() {
        announcer.alsoSystemNotifications.toggle()
    }

    @objc private func toggleLoginItem() {
        LoginItem.set(!LoginItem.isEnabled)
    }

    private func showError(_ title: String, _ error: Error) {
        NSLog("ironpet: \(title): \(error)")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    /// Edit > Paste. Large text and images in the chat become attachments; everything else goes to the first responder.
    @objc func paste(_ sender: Any?) {
        if let window = NSApp.keyWindow as? IronPetPanel, window.attachPaste() { return }
        NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSText.paste(_:)), with: sender)
    }

    @objc func pasteAsPlainText(_ sender: Any?) {
        if let window = NSApp.keyWindow as? IronPetPanel, window.attachPaste() { return }
        NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSTextView.pasteAsPlainText(_:)), with: sender)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let about = NSMenuItem(title: "About IronPet", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        let copy = NSMenuItem(title: "Copy version", action: #selector(copyVersion(_:)), keyEquivalent: "")
        copy.target = self
        appMenu.addItem(about)
        appMenu.addItem(copy)
        let check = NSMenuItem(title: "Check for updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        check.target = self
        appMenu.addItem(check)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit ironpet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        let edit = Self.editItems()
        // The selector is the same as NSText's `paste:`, so without an explicit target the text view would win.
        for item in edit where item.action == #selector(AppDelegate.paste(_:)) || item.action == #selector(AppDelegate.pasteAsPlainText(_:)) {
            item.target = self
        }
        main.addItem(submenu("Edit", edit))
        let newChat = NSMenuItem(title: "New Chat", action: #selector(newChat(_:)), keyEquivalent: "n")
        newChat.target = self
        main.addItem(submenu("Chat", [newChat]))
        // performClose(_:) beeps on the ironpet window, which has no .closable style, so close the key window directly.
        let close = NSMenuItem(title: "Close", action: #selector(closeKeyWindow(_:)), keyEquivalent: "w")
        close.target = self
        main.addItem(submenu("Window", [close]))
        return main
    }

    /// Key equivalents reach a text field only through the main menu, so without these items ⌘Z, ⌘X, ⌘C,
    /// ⌘A and friends did nothing in the chat. The actions go to the first responder. AppKit adds
    /// "Start Dictation" and "Emoji & Symbols" to a menu titled "Edit" by itself.
    private static func editItems() -> [NSMenuItem] {
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        return [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(AppDelegate.paste(_:)), "v"),
            item("Paste and Match Style", #selector(AppDelegate.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Delete", #selector(NSText.delete(_:)), ""),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func closeKeyWindow(_ sender: Any?) {
        NSApp.keyWindow?.close()
    }

    @objc private func newChat(_ sender: Any?) {
        chat.newChat(reason: "menu New chat")
        showChat()
    }
}
