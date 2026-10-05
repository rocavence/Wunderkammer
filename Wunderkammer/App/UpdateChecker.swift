import Foundation

/// Once a day, asks GitHub for the newest release. Nothing downloads by
/// itself: a newer version shows up in the app menu and in Settings → 關於,
/// and opens its page when chosen.
@MainActor
final class UpdateChecker {
    struct Release: Equatable {
        var version: String
        var page: URL
    }

    static let releases = URL(string: "https://github.com/rocavence/Wunderkammer/releases/latest")!
    private static let api = URL(string: "https://api.github.com/repos/rocavence/Wunderkammer/releases/latest")!
    private static let checkedKey = "updateCheckedAt"

    private(set) var available: Release?
    var onChange: (() -> Void)?

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: Self.checkedKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86400 else { return }
        Task { await check() }
    }

    /// Whether a newer version is out; nil when GitHub couldn't be asked.
    @discardableResult
    func check() async -> Bool? {
        struct Latest: Decodable { var tag_name: String; var html_url: URL; var draft: Bool; var prerelease: Bool }
        var request = URLRequest(url: Self.api, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = try? JSONDecoder().decode(Latest.self, from: data), !latest.draft, !latest.prerelease else { return nil }
        UserDefaults.standard.set(Date(), forKey: Self.checkedKey)
        let version = latest.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let found = Self.isNewer(version, than: Self.current) ? Release(version: version, page: latest.html_url) : nil
        if found != available {
            available = found
            onChange?()
        }
        return found != nil
    }

    /// 0.10.0 is newer than 0.9.2; a missing part counts as 0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
