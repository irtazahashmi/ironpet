import IronPetKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The Chat tab. The Mac has one chat open, and this screen reads and drives it.
struct ChatView: View {
    let model: ChatModel
    /// The Mac's chat background: its id, and the picture for `custom`.
    var backgroundID = ChatBackgrounds.defaultID
    var backgroundImage: UIImage?
    /// The pet's face, which marks the agent's replies as it does on the Mac.
    var avatar: CGImage?
    /// The pet's name, shown beside its face in the header, as the Mac does.
    var petName = ""
    /// The agents of the Mac. Nil, or one agent, and the chat looks as it did before there were several.
    var agents: AgentChatsModel?
    @State private var showThreads = false
    @State private var showSettings = false
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var focused = false
    @State private var find = ChatFindState()
    @State private var preview: FilePreviewTarget?
    @State private var record: RecordLink?

    /// Changes when the query or the transcript does, so the matches are found again.
    private var findKey: String {
        "\(find.query)-\(find.isOpen)-\(model.displayItems.count)-\(model.displayItems.last?.text?.utf16.count ?? 0)"
    }
    @Environment(VoiceModel.self) private var voice: VoiceModel?

    var body: some View {
        content.chatTextSize()
    }

    private var content: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if find.isOpen { ChatFindBar(find: find) }
                if let message = model.errorMessage {
                    Label(message, systemImage: SharedSymbols.warning).font(.footnote).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 6)
                        .accessibilityIdentifier("chat-error")
                }
                // The composer floats over the transcript, so the background shows through the glass.
                Transcript(model: model, find: find, avatar: avatar, showsAgentNames: agents?.showsAgents ?? false)
                    .fullPageLoadError(model)
                    .environment(\.openFilePath, { preview = FilePreviewTarget(path: $0) })
                    .environment(\.openRecord, { record = RecordLink(id: $0) })
                    .glassBottomBar {
                        VStack(spacing: 6) {
                            if let notice = model.snapshot?.notice {
                                Label(notice, systemImage: "desktopcomputer").font(.footnote)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 6)
                                    .background(.thinMaterial).accessibilityIdentifier("chat-notice")
                            }
                            if let voice { VoiceNotice(voice: voice) }
                            BackgroundCapsuleRow(model: model)
                            Composer(model: model, showFiles: $showFiles, showPhotos: $showPhotos, focused: $focused)
                        }
                    }
            }
            .background {
                ChatBackgroundPicture(id: backgroundID, customImage: backgroundImage.map(Image.init(uiImage:)), fallback: SharedTheme.window)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("chat-background-\(backgroundID)")
            }
            .navigationTitle(petName.isEmpty ? "Chat" : petName)
            .themedScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let agents, agents.showsAgents {
                    ToolbarItem(placement: .topBarLeading) { AgentPicker(agents: agents) }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        if let avatar {
                            Image(decorative: avatar, scale: 1).resizable().scaledToFit().frame(width: 24, height: 24)
                        }
                        Text(petName.isEmpty ? "Chat" : petName).font(.headline).lineLimit(1).accessibilityIdentifier("chat-title")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // The session the pet is working in. It used to sit under the title.
                        Section {
                            Text(model.title).accessibilityIdentifier("chat-session-title")
                            Text(model.subtitle).accessibilityIdentifier("chat-subtitle")
                        }
                        Button { find.open() } label: { Label("Find in chat", systemImage: SharedSymbols.find) }
                            .accessibilityIdentifier("chat-find-button")
                        Button { showSettings = true } label: { Label("Chat settings", systemImage: SharedSymbols.chatOptions) }
                            .accessibilityIdentifier("chat-settings-button")
                        Button { showThreads = true } label: { Label("Chats", systemImage: SharedSymbols.history) }
                            .accessibilityIdentifier("threads-button")
                    } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("More").accessibilityIdentifier("chat-more-button")
                }
            }
            .onChange(of: findKey) { find.update(model.displayItems) }
            .sheet(isPresented: $showThreads) { ThreadsSheet(model: model, avatar: avatar) }
            .sheet(isPresented: $showSettings) { ChatSettingsSheet(model: model) }
            .sheet(item: $preview) { FilePreviewSheet(client: model.client, target: $0) }
            .sheet(item: $record) { RecordSheet(client: model.client, id: $0.id) }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url) else { continue }
                    let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    model.attach(data: data, fileName: url.lastPathComponent, contentType: type)
                }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photos, maxSelectionCount: ChatModel.maxPendingImages, matching: .images)
            .onChange(of: photos) { _, picked in
                guard !picked.isEmpty else { return }
                let loaders: [@Sendable () async throws -> Data?] = picked.map { item in { try await item.loadTransferable(type: Data.self) } }
                photos = []
                Task { await model.attachPhotos(loaders) }
            }
        }
        .task { model.start() }
    }
}

// MARK: Transcript

/// Where the end of the transcript is, and how big the content and the viewport are, for `TranscriptFollowState`.
private struct EndPosition: Equatable {
    var contentHeight: CGFloat = 0
    /// The bottom of the last row, in screen coordinates.
    var bottom: CGFloat = 0
}

private struct EndPositionKey: PreferenceKey {
    static let defaultValue = EndPosition()
    static func reduce(value: inout EndPosition, nextValue: () -> EndPosition) { value = nextValue() }
}

private final class FollowTracker {
    var state = TranscriptFollowState()
}

/// The menu that picks which agent's chat the tab shows. An agent the Mac turned off is listed and cannot be chosen.
private struct AgentPicker: View {
    let agents: AgentChatsModel

