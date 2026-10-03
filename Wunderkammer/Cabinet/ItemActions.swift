import AppKit

extension NSPasteboard.PasteboardType {
    /// Library item IDs dragged between views and onto boards in the sidebar.
    static let wunderkammerItem = NSPasteboard.PasteboardType("com.rocavence.wunderkammer.item")
}

/// What Grid, Canvas and Infinity share: preview hooks and the actions that
/// apply to a selection (delete, add to board, reveal).
@MainActor
protocol ItemSurface: AnyObject {
    var shownItems: [Item] { get }
    func rectInWindow(for id: UUID) -> NSRect?
    func currentImage(for id: UUID) -> CGImage?
    /// Select and scroll/pan so the item is on screen (preview closing).
    func reveal(_ id: UUID)
    /// Preview ripple: push the neighbours away, then spring them back.
    func previewWillOpen(_ id: UUID)
    func previewWillClose(landingOn id: UUID)
    func previewDidClose()
}

@MainActor
enum ItemActions {
    /// In a board, Delete takes items out of the board. In All Images it
    /// deletes them (files go to the Trash) after confirming.
    static func delete(_ ids: [UUID], board: UUID?, library: Library, window: NSWindow?) {
        guard !ids.isEmpty else { return }
        if let board {
            library.remove(Set(ids), from: board)
            return
        }
        let alert = NSAlert()
        alert.messageText = ids.count == 1 ? "刪除這張圖？" : "刪除 \(ids.count) 張圖？"
        alert.informativeText = "原始檔會移到垃圾桶，所有 board 裡的這些圖也會一起移除。"
        alert.addButton(withTitle: "刪除")
        alert.addButton(withTitle: "取消")
        alert.buttons[0].hasDestructiveAction = true
        let run = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn { library.delete(Set(ids)) }
        }
        if let window {
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { run(response) } }
        } else {
            run(alert.runModal())
        }
    }

    static func menu(for ids: [UUID], board: UUID?, library: Library, window: NSWindow?,
                     open: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("打開預覽") { open() })

        let addTo = NSMenuItem(title: "加入 board", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for b in library.collections where b.id != board {
            sub.addItem(ClosureMenuItem(b.name) { library.add(ids, to: b.id) })
        }
        if !library.collections.isEmpty { sub.addItem(.separator()) }
        sub.addItem(ClosureMenuItem("新增 board…") {
            if let name = promptName(title: "新 board 名稱", initial: "未命名 board", window: window) {
                library.createCollection(named: name, with: ids)
            }
        })
        addTo.submenu = sub
        menu.addItem(addTo)

        menu.addItem(ClosureMenuItem("在 Finder 中顯示") {
            let urls = ids.compactMap(library.item).map(library.originalURL)
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        })
        menu.addItem(.separator())
        let title = board == nil ? "刪除…" : "從 board 移除"
        menu.addItem(ClosureMenuItem(title) { delete(ids, board: board, library: library, window: window) })
        return menu
    }

    static func promptName(title: String, initial: String, window: NSWindow?) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// One pasteboard item per image: our ID for in-app drops, the file for Finder & other apps.
    static func pasteboardItem(for item: Item, library: Library) -> NSPasteboardItem {
        let pb = NSPasteboardItem()
        pb.setString(item.id.uuidString, forType: .wunderkammerItem)
        pb.setString(library.originalURL(item).absoluteString, forType: .fileURL)
        return pb
    }

    static func ids(from pasteboard: NSPasteboard) -> [UUID] {
        (pasteboard.pasteboardItems ?? []).compactMap {
            $0.string(forType: .wunderkammerItem).flatMap(UUID.init(uuidString:))
        }
    }
}

/// NSMenuItem that runs a closure, so menus don't need a target object.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, _ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
