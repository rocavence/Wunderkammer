import Foundation
import Testing
@testable import Wunderkammer

/// Relations across kinds, read off the curiosities themselves.
struct CrossMediaTests {
    private func page(_ title: String, thing: Item.Thing? = nil, credits: [(Item.Credit.Role, String)] = [],
                      text: String? = nil, city: String? = nil) -> Item {
        var item = Item(kind: .web, originalFilename: "", pixelWidth: 1, pixelHeight: 1, contentHash: UUID().uuidString)
        item.title = title
        item.thing = thing
        item.credits = credits.map { Item.Credit(role: $0.0, name: $0.1) }
        item.pageText = text
        item.locality = city
        return item
    }

    @Test func thePersonLinksAFilmAndAnAlbum() {
        let film = page("Lost in Translation", thing: .movie, credits: [(.director, "Sofia Coppola"), (.actor, "Bill Murray")])
        let album = page("Bill Murray Sings", thing: .music, credits: [(.artist, "Bill Murray")])
        let r = CrossMedia.relations(of: film, in: [film, album])
        #expect(r.count == 1)
        #expect(r.first?.kind == .samePerson("Bill Murray", role: .artist))
        #expect(r.first?.sentence(title: "Bill Murray Sings", kindName: "音樂") == "Bill Murray 也演出了《Bill Murray Sings》（音樂）")
    }

    @Test func aPageMentioningAPersonsPage() {
        let cabinet = page("Cabinet of curiosities - Wikipedia", text: "The best-known was assembled by Ole Worm in Copenhagen.")
        let worm = page("Ole Worm - Wikipedia", text: "Danish physician who kept a cabinet of curiosities.")
        #expect(CrossMedia.relations(of: cabinet, in: [cabinet, worm]).first?.kind == .mentions("Ole Worm"))
        // Several words match whatever their case.
        #expect(CrossMedia.relations(of: worm, in: [cabinet, worm]).first?.kind == .mentions("Cabinet of curiosities"))
    }

    @Test func aQuoteMentioningTheAuthorOfABook() {
        var quote = Item(kind: .text, originalFilename: "", pixelWidth: 1, pixelHeight: 1, contentHash: "q")
        quote.text = "Light is the left hand of darkness. — Ursula K. Le Guin"
        let book = page("The Dispossessed: An Ambiguous Utopia", thing: .book, credits: [(.author, "Ursula K. Le Guin")])
        #expect(CrossMedia.relations(of: quote, in: [quote, book]).first?.kind == .mentions("Ursula K. Le Guin"))
        // …and from the book's side, the quote mentions it.
        #expect(CrossMedia.relations(of: book, in: [quote, book]).isEmpty == false)
    }

    @Test func sameCity() {
        let moma = page("The Museum of Modern Art", thing: .place, city: "New York")
        let whitney = page("Whitney Museum of American Art", thing: .place, city: "new york")
        #expect(CrossMedia.relations(of: moma, in: [moma, whitney]).first?.kind == .samePlace("New York"))
    }

    @Test func commonWordsAndPartsOfWordsDontCount() {
        let bound = page("Bound", thing: .movie)
        let worm = page("Ole Worm - Wikipedia")
        let other = page("A Page", text: "Bound for glory. The Holes Wormwood garden.")
        #expect(CrossMedia.name(of: bound) == nil)
        #expect(CrossMedia.relations(of: other, in: [other, bound, worm]).isEmpty)
        #expect(!CrossMedia.mentions("Severances", "Severance"))
        #expect(CrossMedia.mentions("watched Severance, again", "Severance"))
        #expect(!CrossMedia.mentions("severance pay", "Severance"))
    }

    @Test func pilesByRelation() {
        let a = page("Chungking Express", thing: .movie, credits: [(.director, "Wong Kar-Wai")])
        let b = page("In the Mood for Love", thing: .movie, credits: [(.director, "Wong Kar-Wai")])
        let c = page("The Museum of Modern Art", thing: .place, city: "New York")
        let d = page("Whitney Museum of American Art", thing: .place, city: "New York")
        let lone = page("Something Else Entirely")
        let items = [a, c, lone, b, d]
        let piles = CanvasLayout.relationClusters(items, links: CrossMedia.links(among: items))
        #expect(piles.map(\.title).sorted() == ["New York", "Wong Kar-Wai", "其他"])
        #expect(piles.last?.title == "其他" && piles.last?.ids == [lone.id])
        #expect(Set(piles.first { $0.title == "Wong Kar-Wai" }?.ids ?? []) == [a.id, b.id])
    }

    @Test func eachPairOnceForLines() {
        let a = page("Chungking Express", thing: .movie, credits: [(.director, "Wong Kar-Wai")])
        let b = page("In the Mood for Love", thing: .movie, credits: [(.director, "Wong Kar-Wai")])
        let links = CrossMedia.links(among: [a, b])
        #expect(links.count == 1)
        #expect(links.first?.label == "Wong Kar-Wai")
    }
}
