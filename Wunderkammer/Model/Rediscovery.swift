import Foundation

/// Forgetting is part of the product: these bring things back.
enum Rediscovery {
    /// Collected on this calendar day in earlier years, or failing that,
    /// on this day of the month in earlier months.
    static func onThisDay(_ items: [Item], now: Date = Date(), calendar: Calendar = .current) -> [Item] {
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        let earlier = items.filter { calendar.startOfDay(for: $0.dateAdded) < calendar.startOfDay(for: now) }
        let sameDay = earlier.filter {
            let c = calendar.dateComponents([.month, .day], from: $0.dateAdded)
            return c.month == today.month && c.day == today.day
        }
        if !sameDay.isEmpty { return sameDay }
        return earlier.filter { calendar.component(.day, from: $0.dateAdded) == today.day }
    }

    /// Not looked at in a long time (or ever since collecting). Things you
    /// once came back to again and again come first, then the longest unseen.
    static func forgotten(_ items: [Item], now: Date = Date(), after days: Double = 30) -> [Item] {
        let cutoff = now.addingTimeInterval(-days * 86400)
        func score(_ item: Item) -> Double {
            let unseen = now.timeIntervalSince(item.lastViewed ?? item.dateAdded) / 86400
            return unseen * (1 + log1p(Double(item.viewCount)) * 3)
        }
        return items
            .filter { $0.dateAdded < cutoff && ($0.lastViewed ?? $0.dateAdded) < cutoff }
            .sorted { score($0) > score($1) }
    }

    struct Pick {
        let item: Item
        /// Why it's here today, in a line under the picture.
        let reason: String
    }

    /// 今天的推薦: a dozen things for today, chosen on this Mac from what you've
    /// been looking at lately (shared themes), what you used to come back to,
    /// and what you collected but never really looked at. Nothing looked at in
    /// the last three days; things collected that recently only fill in when
    /// the room is too new to have enough else. The same all day; a new set tomorrow.
    static func forToday(_ items: [Item], now: Date = Date(), count: Int = 12, calendar: Calendar = .current) -> [Pick] {
        let day = 86400.0
        let lately = now.addingTimeInterval(-14 * day), fresh = now.addingTimeInterval(-3 * day)
        var taste: [String: Double] = [:]
        for item in items where (item.lastViewed ?? .distantPast) > lately || item.dateAdded > lately {
            for label in Set(item.labels ?? []) where Subjects.isTheme(label) {
                taste[label, default: 0] += 1 + Double(item.viewCount) * 0.2
            }
        }
        let strongest = taste.values.max() ?? 1
        let seed = calendar.startOfDay(for: now).timeIntervalSinceReferenceDate
        var scored: [(pick: Pick, score: Double, theme: String?)] = []
        for item in items where (item.lastViewed ?? .distantPast) < fresh {
            let unseen = now.timeIntervalSince(item.lastViewed ?? item.dateAdded) / day
            let theme = (item.labels ?? []).filter { taste[$0] != nil }.max { taste[$0]! < taste[$1]! }
            let kin = theme.map { taste[$0]! / strongest } ?? 0
            let favourite = item.viewCount >= 3 && unseen > 30
            let unlooked = item.lastViewed == nil && unseen > 14
            var score = kin * 1.2 + log1p(unseen) / 12 + jitter(item.id, seed) * 0.6
            if item.dateAdded > fresh { score -= 10 }
            if favourite { score += 0.8 }
            if unlooked { score += 0.4 }
            let reason: String
            if let theme, kin >= 0.3 {
                reason = String(localized: "和你最近常看的「\(Subjects.title(theme))」有關")
            } else if favourite {
                reason = String(localized: "你以前常看，已經 \(Int(unseen)) 天沒打開")
            } else if unlooked {
                reason = String(localized: "收進來之後還沒仔細看過")
            } else {
                reason = ageLine(item, now: now, calendar: calendar)
            }
            scored.append((Pick(item: item, reason: reason), score, kin >= 0.3 ? theme : nil))
        }
        // Best first, but no one theme takes more than a third of the day.
        var picks: [Pick] = [], perTheme: [String: Int] = [:]
        for s in scored.sorted(by: { $0.score > $1.score }) where picks.count < count {
            if let t = s.theme {
                guard perTheme[t, default: 0] < max(count / 3, 1) else { continue }
                perTheme[t, default: 0] += 1
            }
            picks.append(s.pick)
        }
        return picks
    }

    /// The same small nudge for an item all day, a different one tomorrow.
    private static func jitter(_ id: UUID, _ seed: Double) -> Double {
        var h: UInt64 = 0xcbf29ce484222325
        for b in (id.uuidString + String(Int(seed))).utf8 {
            h = (h ^ UInt64(b)) &* 0x100000001b3
        }
        return Double(h % 10_000) / 10_000
    }

    /// R: not uniform. Older and less-seen things are likelier, recently shown
    /// ones much less; a little pure chance keeps it surprising.
    static func pick(_ items: [Item], now: Date = Date(), avoiding recent: [UUID] = [],
                     random: () -> Double = { Double.random(in: 0..<1) }) -> Item? {
        guard !items.isEmpty else { return nil }
        let recentSet = Set(recent)
        let weights = items.map { item -> Double in
            let ageDays = max(now.timeIntervalSince(item.dateAdded) / 86400, 0)
            let unseenDays = max(now.timeIntervalSince(item.lastViewed ?? item.dateAdded) / 86400, 0)
            var w = 1 + log1p(ageDays) * 0.6 + log1p(unseenDays) * 0.8
            w /= 1 + Double(item.viewCount) * 0.3
            if recentSet.contains(item.id) { w *= 0.02 }
            return w + 0.3 // serendipity floor
        }
        var r = random() * weights.reduce(0, +)
        for (item, w) in zip(items, weights) {
            r -= w
            if r < 0 { return item }
        }
        return items.last
    }

    /// "You collected this 1,247 days ago."
    static func ageLine(_ item: Item, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: item.dateAdded), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return String(localized: "今天收藏的")
        case 1: return String(localized: "昨天收藏的")
        default:
            let n = NumberFormatter.localizedString(from: NSNumber(value: days), number: .decimal)
            return String(localized: "你在 \(n) 天前收藏了這個")
        }
    }
}
