import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The page open in the frontmost browser, for ⌘⇧C without copying first.
enum BrowserTab {
    struct Page {
        var url: URL
        var title: String?
    }

    private static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "company.thebrowser.Browser",
        "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "org.chromium.Chromium", "com.operasoftware.Opera",
    ]
    /// No AppleScript: the address bar is copied with ⌘L ⌘C (needs Accessibility).
    private static let firefoxLike: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "app.zen-browser.zen",
        "net.waterfox.waterfox", "io.github.nicholasgasior.librewolf", "org.torproject.torbrowser",
    ]

    static func isBrowser(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return safari.contains(id) || chromium.contains(id) || firefoxLike.contains(id)
    }

    enum Failure { case notBrowser, needsAccessibility, needsAutomation, failed }

    static func current(_ app: NSRunningApplication?) async -> Result<Page, FailureError> {
        guard let app, let id = app.bundleIdentifier else { return .failure(.init(.notBrowser)) }
        if safari.contains(id) {
            return script("""
                tell application id "\(id)" to return {URL of front document, name of front document}
                """)
        }
        if chromium.contains(id) {
            return script("""
                tell application id "\(id)" to return {URL of active tab of front window, title of active tab of front window}
                """)
        }
        if firefoxLike.contains(id) { return await copyAddressBar(app) }
        return .failure(.init(.notBrowser))
    }

    struct FailureError: Error {
        let reason: Failure
        init(_ reason: Failure) { self.reason = reason }
    }

    private static func script(_ source: String) -> Result<Page, FailureError> {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        // errAEEventNotPermitted: turned off in System Settings → Privacy & Security → Automation.
        if (error?[NSAppleScript.errorNumber] as? Int) == -1743 { return .failure(.init(.needsAutomation)) }
        guard let result, result.numberOfItems >= 1,
              let s = result.atIndex(1)?.stringValue, let url = URL(string: s), url.scheme?.hasPrefix("http") == true
        else { return .failure(.init(.failed)) }
        return .success(Page(url: url, title: result.atIndex(2)?.stringValue))
    }

    /// ⌘L, ⌘C, Esc in the browser, then read the clipboard and put back what was there.
    private static func copyAddressBar(_ app: NSRunningApplication) async -> Result<Page, FailureError> {
        guard AXIsProcessTrusted() else {
            // kAXTrustedCheckOptionPrompt's value; the global itself isn't concurrency-safe.
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return .failure(.init(.needsAccessibility))
        }
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        } ?? []
        let before = pb.changeCount
        let steps: [(Int, CGEventFlags)] = [(kVK_ANSI_L, .maskCommand), (kVK_ANSI_C, .maskCommand), (kVK_Escape, [])]
        for (key, flags) in steps {
            press(key, flags, pid: app.processIdentifier)
            try? await Task.sleep(for: .milliseconds(70))
        }
        try? await Task.sleep(for: .milliseconds(120))
        let copied = pb.changeCount != before ? pb.string(forType: .string) : nil
        // Restore the clipboard so capturing a page doesn't eat what the user had copied.
        pb.clearContents()
        let restored = saved.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in types { item.setData(d, forType: t) }
            return item
        }
        if !restored.isEmpty { pb.writeObjects(restored) }
        guard let copied, let url = PasteboardReader.linkOnly(copied.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return .failure(.init(.failed)) }
        return .success(Page(url: url, title: nil))
    }

    private static func press(_ key: Int, _ flags: CGEventFlags, pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            e?.flags = flags
            e?.postToPid(pid)
        }
    }
}
