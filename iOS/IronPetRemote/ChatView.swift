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
    @State private var showThreads = false
    @State private var showSettings = false
    @State private var showFiles = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var focused = false
    @State private var find = ChatFindState()
    @State private var preview: FilePreviewTarget?

    /// Changes when the query or the transcript does, so the matches are found again.
    private var findKey: String {
        "\(find.query)-\(find.isOpen)-\(model.displayItems.count)-\(model.displayItems.last?.text?.utf16.count ?? 0)"
    }
    @Environment(VoiceModel.self) private var voice: VoiceModel?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if find.isOpen { ChatFindBar(find: find) }
                if let message = model.errorMessage {
                    Label(message, systemImage: SharedSymbols.warning).font(.footnote).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 6)
                        .accessibilityIdentifier("chat-error")
                }
                // The composer floats over the transcript, so the background shows through the glass.
                Transcript(model: model, find: find, avatar: avatar)
                    .environment(\.openFilePath, { preview = FilePreviewTarget(path: $0) })
                    .glassBottomBar {
                        VStack(spacing: 6) {
                            if let notice = model.snapshot?.notice {
                                Label(notice, systemImage: "desktopcomputer").font(.footnote)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 6)
                                    .background(.thinMaterial).accessibilityIdentifier("chat-notice")
                            }
                            if let voice { VoiceNotice(voice: voice) }
                            Composer(model: model, showFiles: $showFiles, photos: $photos, focused: $focused)
                        }
                    }
            }
            .background {
                ChatBackgroundPicture(id: backgroundID, customImage: backgroundImage.map(Image.init(uiImage:)), fallback: SharedTheme.window)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("chat-background-\(backgroundID)")
            }
            .navigationTitle(model.title)
            .themedScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(model.title).font(.headline).lineLimit(1).accessibilityIdentifier("chat-title")
                        Text(model.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).accessibilityIdentifier("chat-subtitle")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { find.open() } label: { Image(systemName: SharedSymbols.find) }
                        .accessibilityLabel("Find in chat").accessibilityIdentifier("chat-find-button")
                    Button { showSettings = true } label: { Image(systemName: SharedSymbols.chatOptions) }
                        .accessibilityLabel("Chat settings").accessibilityIdentifier("chat-settings-button")
                    Button { showThreads = true } label: { Image(systemName: SharedSymbols.history) }
                        .accessibilityLabel("Chats").accessibilityIdentifier("threads-button")
                }
            }
            .onChange(of: findKey) { find.update(model.displayItems) }
            .sheet(isPresented: $showThreads) { ThreadsSheet(model: model, avatar: avatar) }
            .sheet(isPresented: $showSettings) { ChatSettingsSheet(model: model) }
            .sheet(item: $preview) { FilePreviewSheet(client: model.client, target: $0) }
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
            .onChange(of: photos) { _, picked in
                guard !picked.isEmpty else { return }
                Task {
                    for (index, item) in picked.enumerated() {
                        guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                        let type = item.supportedContentTypes.first
                        let ext = type?.preferredFilenameExtension ?? "jpg"
                        model.attach(data: data, fileName: "photo-\(index + 1).\(ext)", contentType: type?.preferredMIMEType ?? "image/jpeg")
                    }
                    photos = []
                }
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

private struct Transcript: View {
    let model: ChatModel
    let find: ChatFindState
    var avatar: CGImage?
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
                        ForEach(RemoteTranscriptGroup.make(model.displayItems)) { group in
                            TranscriptGroupView(group: group, photos: model.sentPhotos, images: model.images, avatar: avatar, expanded: expandedMessages,
                                                toggleExpand: { id in if !expandedMessages.insert(id).inserted { expandedMessages.remove(id) } },
                                                outbox: model.outbox, onRetry: { id in Task { await model.retry(id) } },
                                                onReply: { model.replyTo = $0 },
                                                readAloud: { item in voice.flatMap { ReadAloud(item: item, voice: $0) } },
                                                highlights: find.highlights)
                        }
                        if showsTyping { TypingRow(started: model.snapshot?.runStarted, avatar: avatar) }
                        ForEach(model.approvals) { ApprovalCard(approval: $0, model: model) }
                        ForEach(model.forms) { FormCard(form: $0, model: model) }
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
    var onReply: (RemoteChatItem) -> Void = { _ in }
    /// Nil in a saved thread, whose messages the Mac cannot read from the open chat.
    var readAloud: (RemoteChatItem) -> ReadAloud? = { _ in nil }
    var highlights: [String: RemoteChatFind.RowHighlight] = [:]

    var body: some View {
        switch group {
        case .tools(let steps):
            ToolStepsRow(steps: steps)
        case .item(let item):
            VStack(alignment: .trailing, spacing: 2) {
                MessageRow(item: item, photo: item.fileName.flatMap { photos[$0] }, images: images, avatar: avatar, expanded: expanded.contains(item.id),
                           onToggleExpand: { toggleExpand(item.id) }, onReply: item.canReply && !OutgoingMessage.isPending(item.id) ? { onReply(item) } : nil,
                           readAloud: item.kind == "assistant" ? readAloud(item) : nil, find: highlights[item.id])
                if let message = outbox.first(where: { $0.itemID == item.id }) { OutgoingStatus(message: message, onRetry: { onRetry(message.id) }) }
            }
        }
    }
}

/// Under a message the Mac has not confirmed: "Sending…" while it is on its way, or the error and a Retry button when it failed.
private struct OutgoingStatus: View {
    let message: OutgoingMessage
    let onRetry: () -> Void

    var body: some View {
        switch message.state {
        case .sending, .sent:
            // A voice message shows "Transcribing…" in its bubble until the text arrives.
            if !message.isTranscribing {
                Text("Sending…").font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("outgoing-sending")
            }
        case .failed(let reason):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Button("Retry", action: onRetry).font(.caption2.weight(.semibold)).accessibilityIdentifier("outgoing-retry")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("outgoing-failed")
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
    var onReply: (() -> Void)?
    var readAloud: ReadAloud?
    /// The highlights of Find in chat for this message. Nil outside a search.
    var find: RemoteChatFind.RowHighlight?
    @Environment(\.openFilePath) private var openFilePath

    var body: some View {
        Group {
            switch item.row {
            case .user(let text): UserBubble(item: item, text: text, expanded: expanded, onToggleExpand: onToggleExpand, find: find)
            case .assistant(let text): AssistantBubble(item: item, text: text, avatar: avatar, readAloud: readAloud, find: find)
            case .tool: ToolStepsRow(steps: [item])
            case .error(let text): ErrorRow(text: text)
            case .notice(let text): NoticeRow(notice: ChatNotice(text))
            case .attachment(let name, let isImage):
                Attachment(name: name, isImage: isImage, photo: photo, mine: item.origin == "ios", messageID: item.id, images: images)
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
        // A tap on a file path asks the Mac for a preview. Any other link keeps its usual action.
        .environment(\.openURL, OpenURLAction { url in
            guard let path = ChatFilePaths.path(from: url), let openFilePath else { return .systemAction }
            openFilePath(path)
            return .handled
        })
        .contextMenu {
            if let onReply { Button { onReply() } label: { Label("Reply", systemImage: SharedSymbols.reply) } }
            if let text = item.text, !text.isEmpty { Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: SharedSymbols.copy) } }
            if let readAloud {
                Button(action: readAloud.toggle) {
                    Label(readAloud.active ? "Stop Reading" : "Read Aloud", systemImage: readAloud.active ? SharedSymbols.stopSpeaking : SharedSymbols.speak)
                }
            }
        }
    }

    static func markdown(_ text: String) -> AttributedString { ChatMarkdown.inline(text) }

    static func originName(_ origin: String) -> String {
        OriginBadge(origin: origin)?.label ?? origin.capitalized
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

private struct FormCard: View {
    let form: RemoteForm
    let model: ChatModel
    @State private var typed: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(form.message.isEmpty ? "The agent has a question" : form.message, systemImage: SharedSymbols.question)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            ForEach(form.fields) { field in fieldView(field) }
            HStack {
                Button { Task { await model.submit(form) } } label: { Label("Submit", systemImage: SharedSymbols.allow).frame(minWidth: 70) }.buttonStyle(.borderedProminent).disabled(!form.canSubmit)
                    .accessibilityIdentifier("submit-\(form.id)")
                Button { Task { await model.skip(form) } } label: { Label("Skip", systemImage: SharedSymbols.skip).frame(minWidth: 70) }.buttonStyle(.bordered)
                    .accessibilityIdentifier("skip-\(form.id)")
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.5)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("form-\(form.id)")
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
    let model: ChatModel
    @Environment(VoiceModel.self) private var voice: VoiceModel?
    @Binding var showFiles: Bool
    @Binding var photos: [PhotosPickerItem]
    @Binding var focused: Bool

    /// Gap between the send capsule and the field's top, bottom and trailing edges.
    private static let capsuleInset: CGFloat = 6
    private static let capsuleHeight: CGFloat = GlassCircleButtonStyle.size - 2 * capsuleInset
    private static let capsuleWidth: CGFloat = (capsuleHeight * 1.375).rounded()
    /// Width the capsule takes at the field's trailing edge, so text wraps before it.
    private static let inlineSendWidth: CGFloat = capsuleWidth + capsuleInset

    var body: some View {
        GlassGroup {
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    PhotosPicker(selection: $photos, maxSelectionCount: ChatModel.maxPendingImages, matching: .images) { Label("Photo", systemImage: SharedSymbols.photo) }
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
                    ReplyQuote(reply: RemoteChatReply(itemID: reply.id, sender: reply.kind == "user" ? "You" : "Reply", text: reply.text ?? ""))
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
                    Text("Message").foregroundStyle(.placeholder).padding(.leading, 6).padding(.vertical, ComposerTextView.verticalInset).allowsHitTesting(false).accessibilityHidden(true)
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
            .accessibilityElement(children: .ignore).accessibilityLabel("Pasted image").accessibilityIdentifier("attachment-thumbnail-\(index)")
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
