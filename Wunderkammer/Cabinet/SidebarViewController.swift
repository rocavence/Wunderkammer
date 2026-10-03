import AppKit

/// Source list: All Images, then the boards. Images (ours or files) dropped
/// on a board are added to it. Double-click a board to rename it.
@MainActor
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let library: Library
    private let table = NSTableView()
    var onSelect: ((UUID?) -> Void)?

    /// Row model: 0 = All Images, 1 = "Boards" header, then boards.
    private enum Row { case all, header, board(Board) }
    private var rows: [Row] = []
    private(set) var selectedBoard: UUID?

    init(library: Library) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .default
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.registerForDraggedTypes([.wunderkammerItem, .fileURL, .png, .tiff])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.menu = NSMenu()
        table.menu?.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let add = NSButton(image: Icon.image(.plus),
                           target: self, action: #selector(newBoard(_:)))
        add.isBordered = false
        add.toolTip = "新增 board"

        let container = NSView()
        for v in [scroll, add] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -6),
            add.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            add.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        view = container

        NotificationCenter.default.addObserver(forName: Library.didChange, object: library, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    private func reload() {
        rows = [.all, .header] + library.collections.map { .board($0) }
        table.reloadData()
        if let selectedBoard, library.collection(selectedBoard) == nil {
            select(board: nil)
        } else {
            selectRow(for: selectedBoard)
        }
    }

    func select(board: UUID?) {
        selectedBoard = board.flatMap { library.collection($0) == nil ? nil : $0 }
        selectRow(for: selectedBoard)
        onSelect?(selectedBoard)
    }

    private func selectRow(for board: UUID?) {
        let row = rows.firstIndex {
            switch $0 {
            case .all: return board == nil
            case .board(let b): return b.id == board
            case .header: return false
            }
        } ?? 0
        if table.selectedRow != row { table.selectRowIndexes([row], byExtendingSelection: false) }
    }

    private func board(at row: Int) -> Board? {
        guard rows.indices.contains(row), case .board(let b) = rows[row] else { return nil }
        return b
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header:
            let label = NSTextField(labelWithString: "Boards")
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case .all:
            return cell(title: "全部圖片", symbol: .cabinet, count: library.items.count, editable: false)
        case .board(let b):
            let cell = cell(title: b.name, symbol: .layers, count: b.itemIDs.count, editable: true)
            cell.textField?.delegate = self
            cell.textField?.tag = row
            return cell
        }
    }

    private func cell(title: String, symbol: Reicon, count: Int, editable: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        let icon = NSImageView(image: Icon.image(symbol))
        let text = NSTextField(labelWithString: title)
        text.lineBreakMode = .byTruncatingTail
        text.isEditable = false
        let badge = NSTextField(labelWithString: "\(count)")
        badge.textColor = .tertiaryLabelColor
        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        for v in [icon, text, badge] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.imageView = icon
        cell.textField = text
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard rows.indices.contains(row) else { return }
        let board: UUID? = self.board(at: row)?.id
        guard board != selectedBoard else { return }
        selectedBoard = board
        onSelect?(board)
    }

    // MARK: Rename

    @objc private func doubleClicked() {
        startRename(row: table.clickedRow)
    }

    private func startRename(row: Int) {
        guard board(at: row) != nil,
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let field = cell.textField else { return }
        field.isEditable = true
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let b = board(at: field.tag) else { return }
        field.isEditable = false
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == b.name {
            field.stringValue = b.name
        } else {
            library.renameCollection(b.id, to: name)
        }
    }

    @objc func newBoard(_ sender: Any?) {
        let n = library.collections.count + 1
        let b = library.createCollection(named: "Board \(n)")
        select(board: b.id)
        if let row = rows.firstIndex(where: { if case .board(let x) = $0 { return x.id == b.id }; return false }) {
            startRename(row: row)
        }
    }

    // MARK: Drop

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard op == .on, rows.indices.contains(row) else { return [] }
        switch rows[row] {
        case .board: return .copy
        // Our own items are already in All Images; files get imported.
        case .all: return ItemActions.ids(from: info.draggingPasteboard).isEmpty ? .copy : []
        case .header: return []
        }
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        importPasteboard(info.draggingPasteboard, library: library, board: board(at: row)?.id)
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard let b = board(at: row) else {
            menu.addItem(ClosureMenuItem("新增 board") { [weak self] in self?.newBoard(nil) })
            return
        }
        menu.addItem(ClosureMenuItem("重新命名") { [weak self] in self?.startRename(row: row) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("刪除 board「\(b.name)」") { [weak self] in
            self?.library.deleteCollection(b.id)
        })
    }
}
