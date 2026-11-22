import Foundation

/// The in-process API every client uses: the ironpet window and its views, the MCP endpoint, the `IronPet` CLI, Telegram, and
/// later a remote client. It is the only code that reads or writes the app's stores.
///
/// Conventions, for every area that moves behind it:
/// - One namespace per area, a property on this type (`api.tasks`), that holds the stores it serves and nothing else holds them
///   for a client.
/// - A call takes a `Codable` request value and returns a `Codable` response value, or throws `APIError`. No call returns a
///   store type, an `NSImage` or a closure, so the same call can later cross a network.
/// - Every change a client needs to see is published on `events` by the store that made it.
/// - Views read state through the API and observe the same stores they always did for redraws, but they never call a store.
///   `BoundaryTests` fails when a client file names a store type.
@MainActor
package final class IronPetAPI {
    /// The stores the API serves. Only `IronPetAPI` and the AppKit owners that create them hold these.
    package struct Stores {
        package init(
            tasks: TaskStore,
            automations: AutomationService,
            signals: SignalStore,
            bubbles: BubbleStore,
            notifications: NotificationStore,
            sessions: SessionStore,
            chat: ChatSession,
            meeting: MeetingRecorder,
            meetingLibrary: MeetingLibrary,
            config: ConfigStore,
            speech: SpeechOutput,
            petAssets: PetAssets = UnsupportedPetAssets(),
            files: FileIntake = FolderFileIntake(directory: Paths.attachments),
            usage: UsageStore? = nil,
            permissions: BackgroundPermissions? = nil
        ) {
            self.tasks = tasks
            self.automations = automations
            self.signals = signals
            self.bubbles = bubbles
            self.notifications = notifications
            self.sessions = sessions
            self.chat = chat
            self.meeting = meeting
            self.meetingLibrary = meetingLibrary
            self.config = config
            self.speech = speech
            self.petAssets = petAssets
            self.files = files
            self.usage = usage
            self.permissions = permissions
        }

        package var tasks: TaskStore
        package var automations: AutomationService
        package var signals: SignalStore
        package var bubbles: BubbleStore
        package var notifications: NotificationStore
        package var sessions: SessionStore
        package var chat: ChatSession
        package var meeting: MeetingRecorder
        package var meetingLibrary: MeetingLibrary
        package var config: ConfigStore
        /// The speaker that reads replies aloud.
        package var speech: SpeechOutput
        /// Where pet sheets and background images live. The Mac target passes its own folders.
        package var petAssets: PetAssets = UnsupportedPetAssets()
        /// Where files a client attaches to the chat land.
        package var files: FileIntake = FolderFileIntake(directory: Paths.attachments)
        package var usage: UsageStore?
        /// Where permission requests from jobs and automation sessions wait for an answer.
        package var permissions: BackgroundPermissions?
    }

    package let events: APIEventBus
    package let tasks: TasksAPI
    package let automations: AutomationsAPI
    package let alerts: AlertsAPI
    package let bubbles: BubblesAPI
    package let notifications: NotificationsAPI
    package let agents: AgentsAPI
    package let chat: ChatAPI
    package let meetings: MeetingsAPI
    package let settings: SettingsAPI
    package let voice: VoiceAPI
    package let today: TodayAPI
    package private(set) var usage: UsageAPI?
    /// Set once screen capture, desktop control and the assistant tools exist. Until then a client gets `unavailable`.
    package private(set) var screen: ScreenAPI?
    package private(set) var desktop: DesktopAPI?
    package private(set) var assistant: AssistantAPI?
    package private(set) var memory: MemoryAPI?
    package let pet: PetAPI
    /// The clients connected now, and the handshake that opens a session.
    package let session: SessionAPI
    package var clients: ClientRegistry { session.clients }

    package init(stores: Stores, events: APIEventBus? = nil, clients: ClientRegistry? = nil) {
        let events = events ?? APIEventBus()
        self.events = events
        let registry = clients ?? ClientRegistry()
        var served: () -> [String] = { [] }
        session = SessionAPI(clients: registry, events: events) { served() }
        stores.tasks.events = events
        stores.automations.store.events = events
        tasks = TasksAPI(store: stores.tasks)
        automations = AutomationsAPI(service: stores.automations)
        stores.signals.events = events
        stores.bubbles.events = events
        alerts = AlertsAPI(store: stores.signals)
        bubbles = BubblesAPI(store: stores.bubbles)
        stores.notifications.events = events
        notifications = NotificationsAPI(store: stores.notifications)
        stores.sessions.events = events
        agents = AgentsAPI(store: stores.sessions)
        stores.chat.events = events
        chat = ChatAPI(session: stores.chat, files: stores.files)
        chat.background = stores.permissions
        alerts.permissions = stores.permissions
        stores.meeting.events = events
        stores.meetingLibrary.events = events
        stores.config.events = events
        settings = SettingsAPI(store: stores.config)
        pet = PetAPI(settings: settings, assets: stores.petAssets)
        voice = VoiceAPI(speech: stores.speech, settings: settings)
        pet.events = events
        today = TodayAPI(tasks: tasks, sessions: stores.sessions, signals: stores.signals)
        if let usageStore = stores.usage {
            usage = UsageAPI(store: usageStore)
            if usageStore === UsageStore.shared { UsageAPI.live = usage }
        }
        if stores.config === ConfigStore.shared { PetAPI.live = pet }
        // Tests build their own API over a memory-only config and must not replace the app's.
        if stores.config === ConfigStore.shared { SettingsAPI.live = settings }
        meetings = MeetingsAPI(recorder: stores.meeting, library: stores.meetingLibrary)
        served = { [unowned self] in self.servedFacades }
    }

    /// The facades `session.hello` reports: the ones a client can call now. `memory` and `screen` join once they are attached.
    private var servedFacades: [String] {
        var names = ["agents", "alerts", "automations", "bubbles", "chat", "meetings", "notifications", "session", "settings", "tasks", "today"]
        if memory != nil { names.append("memory") }
        if screen != nil { names.append("screen") }
        return names.sorted()
    }

    package func attach(capture control: CaptureControl) { screen = ScreenAPI(control: control) }

    package func attach(desktop service: DesktopService) { desktop = DesktopAPI(service: service, settings: settings) }

    package func attach(assistant context: AssistantContext) { assistant = AssistantAPI(context: context) }

    /// `services` is asked each time a `memory_*` tool runs, since it names the chat that is open then.
    package func attach(memory services: @escaping () -> MemoryMCP.Services?) { memory = MemoryAPI(services: services) }
}
