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
    @State private var showThreads = false
    @State private var showFiles = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var focused = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 6)
                        .accessibilityIdentifier("chat-error")
                }
                // The composer floats over the transcript, so the background shows through the glass.
                Transcript(model: model)
                    .glassBottomBar {
                        VStack(spacing: 6) {
                            if let notice = model.snapshot?.notice {
                                Label(notice, systemImage: "desktopcomputer").font(.footnote)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 6)
                                    .background(.thinMaterial).accessibilityIdentifier("chat-notice")
                            }
                            Composer(model: model, showFiles: $showFiles, photos: $photos, focused: $focused)
                        }
                    }
            }
            .background {
                ChatBackgroundPicture(id: backgroundID, customImage: backgroundImage.map(Image.init(uiImage:)), fallback: Color(.systemBackground))
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("chat-background-\(backgroundID)")
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(model.title).font(.headline).lineLimit(1).accessibilityIdentifier("chat-title")
                        Text(model.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).accessibilityIdentifier("chat-subtitle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showThreads = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("Chats").accessibilityIdentifier("threads-button")
                }
            }
            .sheet(isPresented: $showThreads) { ThreadsSheet(model: model) }
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

private struct Transcript: View {
    let model: ChatModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.items) { item in
                        MessageRow(item: item, photo: item.fileName.flatMap { model.sentPhotos[$0] },
                                   onReply: item.canReply ? { model.replyTo = item } : nil)
                    }
                    ForEach(model.approvals) { ApprovalCard(approval: $0, model: model) }
                    ForEach(model.forms) { FormCard(form: $0, model: model) }
                    ForEach(model.queue) { QueuedRow(queued: $0) }
                    if model.running { RunningRow(model: model) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal).padding(.vertical, 8)
            }
            // Content that grows (a streamed reply) stays pinned to the bottom, and a reader who scrolled up stays where they are.
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .softBottomEdge()
            .overlay {
                if model.loaded, model.items.isEmpty {
                    ContentUnavailableView("No messages", systemImage: "bubble.left", description: Text("Say something to start."))
                }
            }
            .onChange(of: model.items.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .accessibilityIdentifier("transcript")
        }
    }
}

private struct RunningRow: View {
    let model: ChatModel

    var body: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text(model.snapshot?.activity ?? "Working").font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("running-row")
    }
}

private struct QueuedRow: View {
    let queued: RemoteQueued

