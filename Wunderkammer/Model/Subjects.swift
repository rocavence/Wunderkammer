import Foundation

/// Auto collections by subject: the things the system keeps seeing in the
/// cabinet (people, architecture, illustration…) become views of their own.
/// Nobody makes or maintains them; they appear once there's enough of one.
enum Subjects {
    struct Subject: Hashable {
        var label: String
        var title: String
        var count: Int
    }

    /// Vision labels too general to be a theme.
    private static let ignored: Set<String> = [
        "structure", "material", "textile", "liquid", "water body", "adult", "consumer electronics", "machine",
        "clothing", "plant", "outdoor", "land", "sky", "screenshot", "document", "printed page", "paper", "wood processed",
        "wood natural", "interior room", "conveyance", "vehicle", "container", "furniture", "tool",
    ]

    /// The cabinet's own themes: labels on at least 3 items (and not on nearly
    /// everything), most common first.
    static func discover(in items: [Item], limit: Int = 8) -> [Subject] {
        var counts: [String: Int] = [:]
        for item in items {
            for label in Set(item.labels ?? []) where !ignored.contains(label) { counts[label, default: 0] += 1 }
        }
        let ceiling = max(Int(Double(items.count) * 0.7), 3)
        return counts
            .filter { $0.value >= 3 && $0.value <= ceiling }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { Subject(label: $0.key, title: title($0.key), count: $0.value) }
    }

    static func title(_ label: String) -> String {
        chinese[label] ?? label.prefix(1).uppercased() + label.dropFirst()
    }

    /// Chinese names for the Vision labels that tend to become themes.
    static let chinese: [String: String] = [
        "people": "人物", "portrait": "肖像", "face": "臉", "child": "孩子", "baby": "嬰兒", "crowd": "人群",
        "animal": "動物", "cat": "貓", "dog": "狗", "bird": "鳥", "fish": "魚", "insect": "昆蟲", "horse": "馬", "mammal": "哺乳動物",
        "building": "建築", "architecture": "建築", "house": "房子", "skyscraper": "摩天大樓", "bridge": "橋", "interior": "室內",
        "city": "城市", "street": "街道", "road": "道路", "car": "汽車", "bicycle": "腳踏車", "train": "火車", "aircraft": "飛機", "boat": "船",
        "nature": "自然", "mountain": "山", "sea": "海", "ocean": "海洋", "beach": "海灘", "forest": "森林", "tree": "樹", "flower": "花",
        "sunset_sunrise": "日出日落", "sunset sunrise": "日出日落", "snow": "雪", "desert": "沙漠", "garden": "花園",
        "food": "食物", "dessert": "甜點", "drink": "飲料", "coffee": "咖啡", "fruit": "水果", "vegetable": "蔬菜",
        "art": "藝術", "illustrations": "插畫", "painting": "繪畫", "drawing": "素描", "sculpture": "雕塑", "cartoon": "卡通",
        "poster": "海報", "sign": "標誌", "text": "文字", "logo": "標誌設計", "typography": "字體排印", "book": "書",
        "chair": "椅子", "table": "桌子", "sofa": "沙發", "lamp": "燈", "kitchen": "廚房", "bedroom": "臥室",
        "computer": "電腦", "phone": "手機", "camera": "相機", "television": "電視", "speaker": "喇叭", "headphones": "耳機",
        "jewelry": "珠寶", "shoes": "鞋子", "bag": "包包", "watch": "手錶", "fashion": "時尚", "hat": "帽子", "glasses": "眼鏡",
        "music": "音樂", "musical instrument": "樂器", "guitar": "吉他", "piano": "鋼琴", "concert": "演唱會",
        "sport": "運動", "ball": "球", "game": "遊戲", "toy": "玩具", "map": "地圖", "space": "太空", "night_sky": "夜空", "night sky": "夜空",
        "jacket": "外套", "suit": "西裝", "eyeglasses": "眼鏡", "optical equipment": "光學器材", "branch": "樹枝", "grass": "草",
        "wood": "木頭", "metal": "金屬", "glass": "玻璃", "light": "光", "shadow": "陰影", "pattern": "圖案",
    ]
}
