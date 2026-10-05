import AppIntents
import AppKit

// Siri and Shortcuts: ask the cabinet, search it, pull out something at
// random, collect what's on the clipboard. The same paths the app's own
// commands take; answers are spoken in the language you asked in.

@MainActor
private var cabinet: AppDelegate? { NSApp.delegate as? AppDelegate }

struct AskCabinetIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Wunderkammer"
    static let description = IntentDescription("Ask a question about what you've collected. Answered on this Mac by Apple Intelligence.")

    @Parameter(title: "Question", requestValueDialog: IntentDialog("What would you like to know?"))
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let cabinet else { return .result(dialog: "Wunderkammer isn't ready yet.") }
        return .result(dialog: IntentDialog(stringLiteral: await cabinet.answerForIntent(question)))
    }
}

struct SearchCabinetIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Wunderkammer"
    static let description = IntentDescription("Find curiosities by words, names, colours, sites, years or what they look like.")
    static let openAppWhenRun = true

    @Parameter(title: "Search for", requestValueDialog: IntentDialog("What should I look for?"))
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let found = cabinet?.searchForIntent(query) ?? 0
        return .result(dialog: IntentDialog(stringLiteral: found == 0 ? "Nothing matches “\(query)”." : "Found \(found) for “\(query)”."))
    }
}

struct RandomCuriosityIntent: AppIntent {
    static let title: LocalizedStringResource = "Something from Wunderkammer"
    static let description = IntentDescription("Show something you collected a while ago, at random.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let title = cabinet?.randomForIntent() else { return .result(dialog: "There's nothing in the room yet.") }
        return .result(dialog: IntentDialog(stringLiteral: "Here's “\(title)”."))
    }
}

struct CollectIntent: AppIntent {
    static let title: LocalizedStringResource = "Collect into Wunderkammer"
    static let description = IntentDescription("Collect what you just copied, or the page open in your browser. Same as ⌘⇧C.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let collected = await cabinet?.collectForIntent() ?? false
        return .result(dialog: collected ? "Collected." : "There's nothing to collect. Copy something first.")
    }
}

struct WunderkammerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskCabinetIntent(), phrases: [
            "Ask \(.applicationName)",
            "Ask \(.applicationName) a question",
        ], shortTitle: "Ask", systemImageName: "questionmark.bubble")
        AppShortcut(intent: SearchCabinetIntent(), phrases: [
            "Search \(.applicationName)",
            "Find in \(.applicationName)",
        ], shortTitle: "Search", systemImageName: "magnifyingglass")
        AppShortcut(intent: RandomCuriosityIntent(), phrases: [
            "Show me something from \(.applicationName)",
            "Random \(.applicationName)",
        ], shortTitle: "Something at Random", systemImageName: "shuffle")
        AppShortcut(intent: CollectIntent(), phrases: [
            "Collect into \(.applicationName)",
            "Save to \(.applicationName)",
        ], shortTitle: "Collect", systemImageName: "tray.and.arrow.down")
    }
}
