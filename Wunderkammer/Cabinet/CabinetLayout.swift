import CoreGraphics
import Foundation

/// The scrolling cabinet views: Grid (justified rows), Masonry (columns),
/// Timeline (justified rows under a heading per day collected).
enum CabinetStyle: Int, Sendable {
    case grid, masonry, timeline
}

struct CabinetLayout {
    var style: CabinetStyle
    var width: CGFloat
    /// Row height (grid, timeline) or column width (masonry): what zoom changes.
    var size: CGFloat
    /// Atlas: 14 pt between tiles and at the edges.
    var spacing: CGFloat = 14
    var inset: CGFloat = 14
    /// A day's heading row, and the air above it (more than below, so the
    /// heading belongs to the pictures it names).
    var headerHeight: CGFloat = 44
    var headerGap: CGFloat = 30

    struct Header: Equatable {
        var title: String
        /// The date itself when the title is relative (昨天, 星期五), and how many.
        var detail: String = ""
        var frame: CGRect
    }

    struct Result {
        var frames: [CGRect]
        var headers: [Header] = []
        var height: CGFloat
    }

    func layout(aspects: [CGFloat], dates: [Date] = [], calendar: Calendar = .current, now: Date = Date()) -> Result {
        switch style {
        case .grid:
            let r = JustifiedLayout(width: width, rowHeight: size, spacing: spacing, inset: inset).layout(aspects: aspects)
            return Result(frames: r.frames, height: r.height)
        case .masonry:
            return masonry(aspects)
        case .timeline:
            return timeline(aspects, dates: dates, calendar: calendar, now: now)
        }
    }

    private func masonry(_ aspects: [CGFloat]) -> Result {
        let usable = max(width - inset * 2, 1)
        let columns = max(1, Int((usable + spacing) / (size + spacing)))
        let columnWidth = (usable - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var heights = [CGFloat](repeating: inset, count: columns)
        var frames: [CGRect] = []
        frames.reserveCapacity(aspects.count)
        for aspect in aspects {
            // Shortest column next, leftmost on ties, so reading order stays left to right.
            let c = heights.indices.min { heights[$0] < heights[$1] }!
            let h = columnWidth / max(aspect, 0.01)
            frames.append(CGRect(x: inset + CGFloat(c) * (columnWidth + spacing), y: heights[c], width: columnWidth, height: h))
            heights[c] += h + spacing
        }
        let height = aspects.isEmpty ? 0 : (heights.max() ?? 0) - spacing + inset
        return Result(frames: frames, height: height)
    }

    private func timeline(_ aspects: [CGFloat], dates: [Date], calendar: Calendar, now: Date) -> Result {
        var frames = [CGRect](repeating: .zero, count: aspects.count)
        var headers: [Header] = []
        // y: the bottom of what's laid out so far.
        var y: CGFloat = 0
        var start = 0
        while start < aspects.count {
            let day = calendar.startOfDay(for: dates[safe: start] ?? now)
            var end = start + 1
            while end < aspects.count, calendar.startOfDay(for: dates[safe: end] ?? now) == day { end += 1 }
            let title = Self.title(for: day, calendar: calendar, now: now)
            let date = Self.shortDate(day, calendar: calendar, now: now)
            let count = "\(end - start) 件"
            y += start == 0 ? 2 : headerGap
            headers.append(Header(title: title, detail: title.contains("月") ? count : "\(date) · \(count)",
                                  frame: CGRect(x: inset, y: y, width: width - inset * 2, height: headerHeight)))
            y += headerHeight
            let section = JustifiedLayout(width: width, rowHeight: size, spacing: spacing, inset: inset)
                .layout(aspects: Array(aspects[start..<end]))
            for (i, f) in section.frames.enumerated() {
                frames[start + i] = f.offsetBy(dx: 0, dy: y + 4 - inset)
            }
            y = section.frames.reduce(y) { max($0, $1.maxY + y + 4 - inset) }
            start = end
        }
        return Result(frames: frames, headers: headers, height: aspects.isEmpty ? 0 : y + inset)
    }

    /// 今天、昨天、本週的星期幾，今年的「10 月 3 日」，更早的加上年份。
    /// "10 月 2 日", with the year only when it isn't this one.
    static func shortDate(_ day: Date, calendar: Calendar, now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.calendar = calendar
        f.dateFormat = calendar.isDate(day, equalTo: now, toGranularity: .year) ? "M 月 d 日" : "y 年 M 月 d 日"
        return f.string(from: day)
    }

    static func title(for day: Date, calendar: Calendar, now: Date) -> String {
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days == 0 { return "今天" }
        if days == 1 { return "昨天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.calendar = calendar
        if days < 7 {
            f.dateFormat = "EEEE"
            return f.string(from: day)
        }
        f.dateFormat = calendar.isDate(day, equalTo: today, toGranularity: .year) ? "M 月 d 日 EEEE" : "y 年 M 月 d 日"
        return f.string(from: day)
    }
}

/// Finds the frames in a rect without assuming rows (masonry columns aren't
/// sorted by y). Sorted by top edge; a query scans from the first frame that
/// could reach the rect.
struct SpatialIndex {
    private var order: [Int] = []
    private var tops: [CGFloat] = []
    private var tallest: CGFloat = 0
    private var frames: [CGRect] = []

    init(_ frames: [CGRect] = []) {
        self.frames = frames
        order = frames.indices.sorted { frames[$0].minY < frames[$1].minY }
        tops = order.map { frames[$0].minY }
        tallest = frames.map(\.height).max() ?? 0
    }

    func indices(in rect: CGRect) -> [Int] {
        guard !frames.isEmpty else { return [] }
        let from = rect.minY - tallest
        var lo = 0, hi = tops.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tops[mid] < from { lo = mid + 1 } else { hi = mid }
        }
        var out: [Int] = []
        var k = lo
        while k < tops.count, tops[k] <= rect.maxY {
            let i = order[k]
            if frames[i].intersects(rect) { out.append(i) }
            k += 1
        }
        return out.sorted()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
