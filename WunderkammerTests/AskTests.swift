import Foundation
import Testing
@testable import Wunderkammer

/// The parts of asking that don't need the model.
struct AskTests {
    @Test func questionsAreToldFromSearches() {
        #expect(AppDelegate.isQuestion("我收過哪些王家衛的電影"))
        #expect(AppDelegate.isQuestion("有沒有跟咖啡有關的東西"))
        #expect(AppDelegate.isQuestion("red chair?"))
        #expect(AppDelegate.isQuestion("what did I collect last week"))
        #expect(!AppDelegate.isQuestion("紅色的椅子"))
        #expect(!AppDelegate.isQuestion("2025"))
        #expect(!AppDelegate.isQuestion("嗎"))
    }

    @available(macOS 26.0, *)
    @Test func aRepeatedQuestionIsDropped() {
        #expect(Asker.withoutEcho("你收過哪些王家衛的電影？\n《Chungking Express》和《In the Mood for Love》。") == "《Chungking Express》和《In the Mood for Love》。")
        #expect(Asker.withoutEcho("Is it there?") == "Is it there?")
        #expect(Asker.withoutEcho("Yes, two.\nAnything else?") == "Yes, two.\nAnything else?")
    }

    @available(macOS 26.0, *)
    @Test func answersCiteByTitleOrMaker() throws {
        var book = Item(kind: .web, originalFilename: "", pixelWidth: 1, pixelHeight: 1, contentHash: "a")
        book.title = "The Dispossessed: An Ambiguous Utopia"
        book.credits = [Item.Credit(role: .author, name: "Ursula K. Le Guin")]
        var kettle = Item(kind: .web, originalFilename: "", pixelWidth: 1, pixelHeight: 1, contentHash: "b")
        kettle.title = "Stagg EKG Electric Kettle"
        kettle.credits = [Item.Credit(role: .brand, name: "Fellow")]
        #expect(Asker.names(book, in: "有《The Dispossessed》這本書"))
        #expect(Asker.names(book, in: "都是 Ursula K. Le Guin 寫的"))
        #expect(!Asker.names(book, in: "收藏裡沒有恐龍"))
        // A brand isn't a maker to cite by.
        #expect(!Asker.names(kettle, in: "Fellow 的東西"))
    }
}
