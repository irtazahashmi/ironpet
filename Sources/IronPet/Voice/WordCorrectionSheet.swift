import IronPetCore
import SwiftUI

/// A word from a transcript the user wants to fix. `heard` is what the transcriber wrote, `spelled` what it should have written.
struct WordCorrection: Identifiable {
    let id = UUID()
    var heard: String
}

/// Fixes one word of a transcript. It rewrites the word in the chat box draft when the draft still has it, and can add the
/// spelling to the word list so later recordings get it right.
struct WordCorrectionSheet: View {
    @State var correction: WordCorrection
    let apply: (_ heard: String, _ spelled: String, _ addToWordList: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var spelled = ""
    @State private var addToWordList = true

    private var canApply: Bool {
        !spelled.trimmingCharacters(in: .whitespaces).isEmpty
            && !correction.heard.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Correct a word").font(.headline)
            TextField("Heard as", text: $correction.heard)
                .accessibilityIdentifier("word-correction-heard")
            TextField("Should be", text: $spelled)
                .accessibilityIdentifier("word-correction-spelled")
                .onSubmit(submit)
            Toggle("Add to word list", isOn: $addToWordList)
                .accessibilityIdentifier("word-correction-add")
            Text("The word list is kept on this Mac and used for every recording from now on.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply", action: submit).keyboardShortcut(.defaultAction).disabled(!canApply)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func submit() {
        guard canApply else { return }
        apply(correction.heard.trimmingCharacters(in: .whitespaces), spelled.trimmingCharacters(in: .whitespaces), addToWordList)
        dismiss()
    }
}

/// Settings → Voice: the personal word list. Each row is a term and, optionally, how it tends to come out wrong.
struct WordListSection: View {
    @ObservedObject private var list = VoiceVocabulary.shared.wordList
    @State private var newTerm = ""
    @State private var newMisheard = ""

    var body: some View {
        Section {
            ForEach(list.terms) { entry in
                WordListRow(entry: entry, list: list)
            }
            HStack {
                TextField("New term", text: $newTerm).onSubmit(add)
                    .accessibilityIdentifier("word-list-new-term")
                TextField("Often heard as (comma separated)", text: $newMisheard).onSubmit(add)
                    .accessibilityIdentifier("word-list-new-misheard")
                Button("Add", action: add).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Word list")
        } footer: {
            Text("Names and terms that voice input should spell your way, such as a product or a teammate. Add how the recording usually gets it wrong, like \"length fuse\" for Langfuse. People, projects, organizations and tools that ironpet already remembers count without being added. The list stays on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func add() {
        list.add(newTerm, misheard: WordListRow.forms(newMisheard))
        newTerm = ""
        newMisheard = ""
    }
}

private struct WordListRow: View {
    let entry: WordTerm
    let list: WordListStore
    @State private var term = ""
    @State private var misheard = ""

    var body: some View {
        HStack {
            TextField("Term", text: $term).onSubmit(save)
            TextField("Often heard as", text: $misheard).onSubmit(save)
            Button(role: .destructive) { list.remove(id: entry.id) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove \(entry.term)")
                .accessibilityLabel("Remove \(entry.term)")
        }
        .onAppear(perform: load)
        .onChange(of: entry) { load() }
    }

    private func load() {
        term = entry.term
        misheard = entry.misheard.joined(separator: ", ")
    }

    private func save() {
        if !list.update(id: entry.id, term: term, misheard: Self.forms(misheard)) { load() }
    }

    static func forms(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
