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
    /// Removing never asks (no modal interruption) and can always be undone
    /// with ⌘Z. In a board it takes items out of the board; in the cabinet it
    /// removes them from Wunderkammer. Referenced files on disk are never touched.
    static func delete(_ ids: [UUID], board: UUID?, library: Library, window: NSWindow?) {
        guard !ids.isEmpty else { return }
        let undo = window?.undoManager
        if let board {
            library.remove(Set(ids), from: board)
            undo?.registerUndo(withTarget: library) { lib in
                MainActor.assumeIsolated { lib.add(ids, to: board) }
            }
            undo?.setActionName(ids.count == 1 ? "從 board 移除" : "從 board 移除 \(ids.count) 件")
            return
        }
        guard let removal = library.delete(Set(ids)) else { return }
        undo?.registerUndo(withTarget: library) { lib in
            MainActor.assumeIsolated { lib.restore(removal) }
        }
        undo?.setActionName(ids.count == 1 ? "移除收藏" : "移除 \(ids.count) 件收藏")
    }

    static func menu(for ids: [UUID], board: UUID?, library: Library, window: NSWindow?,
                     open: @escaping () -> Void, similar: (() -> Void)? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("打開預覽") { open() })
        if let similar, ids.count == 1 {
            menu.addItem(ClosureMenuItem("找相似的") { similar() })
        }

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
            let urls = ids.compactMap(library.item).compactMap(library.originalURL)
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        })
        let items = ids.compactMap(library.item)
        if let page = items.first.flatMap(library.archiveURL), ids.count == 1 {
            menu.addItem(ClosureMenuItem("打開頁面快照") { NSWorkspace.shared.open(page) })
        }
        // Only referenced files whose original is still there can be copied.
        let copyable = items.filter { $0.storedFilename == nil && $0.filePath != nil && library.originalURL($0) != nil }.map(\.id)
        if !copyable.isEmpty {
            menu.addItem(ClosureMenuItem("複製一份到圖庫") { Task { await library.copyIntoLibrary(copyable) } })
        }
        menu.addItem(.separator())
        let title = board == nil ? "移除" : "從 board 移除"
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
        if let file = library.originalURL(item) {
            pb.setString(file.absoluteString, forType: .fileURL)
        } else if let url = item.url {
            pb.setString(url, forType: .URL)
        } else if let text = item.text {
            pb.setString(text, forType: .string)
        }
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
