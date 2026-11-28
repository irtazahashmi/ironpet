import IronPetKit
import UIKit
import UniformTypeIdentifiers

/// The share sheet entry of IronPet. It copies the audio it is given into the queue in the app group and ends. The app sends it to the
/// Mac the next time it is open, and shows it in the Meetings tab until then.
final class ShareViewController: UIViewController {
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.text = "Adding to IronPet…"
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
        Task { await handle() }
    }

    private func handle() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var files: [(url: URL, name: String, typeIdentifiers: [String])] = []
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
            if let file = await load(provider, into: scratch) { files.append(file) }
        }
        let queue = MeetingUploadQueue(folder: Self.folder)
        let result = ShareHandoff.accept(files, into: queue)
        if result.refusals.isEmpty, result.queued > 0 {
            label.text = result.queued == 1 ? "Added. IronPet sends it to your Mac." : "Added \(result.queued) files. IronPet sends them to your Mac."
        } else if result.queued == 0 {
            label.text = result.refusals.first ?? "IronPet imports m4a, mp3 and wav files."
        } else {
            label.text = "Added \(result.queued). \(result.refusals.joined(separator: " "))"
        }
        try? await Task.sleep(for: .seconds(result.refusals.isEmpty ? 1 : 3))
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// The system deletes the file it hands over when the closure returns, so the copy happens inside it.
    private func load(_ provider: NSItemProvider, into scratch: URL) async -> (url: URL, name: String, typeIdentifiers: [String])? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let name = provider.suggestedName.map { ($0 as NSString).pathExtension.isEmpty ? $0 + "." + url.pathExtension : $0 } ?? url.lastPathComponent
                let copy = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try FileManager.default.copyItem(at: url, to: copy) } catch { return continuation.resume(returning: nil) }
                continuation.resume(returning: (copy, name, provider.registeredTypeIdentifiers))
            }
        }
    }

    private static var folder: URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.ironpet.app")
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MeetingUploads", isDirectory: true)
    }
}
