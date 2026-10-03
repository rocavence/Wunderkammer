import AppKit
import UniformTypeIdentifiers

/// Share → Wunderkammer. No sheet to fill in: whatever was shared is written
/// to the shared inbox and the extension closes at once. The app picks it up.
final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task {
            await ShareInbox.deposit(items)
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

enum ShareInbox {
    static let group = "7F654HZB2H.com.rocavence.wunderkammer"

    /// One folder per share: a manifest plus any files it carried.
    @MainActor
    static func deposit(_ items: [NSExtensionItem]) async {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Inbox") else { return }
        let folder = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var entries: [[String: String]] = []
        for item in items {
            for provider in item.attachments ?? [] {
                if let entry = await read(provider, into: folder) { entries.append(entry) }
            }
            if entries.isEmpty, let text = item.attributedContentText?.string, !text.isEmpty {
                entries.append(["text": text])
            }
        }
        let data = try? JSONSerialization.data(withJSONObject: ["entries": entries])
        // Written last: the app only reads folders that have a manifest.
        try? data?.write(to: folder.appendingPathComponent("manifest.json"))
    }

    /// Senders hand URLs over as URL, NSURL, bytes or a string.
    private static func url(from loaded: NSSecureCoding) -> URL? {
        if let url = loaded as? URL { return url }
        if let data = loaded as? Data {
            return URL(dataRepresentation: data, relativeTo: nil) ?? String(data: data, encoding: .utf8).flatMap(URL.init(string:))
        }
        if let string = loaded as? String { return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    @MainActor
    private static func read(_ provider: NSItemProvider, into folder: URL) async -> [String: String]? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
           let url = (loaded as? URL) ?? (loaded as? Data).flatMap({ URL(dataRepresentation: $0, relativeTo: nil) }) {
            // The app references the file where it is. Pictures also travel as a
            // copy, in case the app can't reach the original.
            var entry = ["path": url.path]
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                let copy = folder.appendingPathComponent(url.lastPathComponent)
                if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { entry["image"] = copy.lastPathComponent }
            }
            return entry
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
           let url = Self.url(from: loaded), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return ["url": url.absoluteString]
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = try? await provider.loadDataRepresentation(for: .image) {
            let name = (provider.suggestedName ?? "Shared Image") + ".png"
            let file = folder.appendingPathComponent(name)
            if (try? data.write(to: file)) != nil { return ["image": name] }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
            return ["text": text]
        }
        return nil
    }
}

private extension NSItemProvider {
    func loadDataRepresentation(for type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { done in
            _ = loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data { done.resume(returning: data) } else { done.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}
