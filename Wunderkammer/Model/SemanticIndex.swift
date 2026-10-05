import CoreML
import Foundation
import ImageIO

/// Search by meaning: MobileCLIP puts pictures and sentences in the same
/// space, so "a cat at a dinner table" finds the picture even if no word in
/// it says so. Runs locally with Core ML; the models live next to the
/// library (`models/`), fetched the first time they are wanted (ModelInstaller).
final class SemanticIndex: @unchecked Sendable {
    static let modelFiles = ["mobileclip_s0_image.mlmodelc", "mobileclip_s0_text.mlmodelc", "bpe_simple_vocab_16e6.txt"]

    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: CLIPTokenizer
    private let lock = NSLock()

    /// nil when the models aren't installed: search falls back to words only.
    init?(modelsDir: URL) {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let image = try? MLModel(contentsOf: modelsDir.appendingPathComponent(Self.modelFiles[0]), configuration: config),
              let text = try? MLModel(contentsOf: modelsDir.appendingPathComponent(Self.modelFiles[1]), configuration: config),
              let merges = try? String(contentsOf: modelsDir.appendingPathComponent(Self.modelFiles[2]), encoding: .utf8)
        else { return nil }
        imageModel = image
        textModel = text
        tokenizer = CLIPTokenizer(merges: merges)
    }

    /// Unit-length 512-d vector for a picture (its representation).
    func embed(imageAt url: URL) -> [Float]? {
        guard let constraint = imageModel.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = Thumbnailer.decode(source: source, maxPixel: 512),
              let value = try? MLFeatureValue(cgImage: cg, constraint: constraint,
                                              options: [.cropAndScale: VNImageCropAndScaleOptionValue.centerCrop])
        else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let out = try? imageModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": value])) else { return nil }
        return Self.normalized(out)
    }

    /// Unit-length 512-d vector for an English sentence.
    func embed(text: String) -> [Float]? {
        let ids = tokenizer.encode(text)
        guard let array = try? MLMultiArray(shape: [1, NSNumber(value: CLIPTokenizer.contextLength)], dataType: .int32) else { return nil }
        for (i, id) in ids.enumerated() { array[i] = NSNumber(value: id) }
        lock.lock(); defer { lock.unlock() }
        guard let out = try? textModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["text": array])) else { return nil }
        return Self.normalized(out)
    }

    private static func normalized(_ out: MLFeatureProvider) -> [Float]? {
        guard let name = out.featureNames.first, let array = out.featureValue(for: name)?.multiArrayValue else { return nil }
        var v = (0..<array.count).map { Float(truncating: array[$0]) }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        for i in v.indices { v[i] /= norm }
        return v
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

/// Core ML's image option value, spelled out so callers don't need Vision.
private enum VNImageCropAndScaleOptionValue {
    static let centerCrop = NSNumber(value: 0) // VNImageCropAndScaleOption.centerCrop
}
