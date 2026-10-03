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

    /// Not looked at in a long time (or ever since collecting), oldest first.
    static func forgotten(_ items: [Item], now: Date = Date(), after days: Double = 30) -> [Item] {
        let cutoff = now.addingTimeInterval(-days * 86400)
        return items
            .filter { $0.dateAdded < cutoff && ($0.lastViewed ?? $0.dateAdded) < cutoff }
            .sorted { ($0.lastViewed ?? $0.dateAdded) < ($1.lastViewed ?? $1.dateAdded) }
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
        case ..<1: return "今天收藏的"
        case 1: return "昨天收藏的"
        default:
            let n = NumberFormatter.localizedString(from: NSNumber(value: days), number: .decimal)
            return "你在 \(n) 天前收藏了這個"
        }
    }
}