    var body: some View {
        HStack {
            Image(systemName: "clock").foregroundStyle(.secondary)
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
    var onReply: (() -> Void)?

    var body: some View {
        Group {
            switch item.row {
            case .user(let text): bubble(text, mine: true)
            case .assistant(let text): bubble(text, mine: false)
            case .tool(let text, let ok):
                HStack(spacing: 6) {
                    Image(systemName: ok == nil ? "gearshape" : (ok == true ? "checkmark.circle" : "xmark.circle"))
                        .foregroundStyle(ok == false ? .red : .secondary)
                    Text(text).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
            case .error(let text):
                Label(text, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
            case .attachment(let name, let isImage):
                Attachment(name: name, isImage: isImage, photo: photo, mine: item.origin == "ios")
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
        .contextMenu {
            if let onReply { Button { onReply() } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") } }
            if let text = item.text, !text.isEmpty { Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") } }
        }
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if let reply = item.reply { Quote(reply: reply) }
            Text(Self.markdown(text))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(mine ? Color.white : Color.primary)
                .background(mine ? Color.accentColor : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                .textSelection(.enabled)
                .accessibilityIdentifier("bubble-\(item.id)")
            if let origin = item.origin, origin != "ios" { Text(Self.originName(origin)).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    static func originName(_ origin: String) -> String {
        switch origin {
        case "telegram": return "Telegram"
        case "automation": return "Automation"
        case "job": return "Background job"
        case "voice": return "Voice"
        default: return origin.capitalized
        }
    }
}

private struct Quote: View {
    let reply: RemoteChatReply

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(reply.sender).font(.caption2.bold())
            Text(reply.text).font(.caption).lineLimit(2)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 8)
        .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 2) }
    }
}

private struct Attachment: View {
    let name: String
    let isImage: Bool
    let photo: Data?
    let mine: Bool

    var body: some View {
        if let photo, let image = UIImage(data: photo) {
            Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 220, maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("photo-\(name)")
        } else {
            // A screenshot the Mac took, or a file whose bytes the phone does not have. The Mac does not offer them for download.
            Label(mine ? Self.display(name) : "Screenshot on the Mac", systemImage: isImage ? "photo" : "doc")
                .font(.footnote).padding(8).background(.quaternary, in: Capsule())
                .accessibilityIdentifier("chip-\(name)")
        }
    }

    /// The Mac saves a file as `<8 characters>-<name>`. The phone shows the name.
    static func display(_ stored: String) -> String {
        guard stored.count > 9, stored[stored.index(stored.startIndex, offsetBy: 8)] == "-" else { return stored }
        return String(stored.dropFirst(9))
    }
}

private struct FormRecord: View {
    let message: String
    let skipped: Bool
    let lines: [RemoteFormLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(skipped ? "Skipped: \(message)" : message, systemImage: skipped ? "arrow.uturn.right" : "checkmark.bubble").font(.footnote.bold())
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text("\(line.question): \(line.answer)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: Cards

private struct ApprovalCard: View {
    let approval: RemoteApproval
    let model: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(approval.title, systemImage: "hand.raised.fill").font(.subheadline.bold())
            if !approval.detail.isEmpty { Text(approval.detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(6) }
            HStack {
                Button("Allow") { Task { await model.decide(approval, allow: true) } }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("allow-\(approval.id)")
                Button("Deny", role: .destructive) { Task { await model.decide(approval, allow: false) } }.buttonStyle(.bordered)
                    .accessibilityIdentifier("deny-\(approval.id)")
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
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
            Label(form.message, systemImage: "questionmark.bubble.fill").font(.subheadline.bold())
            ForEach(form.fields) { field in fieldView(field) }
            HStack {
                Button("Submit") { Task { await model.submit(form) } }.buttonStyle(.borderedProminent).disabled(!form.canSubmit)
                    .accessibilityIdentifier("submit-\(form.id)")
                Button("Skip") { Task { await model.skip(form) } }.buttonStyle(.bordered)
                    .accessibilityIdentifier("skip-\(form.id)")
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("form-\(form.id)")
    }

    @ViewBuilder
    private func fieldView(_ field: RemoteFormField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !field.title.isEmpty { Text(field.title + (field.required ? " *" : "")).font(.footnote.bold()) }
            if !field.detail.isEmpty { Text(field.detail).font(.caption).foregroundStyle(.secondary) }
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
    let model: ChatModel
    @Environment(VoiceModel.self) private var voice: VoiceModel?
    @Binding var showFiles: Bool
    @Binding var photos: [PhotosPickerItem]
    @Binding var focused: Bool

    /// Width the inline send button takes at the field's trailing edge, so text wraps before it.
    private static let inlineSendWidth: CGFloat = 28

    var body: some View {
        GlassGroup {
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    PhotosPicker(selection: $photos, maxSelectionCount: ChatModel.maxPendingImages, matching: .images) { Label("Photo", systemImage: "photo") }
                    Button { showFiles = true } label: { Label("File", systemImage: "doc") }
                } label: { Image(systemName: "paperclip").glassCircle() }
                    .accessibilityLabel("Attach").accessibilityIdentifier("attach-button")
                field
                if let voice { MicButton(voice: voice) }
                if model.running {
                    Button { Task { await model.stopTurn() } } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                            .frame(width: GlassCircleButtonStyle.size, height: GlassCircleButtonStyle.size)
                            .tintedCircle(.red)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Stop").accessibilityIdentifier("stop-button")
                    .transition(.scale.combined(with: .opacity))
                }
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
                    Quote(reply: RemoteChatReply(itemID: reply.id, sender: reply.kind == "user" ? "You" : "Reply", text: reply.text ?? ""))
                    Spacer(minLength: 0)
                    Button { model.replyTo = nil } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(.secondary)
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
                    Text("Message").foregroundStyle(.placeholder).padding(.leading, 6).padding(.vertical, 8).allowsHitTesting(false).accessibilityHidden(true)
                }
                ComposerTextView(text: Bindable(model).draft, isFocused: $focused) { data in Task { await model.attachPastedImage(data) } }
                    .padding(.trailing, model.canSend ? Self.inlineSendWidth : 0)
            }
        }
        .padding(4)
        .frame(minHeight: GlassCircleButtonStyle.size)
        .overlay(alignment: .bottomTrailing) {
            if model.canSend {
                Button { Task { await model.send() } } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: Self.inlineSendWidth - 4, height: Self.inlineSendWidth - 4)
                        .tintedCircle(.accentColor)
                }
                .buttonStyle(.plain).accessibilityLabel("Send").accessibilityIdentifier("send-button")
                .padding(4)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.canSend)
        .chromeGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    /// A pasted image: 48 pt high, with its remove button at the top trailing corner, like the Mac's thumbnail.
    private func thumbnail(_ image: UIImage, _ attachment: PendingAttachment, _ index: Int) -> some View {
        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
            .accessibilityElement(children: .ignore).accessibilityLabel("Pasted image").accessibilityIdentifier("attachment-thumbnail-\(index)")
            .overlay(alignment: .topTrailing) {
                Button { model.removeAttachment(attachment) } label: {
                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                }
                .padding(2).accessibilityLabel("Remove image").accessibilityIdentifier("attachment-remove-\(index)")
            }
    }

    /// A photo from the picker or a file, which the phone shows by name.
    private func chip(_ attachment: PendingAttachment, _ index: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: attachment.isImage ? "photo" : "doc")
            Text(attachment.fileName).lineLimit(1)
            Button { model.removeAttachment(attachment) } label: { Image(systemName: "xmark.circle.fill") }
                .accessibilityLabel("Remove \(attachment.fileName)").accessibilityIdentifier("attachment-remove-\(index)")
        }
        .font(.caption).padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary, in: Capsule())
    }
}

// MARK: Threads

private struct ThreadsSheet: View {
    let model: ChatModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { Task { if await model.newChat() { dismiss() } } } label: { Label("New chat", systemImage: "square.and.pencil") }
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
            }
            .navigationTitle("Chats")
            .navigationDestination(for: RemoteChatThread.self) { ThreadReader(model: model, thread: $0, dismissSheet: { dismiss() }) }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await model.loadThreads() }
            .alert("Cannot do that now", isPresented: Binding(get: { model.conflictMessage != nil }, set: { if !$0 { model.conflictMessage = nil } })) {
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
    let dismissSheet: () -> Void
    @State private var items: [RemoteChatItem] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(items) { MessageRow(item: $0) }
            }
            .padding()
        }
        .navigationTitle(thread.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Open on Mac") { Task { if await model.open(thread) { dismissSheet() } } }.accessibilityIdentifier("open-on-mac-button")
            }
        }
        .task { items = await model.thread(thread.id)?.items ?? [] }
    }
}
