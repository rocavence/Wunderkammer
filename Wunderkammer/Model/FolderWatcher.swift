import CoreServices
import Foundation

/// Keeps the open 展室 in step with the folders it watches: what's put in a
/// folder is collected, what leaves the folder leaves the 展室. Files still
/// being written wait until they settle.
@MainActor
final class FolderWatcher {
    private let library: Library
    private var folders: [URL] = []
    private var stream: FSEventStreamRef?
    private var syncing = false
    private var again = false
    private var pending: DispatchWorkItem?
    /// Files tried this session that didn't become items of their own (the
    /// same picture already collected, a file nothing could be made of).
    private var tried: Set<String> = []

    /// Half-downloaded files and the like.
    private nonisolated static let unfinished: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload"]
    /// How long a file has to sit unchanged before it's collected.
    private static let settle: TimeInterval = 2

    init(library: Library) {
        self.library = library
    }

    /// Watches these folders from now on (the open 展室's), and catches up
    /// with whatever happened in them meanwhile.
    func watch(_ folders: [URL]) {
        stop()
        self.folders = folders
        tried = []
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.schedule(after: 0.3) }
        }
        stream = FSEventStreamCreate(nil, callback, &context, folders.map(\.path) as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
        schedule(after: 0)
    }

    func stop() {
        pending?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    private func schedule(after delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { await self?.sync() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Compares each folder with the 展室 and settles the difference.
    func sync() async {
        guard !syncing else { again = true; return }
        syncing = true
        defer {
            syncing = false
            if again { again = false; schedule(after: 0.5) }
        }
        let folders = self.folders
        guard !folders.isEmpty else { return }
        let found = await Task.detached { folders.map { Self.files(in: $0) } }.value
        guard folders == self.folders else { return }

        var settling = false
        var fresh: [URL] = []
        var gone: Set<UUID> = []
        for (folder, files) in zip(folders, found) {
            let prefix = folder.path + "/"
            let inFolder = library.items.filter { $0.storedFilename == nil && $0.filePath?.hasPrefix(prefix) == true }
            let known = Set(inFolder.compactMap(\.filePath))
            let present = Set(files.map(\.url.path))
            for item in inFolder where !present.contains(item.filePath!) { gone.insert(item.id) }
            for file in files where !known.contains(file.url.path) && !tried.contains(file.url.path) {
                if Date().timeIntervalSince(file.modified) < Self.settle { settling = true; continue }
                fresh.append(file.url)
            }
        }
        if !gone.isEmpty { library.delete(gone) }
        if !fresh.isEmpty {
            let ids = await library.capture(fresh.map { .file($0) })
            // What didn't come in as its own item isn't tried again this session.
            let paths = Set(ids.compactMap { library.item($0)?.filePath })
            tried.formUnion(fresh.map(\.path).filter { !paths.contains($0) })
        }
        if settling { schedule(after: Self.settle) }
    }

    private nonisolated static func files(in folder: URL) -> [(url: URL, modified: Date)] {
        Representer.expand(folder)
            .filter { !unfinished.contains($0.pathExtension.lowercased()) }
            .map { ($0.standardizedFileURL, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }
}
