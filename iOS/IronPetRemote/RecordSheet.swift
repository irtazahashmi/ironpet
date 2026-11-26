import IronPetKit
import SwiftUI

/// A record id tapped in a chat reply. The sheet opens it.
struct RecordLink: Identifiable, Equatable {
    let id: String
}

private struct OpenRecordKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    /// Set by the chat: a tap on a record link asks for the record to open in a sheet.
    var openRecord: ((String) -> Void)? {
        get { self[OpenRecordKey.self] }
        set { self[OpenRecordKey.self] = newValue }
    }
}

/// Loads one record for the sheet. The fetch is a closure so tests can answer without a Mac.
@MainActor @Observable
final class RecordModel {
    enum State: Equatable {
        case loading
        case loaded(RecordDetails)
        case failed(String)
    }

    private(set) var state: State = .loading
    @ObservationIgnored private let id: String
    @ObservationIgnored private let fetch: (String) async throws -> RecordDetails

    init(id: String, fetch: @escaping (String) async throws -> RecordDetails) {
        self.id = id
        self.fetch = fetch
    }

    func load() async {
        state = .loading
        do {
            state = .loaded(try await fetch(id))
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

/// The sheet for a tapped record link: the record's kind, its ids and its fields. A kind the Mac cannot read says to open it there.
struct RecordSheet: View {
    @State private var model: RecordModel
    @Environment(\.dismiss) private var dismiss

    init(client: IronPetClient, id: String) {
        _model = State(initialValue: RecordModel(id: id) { try await client.record($0) })
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("record-done") } }
        }
        .task { await model.load() }
        .accessibilityIdentifier("record-sheet")
    }

    private var title: String {
        if case .loaded(let record) = model.state { return record.title }
        return "Record"
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("record-loading")
        case .failed(let message):
            Text(message).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("record-error")
        case .loaded(let record):
            List {
                Section {
                    LabeledContent("Ref", value: record.ref)
                    LabeledContent("Kind", value: record.title)
                }
                if record.fields.isEmpty {
                    Section { Text("Open this on your Mac to see it.").foregroundStyle(.secondary).accessibilityIdentifier("record-open-on-mac") }
                } else {
                    Section {
                        ForEach(record.fields, id: \.name) { field in
                            LabeledContent(field.name, value: field.value).accessibilityIdentifier("record-field-\(field.name)")
                        }
                    }
                }
            }
        }
    }
}
