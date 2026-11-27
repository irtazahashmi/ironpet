import AppKit
import AVFoundation
import IronPetCore
import IronPetKit
import SwiftUI

/// `--render-videos <dir> [--sprite <sheet.png>] [--sprite-b <sheet.png>] [--only <name,name>]`: short MP4 clips of ironpet at
/// work, with a JPEG poster each, for the website (`scripts/videos.sh`). Each clip is the same views as the screenshots: a real
/// ironpet window whose sample stores change step by step, or the pet drawn frame by frame with the app's own timings.
/// Nothing here reads your sessions, alerts, chats or memory. The window clips need a display, as `renderWindow` does.
@MainActor
enum PreviewVideos {
    static func run(arguments: [String]) {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil }
        }
        guard let path = value("--render-videos") else { return }
        let dir = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sprite = value("--sprite"), spriteB = value("--sprite-b")
        let only = value("--only").map { Set($0.split(separator: ",").map(String.init)) }
        var config = Config()
        config.pet.sprite = sprite
        ConfigStore.shared.usePreview(config)
        let atlas = Atlas.loadDefault(sprite: sprite)

        let clips: [(String, () -> Take)] = [
            ("pet", { petClip(atlas) }),
            ("welcome", { welcomeClip(atlas) }),
            ("multi", { multiClip(atlas, Atlas.loadDefault(sprite: spriteB)) }),
            ("agents", agentsClip),
            ("chat", chatClip),
            ("alerts", alertsClip),
            ("inbox", inboxClip),
            ("memory", memoryClip),
            ("dashboards", dashboardsClip),
        ]
        for (name, make) in clips where only?.contains(name) ?? true {
            let take = make()
            take.write(to: dir, name)
        }
    }

    // MARK: - Pet clips

    /// Ghost works, finishes, asks before running a command, then takes a water break: `pet.gif`, at full resolution.
    private static func petClip(_ atlas: Atlas?) -> Take {
        let done = doneBubble(project: "demo-app", agent: "Claude Code", body: "Edited 3 files · Fixed the flaky login test.")
        let approval = approvalBubble(pet: "Ghost", detail: "npm test -- login --runInBand")
        let water = AutomationMigration.reminders[0]
        let reminder = BubbleDraft(id: "reminder", symbol: water.symbol, tint: .cyan, title: water.title,
                                   subtitle: "Your agent is still working, good moment for it.", body: water.body,
                                   actions: [.init("done", "Done", style: .primary) {}, .init("snooze", "Snooze 10 min") {}])
        let track = [
            Segment(.running, 2.4),
            Segment(.jumping, 1.0, [done]),
            Segment(.review, 2.0, [done]),
            Segment(.waiting, 3.6, [done, approval]),
            Segment(.drinking, 4.4, [reminder]),
        ]
        let canvas = PetScene(atlas: atlas, row: .waiting, frame: 0, bubbles: [done, approval]).fittingSize
        return animate(tracks: [track]) { states in
            PetScene(atlas: atlas, row: states[0].row, frame: states[0].frame, bubbles: states[0].bubbles, canvas: canvas, solid: true)
        }
    }

    /// Ghost idles while you are away, then waves with what happened.
    private static func welcomeClip(_ atlas: Atlas?) -> Take {
        let left = Date().addingTimeInterval(-62 * 60)
        let window = DateInterval(start: left, end: Date())
        func event(_ kind: ActivityEvent.Kind, _ ref: String, _ title: String, detail: String = "", minutes: Double,
                   extra: [String: String] = [:]) -> ActivityEvent {
            ActivityEvent(at: left.addingTimeInterval(minutes * 60), kind: kind, ref: ref, title: title, detail: detail,
                          url: kind == .alertOpened ? URL(string: "https://github.com") : nil, extra: extra)
        }
        let away = [
            event(.sessionNeedsInput, "claude:1", "demo-app", minutes: 40),
            event(.alertOpened, "automation:gh:84", "Fix the login redirect", detail: "you/demo-app #84", minutes: 22, extra: ["label": "CI failed"]),
            event(.sessionDone, "codex:2", "api", minutes: 10),
            event(.sessionDone, "claude:3", "website", minutes: 30),
            event(.meetingSummary, "/m/summary.md", "2026-11-17 10-00 Standup", minutes: 50),
        ]
        let welcome = Announcer.digestBubble(ActivityDigest.build(events: away, window: window), id: WelcomeBack.bubbleID,
                                             title: "Welcome back", subtitle: Announcer.awayText(window.duration), petName: "Ghost",
                                             open: { _ in }, showAll: {})
        let track = [Segment(.idle, 2.2), Segment(.waving, 1.4, [welcome]), Segment(.idle, 4.4, [welcome])]
        let canvas = PetScene(atlas: atlas, row: .waving, frame: 0, bubbles: [welcome]).fittingSize
        return animate(tracks: [track]) { states in
            PetScene(atlas: atlas, row: states[0].row, frame: states[0].frame, bubbles: states[0].bubbles, canvas: canvas, solid: true)
        }
    }

    /// Two agents, one pet each: Ghost finishes in web-app while Bunny asks before running a command in api-server.
    private static func multiClip(_ ghost: Atlas?, _ bunny: Atlas?) -> Take {
        let done = doneBubble(project: "web-app", agent: "Ghost · Cursor", body: "Made the settings page work on mobile.")
        let approval = approvalBubble(pet: "Bunny", detail: "pnpm add express-rate-limit")
        let ghostTrack = [Segment(.running, 3.4), Segment(.jumping, 1.0, [done]), Segment(.idle, 3.6, [done])]
        let bunnyTrack = [Segment(.running, 1.6), Segment(.waiting, 6.4, [approval])]
        let canvas = PetScene(atlas: ghost, row: .waiting, frame: 0, bubbles: [approval]).fittingSize
        func pet(_ name: String, _ atlas: Atlas?, _ state: PetState) -> some View {
            PetScene(atlas: atlas, row: state.row, frame: state.frame, bubbles: state.bubbles, canvas: canvas, solid: true)
                .overlay(alignment: .bottomTrailing) {
                    Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: Atlas.cell.width * 0.9).padding(.trailing, 28).padding(.bottom, 8)
                }
        }
        // Stacked rather than side by side, so the clip stays readable at phone width.
        return animate(tracks: [ghostTrack, bunnyTrack]) { states in
            VStack(spacing: 0) {
                pet("Ghost", ghost, states[0])
                pet("Bunny", bunny, states[1])
            }
            .background(PetScene.solidBackdrop)
        }
    }

    // MARK: - Window clips

    /// Four agents at work: one asks for input, one fails, two finish.
    private static func agentsClip() -> Take {
        let w = Desk()
        func list(_ apiServer: (AgentStatus, String?, String?), demo: AgentStatus, docs: AgentStatus) -> [AgentSession] {
            [
                session("1", .claude, apiServer.0, "api-server", prompt: "Add rate limiting to the public endpoints", detail: apiServer.1,
                        reply: apiServer.2, minutes: 3),
                session("2", .cursor, .running, "web-app", prompt: "Make the settings page work on mobile", detail: "Editing SettingsPage.tsx", minutes: 2),
                session("3", .claude, demo, "demo-app", prompt: "Why is the login test flaky?", detail: demo == .running ? "Ran npm test -- login" : nil,
                        edited: demo == .done ? ["a", "b", "c"] : [], reply: demo == .done ? "Fixed the flaky login test." : nil, minutes: 6),
                session("4", .codex, docs, "docs-site", prompt: "Upgrade to the new docs theme", detail: docs == .running ? "Running npm run build" : nil,
                        reply: docs == .failed ? "The build fails because the theme needs Node 20." : nil, minutes: 11),
            ]
        }
        w.sessions.loadPreview(list((.running, "Editing src/middleware/limit.ts", nil), demo: .running, docs: .running))
        let take = w.open(.agents)
        take.hold(1.6)
        w.sessions.loadPreview(list((.needsInput, "Run `npm install express-rate-limit`?", nil), demo: .running, docs: .running))
        take.hold(1.8)
        w.sessions.loadPreview(list((.needsInput, "Run `npm install express-rate-limit`?", nil), demo: .running, docs: .failed))
        take.hold(1.8)
        w.sessions.loadPreview(list((.needsInput, "Run `npm install express-rate-limit`?", nil), demo: .done, docs: .failed))
        take.hold(1.8)
        w.sessions.loadPreview(list((.running, "Ran npm install express-rate-limit", nil), demo: .done, docs: .failed))
        take.hold(1.4)
        w.sessions.loadPreview(list((.done, nil, "Added rate limiting to the public endpoints."), demo: .done, docs: .failed))
        take.hold(2.8)
        return w.close(take)
    }

    /// A question, the agent's tool calls, an approval card, Allow, and the answer.
    private static func chatClip() -> Take {
        let w = Desk()
        let question = Item(kind: .user("why is the login test flaky?"))
        let failed = Item(kind: .tool("Ran `npm test -- login`", ok: false))
        let read = Item(kind: .tool("Read src/auth/session.ts", ok: true))
        let answer = Item(kind: .assistant("`refreshToken()` resolves after the test checks the session, so it fails whenever the mock server is slow. Awaiting it in `login()` fixes it. Want me to make the change?"))
        let yes = Item(kind: .user("yes please"))
        let edited = Item(kind: .tool("Edited src/auth/session.ts", ok: true))
        let passed = Item(kind: .tool("Ran `npm test -- login`", ok: true))
        let finished = Item(kind: .assistant("Done! `login()` now waits for the token refresh, and the test passed 20 runs in a row."))
        w.show([])
        let take = w.open(.chat)
        take.hold(0.8)
        w.type("why is the login test flaky?", into: take)
        w.show([question], activity: "Thinking", ranFor: 1)
        take.hold(1.0)
        w.show([question, failed], activity: "Running npm test -- login", ranFor: 3)
        take.hold(0.9)
        w.show([question, failed, read], activity: "Reading src/auth/session.ts", ranFor: 5)
        take.hold(0.9)
        w.show([question, failed, read, answer], ranFor: 7)
        take.hold(2.6)
        w.type("yes please", into: take)
        w.show([question, failed, read, answer, yes, edited], approval: ("Run this command?", "npm test -- login --runInBand"), ranFor: 6)
        take.hold(2.4)
        w.show([question, failed, read, answer, yes, edited, passed], activity: "Running npm test -- login --runInBand", ranFor: 9)
        take.hold(1.0)
        w.show([question, failed, read, answer, yes, edited, passed, finished], ranFor: 14)
        take.hold(3.2)
        return w.close(take)
    }

    /// Pull request alerts arrive, then Ghost explains the failing one in the chat.
    private static func alertsClip() -> Take {
        let w = Desk()
        let url = URL(string: "https://github.com/you/web-app/pull/42")!
        let take = w.open(.alerts)
        take.hold(1.0)
        w.signals.add(Signal(id: "3", title: "Fix flaky login test", subtitle: "you/demo-app #8", url: url, date: Date(),
                             label: "Approved", symbol: "hand.thumbsup.fill", mood: .done), notify: false)
        take.hold(1.4)
        w.signals.add(Signal(id: "2", title: "Add rate limiting to public endpoints", subtitle: "you/api-server #17", url: url, date: Date(),
                             label: "Review requested", symbol: "eye.fill", mood: .needsInput, ask: "Summarize this PR."), notify: false)
        take.hold(1.4)
        w.signals.add(Signal(id: "1", title: "Make the settings page responsive", subtitle: "you/web-app #42 · build", url: url, date: Date(),
                             label: "CI failed", symbol: "xmark.octagon.fill", mood: .failed, ask: "Why is CI failing?"), notify: false)
        take.hold(2.2)
        let ask = Item(kind: .user("Why is CI failing? you/web-app #42"))
        let log = Item(kind: .tool("Ran `gh run view --log-failed`", ok: true))
        let reply = Item(kind: .assistant("The `build` job fails in `SettingsPage.test.tsx`: the snapshot still has the old breakpoint. Run `npm test -- -u` to update it, then push."))
        w.show([ask], activity: "Thinking", ranFor: 1)
        w.window.section = .chat
        take.hold(1.0)
        w.show([ask, log], activity: "Reading the failed job", ranFor: 3)
        take.hold(1.0)
        w.show([ask, log, reply], ranFor: 6)
        take.hold(3.2)
        return w.close(take)
    }

    /// Items arrive from a meeting and from the Gmail watcher, then one is marked done.
    private static func inboxClip() -> Take {
        var clock = Date()
        let store = TaskStore(database: Database.open(path: nil, migrations: AppMigrations.all).database, now: { clock })
        let w = Desk(tasks: TasksAPI(store: store))
        let take = w.open(.inbox)
        take.hold(1.2)
        clock = Date()
        let meeting: [TaskSuggestion] = store.suggest([("Send the design review notes to the team", "Friday", nil), ("Share the load test results", nil, nil)],
                                    meeting: URL(fileURLWithPath: "/Users/you/.ironpet/meetings/2026-11-16-1500"))
        take.hold(2.0)
        clock = Date()
        _ = store.suggest([TaskSuggestion.Draft(key: "msg-1", title: "Reply to Sam about the Q4 budget", due: nil,
                                            url: URL(string: "https://mail.google.com/mail/u/0/#inbox/1"))],
                      automation: "gmail-watch", name: "Gmail watcher")
        take.hold(2.0)
        if let shared = meeting.last { try? store.done(shared.id) }
        take.hold(2.6)
        return w.close(take)
    }

    /// A chat mentions Maya, and Ghost's memory gains a page about her, linked to the project.
    private static func memoryClip() -> Take {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-preview-memory-video-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        EntityMemoryStore.exportDirectory = folder
        let store = EntityMemoryStore(database: Database.open(path: nil, migrations: MemoryIndex.migrations).database)
        let project = ProjectKey(key: "git.northwind.example/lighthouse", name: "Lighthouse", isRepo: true,
                                 workspace: URL(fileURLWithPath: "/Users/you/Projects/lighthouse"))
        var clock = Date().addingTimeInterval(-4 * 86_400)
        store.now = { clock }
        func learn(_ days: Double, _ text: String, _ scope: MemoryScope, _ person: String? = nil, _ source: String = "chat:3f2a9c1d") {
            clock = Date().addingTimeInterval(-days * 86_400)
            _ = store.remember(text, scope: scope, person: person, project: project, source: source)
        }
        learn(4, "Works from Lisbon, one hour behind Berlin.", .me)
        learn(3, "Database migrations are one-way: older builds refuse a migrated database.", .project)
        learn(2, "The CI size limit for the app bundle is 64 MB.", .project, nil, "screen")
        learn(1, "Wrote the retry queue for failed uploads (LH-412).", .people, "Sam Rivera", "meeting:2026-11-23-1005")
        let saved = MemoryAPI.live
        MemoryAPI.live = MemoryAPI(services: { nil }, pages: { store })
        let memory = MemorySectionModel.shared
        defer { MemoryAPI.live = saved; memory.showList(); memory.reload() }
        memory.filter = .all; memory.clearSearch(); memory.showList(); memory.reload()

        let w = Desk()
        let ask = Item(kind: .user("Maya owns the Lighthouse repo and reviews every release build. Loop her in before we ship."))
        let reply = Item(kind: .assistant("Got it. I'll add Maya Chen as a reviewer on the release PR and remember that she signs off on release builds."))
        w.show([ask, reply], ranFor: 4)
        let take = w.open(.chat)
        take.hold(2.4)
        w.window.section = .memory
        take.hold(1.6)
        learn(0, "Owns the Lighthouse repository and reviews every release build.", .people, "Maya Chen")
        if let lighthouse = store.entities().first(where: { $0.name == "Lighthouse" }), let maya = store.entities().first(where: { $0.name == "Maya Chen" }) {
            store.link(from: maya.id, to: lighthouse.id, type: "works_on", source: "chat:3f2a9c1d")
        }
        memory.reload()
        take.hold(1.8)
        guard let maya = store.entities().first(where: { $0.name == "Maya Chen" })?.id else { return w.close(take) }
        memory.open(maya)
        take.hold(2.0)
        learn(0, "Asked that whoever picks up a Lighthouse issue assigns it to themselves.", .people, "Maya Chen", "screen")
        memory.reload()
        memory.open(maya)
        take.hold(3.0)
        return w.close(take)
    }

    /// Ghost writes a dashboard from a chat message, and it opens in the sidebar.
    private static func dashboardsClip() -> Take {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-preview-dashboards-video-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let dashboards = DashboardsAPI(store: DashboardStore(paths: DashboardPaths(root: folder), watch: false))
        let w = Desk(dashboards: dashboards)
        let ask = Item(kind: .user("make me a dashboard of what needs me today"))
        let wrote = Item(kind: .tool("Created dashboard Work", ok: true))
        let reply = Item(kind: .assistant("I made **Work**: agents waiting for you, what's running, failed CI and the week's finished agents. It's in the sidebar."))
        w.show([])
        let take = w.open(.chat)
        take.hold(0.6)
        w.type("make me a dashboard of what needs me today", into: take)
        w.show([ask], activity: "Writing the dashboard", ranFor: 2)
        take.hold(1.2)
        _ = try? dashboards.create(CreateDashboardRequest(id: "work", title: "Work", icon: "briefcase", color: "teal", count: true,
                                                          script: PreviewRenderer.sampleDashboardScript))
        w.show([ask, wrote, reply], ranFor: 9)
        take.hold(2.4)
        w.window.open(dashboard: "work")
        take.hold(4.0, settle: 1.6)
        return w.close(take)
    }

    // MARK: - Pieces

    private static func doneBubble(project: String, agent: String, body: String) -> BubbleDraft {
        BubbleDraft(id: "done", symbol: AgentStatus.done.symbol, tint: AgentStatus.done.bubbleTint, title: "\(project): Done",
                    subtitle: agent, body: body, actions: [.init("open", "Open in iTerm", style: .primary) {}])
    }

    private static func approvalBubble(pet: String, detail: String) -> BubbleDraft {
        BubbleDraft(id: "approval", symbol: "hand.raised.fill", tint: .orange, title: "\(pet) wants to: Run this command?", body: detail,
                    actions: [.init("allow", "Allow", style: .primary) {}, .init("deny", "Deny", style: .destructive) {}, .init("open-chat", "Open chat") {}])
    }

    private static func session(_ id: String, _ source: AgentSource, _ status: AgentStatus, _ project: String, prompt: String,
                                detail: String? = nil, edited: [String] = [], reply: String? = nil, minutes: Double) -> AgentSession {
        var s = AgentSession(id: id, source: source, status: status, prompt: prompt, detail: detail)
        s.origin = SessionOrigin(workspace: "/Users/you/code/\(project)", termProgram: "iTerm.app", itermSessionID: "w0t0p\(id)")
        s.turnStartedAt = Date().addingTimeInterval(-minutes * 60)
        s.updatedAt = s.turnStartedAt
        s.editedFiles = edited
        s.lastResponse = reply
        return s
    }

    /// One stretch of a pet's animation. A looping row repeats for `seconds`; a one-shot row holds its last frame.
    private struct Segment {
        let row: AtlasRow
        let seconds: Double
        let bubbles: [BubbleDraft]
        init(_ row: AtlasRow, _ seconds: Double, _ bubbles: [BubbleDraft] = []) {
            self.row = row; self.seconds = seconds; self.bubbles = bubbles
        }
    }

    private struct PetState {
        let row: AtlasRow
        let frame: Int
        let bubbles: [BubbleDraft]
        var key: String { "\(row.index).\(frame).\(bubbles.map(\.id).joined(separator: ","))" }
    }

    private static func state(of track: [Segment], at time: Double) -> PetState {
        var start = 0.0
        for segment in track {
            if time < start + segment.seconds {
                var t = time - start
                let cycle = segment.row.durations.reduce(0, +)
                if segment.row.loops { t = t.truncatingRemainder(dividingBy: cycle) }
                var frame = segment.row.durations.count - 1
                for (index, duration) in segment.row.durations.enumerated() {
                    if t < duration { frame = index; break }
                    t -= duration
                }
                return PetState(row: segment.row, frame: frame, bubbles: segment.bubbles)
            }
            start += segment.seconds
        }
        let last = track[track.count - 1]
        return PetState(row: last.row, frame: last.row.durations.count - 1, bubbles: last.bubbles)
    }

    /// Steps through the tracks at 25 frames a second and draws a frame only when some pet's frame or bubbles change.
    private static func animate<Scene: View>(tracks: [[Segment]], scene: ([PetState]) -> Scene) -> Take {
        let take = Take(backdrop: false)
        let step = 1.0 / 25
        let length = tracks.map { $0.map(\.seconds).reduce(0, +) }.max() ?? 0
        var lastKey: String?
        for tick in 0..<Int((length / step).rounded()) {
            let states = tracks.map { state(of: $0, at: Double(tick) * step) }
            let key = states.map(\.key).joined(separator: "|")
            if key == lastKey {
                take.extend(by: step)
                continue
            }
            lastKey = key
            guard let image = PreviewRenderer.snapshot(scene(states), wait: 0.02)?.cgImage else { continue }
            take.add(image, step)
        }
        return take
    }

    private typealias Item = ChatSession.Item

    /// The ironpet window over sample stores, open on screen while a clip records it.
    @MainActor
    private final class Desk {
        let sessions = SessionStore()
        let signals = SignalStore()
        let tasks: TasksAPI
        let dashboards: DashboardsAPI
        let chat = ChatSession(restore: false)
        let window = IronPetWindowModel(defaults: UserDefaults(suiteName: "ironpet-previews") ?? .standard)
        private(set) lazy var chatModel = PreviewRenderer.chatModel(chat)
        private var panel: IronPetPanel?

        init(tasks: TasksAPI? = nil, dashboards: DashboardsAPI? = nil) {
            self.tasks = tasks ?? TasksAPI(store: TaskStore(database: Database.open(path: nil, migrations: AppMigrations.all).database))
            self.dashboards = dashboards ?? .unavailable
        }

        func open(_ section: IronPetSection) -> Take {
            window.todayShown = false
            window.sidebarCollapsed = false
            window.section = section
            let library = MeetingLibrary(root: PreviewRenderer.sampleMeetings())
            library.reload()
            let view = IronPetWindowView(model: window, agents: AgentsAPI(store: sessions), alerts: AlertsAPI(store: signals), tasks: tasks,
                                         dashboards: dashboards, chat: chatModel,
                                         meetings: MeetingsAPI(recorder: MeetingController(), library: library), actions: .none)
            let panel = IronPetPanel(model: window, session: chatModel, content: view)
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.setContentSize(CGSize(width: 780, height: 560))
            panel.setFrameOrigin(CGPoint(x: 60, y: 60))
            NSApp.setActivationPolicy(.regular)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            panel.makeKeyAndOrderFront(nil)
            self.panel = panel
            let id = CGWindowID(panel.windowNumber)
            return Take(backdrop: true) {
                CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution])
            }
        }

        /// Sets the chat to one moment of the sample conversation. The view model reads the session only when the API tells it
        /// something changed, and a sample session sends nothing, so it is asked to read again.
        func show(_ items: [Item], activity: String? = nil, approval: (title: String, detail: String)? = nil, ranFor: TimeInterval? = nil) {
            chat.showPreview(items, activity: activity, approval: approval, ranFor: ranFor)
            let model = chatModel
            Task { await model.refreshAll() }
        }

        /// Types into the composer a word at a time, then clears it as if sent.
        func type(_ text: String, into take: Take) {
            let words = text.split(separator: " ")
            for count in 1...words.count {
                chatModel.input = words.prefix(count).joined(separator: " ")
                take.hold(0.14, settle: 0.12, fade: false)
            }
            take.hold(0.4, settle: 0.1, fade: false)
            chatModel.input = ""
        }

        func close(_ take: Take) -> Take {
            panel?.orderOut(nil)
            panel = nil
            return take
        }
    }
}

