import Foundation

/// OpenAI CLIP's byte-level BPE tokenizer, as used by MobileCLIP's text
/// encoder: lowercase, split into words, byte-pair encode, wrap in start/end
/// tokens, pad to 77.
struct CLIPTokenizer: Sendable {
    static let contextLength = 77
    static let startToken: Int32 = 49406
    static let endToken: Int32 = 49407

    private let encoder: [String: Int32]
    private let ranks: [Pair: Int]
    private let byteEncoder: [UInt8: Character]
    private let pattern: NSRegularExpression

    private struct Pair: Hashable, Sendable {
        let a: String
        let b: String
    }

    /// `merges`: the text of bpe_simple_vocab_16e6.txt.
    init(merges text: String) {
        let bytes = Self.bytesToUnicode()
        byteEncoder = bytes
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // The first line is a header; then 49152 − 256 − 2 merges.
        let merges = lines.dropFirst().prefix(49152 - 256 - 2).map { line -> Pair in
            let parts = line.split(separator: " ")
            return Pair(a: String(parts[0]), b: String(parts.count > 1 ? parts[1] : ""))
        }
        var ranks: [Pair: Int] = [:]
        for (i, m) in merges.enumerated() { ranks[m] = i }
        self.ranks = ranks

        var vocab = Self.byteOrder().map { String(bytes[$0]!) }
        vocab += vocab.map { $0 + "</w>" }
        vocab += merges.map { $0.a + $0.b }
        vocab += ["<|startoftext|>", "<|endoftext|>"]
        var encoder: [String: Int32] = [:]
        for (i, v) in vocab.enumerated() { encoder[v] = Int32(i) }
        self.encoder = encoder
        pattern = try! NSRegularExpression(
            pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
            options: [.caseInsensitive])
    }

    /// Token IDs padded with zeros to 77.
    func encode(_ text: String) -> [Int32] {
        let cleaned = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).lowercased()
        var ids: [Int32] = [Self.startToken]
        let ns = cleaned as NSString
        for match in pattern.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: match.range)
            let unicode = String(word.utf8.map { byteEncoder[$0]! })
            for piece in bpe(unicode) {
                if let id = encoder[piece] { ids.append(id) }
            }
        }
        ids = Array(ids.prefix(Self.contextLength - 1))
        ids.append(Self.endToken)
        return ids + Array(repeating: 0, count: Self.contextLength - ids.count)
    }

    private func bpe(_ token: String) -> [String] {
        var word = token.map(String.init)
        guard !word.isEmpty else { return [] }
        word[word.count - 1] += "</w>"
        while word.count > 1 {
            var best: (Int, Int)?
            for i in 0..<(word.count - 1) {
                if let r = ranks[Pair(a: word[i], b: word[i + 1])], best == nil || r < best!.1 { best = (i, r) }
            }
            guard let (_, _) = best else { break }
            let pair = Pair(a: word[best!.0], b: word[best!.0 + 1])
            var merged: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1, word[i] == pair.a, word[i + 1] == pair.b {
                    merged.append(pair.a + pair.b)
                    i += 2
                } else {
                    merged.append(word[i])
                    i += 1
                }
            }
            word = merged
        }
        return word
    }

    /// GPT-2's reversible byte → printable character mapping.
    private static func bytesToUnicode() -> [UInt8: Character] {
        var bs = byteOrder()
        var cs = bs.map { Int($0) }
        var n = 0
        for b in 0...255 where !bs.contains(UInt8(b)) {
            bs.append(UInt8(b))
            cs.append(256 + n)
            n += 1
        }
        var map: [UInt8: Character] = [:]
        for (b, c) in zip(bs, cs) { map[b] = Character(UnicodeScalar(c)!) }
        return map
    }

    /// Printable bytes first, in the order the vocabulary lists them.
    private static func byteOrder() -> [UInt8] {
        let printable = Array(UInt8(ascii: "!")...UInt8(ascii: "~")) + Array(UInt8(0xA1)...UInt8(0xAC)) + Array(UInt8(0xAE)...UInt8(0xFF))
        return printable + (0...255).map(UInt8.init).filter { !printable.contains($0) }
    }
}
