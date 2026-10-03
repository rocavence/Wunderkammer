import AppKit

/// Picks up what the Share extension leaves in the shared App Group inbox:
/// one folder per share, with a manifest.json written last.
@MainActor
final class ShareInboxWatcher {
    static let group = "7F654HZB2H.com.rocavence.wunderkammer"

    private let inbox: URL?
    private let collect: ([Source]) async -> Void
    private var timer: Timer?
    private var busy = false

    init(collect: @escaping ([Source]) async -> Void) {
        self.collect = collect
        inbox = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group)?
            .appendingPathComponent("Inbox")
    }

    func start() {
        guard let inbox else { return }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        check()
    }

    private func check() {
        guard !busy, let inbox,
              let folders = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
        else { return }
        let ready = folders.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
        guard !ready.isEmpty else { return }
        busy = true
        Task {
            for folder in ready {
                let sources = Self.sources(in: folder)
                if !sources.isEmpty { await collect(sources) }
                try? FileManager.default.removeItem(at: folder)
            }
            busy = false
        }
    }

    /// The manifest's entries as capture sources. Web addresses only for links.
    nonisolated static func sources(in folder: URL) -> [Source] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: String]] else { return [] }
        return entries.compactMap { entry -> Source? in
            if let path = entry["path"], FileManager.default.isReadableFile(atPath: path) {
                return .file(URL(fileURLWithPath: path))
            }
            if let name = entry["image"], let data = try? Data(contentsOf: folder.appendingPathComponent(name)) {
                return .imageData(data, name: name, origin: nil)
            }
            if let s = entry["url"], let url = URL(string: s), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                return .web(url, title: nil)
            }
            if let text = entry["text"], !text.isEmpty {
                return PasteboardReader.linkOnly(text.trimmingCharacters(in: .whitespacesAndNewlines)).map { .web($0, title: nil) }
                    ?? .text(String(text.prefix(20_000)), origin: nil)
            }
            return nil
        }
    }
}
