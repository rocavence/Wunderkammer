import AppKit

/// An empty 釘選版 says what it is: a few things picked out of the room and
/// kept together, its own canvas on the 工作台, what it's good for, and how
/// to put things on it.
@MainActor
final class BoardIntro: NSView {
    init() {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: String(localized: "這個釘選版還是空的"))
        title.font = Typography.display(20) ?? .systemFont(ofSize: 20, weight: .semibold)
        let points: [(Reicon, String)] = [
            (.cabinet, String(localized: "從這個展室挑出來放在一起的東西。東西仍在展室裡，同一件可以釘在好幾個版上，從版上拿掉也不會刪除。")),
            (.kanban, String(localized: "到工作台打開它，會有一張專屬的畫布：自由擺放、分堆、連線，不影響「全部」的排法。")),
            (.sparkles, String(localized: "適合放一個專案的參考、挑給別人看的候選，或下一趟旅行想去的地方。")),
            (.inboxIn, String(localized: "把收藏拖到左邊的這個釘選版上，或直接把檔案拖進來。")),
        ]
        let lines = points.map { icon, text -> NSView in
            let mark = NSImageView(image: Icon.optical(icon, size: 18))
            mark.contentTintColor = .accent
            mark.setContentHuggingPriority(.required, for: .horizontal)
            let words = NSTextField(wrappingLabelWithString: text)
            words.font = .systemFont(ofSize: 14)
            words.textColor = .secondaryLabelColor
            words.preferredMaxLayoutWidth = Self.width - 30
            let line = NSStackView(views: [mark, words])
            line.alignment = .top
            line.spacing = 12
            return line
        }
        let stack = NSStackView(views: [title] + lines)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.setCustomSpacing(22, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    static let width: CGFloat = 400
}
