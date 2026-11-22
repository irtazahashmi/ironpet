import IronPetKit
import Observation
import SwiftUI

/// The state of Find in chat: the query, every match in the open chat and the current one. The bar and the transcript share it.
@MainActor @Observable
final class ChatFindState {
    var isOpen = false
    var query = "" {
        didSet { if query != oldValue { current = nil; index = nil } }
    }
    private(set) var matches: [RemoteChatFind.Match] = []
    private(set) var index: Int?
    private(set) var current: RemoteChatFind.Match?
    /// Counts each jump, so the field takes focus again when the reader opens find a second time.
    private(set) var focusTick = 0

    var label: String { ChatFindText.label(query: query, count: matches.count, index: index) }
    var highlights: [String: RemoteChatFind.RowHighlight] {
        isOpen && !query.isEmpty ? RemoteChatFind.highlights(query: query, matches: matches, current: current) : [:]
    }

    func open() {
        isOpen = true
        focusTick += 1
    }

    func close() {
        isOpen = false
        query = ""
        matches = []
    }

    /// Recomputes the matches after the query or the transcript changed. The reader keeps the current match while it exists.
    func update(_ items: [RemoteChatItem]) {
        guard isOpen else { return }
        matches = RemoteChatFind.matches(query: query, in: items)
        index = ChatFindText.reconcile(current: current, previousIndex: index, in: matches)
        current = index.map { matches[$0] }
    }

    func step(by delta: Int) {
        index = ChatFindText.step(from: index, count: matches.count, by: delta)
        current = index.map { matches[$0] }
    }
}

extension AttributedString {
    /// The text with every match of the query highlighted, the current one in a stronger colour. Text without a match is unchanged.
    func findHighlighted(segment: Int, find: RemoteChatFind.RowHighlight?) -> AttributedString {
        guard let find else { return self }
        let ranges = ChatFindText.ranges(of: find.query, in: String(characters))
        guard !ranges.isEmpty else { return self }
        var result = self
        var cursor = result.startIndex
        var cursorOffset = 0
        for (occurrence, range) in ranges.enumerated() {
            let start = result.characters.index(cursor, offsetBy: range.lowerBound - cursorOffset)
            let end = result.characters.index(start, offsetBy: range.count)
            cursor = end
            cursorOffset = range.upperBound
            let isCurrent = find.current?.segment == segment && find.current?.occurrence == occurrence
            result[start..<end].backgroundColor = isCurrent ? .orange : Color.yellow
            result[start..<end].foregroundColor = .black
        }
        return result
    }
}

/// The bar above the transcript: query field, "2 of 5", previous and next, done.
struct ChatFindBar: View {
    @Bindable var find: ChatFindState
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: SharedSymbols.find).foregroundStyle(.secondary)
            TextField("Find in chat", text: $find.query)
                .focused($focused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { find.step(by: 1) }
                .accessibilityIdentifier("find-field")
            Text(find.label).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityIdentifier("find-label")
            Button { find.step(by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(find.matches.isEmpty).accessibilityLabel("Previous match").accessibilityIdentifier("find-previous")
            Button { find.step(by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(find.matches.isEmpty).accessibilityLabel("Next match").accessibilityIdentifier("find-next")
            Button("Done") { find.close() }.accessibilityIdentifier("find-done")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
        .onAppear { focused = true }
        .onChange(of: find.focusTick) { focused = true }
    }
}