    var body: some View {
        Menu {
            ForEach(agents.listed) { record in
                let shown = agents.currentRecord?.id == record.id
                Button {
                    agents.select(record.chatAgentID)
                } label: {
                    Label(record.enabled ? record.displayName : "\(record.displayName) (off)", systemImage: shown ? SharedSymbols.allow : SharedSymbols.agents)
                }
                .disabled(!record.enabled)
                .accessibilityIdentifier("agent-choice-\(record.id)")
            }
        } label: { Image(systemName: SharedSymbols.agents) }
            .accessibilityLabel("Agents").accessibilityIdentifier("chat-agents-button")
    }
}

private struct Transcript: View {
    let model: ChatModel
    let find: ChatFindState
    var avatar: CGImage?
    var showsAgentNames = false
    @Environment(VoiceModel.self) private var voice: VoiceModel?
    /// The follow logic keeps its last measurements in a reference, so a scroll frame does not invalidate the view. Only a change of
    /// `pinned` or `newBelow` does.
    @State private var tracker = FollowTracker()
    @State private var pinned = true
    @State private var newBelow = false
    @State private var viewport = CGRect.zero
    @State private var dragging = false
    @State private var lastItemID: String?
    @State private var lastContentKey = ""
    /// Which long messages the reader opened. The transcript owns it because a lazy row that scrolls away loses its own state.
    @State private var expandedMessages: Set<String> = []

    /// Changes whenever something arrives that a reader at the end should see: a message, streamed text, a card or the working row.
    private var contentKey: String {
        "\(model.displayItems.count)-\(model.displayItems.last?.text?.utf16.count ?? 0)-\(model.approvals.count)-\(model.forms.count)-\(model.queue.count)-\(showsTyping)"
    }

    private func publish() {
        if pinned != tracker.state.pinned { pinned = tracker.state.pinned }
        if newBelow != tracker.state.newBelow { newBelow = tracker.state.newBelow }
    }