/// The frames of one clip, each with how long it shows.
@MainActor
final class Take {
    private(set) var frames: [(image: CGImage, seconds: Double)] = []
    /// Window clips sit on a soft backdrop with a shadow, since the window's rounded corners are transparent.
    let backdrop: Bool
    private let capture: () -> CGImage?

    init(backdrop: Bool, capture: @escaping () -> CGImage? = { nil }) {
        self.backdrop = backdrop
        self.capture = capture
    }

    func add(_ image: CGImage, _ seconds: Double) { frames.append((image, seconds)) }

    func extend(by seconds: Double) {
        guard !frames.isEmpty else { return }
        frames[frames.count - 1].seconds += seconds
    }

    /// Lets the views settle, captures the window and shows it for `seconds`, crossfading from the frame before.
    func hold(_ seconds: Double, settle: TimeInterval = 0.45, fade: Bool = true) {
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        guard let image = capture() else { return }
        if fade, let last = frames.last?.image, last.width == image.width, last.height == image.height {
            for step in 1...5 {
                if let mix = Self.blend(last, image, CGFloat(step) / 6) { add(mix, 0.04) }
            }
        }
        add(image, seconds)
    }

    private static func blend(_ a: CGImage, _ b: CGImage, _ amount: CGFloat) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: a.width, height: a.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: a.width, height: a.height)
        ctx.draw(a, in: rect)
        ctx.setAlpha(amount)
        ctx.draw(b, in: rect)
        return ctx.makeImage()
    }

    /// Writes `<name>.mp4` (H.264, variable frame rate) and `<name>.jpg`, the longest-held frame, as its poster.
    func write(to dir: URL, _ name: String) {
        guard let first = frames.first?.image else { return print("no frames for \(name)") }
        let pad = backdrop ? 96 : 0
        let width = (first.width + pad * 2) & ~1, height = (first.height + pad * 2) & ~1
        let file = dir.appendingPathComponent("\(name).mp4")
        try? FileManager.default.removeItem(at: file)
        guard let writer = try? AVAssetWriter(outputURL: file, fileType: .mp4) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_500_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { return print("could not write \(name): \(writer.error?.localizedDescription ?? "")") }
        writer.startSession(atSourceTime: .zero)
        var time = CMTime.zero
        for frame in frames {
            while !input.isReadyForMoreMediaData { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            guard let pool = adaptor.pixelBufferPool, let buffer = draw(frame.image, width: width, height: height, pad: pad, pool: pool) else { continue }
            adaptor.append(buffer, withPresentationTime: time)
            time = CMTimeAdd(time, CMTime(seconds: frame.seconds, preferredTimescale: 600))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: time)
        writer.finishWriting {}
        while writer.status == .writing { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard writer.status == .completed else { return print("could not write \(name): \(writer.error?.localizedDescription ?? "")") }
        print("wrote \(file.path) (\(frames.count) frames, \(String(format: "%.1f", time.seconds)) s)")

        guard let poster = frames.max(by: { $0.seconds < $1.seconds })?.image,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        compose(poster, in: ctx, width: width, height: height, pad: pad)
        guard let image = ctx.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return }
        try? jpeg.write(to: dir.appendingPathComponent("\(name).jpg"))
    }

    private func draw(_ image: CGImage, width: Int, height: Int, pad: Int, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        compose(image, in: ctx, width: width, height: height, pad: pad)
        return buffer
    }

    /// The website's pink-to-ice glow behind a window, or the frame edge to edge for the pet clips.
    private func compose(_ image: CGImage, in ctx: CGContext, width: Int, height: Int, pad: Int) {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard backdrop else {
            ctx.draw(image, in: bounds)
            return
        }
        let colors = [CGColor(srgbRed: 0.965, green: 0.722, blue: 0.769, alpha: 1), CGColor(srgbRed: 0.812, green: 0.878, blue: 0.949, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        }
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 48, color: CGColor(gray: 0, alpha: 0.35))
        ctx.draw(image, in: CGRect(x: pad, y: height - pad - image.height, width: image.width, height: image.height))
    }
}
