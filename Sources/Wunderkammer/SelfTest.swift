import AppKit

/// `WK_SELFTEST=<output dir>` runs a scripted walk through every feature
/// against `WK_LIBRARY_ROOT` (a throwaway copy), sending mouse and key events
/// straight to our own window, logging checks and saving window screenshots.
/// Nothing touches the real library, the real mouse, or user defaults.
@MainActor
final class SelfTest {
    static let outputDir = ProcessInfo.processInfo.environment["WK_SELFTEST"].map { URL(fileURLWithPath: $0) }
    static var isEnabled: Bool { outputDir != nil }

    private let window: NSWindow
    private let library: Library
    private let ui: SelfTestUI
    private var failures = 0

    init(window: NSWindow, library: Library, ui: SelfTestUI) {
        self.window = window
        self.library = library
        self.ui = ui
    }

    // MARK: Primitives

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func log(_ s: String) {
        print(s)
        fflush(stdout)
    }

    private func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1 }
        log("\(ok ? "PASS" : "FAIL") \(what)")
    }

    private func shot(_ name: String) {
        guard let dir = Self.outputDir else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", dir.appendingPathComponent("\(name).png").path]
        try? p.run()
        p.waitUntilExit()
    }

    private func mouse(_ type: NSEvent.EventType, _ view: NSView, _ p: NSPoint,
                       flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        let loc = view.convert(p, to: nil)
        guard let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: flags,
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         eventNumber: 0, clickCount: clicks, pressure: 1) else { return }
        window.sendEvent(e)
    }

    private func click(_ view: NSView, _ p: NSPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        for c in 1...clicks {
            mouse(.leftMouseDown, view, p, flags: flags, clicks: c)
            mouse(.leftMouseUp, view, p, flags: flags, clicks: c)
        }
    }

    private func drag(_ view: NSView, from a: NSPoint, to b: NSPoint, steps: Int = 20,
                      flags: NSEvent.ModifierFlags = []) async {
        mouse(.leftMouseDown, view, a, flags: flags)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            mouse(.leftMouseDragged, view, NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), flags: flags)
            await wait(0.016)
        }
        await wait(0.1)
        mouse(.leftMouseUp, view, b, flags: flags)
    }

    private func key(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: code) else { continue }
            window.sendEvent(e)
        }
    }

    /// Center of an item's tile, in the given view's coordinates.
    private func center(of id: UUID, in surface: ItemSurface & NSView) -> NSPoint? {
        guard let r = surface.rectInWindow(for: id) else { return nil }
        let local = surface.convert(r, from: nil)
        return NSPoint(x: local.midX, y: local.midY)
    }

    // MARK: Script

    func run() async {
        await wait(1.5)
        log("window key: \(window.isKeyWindow)")
        if ProcessInfo.processInfo.environment["WK_SELFTEST_ONLY"] == "infinity-close" {
            await infinityCloseCheck()
            return finish()
        }
        let all = library.items
        check(all.count >= 8, "library has test images (\(all.count))")
        guard all.count >= 8 else { return finish() }

        // 1. Grid: click, shift-click, cmd-click.
        ui.setMode(.grid)
        await wait(0.6)
        let grid: GridView = ui.grid
        shot("01-grid")
        click(grid, center(of: all[0].id, in: grid)!)
        click(grid, center(of: all[2].id, in: grid)!, flags: .shift)
        click(grid, center(of: all[5].id, in: grid)!, flags: .command)
        await wait(0.3)
        check(grid.selection.ids == Set([0, 1, 2, 5].map { all[$0].id }), "grid click/shift/cmd selection = 4")
        shot("02-grid-multiselect")

        // 2. Zoom smoothness: the spot under the cursor must stay put while
        // pinching and through the reflow animation afterwards.
        await zoomCheck(grid, item: all[6].id, factors: Array(repeating: 0.97, count: 30), label: "pinch out")
        shot("02b-grid-zoomed-out")
        await zoomCheck(grid, item: all[6].id, factors: Array(repeating: 1.04, count: 30), label: "pinch in")
        shot("02c-grid-zoomed-in")

        // Ripple: opening pushes neighbours away, closing springs them back.
        await rippleCheck(grid, item: all[7].id)

        // 3. Select all.
        grid.selectAll(nil)
        await wait(0.2)
        check(grid.selection.ids.count == all.count, "select all")

        // 4. Boards: create one with 6 images, show it, remove one with Delete.
        let board = library.createCollection(named: "測試 board", with: all.prefix(6).map(\.id))
        ui.sidebar.select(board: board.id)
        await wait(0.6)
        check(grid.shownItems.count == 6, "board shows its 6 images")
        shot("04-board")
        // Marquee: from empty space right of the last tile, sweep left over the last row.
        let last = grid.frames.last!
        await drag(grid, from: NSPoint(x: min(last.maxX + 60, grid.bounds.width - 40), y: last.maxY + 20),
                   to: NSPoint(x: last.minX + 5, y: last.midY))
        await wait(0.2)
        check(grid.selection.ids.contains(grid.shownItems.last!.id) && grid.selection.ids.count >= 1,
              "marquee selects the last row (\(grid.selection.ids.count))")
        shot("04b-board-marquee")

        // Dropping images on a board in the sidebar (same pasteboard path as a drag).
        let other = library.createCollection(named: "第二個 board")
        let pb = NSPasteboard(name: .init("wk-selftest-\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects(all.suffix(3).map { ItemActions.pasteboardItem(for: $0, library: library) })
        check(importPasteboard(pb, library: library, board: other.id), "board accepts dropped images")
        check(library.collection(other.id)?.itemIDs.count == 3, "dropped images are in the board")
        pb.releaseGlobally()
        ui.sidebar.select(board: board.id)
        await wait(0.4)

        click(grid, center(of: all[1].id, in: grid)!)
        key(51)
        await wait(0.6)
        check(library.collection(board.id)?.itemIDs.count == 5, "Delete in a board removes from the board")
        check(library.item(all[1].id) != nil, "…but keeps the image in the library")
        shot("05-board-after-remove")

        // 5. Canvas on the board: drag two images out into a new pile.
        ui.setMode(.canvas)
        await wait(0.8)
        let canvas: CanvasView = ui.canvas
        shot("06-canvas")
        let ids = library.collection(board.id)!.itemIDs
        check(library.canvasGroups(for: board.id).count == 1, "canvas starts as one pile")
        click(canvas, center(of: ids[0], in: canvas)!)
        click(canvas, center(of: ids[3], in: canvas)!, flags: .command)
        let start = center(of: ids[0], in: canvas)!
        let target = NSPoint(x: canvas.bounds.width - 120, y: canvas.bounds.height - 120)
        // Drag in two halves to grab a mid-drag frame.
        mouse(.leftMouseDown, canvas, start)
        for i in 1...12 {
            let t = CGFloat(i) / 24
            mouse(.leftMouseDragged, canvas, NSPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t))
            await wait(0.016)
        }
        await wait(0.15)
        shot("07-canvas-dragging")
        for i in 13...24 {
            let t = CGFloat(i) / 24
            mouse(.leftMouseDragged, canvas, NSPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t))
            await wait(0.016)
        }
        mouse(.leftMouseUp, canvas, target)
        await wait(0.6)
        var groups = library.canvasGroups(for: board.id)
        check(groups.count == 2, "drag out makes a second pile (\(groups.count))")
        check(groups.contains { Set($0.itemIDs) == Set([ids[0], ids[3]]) }, "new pile holds the two dragged images")
        shot("08-canvas-dropped")

        // 6. Drag one more image onto the new pile: joins it, no third pile.
        let newPile = groups.first { $0.itemIDs.contains(ids[0]) }!
        canvas.fit()
        await wait(0.3)
        if let from = center(of: ids[1], in: canvas), let onto = center(of: newPile.itemIDs[0], in: canvas) {
            click(canvas, from)
            await drag(canvas, from: from, to: onto)
            await wait(0.6)
            groups = library.canvasGroups(for: board.id)
            check(groups.count == 2, "dropping on a pile joins it (\(groups.count) piles)")
            check(groups.contains { $0.itemIDs.contains(ids[1]) && $0.itemIDs.contains(ids[0]) }, "joined pile has 3 images")
            check(!overlapping(board: board.id), "piles don't overlap after drop")
            shot("09-canvas-joined")
        }

        // 7. Arrange.
        ui.canvas.arrange(nil)
        await wait(0.7)
        check(!overlapping(board: board.id), "arrange leaves no overlap")
        shot("10-canvas-arranged")

        // 8. Infinity on All Images: drifts by itself; click opens preview.
        ui.sidebar.select(board: nil)
        ui.setMode(.infinity)
        await wait(0.5)
        shot("11-infinity")
        let infinity: InfinityView = ui.infinity
        let before = infinity.debugOffset
        await wait(4)
        check(infinity.debugOffset != before, "infinity drifts when idle")
        shot("12-infinity-drifted")
        // Click the middle of a tile near the center (the gaps between tiles do nothing).
        let clickTarget = infinity.shownItems.compactMap { item -> NSPoint? in
            guard let r = infinity.rectInWindow(for: item.id) else { return nil }
            let local = infinity.convert(r, from: nil)
            return infinity.bounds.insetBy(dx: 100, dy: 100).contains(local) ? NSPoint(x: local.midX, y: local.midY) : nil
        }.first ?? NSPoint(x: infinity.bounds.midX, y: infinity.bounds.midY)
        click(infinity, clickTarget)
        await wait(0.6)
        check(ui.preview.isOpen, "click in infinity opens preview")
        shot("13-infinity-preview")
        key(53)
        await wait(0.6)
        check(!ui.preview.isOpen, "esc closes preview")

        // 9. Delete for real (All Images, confirmed) and watch the grid close the gap.
        ui.setMode(.grid)
        await wait(0.4)
        let victim = all[3]
        library.delete([victim.id])
        await wait(0.6)
        check(library.item(victim.id) == nil && grid.shownItems.count == all.count - 1, "delete removes from library and grid")
        check(!FileManager.default.fileExists(atPath: library.originalURL(victim).path), "original moved out of the library")
        check(library.collection(board.id)?.itemIDs.contains(victim.id) == false, "deleted image leaves its boards")
        shot("14-grid-after-delete")

        // 10. Persistence: a fresh Library on the same root sees the same state.
        let reread = Library(root: library.root)
        check(reread.items.count == library.items.count, "items persist")
        check(reread.collections.map(\.name) == library.collections.map(\.name), "boards persist")
        check(reread.canvasGroups(for: board.id).count == library.canvasGroups(for: board.id).count, "canvas piles persist")

        finish()
    }

    /// Pinches around the center of `item`'s tile, sampling where that point
    /// is on screen every frame of the gesture and of the reflow animation.
    private func zoomCheck(_ grid: GridView, item: UUID, factors: [CGFloat], label: String) async {
        guard let clip = grid.superview, let start = center(of: item, in: grid),
              let tile = grid.pool.tiles[item.uuidString] else { return log("SKIP \(label)") }
        let f0 = tile.frame
        let u = CGPoint(x: (start.x - f0.minX) / f0.width, y: (start.y - f0.minY) / f0.height)
        let screen0 = CGPoint(x: start.x - clip.bounds.minX, y: start.y - clip.bounds.minY)
        var worst: CGFloat = 0
        func position() -> CGPoint? {
            // Presentation values only update when the transaction is committed.
            CATransaction.flush()
            guard let t = grid.pool.tiles[item.uuidString] else { return nil }
            let f = (t.presentation() ?? t).frame
            return CGPoint(x: f.minX + u.x * f.width - clip.bounds.minX, y: f.minY + u.y * f.height - clip.bounds.minY)
        }
        for k in factors {
            grid.liveZoom(by: k, around: start)
            if let p = position() { worst = max(worst, hypot(p.x - screen0.x, p.y - screen0.y)) }
            await wait(0.016)
        }
        let beforeCommit = position()
        grid.commitLiveZoom()
        let afterCommit = position()
        // Then the reflow animation: it should move in steps, never teleport.
        var last = afterCommit, biggestStep: CGFloat = 0, frames = 0
        for _ in 0..<30 {
            await wait(0.016)
            guard let p = position() else { continue }
            if let l = last { biggestStep = max(biggestStep, hypot(p.x - l.x, p.y - l.y)) }
            if let l = last, hypot(p.x - l.x, p.y - l.y) > 0.5 { frames += 1 }
            last = p
        }
        check(worst < 1, "\(label): point under cursor fixed while pinching (max drift \(String(format: "%.1f", worst))pt)")
        if let b = beforeCommit, let a = afterCommit {
            let jump = hypot(a.x - b.x, a.y - b.y)
            check(jump < 1, "\(label): no jump when the fingers lift (\(String(format: "%.1f", jump))pt)")
        }
        check(frames >= 4, "\(label): reflow animates over \(frames) frames, biggest step \(String(format: "%.0f", biggestStep))pt")
    }

    private func rippleCheck(_ grid: GridView, item: UUID) async {
        let homes = grid.pool.tiles.mapValues(\.frame)
        func displacement() -> CGFloat {
            CATransaction.flush()
            return homes.compactMap { k, home -> CGFloat? in
                guard k != item.uuidString, let t = grid.pool.tiles[k] else { return nil }
                let f = (t.presentation() ?? t).frame
                return hypot(f.midX - home.midX, f.midY - home.midY)
            }.max() ?? 0
        }
        grid.onOpen?(item)
        await wait(0.12)
        shot("02d-ripple-opening")
        await wait(0.5)
        let pushed = displacement()
        check(ui.preview.isOpen && pushed > 100, "open pushes neighbours away (\(Int(pushed))pt)")
        ui.preview.close()
        // The neighbours come back in place; when the image lands they get a
        // small nudge outward and spring back.
        var biggest: CGFloat = 0
        for i in 0..<45 {
            await wait(0.016)
            biggest = max(biggest, displacement())
            if i == 16 { shot("02e-ripple-closing") }
        }
        check(biggest > 3 && biggest < 80, "closing nudges neighbours slightly (max \(Int(biggest))pt)")
        await wait(0.8)
        let settled = displacement()
        let allVisible = grid.pool.tiles.values.allSatisfy { $0.opacity == 1 }
        check(settled < 0.5 && allVisible && !ui.preview.isOpen,
              "after closing every tile is home and visible (\(String(format: "%.1f", settled))pt)")
        shot("02f-ripple-closed")
    }

    /// Clicking the empty area around an open preview must close it, not
    /// reach the Infinity wall underneath and open another image.
    private func infinityCloseCheck() async {
        ui.setMode(.infinity)
        await wait(0.8)
        let infinity: InfinityView = ui.infinity
        guard let first = infinity.shownItems.first(where: { item in
            infinity.rectInWindow(for: item.id).map { infinity.bounds.insetBy(dx: 100, dy: 100).contains(infinity.convert($0, from: nil)) } ?? false
        }), let r = infinity.rectInWindow(for: first.id) else { return log("SKIP no tile") }
        let local = infinity.convert(r, from: nil)
        click(infinity, NSPoint(x: local.midX, y: local.midY))
        await wait(0.8)
        check(ui.preview.isOpen, "click opens preview")
        let opened = ui.preview.currentID
        // A corner of the window, outside the enlarged image.
        let corner = NSPoint(x: infinity.bounds.maxX - 30, y: infinity.bounds.maxY - 30)
        click(infinity, corner)
        await wait(0.2)
        check(ui.preview.isClosing || !ui.preview.isOpen, "click on empty area starts closing")
        await wait(1.0)
        check(!ui.preview.isOpen, "preview closed (opened \(String(describing: opened?.uuidString.prefix(8))), now \(String(describing: ui.preview.currentID?.uuidString.prefix(8))))")
        shot("infinity-after-blank-click")
    }

    private func overlapping(board: UUID?) -> Bool {
        let frames = ui.canvas.debugGroupFrames
        for (i, a) in frames.enumerated() {
            for b in frames.dropFirst(i + 1) where a.insetBy(dx: -1, dy: -1).intersects(b) { return true }
        }
        return false
    }

    private func finish() {
        log(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

/// The pieces of the app the self-test drives.
@MainActor
protocol SelfTestUI: AnyObject {
    var grid: GridView! { get }
    var canvas: CanvasView! { get }
    var infinity: InfinityView! { get }
    var preview: PreviewView! { get }
    var sidebar: SidebarViewController! { get }
    func setMode(_ mode: ViewMode)
}
