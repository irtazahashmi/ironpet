import IronPetKit
import SwiftUI
import UIKit

/// Opens a Mac file preview for an absolute path. The live chat sets it, and a view without it draws paths as plain text, so a saved
/// thread does not show links that go nowhere.
private struct OpenFilePathKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var openFilePath: ((String) -> Void)? {
        get { self[OpenFilePathKey.self] }
        set { self[OpenFilePathKey.self] = newValue }
    }
}

extension AttributedString {
    /// Links every file path in the text to a preview. The phone cannot tell whether a path exists, so each one is a link, and the Mac
    /// answers a tap with the file or the reason it will not show it. A markdown link already in the text is left alone.
    func linkingFilePaths(_ enabled: Bool) -> AttributedString {
        let plain = String(characters)
        guard enabled, plain.contains("/") else { return self }
        var result = self
        var plainIndex = plain.startIndex
        var resultIndex = result.startIndex
        var offset = 0
        for match in ChatFilePaths.detect(in: plain, home: nil) {
            let lower = offset + plain.distance(from: plainIndex, to: match.range.lowerBound)
            let upper = lower + plain.distance(from: match.range.lowerBound, to: match.range.upperBound)
            let a = result.characters.index(resultIndex, offsetBy: lower - offset)
            let b = result.characters.index(a, offsetBy: upper - lower)
            plainIndex = match.range.upperBound
            resultIndex = b
            offset = upper
            guard result[a..<b].runs.allSatisfy({ $0.link == nil }), let url = ChatFilePaths.link(forPath: match.path) else { continue }
            result[a..<b].link = url
            result[a..<b].underlineStyle = .single
        }
        return result
    }
}

/// A path the reader tapped, as a sheet item.
struct FilePreviewTarget: Identifiable, Equatable {
    let path: String
    var id: String { path }
}

/// The Mac's preview of one file: its text, or the image. When the Mac refuses, its reason is the content.
struct FilePreviewSheet: View {
    let client: IronPetClient
    let target: FilePreviewTarget
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case text(String, truncated: Bool)
        case image(UIImage)
        case failed(String)
    }

    @State private var phase = Phase.loading

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("Asking the Mac").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .text(let text, let truncated):
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(text.isEmpty ? "The file is empty." : text)
                                .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("file-preview-text")
                            if truncated {
                                Text("Showing the start of the file.").font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("file-preview-truncated")
                            }
                        }
                        .padding()
                    }
                case .image(let image):
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).accessibilityIdentifier("file-preview-image")
                    }
                case .failed(let reason):
                    ContentUnavailableView {
                        Label("Cannot show this file", systemImage: "doc.questionmark")
                    } description: {
                        Text(reason).accessibilityIdentifier("file-preview-error")
                    }
                }
            }
            .navigationTitle((target.path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("file-preview-done") }
            }
            .safeAreaInset(edge: .bottom) {
                Text(target.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    .padding(.horizontal).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
                    .accessibilityIdentifier("file-preview-path")
            }
        }
        .task { await load() }
        .accessibilityIdentifier("file-preview")
    }

    private func load() async {
        do {
            let preview = try await client.filePreview(path: target.path)
            if preview.isImage {
                if let image = PastedImage.thumbnail(from: preview.data, longSide: 3000) { phase = .image(image) } else { phase = .failed("The image could not be decoded.") }
            } else if let text = preview.text {
                phase = .text(text, truncated: preview.truncated)
            } else {
                phase = .failed("The phone previews text files and images only.")
            }
        } catch ClientError.api(_, _, let message) {
            phase = .failed(message.prefix(1).uppercased() + message.dropFirst())
        } catch {
            phase = .failed(PlainError.message(for: error))
        }
    }
}
