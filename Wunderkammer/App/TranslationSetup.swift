import AppKit
import SwiftUI
import Translation

/// The system's own "download this language" prompt for Chinese → English,
/// shown once in a small sheet. Translation stays on this Mac.
@MainActor
enum TranslationSetup {
    static func present(over window: NSWindow, done: @escaping () -> Void) {
        guard #available(macOS 15.0, *) else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        let view = SetupView {
            window.endSheet(sheet)
            done()
        }
        sheet.contentView = NSHostingView(rootView: view)
        window.beginSheet(sheet)
    }

    @available(macOS 15.0, *)
    private struct SetupView: View {
        let close: () -> Void
        @State private var configuration: TranslationSession.Configuration?
        @State private var message = "下載「中文（繁體）→ 英文」的翻譯語言後，就能用中文描述搜尋，例如「坐在餐桌前的貓」。翻譯在這台 Mac 上完成。"

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text(message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("稍後") { close() }
                    Button("下載") {
                        configuration = .init(source: Locale.Language(identifier: "zh-Hant"), target: Locale.Language(identifier: "en"))
                    }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 380)
            .translationTask(configuration) { session in
                nonisolated(unsafe) let s = session
                do {
                    try await s.prepareTranslation()
                    close()
                } catch {
                    message = "沒有完成下載。也可以到「系統設定 → 一般 → 語言與地區 → 翻譯語言」下載。"
                }
            }
        }
    }
}
