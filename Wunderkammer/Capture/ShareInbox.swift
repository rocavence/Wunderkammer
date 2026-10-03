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
        let ready = folders.filter {
            (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }
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

    /// The manifest's entries as capture sources. Anything that could write to
    /// the inbox could also write a manifest, so nothing in it is trusted:
    /// image names can't leave their folder, referenced files must be ordinary
    /// files where a user keeps things, links must be web addresses.
    nonisolated static func sources(in folder: URL) -> [Source] {
        guard !isSymlink(folder),
              let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              data.count < 2_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: String]] else { return [] }
        return entries.prefix(50).compactMap { entry -> Source? in
            if let path = entry["path"], let url = referenceableFile(path) {
                return .file(url)
            }
            if let name = entry["image"], let file = contained(name, in: folder),
               let data = try? Data(contentsOf: file), data.count < 200_000_000 {
                return .imageData(data, name: file.lastPathComponent, origin: nil)
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

    /// A file inside the share's own folder, by name only (no "../", no links).
    nonisolated static func contained(_ name: String, in folder: URL) -> URL? {
        let leaf = (name as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.hasPrefix(".") else { return nil }
        let file = folder.appendingPathComponent(leaf)
        guard file.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
              !isSymlink(file), isRegularFile(file) else { return nil }
        return file
    }

    /// Only ordinary, visible files in the places people keep things: the home
    /// folder outside ~/Library, or an external volume.
    nonisolated static func referenceableFile(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        let p = url.path
        let inHome = p.hasPrefix(home + "/") && !p.hasPrefix(home + "/Library/")
        let onVolume = p.hasPrefix("/Volumes/")
        guard inHome || onVolume,
              !url.pathComponents.contains(where: { $0.hasPrefix(".") }),
              isRegularFile(url), FileManager.default.isReadableFile(atPath: p) else { return nil }
        return url
    }

    nonisolated private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    nonisolated private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
