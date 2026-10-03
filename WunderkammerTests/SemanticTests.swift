import Foundation
import Testing
@testable import Wunderkammer

/// Needs the MobileCLIP models (scripts/models/fetch-mobileclip.sh); skipped otherwise.
struct SemanticTests {
    static let modelsDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WK_MODELS_DIR"]
        ?? (NSHomeDirectory() + "/Library/Application Support/Wunderkammer/models"))

    @Test func tokenizerMatchesCLIP() throws {
        let vocab = Self.modelsDir.appendingPathComponent("bpe_simple_vocab_16e6.txt")
        guard let text = try? String(contentsOf: vocab, encoding: .utf8) else { return }
        let ids = CLIPTokenizer(merges: text).encode("a photo of a cat")
        #expect(Array(ids.prefix(7)) == [49406, 320, 1125, 539, 320, 2368, 49407])
        #expect(ids.count == 77 && ids[7] == 0)
    }

    @Test func picturesAndWordsMeet() throws {
        guard let index = SemanticIndex(modelsDir: Self.modelsDir) else { return }
        let cat = try #require(index.embed(text: "a photo of a cat"))
        let car = try #require(index.embed(text: "a red sports car"))
        let kitten = try #require(index.embed(text: "a small kitten"))
        #expect(SemanticIndex.cosine(cat, kitten) > SemanticIndex.cosine(cat, car))
    }
}

/// Prints how well descriptions find the memes in the real library (manual check).
struct SemanticMemeProbe {
    @Test func probe() throws {
        guard ProcessInfo.processInfo.environment["WK_PROBE"] != nil,
              let index = SemanticIndex(modelsDir: SemanticTests.modelsDir) else { return }
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Wunderkammer")
        let data = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let items = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["items"] as! [[String: Any]]
        var vectors: [(String, [Float])] = []
        for it in items {
            let id = it["id"] as! String, name = it["originalFilename"] as! String
            let v = (it["representationVersion"] as? Int) ?? 0
            let thumb = root.appendingPathComponent("thumbnails/\(v == 0 ? id : "\(id)-v\(v)").jpg")
            if let e = index.embed(imageAt: thumb) { vectors.append((name, e)) }
        }
        for q in ["a man in an orange jacket", "astronauts in space", "a cat at a dinner table", "spiderman",
                  "a muscular dog", "a car swerving off the highway", "clowns", "an old man with raised hands", "a sign that says change my mind"] {
            guard let t = index.embed(text: q) else { continue }
            let top = vectors.map { ($0.0, SemanticIndex.cosine(t, $0.1)) }.sorted { $0.1 > $1.1 }.prefix(3)
            print("PROBE \(q) → " + top.map { "\($0.0.prefix(28)) \(String(format: "%.3f", $0.1))" }.joined(separator: " | "))
        }
    }
}
