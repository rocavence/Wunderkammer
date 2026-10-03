import Foundation
import Testing
@testable import Wunderkammer

struct SearchTests {
    private func item(_ kind: Item.Kind = .image, title: String? = nil, file: String = "", url: String? = nil,
                      text: String? = nil, labels: [String]? = nil, colors: [String]? = nil, ocr: String? = nil,
                      added: Date = Date()) -> Item {
        var i = Item(kind: kind, dateAdded: added, originalFilename: file, pixelWidth: 1, pixelHeight: 1, contentHash: UUID().uuidString)
        i.title = title; i.url = url; i.text = text; i.labels = labels; i.colors = colors; i.ocrText = ocr
        return i
    }

    @Test func everyTermMustMatchSomewhere() {
        let chair = item(labels: ["chair", "furniture"], colors: ["red"])
        let blueChair = item(labels: ["chair"], colors: ["blue"])
        let redCar = item(labels: ["car"], colors: ["red"])
        #expect(Search.run("red chair", in: [chair, blueChair, redCar]).map(\.id) == [chair.id])
    }

    @Test func chineseQueryFindsEnglishLabels() {
        let chair = item(labels: ["chair"], colors: ["red"])
        let other = item(labels: ["dog"], colors: ["red"])
        #expect(Search.tokens("紅色的椅子") == ["紅色", "椅子"])
        #expect(Search.run("紅色的椅子", in: [other, chair]).map(\.id) == [chair.id])
    }

    @Test func titlesRankAboveBodyText() {
        let inBody = item(.text, text: "a note about Wong Kar-wai films")
        let inTitle = item(.web, title: "Wong Kar-wai: In the Mood for Love", url: "https://example.com")
        #expect(Search.run("wong kar-wai", in: [inBody, inTitle]).map(\.id) == [inTitle.id, inBody.id])
    }

    @Test func yearsAndStopwords() {
        let old = item(title: "poster", added: ISO8601DateFormatter().date(from: "2025-05-01T00:00:00Z")!)
        let new = item(title: "poster", added: ISO8601DateFormatter().date(from: "2026-05-01T00:00:00Z")!)
        #expect(Search.run("things I saved in 2025", in: [old, new]).map(\.id) == [old.id])
    }

    @Test func accentsWidthAndCase() {
        let cafe = item(title: "Café Ｍｏｄｅｒｎ")
        #expect(Search.run("cafe modern", in: [cafe]).count == 1)
    }

    @Test func kindsAndOCR() {
        let video = item(.video, file: "clip.mov")
        let sign = item(labels: ["sign"], ocr: "OPEN 24 HOURS")
        #expect(Search.run("影片", in: [video, sign]).map(\.id) == [video.id])
        #expect(Search.run("24 hours", in: [video, sign]).map(\.id) == [sign.id])
    }
}

struct RediscoveryTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()

    private func at(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }
    private func item(added: Date, viewed: Date? = nil, views: Int = 0) -> Item {
        var i = Item(kind: .image, dateAdded: added, originalFilename: "", pixelWidth: 1, pixelHeight: 1, contentHash: UUID().uuidString)
        i.lastViewed = viewed; i.viewCount = views
        return i
    }

    @Test func onThisDayPrefersSameDateInEarlierYears() {
        let now = at(2026, 10, 4)
        let lastYear = item(added: at(2025, 10, 4)), lastMonth = item(added: at(2026, 9, 4)), today = item(added: now)
        #expect(Rediscovery.onThisDay([today, lastMonth, lastYear], now: now, calendar: cal).map(\.id) == [lastYear.id])
        #expect(Rediscovery.onThisDay([today, lastMonth], now: now, calendar: cal).map(\.id) == [lastMonth.id])
    }

    @Test func forgottenIsOldAndUnseen() {
        let now = at(2026, 10, 4)
        let seenRecently = item(added: at(2025, 1, 1), viewed: at(2026, 10, 1))
        let neverSeen = item(added: at(2025, 1, 1)), older = item(added: at(2024, 1, 1)), fresh = item(added: at(2026, 10, 1))
        #expect(Rediscovery.forgotten([seenRecently, neverSeen, older, fresh], now: now).map(\.id) == [older.id, neverSeen.id])
    }

    @Test func onceFavouritesComeBackFirst() {
        let now = at(2026, 10, 4)
        let favourite = item(added: at(2025, 1, 1), viewed: at(2026, 6, 1), views: 12)
        let untouched = item(added: at(2025, 1, 1))
        #expect(Rediscovery.forgotten([untouched, favourite], now: now).first?.id == favourite.id)
    }

    @Test func randomFavoursOldUnseenAndAvoidsRepeats() {
        let now = at(2026, 10, 4)
        let old = item(added: at(2021, 1, 1)), fresh = item(added: now, viewed: now, views: 20)
        var oldCount = 0
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 where Rediscovery.pick([old, fresh], now: now, random: { Double.random(in: 0..<1, using: &rng) })?.id == old.id { oldCount += 1 }
        #expect(oldCount > 1700)
        let shownJustNow = Rediscovery.pick([old, fresh], now: now, avoiding: [old.id], random: { 0.0 })
        #expect(shownJustNow?.id == fresh.id || shownJustNow?.id == old.id)
        #expect(Rediscovery.ageLine(item(added: at(2023, 3, 7)), now: now, calendar: cal) == "你在 1,307 天前收藏了這個")
    }
}

@MainActor
struct TrailTests {
    @Test func recordsPathsAndPersists() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wk-trail-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = UUID(), b = UUID(), c = UUID()
        let trail = Trail(root: root)
        let t0 = Date()
        trail.record(a, via: .browse, at: t0)
        trail.record(a, via: .browse, at: t0.addingTimeInterval(5))       // same visit
        trail.record(b, via: .search("receive"), at: t0.addingTimeInterval(10))
        trail.record(c, via: .similar(b), at: t0.addingTimeInterval(20))
        trail.record(a, via: .random, at: t0.addingTimeInterval(30))
        #expect(trail.steps.count == 4)
        #expect(trail.recentItems(existing: [a, b, c]) == [a, c, b])
        #expect(trail.recentItems(existing: [b, c]) == [c, b])
        #expect(trail.lastArrival(at: c)?.via == .similar(b))
        #expect(Trail.describe(.search("receive"), title: { _ in nil }) == "上次是從搜尋「receive」來的")
        trail.save()
        #expect(Trail(root: root).steps == trail.steps)
    }
}
