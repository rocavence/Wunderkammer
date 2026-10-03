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
        if running >= 2 { await withCheckedContinuation { waiting.append($0) } }
        running += 1
        defer {
            running -= 1
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        return await take(url, size: size, timeout: timeout)
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
            // Give late layout and web fonts a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                MainActor.assumeIsolated { self?.snapshot() }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(nil) }
    }

    private func snapshot() {
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
