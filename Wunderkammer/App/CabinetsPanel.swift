import AppKit

/// The 珍奇室 on this Mac, as a sheet: switch to one, add one, rename or
/// remove one. Opened from the button beside the sidebar's first row.
@MainActor
final class CabinetsPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onSwitch: ((UUID) -> Void)?
    /// A name was added, changed or removed.
    var onChange: (() -> Void)?

    private let cabinets: Cabinets
    private let count: (Cabinets.Entry) -> Int
    private let sheet: NSWindow
    private let table = NSTableView()
    private let switchButton = NSButton(title: "切換", target: nil, action: nil)
    private let renameButton = NSButton(title: "重新命名…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "刪除…", target: nil, action: nil)

    init(cabinets: Cabinets, count: @escaping (Cabinets.Entry) -> Int) {
        self.cabinets = cabinets
        self.count = count
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        build()
    }

    func present(on window: NSWindow) {
        table.reloadData()
        selectRow(cabinets.currentID)
        window.beginSheet(sheet)
    }

    private var selected: Cabinets.Entry? {
        cabinets.entries.indices.contains(table.selectedRow) ? cabinets.entries[table.selectedRow] : nil
    }

    private func build() {
        let title = NSTextField(labelWithString: "珍奇室")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let note = NSTextField(labelWithString: "每個珍奇室都有自己的收藏。雙擊就能切換。")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor

        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.headerView = nil
        table.rowHeight = 30
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(switchTo)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let add = NSButton(title: "新增…", target: self, action: #selector(add))
        renameButton.target = self
        renameButton.action = #selector(rename)
        deleteButton.target = self
        deleteButton.action = #selector(delete)
        let done = NSButton(title: "完成", target: self, action: #selector(close))
        done.keyEquivalent = "\u{1b}"
        switchButton.target = self
        switchButton.action = #selector(switchTo)
        switchButton.keyEquivalent = "\r"
        for b in [add, renameButton, deleteButton, done, switchButton] { b.bezelStyle = .rounded }

        let left = NSStackView(views: [add, renameButton, deleteButton])
        left.spacing = 8
        let right = NSStackView(views: [done, switchButton])
        right.spacing = 8
        let buttons = NSStackView()
        buttons.addView(left, in: .leading)
        buttons.addView(right, in: .trailing)

        let stack = NSStackView(views: [title, note, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(4, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(equalToConstant: 170),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        sheet.contentView = content
    }

    private func selectRow(_ id: UUID) {
        if let i = cabinets.entries.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        updateButtons()
    }

    private func updateButtons() {
        let s = selected
        switchButton.isEnabled = s != nil && s?.id != cabinets.currentID
        renameButton.isEnabled = s != nil
        deleteButton.isEnabled = s.map { cabinets.canDelete($0.id) } ?? false
        deleteButton.toolTip = s?.folder.isEmpty == true ? "原本的珍奇室不能刪除"
            : s?.id == cabinets.currentID ? "先切換到別的珍奇室，才能刪除這一個" : nil
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { cabinets.entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = cabinets.entries[row]
        let name = NSTextField(labelWithString: e.name)
        name.font = .systemFont(ofSize: 13, weight: e.id == cabinets.currentID ? .semibold : .regular)
        name.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: "\(count(e)) 件" + (e.id == cabinets.currentID ? " · 目前" : ""))
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let cell = NSTableCellView()
        for v in [name, detail] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            detail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // MARK: Actions

    @objc private func switchTo() {
        guard let s = selected, s.id != cabinets.currentID else { return }
        close()
        onSwitch?(s.id)
    }

    @objc private func add() {
        guard let name = ItemActions.promptName(title: "新的珍奇室", initial: "未命名珍奇室", window: nil) else { return }
        let entry = cabinets.create(named: name)
        table.reloadData()
        selectRow(entry.id)
        onChange?()
    }

    @objc private func rename() {
        guard let s = selected,
              let name = ItemActions.promptName(title: "重新命名珍奇室", initial: s.name, window: nil) else { return }
        cabinets.rename(s.id, to: name)
        table.reloadData()
        selectRow(s.id)
        onChange?()
    }

    @objc private func delete() {
        guard let s = selected, cabinets.canDelete(s.id) else { return }
        let alert = NSAlert()
        alert.messageText = "刪除「\(s.name)」？"
        alert.informativeText = "裡面的 \(count(s)) 件收藏會一起移到垃圾桶，清空垃圾桶前都還能找回來。"
        alert.addButton(withTitle: "刪除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        cabinets.delete(s.id)
        table.reloadData()
        selectRow(cabinets.currentID)
        onChange?()
    }

    @objc private func close() {
        sheet.sheetParent?.endSheet(sheet)
    }

    // Tests drive the sheet the way a click would.
    var isShown: Bool { sheet.isVisible }
    func closeForTest() { close() }
}
