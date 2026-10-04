import Foundation
import Testing
@testable import Wunderkammer

/// What a page is about and who made it, from schema.org JSON-LD or Open Graph.
struct StructuredDataTests {
    let base = URL(string: "https://example.com/page")!

    private func page(_ head: String) -> WebMetadata {
        WebMetadata.parse("<html><head><title>Fallback</title>\(head)</head><body></body></html>", base: base)
    }

    @Test func bookWithAuthors() {
        let m = page("""
        <script type="application/ld+json">
        {"@context":"https://schema.org","@type":"Book","name":"The Left Hand of Darkness",
         "author":[{"@type":"Person","name":"Ursula K. Le Guin"}],"datePublished":"1969-03-01"}
        </script>
        """)
        #expect(m.thing == .book)
        #expect(m.title == "The Left Hand of Darkness")
        #expect(m.credits == [Item.Credit(role: .author, name: "Ursula K. Le Guin")])
        #expect(m.released == "1969-03-01")
    }

    @Test func movieInsideAGraphWithSeveralDirectors() {
        let m = page("""
        <script type='application/ld+json'>
        {"@graph":[{"@type":"WebPage","name":"Page"},
          {"@type":["Movie"],"name":"The Matrix","director":[{"name":"Lana Wachowski"},{"name":"Lilly Wachowski"}],
           "dateCreated":"1999-03-31T00:00:00Z"}]}
        </script>
        """)
        #expect(m.thing == .movie)
        #expect(m.credits.map(\.name) == ["Lana Wachowski", "Lilly Wachowski"])
        #expect(m.credits.allSatisfy { $0.role == .director })
        #expect(m.released == "1999-03-31")
    }

    /// Letterboxd wraps its JSON in a commented-out CDATA block.
    @Test func jsonInsideCommentWrappers() {
        let m = page("""
        <script type="application/ld+json">
        /* <![CDATA[ */
        {"@type":"Movie","name":"Cléo from 5 to 7","director":[{"@type":"Person","name":"Agnès Varda"}]}
        /* ]]> */
        </script>
        """)
        #expect(m.thing == .movie)
        #expect(m.credits.map(\.name) == ["Agnès Varda"])
    }

    /// TMDB: dateCreated is when their record was made; the release is an event.
    @Test func releaseEventBeatsRecordDate() {
        let m = page("""
        <script type="application/ld+json">{"@type":"Movie","name":"The Matrix","dateCreated":"2010-04-16T16:29:25Z",
         "releasedEvent":[{"@type":"PublicationEvent","startDate":"1999-03-31"}]}</script>
        """)
        #expect(m.released == "1999-03-31")
    }

    @Test func albumCreditsTheArtist() {
        let m = page("""
        <script type="application/ld+json">[{"@type":"MusicAlbum","name":"Blue","byArtist":{"@type":"MusicGroup","name":"Joni Mitchell"},"datePublished":"1971"}]</script>
        """)
        #expect(m.thing == .music)
        #expect(m.credits == [Item.Credit(role: .artist, name: "Joni Mitchell")])
        #expect(m.released == "1971")
    }

    @Test func productBrandIsNotAPerson() {
        let m = page("""
        <script type="application/ld+json">{"@type":"Product","name":"T3 Pocket Radio","brand":{"@type":"Brand","name":"Braun"}}</script>
        """)
        #expect(m.thing == .product)
        #expect(m.credits == [Item.Credit(role: .brand, name: "Braun")])
        #expect(Item.merging([], credits: m.credits).isEmpty)
    }

    @Test func openGraphFallbackSkipsProfileLinks() {
        let m = page("""
        <meta property="og:type" content="video.movie">
        <meta property="video:director" content="https://example.com/people/1">
        <meta name="author" content="Agnès Varda">
        <meta property="video:release_date" content="1962-04-11">
        """)
        #expect(m.thing == .movie)
        #expect(m.credits == [Item.Credit(role: .author, name: "Agnès Varda")])
        #expect(m.released == "1962-04-11")
    }

    @Test func ordinaryPagesStayPages() {
        let m = page("""
        <meta property="og:type" content="article"><meta name="author" content="Someone">
        <script type="application/ld+json">{"@type":"NewsArticle","author":{"name":"Someone"}}</script>
        <script type="application/ld+json">{ not json </script>
        """)
        #expect(m.thing == nil)
        #expect(m.credits.isEmpty)
        #expect(m.author == "Someone")
    }

    @Test func creditedPeopleBecomeNamesOnce() {
        let names = Item.merging([Item.Entity(kind: .person, name: "Ursula K. Le Guin")],
                                 credits: [Item.Credit(role: .author, name: "ursula k. le guin"),
                                           Item.Credit(role: .author, name: "Ted Chiang")])
        #expect(names.map(\.name) == ["Ursula K. Le Guin", "Ted Chiang"])
    }

    @Test func thingViewsFindPagesByWhatTheyAre() {
        var book = Item(kind: .web, originalFilename: "", pixelWidth: 1, pixelHeight: 1, contentHash: "a")
        book.thing = .book
        let page = Item(kind: .web, originalFilename: "", pixelWidth: 1, pixelHeight: 1, contentHash: "b")
        #expect(Scope.KindView.books.contains(book))
        #expect(!Scope.KindView.books.contains(page))
        #expect(Scope.KindView.web.contains(book))
    }

    @Test func releaseDatesReadInChinese() {
        #expect(InspectorViewController.released("2021-10-22") == "2021 年 10 月 22 日")
        #expect(InspectorViewController.released("1971") == "1971 年")
    }
}
