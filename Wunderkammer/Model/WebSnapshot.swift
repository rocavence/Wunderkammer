import AppKit
import WebKit

/// A picture of a page that has no preview image of its own: loaded in an
/// invisible web view with no cookies or logins (a fresh, private data store),
/// and snapshotted once it has finished loading.
@MainActor
final class WebSnapshot: NSObject, WKNavigationDelegate {
    private let view: WKWebView
    private let window: NSWindow
    private var done: CheckedContinuation<CGImage?, Never>?
    /// For saving a page: resumed true once it has loaded, false if it didn't.
    private var loaded: CheckedContinuation<Bool, Never>?
    private var timeout: DispatchWorkItem?

    private init(size: CGSize) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        view = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        // Off screen, but in a window, so WebKit renders it.
        window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        // Pages as they are on the web, not tinted by the app's dark mode.
        window.appearance = NSAppearance(named: .aqua)
        view.appearance = NSAppearance(named: .aqua)
        super.init()
        view.navigationDelegate = self
    }

    /// Many links captured at once shouldn't spin up a web view each.
    private static var running = 0
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    static func capture(_ url: URL, size: CGSize = CGSize(width: 1200, height: 800), timeout: TimeInterval = 12) async -> CGImage? {
        guard WebMetadata.isWeb(url) else { return nil }
        await enter()
        defer { leave() }
        return await take(url, size: size, timeout: timeout)
    }

    private static func enter() async {
        if running >= 2 { await withCheckedContinuation { waiting.append($0) } }
        running += 1
    }

    private static func leave() {
        running -= 1
        if !waiting.isEmpty { waiting.removeFirst().resume() }
    }

    struct Archive: Sendable {
        /// The whole page, top to bottom, as one PDF page (text stays text).
        var pdf: Data
        /// What the page says, as plain text.
        var text: String?
    }

    /// The page as it is now, to keep: a PDF of all of it and its words.
    static func archive(_ url: URL, timeout: TimeInterval = 20) async -> Archive? {
        guard WebMetadata.isWeb(url) else { return nil }
        await enter()
        defer { leave() }
        let snap = WebSnapshot(size: CGSize(width: 1200, height: 900))
        defer { snap.view.stopLoading(); snap.window.orderOut(nil) }
        let ok = await withCheckedContinuation { c in
            snap.loaded = c
            let work = DispatchWorkItem { [weak snap] in MainActor.assumeIsolated { snap?.didLoad(false) } }
            snap.timeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
            snap.window.orderBack(nil)
            snap.view.load(URLRequest(url: url, timeoutInterval: timeout))
        }
        guard ok else { return nil }
        // Down to the bottom and back, so images that load on scroll are there.
        _ = try? await snap.view.callAsyncJavaScript("window.scrollTo(0, document.body.scrollHeight)", contentWorld: .page)
        try? await Task.sleep(for: .milliseconds(900))
        _ = try? await snap.view.callAsyncJavaScript("window.scrollTo(0, 0)", contentWorld: .page)
        _ = try? await snap.view.callAsyncJavaScript(clearOverlays, contentWorld: .page)
        try? await Task.sleep(for: .milliseconds(300))
        // The page's main content when it marks one, rather than menus first.
        let text = (try? await snap.view.callAsyncJavaScript("""
            const main = document.querySelector('main, article, [role=main]');
            const t = main ? main.innerText : '';
            return t.length > 200 ? t : (document.body ? document.body.innerText : '');
            """, contentWorld: .page)) as? String
        // A blank page, a block or a "are you human" check isn't worth keeping.
        guard let words = text.map(tidy), words.count >= 200,
              let pdf = try? await snap.view.pdf(configuration: WKPDFConfiguration()) else { return nil }
        return Archive(pdf: pdf, text: words)
    }

    /// Blank lines and runs of spaces squeezed out.
    nonisolated static func tidy(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func didLoad(_ ok: Bool) {
        timeout?.cancel()
        guard let loaded else { return }
        self.loaded = nil
        loaded.resume(returning: ok)
    }

    private static func take(_ url: URL, size: CGSize, timeout: TimeInterval) async -> CGImage? {
        let snap = WebSnapshot(size: size)
        return await withCheckedContinuation { c in
            snap.done = c
            let work = DispatchWorkItem { [weak snap] in MainActor.assumeIsolated { snap?.finish(nil) } }
            snap.timeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
            snap.window.orderBack(nil)
            snap.view.load(URLRequest(url: url, timeoutInterval: timeout))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            if loaded != nil { return didLoad(true) }
            // Give late layout and web fonts a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                MainActor.assumeIsolated { self?.snapshot() }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { didLoad(false); finish(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { didLoad(false); finish(nil) }
    }

    /// Cookie and consent notices pinned over the page aren't the page: gone
    /// before the picture or the saved copy is taken. Only overlays (fixed,
    /// sticky or dialogs) that talk about cookies, consent or privacy.
    static let clearOverlays = """
        const words = /cookie|consent|gdpr|onetrust|didomi|cookiebot|truste|osano|privacy|同意|隱私|クッキー/i;
        let removed = 0;
        for (const el of Array.from(document.querySelectorAll('body *'))) {
            if (!el.isConnected) continue;
            const cs = getComputedStyle(el);
            const overlay = cs.position === 'fixed' || cs.position === 'sticky'
                || el.getAttribute('role') === 'dialog' || el.getAttribute('aria-modal') === 'true';
            if (!overlay) continue;
            const named = words.test((el.id || '') + ' ' + (typeof el.className === 'string' ? el.className : ''));
            const text = (el.innerText || '').slice(0, 2000);
            if (named || words.test(text)) { el.remove(); removed++; }
        }
        document.documentElement.style.overflow = '';
        if (document.body) document.body.style.overflow = '';
        return removed;
        """

    private func snapshot() {
        Task { @MainActor in
            _ = try? await view.callAsyncJavaScript(Self.clearOverlays, contentWorld: .page)
            try? await Task.sleep(for: .milliseconds(150))
            takePicture()
        }
    }

    private func takePicture() {
        let config = WKSnapshotConfiguration()
        config.rect = view.bounds
        // Points; ×2 on Retina gives the 1,200 px every representation gets.
        config.snapshotWidth = NSNumber(value: Double(Representer.cardSize) / Double(window.backingScaleFactor))
        view.takeSnapshot(with: config) { [weak self] image, _ in
            MainActor.assumeIsolated {
                self?.finish(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    private func finish(_ image: CGImage?) {
        timeout?.cancel()
        guard let done else { return }
        self.done = nil
        view.stopLoading()
        window.orderOut(nil)
        done.resume(returning: image)
    }
}
