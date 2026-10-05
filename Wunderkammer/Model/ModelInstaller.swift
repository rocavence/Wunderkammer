import CoreML
import Foundation

/// Fetches the meaning-search models (Apple's MobileCLIP S0, and CLIP's
/// merges) the first time they're wanted, and compiles them in place. About
/// 106 MB; nothing ships inside the app.
@MainActor
final class ModelInstaller {
    enum State: Equatable {
        case idle
        case downloading(Double)
        case failed
    }

    private(set) var state: State = .idle { didSet { onChange?(state) } }
    var onChange: ((State) -> Void)?

    private static let source = "https://huggingface.co/apple/coreml-mobileclip/resolve/main"
    private static let merges = URL(string: "https://huggingface.co/openai/clip-vit-base-patch32/resolve/main/merges.txt")!
    private static let parts = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]
    /// Roughly what comes down, to show one steady percentage across the files.
    private static let expectedBytes: Double = 108_000_000

    private var task: Task<Void, Never>?

    var isInstalled: Bool {
        SemanticIndex.modelFiles.allSatisfy { FileManager.default.fileExists(atPath: Understanding.modelsDir.appendingPathComponent($0).path) }
    }

    /// Downloads and compiles; calls back on the main actor when the models are in place.
    func install(then done: @escaping () -> Void) {
        guard task == nil else { return }
        state = .downloading(0)
        task = Task {
            defer { task = nil }
            do {
                try await fetch()
                state = .idle
                done()
            } catch {
                state = .failed
            }
        }
    }

    private func fetch() async throws {
        let fm = FileManager.default
        let dest = Understanding.modelsDir
        let work = fm.temporaryDirectory.appendingPathComponent("wunder-models-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var received: Double = 0
        for name in ["mobileclip_s0_image", "mobileclip_s0_text"] {
            let package = work.appendingPathComponent("\(name).mlpackage")
            for part in Self.parts {
                let url = URL(string: "\(Self.source)/\(name).mlpackage/\(part)")!
                let file = package.appendingPathComponent(part)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                received += Double(try await Self.download(url, to: file, progress: progress(from: received)))
            }
            let compiled = try await MLModel.compileModel(at: package)
            let target = dest.appendingPathComponent("\(name).mlmodelc")
            try? fm.removeItem(at: target)
            try fm.moveItem(at: compiled, to: target)
        }
        // The tokenizer reads the merges after one header line, as in CLIP's own file.
        let vocab = dest.appendingPathComponent(SemanticIndex.modelFiles[2])
        try? fm.removeItem(at: vocab)
        _ = try await Self.download(Self.merges, to: vocab, progress: progress(from: received))
    }

    /// Reports one file's bytes on top of what's already down.
    private func progress(from base: Double) -> @MainActor @Sendable (Int64) -> Void {
        { [weak self] bytes in
            self?.state = .downloading(min((base + Double(bytes)) / Self.expectedBytes, 0.99))
        }
    }

    /// One file, reporting bytes as they arrive; returns its size.
    private static func download(_ url: URL, to file: URL, progress: @escaping @MainActor @Sendable (Int64) -> Void) async throws -> Int64 {
        let watcher = ProgressWatcher(progress)
        let (temp, response) = try await URLSession.shared.download(from: url, delegate: watcher)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temp, to: file)
        return (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}

/// Passes a download's byte count along while it runs.
private final class ProgressWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @MainActor @Sendable (Int64) -> Void
    private var observation: NSKeyValueObservation?

    init(_ report: @escaping @MainActor @Sendable (Int64) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.completedUnitCount) { [report] p, _ in
            let bytes = p.completedUnitCount
            Task { @MainActor in report(bytes) }
        }
    }
}