    private var showsTyping: Bool { (model.running || model.awaitingReply) && model.approvals.isEmpty && model.forms.isEmpty }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The end marker sits outside the lazy stack, so it keeps reporting its position while the rows around it are not built.
                VStack(spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        // The row above the oldest loaded message. Coming into view loads the page before it.
                        if model.hasOlderHistory {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
                                .onAppear { Task { await model.loadOlder() } }
                        }
                        ForEach(RemoteTranscriptGroup.make(model.displayItems)) { group in
                            TranscriptGroupView(group: group, photos: model.sentPhotos, images: model.images, avatar: avatar, expanded: expandedMessages,
                                                toggleExpand: { id in if !expandedMessages.insert(id).inserted { expandedMessages.remove(id) } },
                                                outbox: model.outbox, onRetry: { id in Task { await model.retry(id) } }, onDelete: { id in model.deleteQueued(id) },
                                                onReply: { model.reply(to: $0, selection: $1) },
                                                readAloud: { item in voice.flatMap { ReadAloud(item: item, voice: $0) } },
                                                highlights: find.highlights, deliveredID: model.deliveredID)
                        }
                        if showsTyping { TypingRow(started: model.snapshot?.runStarted, avatar: avatar) }
                        ForEach(model.approvals) { ApprovalCard(approval: $0, model: model, agentName: showsAgentNames ? $0.agentName : nil) }
                        ForEach(model.forms) { FormCard(form: $0, model: model, agentName: showsAgentNames ? $0.agentName : nil) }
                        ForEach(model.queue) { QueuedRow(queued: $0) }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: EndPositionKey.self,
                                                   value: EndPosition(contentHeight: geometry.frame(in: .named("content")).maxY, bottom: geometry.frame(in: .global).maxY))
                        })
                }
                .coordinateSpace(name: "content")
                .padding(.horizontal).padding(.vertical, 8)
            }
            // The first screen of a chat opens at its newest message. After that, `follow` decides whether new content scrolls.
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .hidesKeyboardOnHold()
            .softBottomEdge()
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                viewport = frame
                if pinned, !find.isOpen { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onPreferenceChange(EndPositionKey.self) { position in
                tracker.state.measure(contentHeight: position.contentHeight, viewportHeight: viewport.height,
                                      distanceFromBottom: position.bottom - viewport.maxY, userDriven: dragging)
                publish()
            }
            .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { _ in dragging = true }.onEnded { _ in dragging = false })
            .overlay(alignment: .bottom) {
                if newBelow {
                    JumpToLatestButton {
                        tracker.state.jumpedToLatest()
                        publish()
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: newBelow)
            .overlay {
                if model.loaded, model.items.isEmpty {
                    ContentUnavailableView("No messages", systemImage: "bubble.left", description: Text("Say something to start."))
                }
            }
            .onChange(of: contentKey) {
                // A message this phone just sent always jumps to the end. Streamed text follows only while the reader is at the end.
                let last = model.items.last
                let readerSent = last?.id != lastItemID && last?.kind == "user" && last?.origin == "ios"
                lastItemID = last?.id
                tracker.state.contentArrived(readerSent: readerSent)
                publish()
                if tracker.state.pinned, !find.isOpen { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // Stepping to a match scrolls to its message. A long message the reader has not opened opens, so the match is on screen.
            .onChange(of: find.current) { _, match in
                guard let match else { return }
                if model.displayItems.first(where: { $0.id == match.itemID })?.kind == "user" { expandedMessages.insert(match.itemID) }
                withAnimation { proxy.scrollTo(match.itemID, anchor: .center) }
            }
            .accessibilityIdentifier("transcript")
        }
    }
}

/// One group of the transcript: a run of tool steps, or one message.
private struct TranscriptGroupView: View {
    let group: RemoteTranscriptGroup
    let photos: [String: Data]
    /// Fetches the Mac's images. Nil in a saved thread, whose message ids the Mac cannot look up.
    var images: ChatImages?
    var avatar: CGImage?
    var expanded: Set<String> = []
    var toggleExpand: (String) -> Void = { _ in }
    var outbox: [OutgoingMessage] = []
    var onRetry: (UUID) -> Void = { _ in }
    var onDelete: (UUID) -> Void = { _ in }
    var onReply: (RemoteChatItem, String?) -> Void = { _, _ in }
    /// Nil in a saved thread, whose messages the Mac cannot read from the open chat.
    var readAloud: (RemoteChatItem) -> ReadAloud? = { _ in nil }
    var highlights: [String: RemoteChatFind.RowHighlight] = [:]
    /// The last message from this phone that the Mac has confirmed. It shows the check.
    var deliveredID: String?

    var body: some View {
        switch group {
        case .tools(let steps):
            ToolStepsRow(steps: steps)
        case .item(let item):
            let message = outbox.first(where: { $0.itemID == item.id })
            // "Delivered" sits beside the source and time of a text bubble. A photo or other row has no such line, so it goes below.
            let delivered: AnyView? = message == nil && item.id == deliveredID
                ? AnyView(Label("Delivered", systemImage: "checkmark").font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("outgoing-delivered")) : nil
            let inline: Bool = { if case .user = item.row { return true } else { return false } }()
            VStack(alignment: .trailing, spacing: 2) {
                MessageRow(item: item, photo: item.fileName.flatMap { photos[$0] }, images: images, avatar: avatar, expanded: expanded.contains(item.id),
                           onToggleExpand: { toggleExpand(item.id) }, onReply: item.canReply && !OutgoingMessage.isPending(item.id) ? { selection in onReply(item, selection) } : nil,
                           readAloud: item.kind == "assistant" ? readAloud(item) : nil, find: highlights[item.id],
                           outgoing: message.map(OutgoingLook.init), onRetry: message.map { message in { onRetry(message.id) } }, onDelete: message.map { message in { onDelete(message.id) } },
                           status: inline ? delivered : nil)
                if !inline, let delivered { delivered }
            }
        }
    }
}

private struct QueuedRow: View {
    let queued: RemoteQueued

    var body: some View {
        HStack {
            Image(systemName: SharedSymbols.sentAt).foregroundStyle(.secondary)
            Text(queued.text.isEmpty ? "Attachment" : queued.text).font(.footnote).lineLimit(2)
            Spacer()
            Text("Queued").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("queued-\(queued.id)")
    }
}

// MARK: Rows

/// One message of the transcript. Used by the live chat and, read only, by a saved thread.
struct MessageRow: View {
    let item: RemoteChatItem
    var photo: Data?
    var images: ChatImages?
    var avatar: CGImage?
    var expanded = false
    var onToggleExpand: () -> Void = {}
    /// Starts a reply. The text is the part of the message the reader selected, or nil for the whole message.
    var onReply: ((String?) -> Void)?
    var readAloud: ReadAloud?
    /// The highlights of Find in chat for this message. Nil outside a search.
    var find: RemoteChatFind.RowHighlight?
    /// How the message looks while the Mac has not confirmed it. Nil for a message the transcript already holds.
    var outgoing: OutgoingLook?
    var onRetry: (() -> Void)?
    var onDelete: (() -> Void)?
    /// The "Delivered" mark, drawn on the row of the source and the time. Only a text bubble has that row.
    var status: AnyView?
    @Environment(\.openFilePath) private var openFilePath
    @Environment(\.openRecord) private var openRecord
    @State private var selecting = false

    var body: some View {
        Group {
            switch item.row {
            case .user(let text): UserBubble(item: item, text: text, expanded: expanded, onToggleExpand: onToggleExpand, find: find, outgoing: outgoing, onRetry: onRetry, status: status)
            case .assistant(let text): AssistantBubble(item: item, text: text, avatar: avatar, readAloud: readAloud, find: find)
            case .tool: ToolStepsRow(steps: [item])
            case .error(let text): ErrorRow(text: text)
            case .notice(let text): NoticeRow(notice: ChatNotice(text))
            case .attachment(let name, let isImage):
                Attachment(name: name, isImage: isImage, photo: photo, mine: item.origin == "ios", messageID: item.id, images: images)
                    .modifier(OutgoingMarks(look: outgoing, onRetry: onRetry))
            case .form(let message, let skipped, let lines):
                FormRecord(message: message, skipped: skipped, lines: lines)
            case .unsupported(let text):
                VStack(alignment: .leading, spacing: 2) {
                    Label("Unsupported message", systemImage: "questionmark.square.dashed").font(.caption).foregroundStyle(.secondary)
                    if !text.isEmpty { Text(text).font(.footnote).foregroundStyle(.secondary) }
                }
                .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("unsupported-\(item.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: item.kind == "user" || (item.kind == "screenshot" && item.origin != nil) ? .trailing : .leading)
        // A tap on a record id opens the record, and a tap on a file path asks the Mac for a preview. Any other link keeps its usual action.
        .environment(\.openURL, OpenURLAction { url in
            if let id = RecordLinks.id(from: url), let openRecord {
                openRecord(id)
                return .handled
            }
            guard let path = ChatFilePaths.path(from: url), let openFilePath else { return .systemAction }
            openFilePath(path)
            return .handled
        })
        .environment(\.selectingText, $selecting)
        .environment(\.askAboutSelection, onReply.map { reply in { text in reply(text) } })
        .swipeToReply(onReply.map { reply in { reply(nil) } })
        .modifier(MessageMenu(item: item, preview: preview) { menuItems })
    }

    /// What lifts when the message is long pressed: the bubble's own shape for your message, a rounded card in the system background
    /// for a reply. Without it the row lifts as a full-width block with no background behind the text.
    private var preview: MessagePreview {
        switch item.row {
        case .user(let text): .user(String(text.prefix(1200)), outgoing)
        case .assistant(let text): .assistant(String(text.prefix(1200)))
        default: .none
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if let reason = outgoing?.failureReason { Text(reason) }
        if outgoing?.isFailed == true, let onRetry { Button(action: onRetry) { Label("Retry", systemImage: "arrow.clockwise") }.accessibilityIdentifier("outgoing-retry-menu") }
        if outgoing?.canDelete == true, let onDelete { Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }.accessibilityIdentifier("outgoing-delete") }
        if let onReply { Button { onReply(nil) } label: { Label("Reply", systemImage: SharedSymbols.reply) } }
        if case .assistant = item.row { Button { selecting = true } label: { Label("Select text", systemImage: "selection.pin.in.out") } }
        if let text = item.text, !text.isEmpty { Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: SharedSymbols.copy) } }
        if let readAloud {
            Button(action: readAloud.toggle) {
                Label(readAloud.active ? "Stop Reading" : "Read Aloud", systemImage: readAloud.active ? SharedSymbols.stopSpeaking : SharedSymbols.speak)
            }
        }
    }

    static func markdown(_ text: String) -> AttributedString { ChatMarkdown.inline(text) }

    static func originName(_ origin: String) -> String {
        OriginBadge(origin: origin)?.label ?? origin.capitalized
    }
}

enum MessagePreview { case user(String, OutgoingLook?), assistant(String), none }

/// The long-press menu of a message, with an explicit preview so the lifted message has a solid rounded background.
private struct MessageMenu<Items: View>: ViewModifier {
    let item: RemoteChatItem
    let preview: MessagePreview
    @ViewBuilder let items: Items
    @Environment(\.macAccent) private var macAccent
    @ChatScale(.body) private var scale

    func body(content: Content) -> some View {
        switch preview {
        case .user(let text, let outgoing):
            content.contextMenu { items } preview: {
                Text(text).font(.system(size: ChatMetrics.macBody * scale)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: 320, alignment: .leading)
                    .background(outgoing?.isFailed == true ? OutgoingLook.failedFill : macAccent, in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 5, topTrailingRadius: 16))
                    .opacity(outgoing?.opacity ?? 1)
                    .accessibilityIdentifier("preview-\(item.id)")
            }
        case .assistant(let text):
            content.contextMenu { items } preview: {
                MarkdownBody(text: text, find: nil)
                    .padding(12)
                    .frame(maxWidth: 340, alignment: .leading)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityIdentifier("preview-\(item.id)")
            }
        case .none:
            content.contextMenu { items }
        }
    }
}

private struct Attachment: View {
    let name: String
    let isImage: Bool
    let photo: Data?
    let mine: Bool
    let messageID: String
    var images: ChatImages?
    /// What the Mac sent, once it has arrived. Nil while it loads or when the Mac refused.
    @State private var loaded: UIImage?
    @State private var failure: String?
    @State private var viewing = false

    var body: some View {
        Group {
            if let image = shown {
                // The Mac's thumbnail: 110 pt high, rounded, with a hairline edge. A tap opens the picture full size.
                Button { viewing = true } label: {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Image \(Self.display(name))").accessibilityHint("Opens the image full size")
                .accessibilityIdentifier("photo-\(name)")
            } else {
                chip
            }
        }
        .task(id: messageID) { await load() }
        .fullScreenCover(isPresented: $viewing) {
            ImageViewer(name: Self.display(name), local: photo, messageID: messageID, images: images)
        }
    }

    /// The bytes this phone already has win over a fetch: a photo it sent shows at once.
    private var shown: UIImage? {
        if let photo, let image = UIImage(data: photo) { return image }
        return loaded
    }

    private func load() async {
        guard photo == nil, isImage, let images else { return }
        switch await images.thumbnail(for: messageID) {
        case .success(let image): loaded = image; failure = nil
        case .failure(let error): loaded = nil; failure = error.message
        }
    }

    private var chip: some View {
        // A file the phone does not show, an image still loading, or one the Mac no longer has.
        HStack(spacing: 6) {
            if isImage, images != nil, failure == nil, photo == nil { ProgressView().controlSize(.small) } else {
                Image(systemName: isImage ? SharedSymbols.photo : SharedSymbols.file).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(mine ? Self.display(name) : (isImage ? "Screenshot on the Mac" : Self.display(name))).font(.system(size: 11.5)).lineLimit(2).truncationMode(.middle)
                if let failure { Text(failure).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
        .padding(.horizontal, 8).frame(minHeight: 48)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
        .accessibilityIdentifier("chip-\(name)")
    }

    /// The Mac saves a file as `<8 characters>-<name>`. The phone shows the name.
    static func display(_ stored: String) -> String {
        guard stored.count > 9, stored[stored.index(stored.startIndex, offsetBy: 8)] == "-" else { return stored }
        return String(stored.dropFirst(9))
    }
}

/// An attachment picture at full size: pinch or double-tap to zoom, drag to move.
private struct ImageViewer: View {
    let name: String
    let local: Data?
    let messageID: String
    var images: ChatImages?
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var settledOffset = CGSize.zero

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        .scaleEffect(zoom).offset(offset)
                        .gesture(MagnifyGesture().onChanged { zoom = max(1, settledZoom * $0.magnification) }
                            .onEnded { _ in settledZoom = zoom; if zoom == 1 { offset = .zero; settledOffset = .zero } })
                        .simultaneousGesture(DragGesture().onChanged { if zoom > 1 { offset = CGSize(width: settledOffset.width + $0.translation.width, height: settledOffset.height + $0.translation.height) } }
                            .onEnded { _ in settledOffset = offset })
                        .onTapGesture(count: 2) {
                            withAnimation { zoom = zoom > 1 ? 1 : 2.5; settledZoom = zoom; if zoom == 1 { offset = .zero; settledOffset = .zero } }
                        }
                        .accessibilityLabel("Image \(name)").accessibilityIdentifier("image-viewer-picture")
                } else if let failure {
                    Label(failure, systemImage: SharedSymbols.warning).foregroundStyle(.white).padding()
                        .accessibilityIdentifier("image-viewer-error")
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.accessibilityIdentifier("image-viewer-done") }
            }
        }
        .task {
            if let local, let decoded = await ChatImages.decodeFull(local) { image = decoded; return }
            guard let images else { return }
            switch await images.full(for: messageID) {
            case .success(let loaded): image = loaded
            case .failure(let error): failure = error.message
            }
        }
    }
}

private struct FormRecord: View {
    let message: String
    let skipped: Bool
    let lines: [RemoteFormLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message.isEmpty ? "Question" : message, systemImage: skipped ? "forward.circle" : SharedSymbols.done)
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if skipped { Text("Skipped").font(.system(size: 12)).foregroundStyle(.secondary) }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.question).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(line.answer).font(.system(size: 12.5)).textSelection(.enabled)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(SharedTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: Cards

private struct ApprovalCard: View {
    let approval: RemoteApproval
    let model: ChatModel
    /// The agent that asks, shown when the Mac runs several. Nil otherwise.
    var agentName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let agentName { Text(agentName).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("approval-agent-\(approval.id)") }
            Label(approval.title, systemImage: SharedSymbols.approval).font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
            if !approval.detail.isEmpty {
                Text(approval.detail).font(.system(size: 11.5, design: .monospaced)).lineLimit(10).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button { Task { await model.decide(approval, allow: true) } } label: { Label("Allow", systemImage: SharedSymbols.allow).frame(minWidth: 70) }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("allow-\(approval.id)")
                Button { Task { await model.decide(approval, allow: false) } } label: { Label("Deny", systemImage: SharedSymbols.deny).frame(minWidth: 70) }.buttonStyle(.bordered)
                    .accessibilityIdentifier("deny-\(approval.id)")
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.5)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval-\(approval.id)")
    }
}

/// The title with its icon, or the title alone when `titleOnly` is set.
private struct SubmitLabelStyle: LabelStyle {
    let titleOnly: Bool
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if titleOnly { configuration.title } else { HStack(spacing: 6) { configuration.icon; configuration.title } }
    }
}

private struct FormCard: View {
    let form: RemoteForm
    let model: ChatModel
    /// The agent that asks, shown when the Mac runs several. Nil otherwise.
    var agentName: String?
    @State private var typed: [String: String] = [:]
    @State private var pager: ElicitationPager?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var current: ElicitationPager { pager ?? ElicitationPager(pageCount: form.pages.count) }
    private var pending: Bool { model.submittingForms.contains(form.id) }

    var body: some View {
        let pages = form.pages
        let page = current
        VStack(alignment: .leading, spacing: 10) {
            if let agentName { Text(agentName).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("form-agent-\(form.id)") }
            Label(form.message.isEmpty ? "The agent has a question" : form.message, systemImage: SharedSymbols.question)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            // Every page sits in the same ZStack and only the current one shows, so the card keeps the height of the tallest page
            // and the composer and the transcript above do not move when the page changes.
            ZStack(alignment: .topLeading) {
                ForEach(Array(pages.enumerated()), id: \.offset) { position, fields in
                    let shown = position == min(page.index, pages.count - 1)
                    let content = VStack(alignment: .leading, spacing: 10) { ForEach(fields) { field in fieldView(field) } }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // `hidden()` keeps the page's size in the layout and takes it out of the accessibility tree and out of touch handling.
                    if shown { content } else { content.hidden() }
                }
            }
            controls(page)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.5)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("form-\(form.id)")
    }

    /// The control row. At accessibility text sizes Back, the page label and Skip sit above the Next and Submit slot, so Submit keeps its
    /// label on one line instead of hyphenating it.
    @ViewBuilder
    private func controls(_ page: ElicitationPager) -> some View {
        let stacked = page.isPaged && dynamicTypeSize.isAccessibilitySize
        let backButton = Button { move { $0.back() } } label: { Image(systemName: "chevron.left") }.buttonStyle(.bordered).disabled(!page.canGoBack)
            .accessibilityLabel("Back").accessibilityIdentifier("back-\(form.id)")
        let pageLabel = Text(page.label).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
            .accessibilityIdentifier("page-\(form.id)")
        // Next and Submit share one slot and the unused one stays in the layout, so the row is as tall on every page
        // and the card does not grow on the last page.
        let nextButton = Button { move { $0.forward() } } label: { Image(systemName: SharedSymbols.chevron) }.buttonStyle(.bordered)
            .accessibilityLabel("Next").accessibilityIdentifier("next-\(form.id)")
        let submitButton = Button { submit() } label: {
            if pending { ProgressView().frame(minWidth: 70) }
            else {
                // One line that the row cannot compress, so the button is as tall as Back and Skip. The icon goes at accessibility sizes.
                Label("Submit", systemImage: SharedSymbols.allow)
                    .labelStyle(SubmitLabelStyle(titleOnly: dynamicTypeSize.isAccessibilitySize))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false).frame(minWidth: 70)
            }
        }.buttonStyle(.borderedProminent)
            .disabled((!page.isPaged && !form.canSubmit) || pending)
            .accessibilityIdentifier("submit-\(form.id)")
        let slot = ZStack(alignment: .leading) {
            if page.isLast { nextButton.hidden() } else { nextButton }
            if page.isLast { submitButton } else { submitButton.hidden() }
        }
        // On a paged form the row also holds Back, the page label and Submit, so Skip shrinks to its icon to stay on one line.
        let skipButton = Button { Task { await model.skip(form) } } label: {
            if page.isPaged { Label("Skip", systemImage: SharedSymbols.skip).labelStyle(.iconOnly) }
            else { Label("Skip", systemImage: SharedSymbols.skip).frame(minWidth: 70) }
        }.buttonStyle(.bordered).disabled(pending).accessibilityLabel("Skip")
            .accessibilityIdentifier("skip-\(form.id)")
        if stacked {
            VStack(alignment: .leading, spacing: 8) {
                HStack { backButton; pageLabel; Spacer(); skipButton }
                slot
            }
        } else {
            HStack {
                if page.isPaged { backButton; pageLabel; slot } else { submitButton }
                skipButton
            }
        }
    }

    /// Sends the text typed on the shown page, so it survives the page change and reaches the Mac.
    private func commitTyped() {
        for field in form.pages[min(current.index, form.pages.count - 1)] {
            guard let text = typed[field.id], form.answers[field.id] != .text(text) else { continue }
            Task { await model.answer(form, field: field.id, .text(text)) }
        }
    }

    private func move(_ change: (inout ElicitationPager) -> Void) {
        commitTyped()
        var next = current
        change(&next)
        pager = next
    }

    /// Sends the answers, or jumps to the first question that still needs one.
    private func submit() {
        if let page = form.firstIncompletePage(typed: typed) {
            move { $0.show(page) }
        } else {
            let pending = form.pages.flatMap { $0 }.compactMap { field in typed[field.id].map { (field.id, $0) } }.filter { form.answers[$0.0] != .text($0.1) }
            Task {
                for (id, text) in pending { await model.answer(form, field: id, .text(text)) }
                await model.submit(form)
            }
        }
    }

    @ViewBuilder
    private func fieldView(_ field: RemoteFormField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !field.title.isEmpty { Text(field.title + (field.required ? " *" : "")).font(.system(size: 12, weight: .semibold)) }
            if !field.detail.isEmpty { Text(field.detail).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            switch field.type {
            case "single":
                ForEach(field.options ?? [], id: \.value) { option in
                    let picked = form.answers[field.id] == .text(option.value)
                    Button { Task { await model.answer(form, field: field.id, .text(option.value)) } } label: {
                        Label(option.title, systemImage: picked ? "largecircle.fill.circle" : "circle")
                    }
                    .accessibilityIdentifier("option-\(field.id)-\(option.value)")
                }
            case "multi":
                ForEach(field.options ?? [], id: \.value) { option in
                    let current: [String] = { if case .list(let list)? = form.answers[field.id] { return list } else { return [] } }()
                    let picked = current.contains(option.value)
                    Button {
                        let next = picked ? current.filter { $0 != option.value } : current + [option.value]
                        Task { await model.answer(form, field: field.id, .list(next)) }
                    } label: { Label(option.title, systemImage: picked ? "checkmark.square.fill" : "square") }
                    .accessibilityIdentifier("option-\(field.id)-\(option.value)")
                }
            case "boolean":
                Toggle(field.title, isOn: Binding(get: { form.answers[field.id] == .flag(true) },
                                                  set: { value in Task { await model.answer(form, field: field.id, .flag(value)) } }))
                    .labelsHidden()
            default:
                TextField(field.type == "number" ? "Number" : "Answer", text: Binding(
                    get: { typed[field.id] ?? { if case .text(let text)? = form.answers[field.id] { return text } else { return "" } }() },
                    set: { typed[field.id] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(field.type == "number" ? .decimalPad : .default)
                    .onSubmit { Task { await model.answer(form, field: field.id, .text(typed[field.id] ?? "")) } }
                    .accessibilityIdentifier("field-\(field.id)")
            }
        }
    }
}

// MARK: Composer

private struct Composer: View {
    @Environment(\.macAccent) private var macAccent
    @ChatScale(.body) private var bodyScale
    let model: ChatModel
    @Environment(VoiceModel.self) private var voice: VoiceModel?
    @Binding var showFiles: Bool
    @Binding var showPhotos: Bool
    @Binding var focused: Bool

    /// Gap between the send capsule and the field's top, bottom and trailing edges.
    private static let capsuleInset: CGFloat = 6
    private static let capsuleHeight: CGFloat = GlassCircleButtonStyle.size - 2 * capsuleInset
    private static let capsuleWidth: CGFloat = (capsuleHeight * 1.375).rounded()
    /// Width the capsule takes at the field's trailing edge, so text wraps before it.
    private static let inlineSendWidth: CGFloat = capsuleWidth + capsuleInset

    var body: some View {
        if let voice, voice.state == .recording {
            VoiceRecordingBar(voice: voice)
        } else {
            composer
        }
    }

    private var composer: some View {
        GlassGroup {
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    // The picker is presented from ChatView. A PhotosPicker inside the menu is removed when the menu closes.
                    Button { showPhotos = true } label: { Label("Photo", systemImage: SharedSymbols.photo) }
                        .accessibilityIdentifier("attach-photo")
                    Button { showFiles = true } label: { Label("File", systemImage: SharedSymbols.file) }
                } label: { Image(systemName: SharedSymbols.attach).glassCircle() }
                    .accessibilityLabel("Attach").accessibilityIdentifier("attach-button")
                field
                if let voice { MicButton(voice: voice) }
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.running)
        .onChange(of: model.draft) { _, _ in voice?.userTyped() }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reply = model.replyTo {
                HStack(spacing: 4) {
                    ReplyQuote(reply: RemoteChatReply(itemID: reply.id, sender: reply.kind == "user" ? "You" : "Reply", text: model.replySelection ?? reply.text ?? "",
                                                      selection: model.replySelection == nil ? nil : true))
                    Spacer(minLength: 0)
                    Button { model.replyTo = nil } label: { Image(systemName: SharedSymbols.removeAttachment) }.foregroundStyle(.secondary)
                        .accessibilityLabel("Cancel reply").accessibilityIdentifier("cancel-reply")
                }
                .padding(.horizontal, 6).padding(.top, 4)
                .accessibilityIdentifier("reply-bar")
            }
            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(model.attachments.enumerated()), id: \.element.id) { index, attachment in
                            if let preview = attachment.preview { thumbnail(preview, attachment, index) } else { chip(attachment, index) }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .accessibilityIdentifier("attachments")
            }
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty {
                    Text("Message").font(.system(size: ChatMetrics.macBody * bodyScale)).foregroundStyle(.placeholder).padding(.leading, 6).padding(.vertical, ComposerTextView.verticalInset).allowsHitTesting(false).accessibilityHidden(true)
                }
                ComposerTextView(text: Bindable(model).draft, isFocused: $focused) { data in Task { await model.attachPastedImage(data) } }
                    .padding(.trailing, Self.inlineSendWidth - 4)
            }
        }
        .padding(.horizontal, 4)
        .frame(minHeight: GlassCircleButtonStyle.size)
        .overlay(alignment: .bottomTrailing) {
            capsuleButton.padding(Self.capsuleInset)
        }
        .animation(.easeOut(duration: 0.12), value: model.canSend)
        .animation(.easeOut(duration: 0.12), value: model.running)
        .chromeGlass(in: RoundedRectangle(cornerRadius: GlassCircleButtonStyle.size / 2, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    /// Stop while a turn runs and nothing is typed, otherwise Send (grey when empty).
    @ViewBuilder
    private var capsuleButton: some View {
        if model.running, !model.canSend {
            capsule(SharedSymbols.stop, fill: .red, foreground: .white) { Task { await model.stopTurn() } }
                .accessibilityLabel("Stop").accessibilityIdentifier("stop-button")
        } else {
            capsule(SharedSymbols.send, fill: model.canSend ? macAccent : Color(.tertiarySystemFill),
                    foreground: model.canSend ? .white : Color.secondary) { Task { await model.send() } }
                .disabled(!model.canSend)
                .accessibilityLabel("Send").accessibilityIdentifier("send-button")
        }
    }

    private func capsule(_ symbol: String, fill: Color, foreground: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(foreground)
                .frame(width: Self.capsuleWidth, height: Self.capsuleHeight)
                .background(fill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// A pasted image: 48 pt high, with its remove button at the top trailing corner, like the Mac's thumbnail.
    private func thumbnail(_ image: UIImage, _ attachment: PendingAttachment, _ index: Int) -> some View {
        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
            .accessibilityElement(children: .ignore).accessibilityLabel(model.uploadFailure.map { "Pasted image. \($0)" } ?? "Pasted image").accessibilityIdentifier("attachment-thumbnail-\(index)")
            .overlay { uploadBadge }
            .overlay(alignment: .topTrailing) {
                Button { model.removeAttachment(attachment) } label: {
                    Image(systemName: SharedSymbols.removeAttachment).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                }
                .padding(2).accessibilityLabel("Remove image").accessibilityIdentifier("attachment-remove-\(index)")
            }
    }

    /// A photo from the picker or a file, which the phone shows by name.
    private func chip(_ attachment: PendingAttachment, _ index: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: attachment.isImage ? SharedSymbols.photo : SharedSymbols.file)
            Text(attachment.fileName).lineLimit(1)
            Button { model.removeAttachment(attachment) } label: { Image(systemName: SharedSymbols.removeAttachment) }
                .accessibilityLabel("Remove \(attachment.fileName)").accessibilityIdentifier("attachment-remove-\(index)")
        }
        .font(.caption).padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary, in: Capsule())
        .overlay(alignment: .leading) { uploadBadge.scaleEffect(0.8).offset(x: -6) }
    }

    /// Shown on every attachment after an upload failed. Tapping it sends again. It is an overlay, so the composer keeps its height.
    @ViewBuilder
    private var uploadBadge: some View {
        if let failure = model.uploadFailure {
            Button { Task { await model.send() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(Circle().fill(OutgoingLook.failedFill))
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(model.sending)
            .accessibilityLabel("Retry upload. \(failure)").accessibilityIdentifier("upload-retry")
        }
    }
}

// MARK: Threads

/// The Mac chat's settings popover, as a sheet: project, agent, model and the agent's mode. Each choice goes to the Mac and the sheet shows what
/// the Mac reports back, so a refused change does not stay on screen.
private struct ChatSettingsSheet: View {
    let model: ChatModel
    @Environment(\.dismiss) private var dismiss

    private var options: RemoteChatOptions { model.snapshot?.options ?? RemoteChatOptions() }
    private var locked: Bool { model.running }

    private var folderName: String {
        guard let folder = options.folder else { return "No project" }
        return options.folders.first { $0.id == folder }?.name ?? (folder as NSString).lastPathComponent
    }

    private var modelName: String {
        guard let id = model.snapshot?.model else { return "Default" }
        return options.models.first { $0.id == id }?.name ?? id
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        Picker("Project", selection: Binding(
                            get: { options.folder ?? "" },
                            set: { id in Task { await model.setOptions(id.isEmpty ? RemoteChatOptionsChange(noProject: true) : RemoteChatOptionsChange(folder: id)) } })) {
                            Text("No project").tag("")
                            ForEach(options.folders) { Text($0.name).tag($0.id) }
                            if let folder = options.folder, !options.folders.contains(where: { $0.id == folder }) { Text(folderName).tag(folder) }
                        }
                        .accessibilityIdentifier("settings-project")
                        Picker("Agent", selection: Binding(
                            get: { model.snapshot?.agent.id ?? "" },
                            set: { id in Task { await model.setOptions(RemoteChatOptionsChange(agent: id)) } })) {
                            ForEach(options.agents) { Text($0.name).tag($0.id) }
                        }
                        .accessibilityIdentifier("settings-agent")
                        if !options.models.isEmpty {
                            Picker("Model", selection: Binding(
                                get: { model.snapshot?.model ?? "" },
                                set: { id in Task { await model.setOptions(RemoteChatOptionsChange(model: .some(id.isEmpty ? nil : id))) } })) {
                                Text("Default (agent setting)").tag("")
                                ForEach(options.models) { Text($0.name).tag($0.id) }
                            }
                            .accessibilityIdentifier("settings-model")
                        }
                    } footer: {
                        Text(locked ? "The agent is working. Project, agent and model change when it is done." : "Changing the project or agent starts a new chat on your Mac.")
                    }
                    .disabled(locked)
                    if !options.modes.isEmpty {
                        // The modes the agent advertises, the same list as the Mac's picker. A mode can change while the agent works.
                        Section {
                            Picker("Mode", selection: Binding(
                                get: { options.mode ?? "" },
                                set: { id in if !id.isEmpty { Task { await model.setOptions(RemoteChatOptionsChange(mode: id)) } } })) {
                                ForEach(options.modes) { mode in
                                    VStack(alignment: .leading) {
                                        Text(mode.name)
                                        if let detail = mode.detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    .tag(mode.id)
                                    .accessibilityIdentifier("settings-mode-\(mode.id)")
                                }
                            }
                            .pickerStyle(.inline).labelsHidden()
                        } header: {
                            Text("Mode")
                        } footer: {
                            Text("What the agent may do without asking. The agent defines the modes.")
                        }
                    }
                    Section {
                        Button { Task { if await model.newChat() { dismiss() } } } label: { Label("New chat", systemImage: SharedSymbols.newChat) }
                            .disabled(locked)
                            .accessibilityIdentifier("settings-new-chat")
                    }
            
                }.listRowBackground(SharedTheme.card)
            }
            .navigationTitle("Chat settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Cannot do that now", isPresented: Binding(get: { model.conflictMessage != nil }, set: { if !$0 { model.conflictMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.conflictMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ThreadsSheet: View {
    let model: ChatModel
    var avatar: CGImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section {
                        Button { Task { if await model.newChat() { dismiss() } } } label: { Label("New chat", systemImage: SharedSymbols.newChat) }
                            .accessibilityIdentifier("new-chat-button")
                    } footer: {
                        Text("New chat and Open on Mac change the chat on your Mac.")
                    }
                    Section("Saved chats") {
                        ForEach(model.threads) { thread in
                            NavigationLink(value: thread) {
                                VStack(alignment: .leading) {
                                    Text(thread.title).lineLimit(2)
                                    Text([thread.folderLabel, thread.updated.formatted(date: .abbreviated, time: .shortened)].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("thread-\(thread.id)")
                        }
                    }
            
                }.listRowBackground(SharedTheme.card)
            }
            .navigationTitle("Chats")
            .themedScreen()
            .navigationDestination(for: RemoteChatThread.self) { ThreadReader(model: model, thread: $0, avatar: avatar, dismissSheet: { dismiss() }) }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await model.loadThreads() }
            .alert("Cannot do that now", isPresented: Binding(get: { model.conflictMessage != nil && !model.readerOpen }, set: { if !$0 { model.conflictMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.conflictMessage ?? "")
            }
        }
    }
}

private struct ThreadReader: View {
    let model: ChatModel
    let thread: RemoteChatThread
    var avatar: CGImage?
    let dismissSheet: () -> Void
    @State private var items: [RemoteChatItem] = []
    @State private var expandedMessages: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(RemoteTranscriptGroup.make(items)) { group in
                    TranscriptGroupView(group: group, photos: [:], avatar: avatar, expanded: expandedMessages,
                                        toggleExpand: { id in if !expandedMessages.insert(id).inserted { expandedMessages.remove(id) } })
                }
            }
            .padding()
        }
        .navigationTitle(thread.title)
        .themedScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Open on Mac") { Task { if await model.open(thread) { dismissSheet() } } }.accessibilityIdentifier("open-on-mac-button")
            }
        }
        .task { items = await model.thread(thread.id)?.items ?? [] }
        .onAppear { model.readerOpen = true }
        .onDisappear { model.readerOpen = false }
        // The sheet's own alert sits under this pushed screen, so a refusal from "Open on Mac" shows here.
        .alert("Cannot do that now", isPresented: Binding(get: { model.conflictMessage != nil }, set: { if !$0 { model.conflictMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.conflictMessage ?? "")
        }
    }
}
