import AppKit

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
    static func discover(in items: [Item], limit: Int = 8, minimum: Int = 3) -> [Subject] {
        var counts: [String: Int] = [:]
        for item in items {
            for label in Set(item.labels ?? []) where !ignored.contains(label) { counts[label, default: 0] += 1 }
        }
        let ceiling = max(Int(Double(items.count) * 0.7), 3)
        return counts
            .filter { $0.value >= minimum && $0.value <= ceiling }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { Subject(label: $0.key, title: title($0.key), count: $0.value) }
    }

    /// A theme's name in the app's language: from the Themes table (keyed by
    /// the Vision label), else the Chinese name, else the label itself.
    static func title(_ label: String) -> String {
        let fallback = chinese[label] ?? label.prefix(1).uppercased() + label.dropFirst()
        return Bundle.main.localizedString(forKey: label, value: fallback, table: "Themes")
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
        "recreation": "休閒", "celebration": "慶祝", "party": "派對", "wedding": "婚禮", "people_group": "群體", "people group": "群體",
        "office": "辦公室", "workplace": "工作場所", "classroom": "教室", "restaurant": "餐廳", "shop": "商店", "museum": "博物館",
        "gadget": "小器材", "electronics": "電子產品", "appliance": "家電", "radio": "收音機", "clock": "時鐘", "screen": "螢幕",
        "monitor": "螢幕", "keyboard": "鍵盤", "turntable": "唱盤", "vinyl": "黑膠", "record": "唱片", "film": "電影", "movie": "電影",
        "comics": "漫畫", "anime": "動畫", "graphic design": "平面設計", "handwriting": "手寫字", "calligraphy": "書法",
        "flag": "旗子", "fireworks": "煙火", "candle": "蠟燭", "bottle": "瓶子", "cup": "杯子", "plate": "盤子", "bowl": "碗",
        "dining": "用餐", "cooking": "烹飪", "bread": "麵包", "cake": "蛋糕", "pizza": "披薩", "sushi": "壽司", "wine": "葡萄酒",
        "flowerpot": "盆栽", "houseplant": "室內植物", "leaf": "葉子", "rock": "岩石", "lake": "湖", "river": "河", "waterfall": "瀑布",
        "cloud": "雲", "rain": "雨", "winter": "冬天", "autumn": "秋天", "spring": "春天", "summer": "夏天",
        "adult": "成人", "teen": "青少年", "document": "文件", "printed page": "印刷頁", "screenshot": "截圖",
        "door": "門", "brick": "磚", "cardboard box": "紙箱", "cord": "線材", "raw glass": "玻璃", "cabinet": "櫃子",
        "circuit board": "電路板", "chart": "圖表", "diagram": "圖解", "stool": "凳子", "footwear": "鞋類", "sandal": "涼鞋",
        "toilet seat": "馬桶座", "toilet": "馬桶", "bathroom": "浴室", "sink": "洗手台", "bathtub": "浴缸", "faucet": "水龍頭",
        "tile": "磁磚", "floor": "地板", "wall": "牆", "ceiling": "天花板", "stairs": "樓梯", "curtain": "窗簾", "shelf": "架子",
        "bed": "床", "desk": "書桌", "mirror": "鏡子", "rug": "地毯", "pillow": "枕頭", "tool": "工具", "hand": "手",
        "cable": "電線", "wire": "電線", "construction": "施工", "paper": "紙",
        "textile": "布料", "fabric": "布料", "bag_luggage": "行李", "container": "容器", "box": "盒子",
        "structure": "結構物", "outdoor": "戶外", "land": "地景", "clothing": "服裝", "sky": "天空", "blue sky": "藍天",
        "blue_sky": "藍天", "cloudy": "多雲", "machine": "機器", "conveyance": "交通工具", "vehicle": "車輛",
        "automobile": "汽車", "road other": "道路", "material": "材質", "fence": "圍欄", "necktie": "領帶",
        "foliage": "枝葉", "cityscape": "城市風景", "elevator": "電梯", "portal": "入口", "window": "窗戶",
        "electric fan": "電風扇", "plant": "植物",
        "path": "小徑", "decoration": "裝飾", "frame": "框", "washbasin": "洗手台", "armchair": "扶手椅", "hill": "山丘", "bathroom room": "浴室空間", "carton": "紙盒", "utensil": "器具", "sneaker": "球鞋", "shower": "淋浴", "bucket": "水桶", "kitchen countertop": "流理台", "alley": "巷弄", "bath": "泡澡", "bathroom faucet": "浴室水龍頭", "broom": "掃把", "housewares": "家用品", "kitchen sink": "廚房水槽", "decorative plant": "裝飾植物",
    ]
}

/// The colour words the analysis gives each picture, in the order of the
/// spectrum, with their Chinese names and a swatch to show them by.
enum Colours {
    static let all: [(name: String, title: String, swatch: NSColor)] = [
        ("red", String(localized: "紅色"), .systemRed), ("orange", String(localized: "橙色"), .systemOrange),
        ("yellow", String(localized: "黃色"), .systemYellow), ("green", String(localized: "綠色"), .systemGreen),
        ("blue", String(localized: "藍色"), .systemBlue), ("purple", String(localized: "紫色"), .systemPurple),
        ("pink", String(localized: "粉紅色"), .systemPink), ("brown", String(localized: "棕色"), .systemBrown),
        ("black", String(localized: "黑色"), NSColor(white: 0.08, alpha: 1)), ("white", String(localized: "白色"), NSColor(white: 0.97, alpha: 1)),
        ("gray", String(localized: "灰色"), .systemGray),
    ]

    static func title(_ name: String) -> String { all.first { $0.name == name }?.title ?? name }
    static func swatch(_ name: String) -> NSColor { all.first { $0.name == name }?.swatch ?? .gray }
}
