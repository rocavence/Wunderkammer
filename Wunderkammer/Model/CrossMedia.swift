import Foundation

/// How two curiosities are related across kinds (a film and a book, a page
/// and a person): the same person in both, one mentioning the other, the
/// same city. Only what can be read off the curiosities, nothing guessed.
struct Relation: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Credited in both: the name, and their role on the other one.
        case samePerson(String, role: Item.Credit.Role)
        /// This one's words mention the other (its title, or who made it).
        case mentions(String)
        /// The other one's words mention this one.
        case mentionedBy(String)
        case samePlace(String)
    }

    var other: UUID
    var kind: Kind

    /// One line for the info panel, about `other` (titled `title`, of kind `kindName`).
    func sentence(title: String, kindName: String) -> String {
        let thing = "《\(title)》\(kindName.isEmpty ? "" : "（\(kindName)）")"
        switch kind {
        case .samePerson(let name, let role): return "\(name) 也\(Self.verb(role))\(thing)"
        case .mentions(let what): return what == title ? "這件提到\(thing)" : "這件提到 \(what)：\(thing)"
        case .mentionedBy(let what): return "\(thing)提到 \(what)"
        case .samePlace(let city): return "同在 \(city)：\(thing)"
        }
    }

    /// A few words for a line drawn between the two.
    var label: String {
        switch kind {
        case .samePerson(let name, _): name
        case .mentions, .mentionedBy: "提到"
        case .samePlace(let city): city
        }
    }

    static func verb(_ role: Item.Credit.Role) -> String {
        switch role {
        case .author: "寫了"
        case .director: "導了"
        case .artist: "演出了"
        case .actor: "演了"
        case .creator: "做了"
        case .brand: "出了"
        }
    }
}

enum CrossMedia {
    /// What others would call it: "The Dispossessed: An Ambiguous Utopia" →
    /// "The Dispossessed", "Ole Worm - Wikipedia" → "Ole Worm". nil for
    /// things without a name worth looking for (images, notes, files).
    static func name(of item: Item) -> String? {
        guard item.kind == .web, let title = item.title else { return nil }
        var name = title
        for separator in [" - ", " – ", " — ", " | ", ": "] {
            if let r = name.range(of: separator) { name = String(name[..<r.lowerBound]) }
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return isDistinct(name) ? name : nil
    }

    /// Long or specific enough that finding it in a text means something.
    static func isDistinct(_ name: String) -> Bool {
        if name.unicodeScalars.contains(where: { $0.properties.isIdeographic }) { return name.count >= 2 }
        let words = name.split(separator: " ")
        return words.count >= 2 ? name.count >= 6 : name.count >= 6 && name.first?.isUppercase == true
    }

    /// The words a curiosity has of its own (not its title).
    static func words(of item: Item) -> String {
        [item.text, item.pageText, item.ocrText].compactMap { $0 }.joined(separator: "\n")
    }

    /// Whole-word match: case-sensitive for one word ("Severance"), not for
    /// several ("cabinet of curiosities").
    static func mentions(_ text: String, _ name: String) -> Bool {
        let ideographic = name.unicodeScalars.contains { $0.properties.isIdeographic }
        let options: String.CompareOptions = name.contains(" ") ? [.caseInsensitive] : []
        var searchRange = text.startIndex..<text.endIndex
        while let r = text.range(of: name, options: options, range: searchRange) {
            if ideographic { return true }
            let before = r.lowerBound > text.startIndex ? text[text.index(before: r.lowerBound)] : " "
            let after = r.upperBound < text.endIndex ? text[r.upperBound] : " "
            if !before.isLetter && !before.isNumber && !after.isLetter && !after.isNumber { return true }
            searchRange = r.upperBound..<text.endIndex
        }
        return false
    }

    private static func key(_ name: String) -> String { Search.normalize(name) }

    /// Everything `item` relates to in `items`, strongest kinds first.
    static func relations(of item: Item, in items: [Item]) -> [Relation] {
        let mine = Dictionary((item.credits ?? []).filter { $0.role != .brand }.map { (key($0.name), $0) }, uniquingKeysWith: { a, _ in a })
        let myWords = words(of: item)
        let myName = name(of: item)
        var out: [Relation] = []
        for other in items where other.id != item.id {
            var found: Relation.Kind?
            for c in other.credits ?? [] where c.role != .brand {
                if let me = mine[key(c.name)] { found = .samePerson(me.name, role: c.role); break }
            }
            if found == nil, !myWords.isEmpty {
                if let n = name(of: other), mentions(myWords, n) {
                    found = .mentions(n)
                } else if let c = (other.credits ?? []).first(where: { $0.role != .brand && isDistinct($0.name) && mentions(myWords, $0.name) }) {
                    found = .mentions(c.name)
                }
            }
            if found == nil {
                let theirWords = words(of: other)
                if let myName, mentions(theirWords, myName) {
                    found = .mentionedBy(myName)
                } else if !theirWords.isEmpty, let me = mine.values.first(where: { isDistinct($0.name) && mentions(theirWords, $0.name) }) {
                    found = .mentionedBy(me.name)
                }
            }
            if found == nil, let city = item.locality, other.locality.map(key) == key(city) { found = .samePlace(city) }
            if let found { out.append(Relation(other: other.id, kind: found)) }
        }
        func rank(_ r: Relation) -> Int {
            switch r.kind {
            case .samePerson: 0
            case .mentions: 1
            case .mentionedBy: 2
            case .samePlace: 3
            }
        }
        return out.sorted { rank($0) < rank($1) }
    }

    /// Each related pair once, for drawing lines between them.
    static func links(among items: [Item]) -> [(a: UUID, b: UUID, label: String)] {
        var seen = Set<[UUID]>()
        var out: [(a: UUID, b: UUID, label: String)] = []
        for item in items {
            for r in relations(of: item, in: items) {
                let pair = [item.id, r.other].sorted { $0.uuidString < $1.uuidString }
                if seen.insert(pair).inserted { out.append((item.id, r.other, r.label)) }
            }
        }
        return out
    }
}
