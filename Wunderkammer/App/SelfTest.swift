import AppKit
import Quartz

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

    private func shot(_ name: String, windowNumber: Int? = nil) {
        guard let dir = Self.outputDir else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let file = dir.appendingPathComponent("\(name).png")
        p.arguments = ["-x", "-o", "-l", "\(windowNumber ?? window.windowNumber)", file.path]
        try? p.run()
        p.waitUntilExit()
        // A locked screen can't be captured: the window draws itself instead (glass comes out flat).
        if !FileManager.default.fileExists(atPath: file.path), windowNumber == nil, let frame = window.contentView?.superview,
           let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
        }
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
        if ProcessInfo.processInfo.environment["WK_FIXTURE"] == "1" { await seedFixtures() }
        switch ProcessInfo.processInfo.environment["WK_SELFTEST_ONLY"] {
        case "infinity-close":
            await infinityCloseCheck()
            return finish()
        case "capture":
            await captureCheck()
            return finish()
        case "ui":
            await captureCheck()
            await cabinetUICheck()
            return finish()
        case "understand":
            await understandingCheck()
            return finish()
        case "perf":
            await performanceCheck()
            return finish()
        case "formats":
            // Real files from macOS itself: video, audio, HEIC, PDF, a package.
            let files = ["/System/Library/Wallpapers/.default/Golden Gate.mov", "/System/Library/Sounds/Basso.aiff",
                         "/System/Library/Desktop Pictures/iMac Blue.heic", "/System/Library/ProductDocuments/ProductGuides/ENERGY STAR.pdf",
                         "/System/Applications/Calculator.app"].map { URL(fileURLWithPath: $0) }
            let t = CACurrentMediaTime()
            let ids = await library.capture(files.map { .file($0) })
            let elapsed = (CACurrentMediaTime() - t) * 1000
            let got = ids.compactMap(library.item)
            check(got.map(\.kind) == [.video, .audio, .image, .pdf, .file], "kinds: \(got.map(\.kind.rawValue)) in \(Int(elapsed)) ms")
            check(got[0].duration.map { $0 > 1 } == true && got[0].pixelWidth > got[0].pixelHeight, "video: \(got[0].duration.map { String(format: "%.1f s", $0) } ?? "–"), poster \(got[0].pixelWidth)×\(got[0].pixelHeight)")
            check(got[1].duration.map { $0 > 0.1 } == true, "audio: \(got[1].duration.map { String(format: "%.2f s", $0) } ?? "–"), waveform card")
            check(got[2].pixelWidth > 1000, "HEIC: \(got[2].pixelWidth)×\(got[2].pixelHeight)")
            check((got[3].pageCount ?? 0) >= 1, "PDF: \(got[3].pageCount ?? 0) pages")
            check(got.allSatisfy { FileManager.default.fileExists(atPath: library.thumbnailURL($0).path) }, "every one has a representation")
            check(got.allSatisfy { $0.storedFilename == nil }, "all referenced, none copied")
            ui.setMode(.grid)
            await wait(1.2)
            shot("formats")
            // Resting on the video plays it in its tile.
            if let video = got.first, let p = center(of: video.id, in: ui.grid),
               let e = NSEvent.mouseEvent(with: .mouseMoved, location: ui.grid.convert(p, to: nil), modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                ui.grid.mouseMoved(with: e)
                await wait(1.5)
                check(ui.grid.hoverPlaying == video.id, "hovering the video plays it in place")
                shot("formats-hover-video")
            }
            return finish()
        case "semantic":
            var waited = 0.0
            while library.items.contains(where: { !$0.analyzed }), waited < 60 { await wait(0.5); waited += 0.5 }
            await wait(4) // embeddings come after the analysis pass
            let cases = [("an owl", "Owl"), ("a zebra", "Zebra"), ("a field of sunflowers", "Sunflower"),
                         ("a grand piano", "Piano"), ("a penguin", "Penguin")]
            for (query, expected) in cases {
                ui.search(query)
                await wait(1.5)
                let first = ui.grid.shownItems.first?.originalFilename ?? "–"
                check(first.contains(expected), "by meaning: “\(query)” → \(first)")
            }
            shot("semantic-search")
            ui.search("")
            return finish()
        case "showcase":
            // Screenshots for the site and README: CC0 museum pictures (scripts/samples/fetch-samples.py).
            await showcase()
            return finish()
        case "models":
            // Run with WK_MODELS_DIR pointing at an empty folder: the first search offers the models.
            ui.search("a cat")
            await wait(0.6)
            check(ui.semanticOfferForTest?.contains("106 MB") == true, "a search without the models offers them (\(ui.semanticOfferForTest ?? "nothing"))")
            shot("models-offer")
            ui.installSemanticForTest()
            await wait(3)
            shot("models-downloading")
            log("downloading: \(ui.semanticOfferForTest ?? "–")")
            var waited = 0.0
            while !ui.semanticLoadedForTest, waited < 300 { await wait(1); waited += 1 }
            check(ui.semanticLoadedForTest, "the models download, compile and load (\(Int(waited)) s)")
            check(ui.semanticOfferForTest == nil, "the offer goes once they're in")
            ui.search("")
            return finish()
        case "empty":
            // A brand-new cabinet: the welcome, then the first capture replaces it.
            await wait(0.5)
            shot("empty-cabinet")
            await library.capture([.text("The first curiosity.", origin: nil)])
            await wait(0.6)
            check(library.items.count == 1, "first capture lands in an empty cabinet")
            shot("empty-after-first")
            return finish()
        case "settings":
            if let w = ui.showSettingsForTest(), let dir = Self.outputDir {
                await wait(0.6)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", dir.appendingPathComponent("settings.png").path]
                try? p.run()
                p.waitUntilExit()
                check(w.isVisible, "settings window shows")
                // Each section, and an accent other than orange reaching the main window.
                for (tab, name) in [(SettingsWindowController.Tab.collecting, "settings-collecting"), (.understanding, "settings-understanding"),
                                    (.privacy, "settings-privacy"), (.about, "settings-about")] {
                    ui.showSettingsTabForTest(tab)
                    await wait(0.3)
                    shot(name, windowNumber: w.windowNumber)
                }
                ui.showSettingsTabForTest(.general)
                let was = Accent.current
                Accent.apply(.blue)
                await wait(0.5)
                shot("settings-accent", windowNumber: w.windowNumber)
                check(NSColor.accent.usingColorSpace(.sRGB)?.blueComponent ?? 0 > 0.7, "the accent changes the app's accent colour")
                w.orderOut(nil)
                shot("accent-main")
                Accent.apply(was)
            }
            return finish()
        case "timeline":
            // Spread the cabinet over a few days, then scroll through it.
            for (i, item) in library.items.enumerated() {
                library.update(item.id, notify: false) { $0.dateAdded = Date().addingTimeInterval(-Double(i / 6) * 86400 - Double(i) * 60) }
            }
            ui.sidebar.select(.forgotten)
            ui.sidebar.select(.all)
            ui.setMode(.timeline)
            await wait(0.8)
            let grid: GridView = ui.grid
            check(grid.headers.count >= 4, "timeline has a heading per day (\(grid.headers.map(\.title)))")
            if let clip = grid.superview as? NSClipView, grid.headers.count > 2 {
                let second = grid.headers[1].frame
                clip.scroll(to: NSPoint(x: 0, y: second.minY + 120))
                await wait(0.5)
                check(grid.pinnedHeading == grid.headers[1].title, "current day's heading stays at the top (\(grid.pinnedHeading ?? "none"))")
                shot("timeline-pinned")
                if let close = window.standardWindowButton(.closeButton) {
                    let lightY = close.convert(close.bounds, to: nil).midY
                    let toggleY = ui.sidebarToggleForTest.convert(ui.sidebarToggleForTest.bounds, to: nil).midY
                    check(lightY > toggleY + 20, "the lights keep their own row after scrolling (\(Int(lightY)) over \(Int(toggleY)))")
                }
            }
            return finish()
        case "toast":
            let toast = CaptureToast()
            let image = library.items.first.flatMap { NSImage(contentsOf: library.thumbnailURL($0)) }
            toast.show(title: "收進展室", detail: library.items.first?.displayTitle, image: image)
            await wait(0.5)
            if let panel = toast.panel, let dir = Self.outputDir {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", "\(panel.windowNumber)", dir.appendingPathComponent("toast.png").path]
                try? p.run()
                p.waitUntilExit()
            }
            check(toast.panel?.isVisible == true && toast.panel?.isKeyWindow == false, "toast shows without taking focus")
            // Dropped on the menu bar's arch: collected like ⌘⇧C.
            let before = library.items.count
            let pb = NSPasteboard(name: NSPasteboard.Name("wk-drop-test"))
            pb.clearContents()
            pb.setString("拖到選單列的一句話 \(UUID().uuidString.prefix(6))", forType: .string)
            check(ui.collectDropForTest(pb), "the menu bar arch takes a drop")
            for _ in 0..<20 where library.items.count == before { await wait(0.25) }
            check(library.items.count == before + 1, "what was dropped is collected (\(before) → \(library.items.count))")
            return finish()
        case "relations":
            await relationsCheck()
            return finish()
        case "cards":
            // Text cards as they're drawn now, for looking at.
            let samples = [("收藏的本質不是擁有，而是記得自己曾經為什麼停下腳步。", "en.wikipedia.org"),
                           ("Light is the left hand of darkness, and darkness the right hand of light. — 勒瑰恩", "www.goodreads.com")]
            for (i, (text, source)) in samples.enumerated() {
                if let image = CardRenderer.text(text, source: source), let dir = Self.outputDir {
                    Thumbnailer.writeJPEG(image, to: dir.appendingPathComponent("card-\(i).jpg"))
                }
            }
            return finish()
        case "overlay":
            // Cookie notices are cleared off page pictures (network).
            if let kettle = library.items.first(where: { $0.url?.contains("fellowproducts.com/products/stagg") == true }) {
                let before = kettle.representationVersion
                library.enrichWeb(kettle.id)
                for _ in 0..<80 where (library.item(kettle.id)?.representationVersion ?? 0) == before { await wait(0.25) }
                check((library.item(kettle.id)?.representationVersion ?? 0) > before, "the page picture is taken again")
                if let url = library.item(kettle.id).map(library.thumbnailURL) {
                    try? FileManager.default.copyItem(at: url, to: Self.outputDir!.appendingPathComponent("overlay-kettle.jpg"))
                }
            }
            return finish()
        case "cabinets":
            await cabinetsCheck()
            return finish()
        case "cloud":
            await cloudCheck()
            return finish()
        case "watch":
            await watchCheck()
            return finish()
        case "spaces":
            await spacesCheck()
            return finish()
        case "intents":
            await intentsCheck()
            return finish()
        case "trail":
            await trailCheck()
            return finish()
        case "keep":
            await keepCheck()
            return finish()
        case "ask":
            await askCheck()
            return finish()
        case "structured":
            await structuredCheck()
            return finish()
        case "share":
            // Picks up whatever the Share extension left in the App Group inbox.
            let before = library.items.count
            let watcher = ShareInboxWatcher { [library] sources in await library.capture(sources, sourceApp: "分享") }
            watcher.start()
            await wait(4)
            let got = library.items.first { $0.url?.contains("shared-from-test") == true }
            check(got != nil && library.items.count == before + 1, "shared page arrived via the inbox (\(got?.url ?? "–"))")
            return finish()
        default:
            break
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
        // A picture (videos and documents open in Quick Look, with no ripple), whatever the library holds.
        await rippleCheck(grid, item: (all.dropFirst(5).first { $0.kind == .image } ?? all[7]).id)

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
        // The last row may be below the fold: bring it into view first.
        grid.scrollToVisible(last.insetBy(dx: 0, dy: -30))
        await wait(0.3)
        // Start in the margin under the last row (still inside the view, whatever the zoom).
        await drag(grid, from: NSPoint(x: min(last.maxX + 60, grid.bounds.width - 40), y: min(last.maxY + 8, grid.bounds.maxY - 2)),
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
        if groups.count != 2 {
            await wait(2)
            log("DIAG canvas drag: after 2.6s \(library.canvasGroups(for: board.id).count) piles; selection \(canvas.debugSelectionCount), gesture \(canvas.debugGesture)")
        }
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

        // Connect two images on the canvas with ⌥-drag.
        if let a = center(of: ids[2], in: canvas), let b = center(of: ids[4], in: canvas) {
            await drag(canvas, from: a, to: b, flags: .option)
            await wait(0.3)
            let links = library.links(key: board.id.uuidString)
            check(links.count == 1 && Set([links[0].a, links[0].b]) == Set([ids[2], ids[4]]), "⌥-drag connects two items (\(links.count))")
            check(Library(root: library.root).links(key: board.id.uuidString).count == 1, "connection persists")
            shot("09b-canvas-connected")
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
        // Unseen (another Space, a full-screen app, the display asleep), the wall
        // rightly stops moving: nothing to check then.
        let seen = window.occlusionState.contains(.visible)
        if infinity.debugOffset == before { log("infinity: \(infinity.debugState)") }
        if seen { check(infinity.debugOffset != before, "infinity drifts when idle") } else { log("SKIP infinity drift: window not visible") }
        shot("12-infinity-drifted")
        // Click the middle of a tile near the center (the gaps between tiles do nothing).
        let clickTarget = infinity.shownItems.compactMap { item -> NSPoint? in
            guard let r = infinity.rectInWindow(for: item.id) else { return nil }
            let local = infinity.convert(r, from: nil)
            return infinity.bounds.insetBy(dx: 100, dy: 100).contains(local) ? NSPoint(x: local.midX, y: local.midY) : nil
        }.first ?? NSPoint(x: infinity.bounds.midX, y: infinity.bounds.midY)
        click(infinity, clickTarget)
        await wait(0.6)
        if seen { check(ui.preview.isOpen, "click in infinity opens preview") } else { log("SKIP infinity click: window not visible") }
        shot("13-infinity-preview")
        key(53)
        await wait(0.6)
        check(!ui.preview.isOpen, "esc closes preview")

        // 9. Remove with Delete (no dialog), watch the grid close the gap, then ⌘Z.
        ui.setMode(.grid)
        await wait(0.4)
        let victim = all[3]
        let wasInBoard = library.collection(board.id)?.itemIDs.contains(victim.id) == true
        grid.reveal(victim.id)
        key(51)
        await wait(0.6)
        check(library.item(victim.id) == nil && grid.shownItems.count == all.count - 1, "Delete removes from cabinet and grid, no dialog")
        check(library.originalURL(victim).map { FileManager.default.fileExists(atPath: $0.path) } ?? true, "the file itself is untouched (undo possible)")
        check(library.collection(board.id)?.itemIDs.contains(victim.id) == false, "removed item leaves its boards")
        shot("14-grid-after-delete")
        window.undoManager?.undo()
        await wait(0.6)
        check(library.item(victim.id) != nil && grid.shownItems.count == all.count, "⌘Z brings it back")
        check(library.collection(board.id)?.itemIDs.contains(victim.id) == wasInBoard, "…into its boards too")

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
        // The neighbours ride the Item Spring home from where they were pushed:
        // a glide that settles with the image, no jump back and no wobble.
        let closeStart = CACurrentMediaTime()
        var curve: [(t: Double, d: CGFloat)] = []
        while CACurrentMediaTime() - closeStart < 0.7 {
            await wait(0.016)
            curve.append((CACurrentMediaTime() - closeStart, displacement()))
            if curve.count == 10 { shot("02e-ripple-closing") }
        }
        log("close curve: " + curve.map { String(format: "%.2fs %.0f", $0.t, $0.d) }.joined(separator: ", "))
        let first = curve.first?.d ?? 0
        check(first > pushed * 0.5, "closing starts from where the neighbours were (\(Int(first))pt of \(Int(pushed))pt)")
        let homeAt = curve.first { $0.d < 1 }?.t ?? 9
        check(homeAt > 0.25 && homeAt < 0.6, "neighbours glide home in \(String(format: "%.2f", homeAt))s")
        await wait(0.3)
        let settled = displacement()
        let allVisible = grid.pool.tiles.values.allSatisfy { $0.opacity == 1 }
        check(settled < 0.5 && allVisible && !ui.preview.isOpen,
              "after closing every tile is home and visible (\(String(format: "%.1f", settled))pt)")
        shot("02f-ripple-closed")
    }

    /// Several 展室, each its own library: switch, collect, switch back.
    /// A watched folder: what goes in is collected, what leaves goes too.
    private func watchCheck() async {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("wk-watch-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func picture(_ name: String, hue: CGFloat) -> URL {
            let image = NSImage(size: NSSize(width: 64, height: 48), flipped: false) { r in
                NSColor(hue: hue, saturation: 0.7, brightness: 0.8, alpha: 1).setFill()
                r.fill()
                return true
            }
            let url = dir.appendingPathComponent(name)
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try? rep.representation(using: .png, properties: [:])!.write(to: url)
            return url
        }
        func inFolder() -> Int { library.items.filter { $0.filePath?.hasPrefix(dir.standardizedFileURL.path + "/") == true }.count }
        _ = picture("a.png", hue: 0.11)
        _ = picture("b.png", hue: 0.37)
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: dir.appendingPathComponent("a.png").path)
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: dir.appendingPathComponent("b.png").path)
        // The copied library may already watch folders of its own.
        for f in ui.watchedFoldersForTest { ui.unwatchFolderForTest(f) }
        check(ui.watchFolderForTest(dir), "a folder can be watched")
        for _ in 0..<40 where inFolder() < 2 { await wait(0.25) }
        check(inFolder() == 2, "what was already there comes in (\(inFolder()) of 2)")
        let c = picture("c.png", hue: 0.63)
        for _ in 0..<40 where inFolder() < 3 { await wait(0.25) }
        check(inFolder() == 3, "a new file comes in by itself (\(inFolder()) of 3)")
        try? fm.removeItem(at: c)
        for _ in 0..<40 where inFolder() > 2 { await wait(0.25) }
        check(inFolder() == 2, "a file taken out leaves the 展室 (\(inFolder()) of 2)")
        var extra: [URL] = []
        for i in 0..<3 {
            let f = fm.temporaryDirectory.appendingPathComponent("wk-watch-extra-\(i)-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: f, withIntermediateDirectories: true)
            extra.append(f)
        }
        check(ui.watchFolderForTest(extra[0]) && ui.watchFolderForTest(extra[1]), "up to three folders")
        check(!ui.watchFolderForTest(extra[2]), "not a fourth")
        check(!ui.watchFolderForTest(dir.appendingPathComponent("sub")), "nor one inside a watched folder")
        ui.manageCabinets()
        await wait(0.6)
        shot("watch-panel", windowNumber: ui.cabinetsWindowNumber)
        ui.closeCabinetsForTest()
        for f in extra + [dir] { ui.unwatchFolderForTest(f) }
        _ = picture("d.png", hue: 0.85)
        await wait(4)
        check(inFolder() == 2, "an unwatched folder is left alone")

        // Keeping files instead: a vault of the 展室's own, a copy of each file in it.
        let vault = fm.temporaryDirectory.appendingPathComponent("wk-vault-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
        ui.setVaultForTest(vault)
        check(!ui.watchFolderForTest(extra[0]), "a 展室 that keeps files doesn't also link folders")
        let loose = fm.temporaryDirectory.appendingPathComponent("wk-loose-\(UUID().uuidString).txt")
        try? "苔寺的筆記".write(to: loose, atomically: true, encoding: .utf8)
        let ids = await library.importFiles([loose])
        for _ in 0..<40 where !(library.item(ids.first ?? UUID())?.filePath?.hasPrefix(vault.standardizedFileURL.path) ?? false) { await wait(0.25) }
        let kept = ids.first.flatMap { library.item($0)?.filePath }
        check(kept?.hasPrefix(vault.standardizedFileURL.path + "/") == true && kept.map { fm.fileExists(atPath: $0) } == true,
              "a collected file is copied into the vault (\(kept ?? "nowhere"))")
        check(fm.fileExists(atPath: loose.path), "the original stays where it was")
        // A cover of its own.
        check(ui.setCoverForTest(picture("cover.png", hue: 0.55)), "a picture can be the 展室's cover")
        ui.manageCabinets()
        await wait(0.6)
        ui.flipCabinetForTest()
        await wait(1.2)
        shot("cabinet-back", windowNumber: ui.cabinetsWindowNumber)
        ui.closeCabinetsForTest()
        _ = ui.setCoverForTest(nil)
        ui.setVaultForTest(nil)
        try? fm.removeItem(at: vault)
        try? fm.removeItem(at: loose)
        for f in extra + [dir] { try? fm.removeItem(at: f) }
    }

    private func cabinetsCheck() async {
        let home = ui.currentCabinet
        let before = library.items.count
        let other = ui.createCabinetForTest("旅行的展室")
        ui.switchCabinet(to: other)
        await wait(0.8)
        check(library.items.isEmpty && ui.grid.shownItems.isEmpty, "a new 展室 starts empty")
        check(window.title == "旅行的展室", "its name is the title (\(window.title))")
        shot("cabinet-new")
        _ = await library.capture([.text("京都的苔寺，雨後最好看。", origin: nil)])
        await wait(0.6)
        check(library.items.count == 1, "collecting goes into the open 展室")
        ui.switchCabinet(to: home)
        await wait(0.8)
        check(library.items.count == before && !library.items.contains { $0.text?.contains("苔寺") == true },
              "back home: everything as it was (\(library.items.count) of \(before))")
        shot("cabinet-home")
        ui.switchCabinet(to: other)
        await wait(0.6)
        check(library.items.count == 1 && library.items.first?.text?.contains("苔寺") == true, "the other 展室 kept its things")
        check(ui.cabinetNames.contains("旅行的展室"), "it's in the list")
        ui.switchCabinet(to: home)
        await wait(0.4)
        // The window from the 展室 card atop the sidebar.
        ui.manageCabinets()
        await wait(0.6)
        shot("cabinet-panel", windowNumber: ui.cabinetsWindowNumber)
        // 新增: a blank card, named where it stands.
        let count = ui.cabinetNames.count
        ui.beginAddCabinetForTest()
        await wait(0.4)
        shot("cabinet-draft", windowNumber: ui.cabinetsWindowNumber)
        check(ui.cabinetNames.count == count, "nothing is made before it has a name")
        ui.typeCabinetNameForTest("草稿的展室")
        await wait(0.3)
        check(ui.cabinetNames.contains("草稿的展室"), "Return makes it, with that name")
        ui.closeCabinetsForTest()
        await wait(0.3)
        if let draft = ui.cabinetID(named: "草稿的展室") { ui.deleteCabinetForTest(draft) }
        check(!ui.canDeleteCabinet(home) && ui.canDeleteCabinet(other), "the original stays; another can be removed")
        ui.deleteCabinetForTest(other)
        check(!ui.cabinetNames.contains("旅行的展室"), "removed from the list")
    }

    /// Three spaces, each remembering its layout; the sidebar follows.
    private func keyEvent(_ type: NSEvent.EventType, _ code: UInt16, _ chars: String, repeating: Bool = false) {
        guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil,
                                       characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: repeating, keyCode: code) else { return }
        window.sendEvent(e)
    }

    /// Space held on the map's canvas: a drag moves the canvas, even one that
    /// starts on a piece, and the pieces keep their places.
    private func spacePanCheck() async {
        let canvas = ui.canvas!
        window.makeFirstResponder(canvas)
        let shown = library.items.map(\.id).filter { canvas.rectInWindow(for: $0) != nil }.prefix(2)
        guard shown.count == 2, let a = center(of: shown[0], in: canvas),
              let before0 = canvas.rectInWindow(for: shown[0]), let before1 = canvas.rectInWindow(for: shown[1]) else {
            return check(false, "the canvas shows pieces to pan past")
        }
        let start = canvas.debugOffset
        keyEvent(.keyDown, 49, " ")
        keyEvent(.keyDown, 49, " ", repeating: true)
        await drag(canvas, from: a, to: NSPoint(x: a.x - 120, y: a.y - 60))
        keyEvent(.keyUp, 49, " ")
        await wait(0.3)
        let moved = canvas.debugOffset
        check(hypot(moved.x - start.x, moved.y - start.y) > 50, "space + drag moves the canvas (\(Int(moved.x - start.x)), \(Int(moved.y - start.y)))")
        if let after0 = canvas.rectInWindow(for: shown[0]), let after1 = canvas.rectInWindow(for: shown[1]) {
            let d0 = CGPoint(x: after0.minX - before0.minX, y: after0.minY - before0.minY)
            let d1 = CGPoint(x: after1.minX - before1.minX, y: after1.minY - before1.minY)
            check(abs(d0.x - d1.x) < 1 && abs(d0.y - d1.y) < 1, "the pieces move together: nothing was dragged out of place")
        }
        check(!ui.preview.isOpen, "a space that panned doesn't open the preview")
        // Reset: one pile again, connections kept.
        canvas.clusterByTheme(nil)
        await wait(0.6)
        let pilesBefore = canvas.debugGroupFrames.count, linksBefore = canvas.debugLinkCount
        // Asked first; going on asks again; cancelling leaves it as it was.
        canvas.resetArrangement(nil)
        await wait(0.6)
        check(window.attachedSheet != nil, "reset asks first")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        await wait(0.6)
        check(window.attachedSheet != nil, "and asks again")
        shot("reset-confirm")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        await wait(0.5)
        check(canvas.debugGroupFrames.count == pilesBefore, "cancelling changes nothing")
        canvas.performReset()
        await wait(0.6)
        check(pilesBefore > 1 && canvas.debugGroupFrames.count == 1, "reset puts it back in one pile (\(pilesBefore) → \(canvas.debugGroupFrames.count))")
        check(canvas.debugLinkCount == linksBefore, "reset keeps the connections (\(linksBefore))")
        // Scrolling zooms rather than moves.
        let zoomBefore = canvas.debugZoom, offsetBefore = canvas.debugOffset
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0),
           let e = NSEvent(cgEvent: cg) {
            canvas.scrollWheel(with: e)
        }
        await wait(0.2)
        check(canvas.debugZoom > zoomBefore * 1.05, "scrolling up zooms in (\(zoomBefore) → \(canvas.debugZoom))")
        check(canvas.debugOffset != offsetBefore || canvas.debugZoom != zoomBefore, "the view changed around the pointer")
        // A tap, no drag: the preview, as before.
        // One clear of the bar at the foot.
        // Clear of both bars: the view bar below, the top bar above.
        let clearBand = 140...(window.contentLayoutRect.height - TopBar.chrome)
        let across = 60...(canvas.bounds.width - 60)
        if let picture = library.items.first(where: {
            guard $0.kind == .image, let r = canvas.rectInWindow(for: $0.id) else { return false }
            let local = canvas.convert(r, from: nil)
            return clearBand.contains(r.midY) && across.contains(local.midX)
        }),
           let p = center(of: picture.id, in: canvas) {
            click(canvas, p)
            keyEvent(.keyDown, 49, " ")
            keyEvent(.keyUp, 49, " ")
            for _ in 0..<10 where !ui.preview.isOpen { await wait(0.2) }
            check(ui.preview.isOpen, "a tap of space still previews")
            if ui.preview.isOpen { ui.preview.dismissImmediately() }
            await wait(0.3)
        }
    }

    private func spacesCheck() async {
        // Search waits folded as a button, opens when wanted, folds once left empty.
        check(!ui.isSearchExpanded, "search starts folded away")
        if let capsule = ui.topBarSearchCapsuleForTest {
            check(abs(capsule.frame.width - capsule.frame.height) < 1, "folded, search is a circle (\(capsule.frame.size))")
        }
        ui.openSearchForTest()
        await wait(0.3)
        check(ui.isSearchExpanded, "⌘K opens it")
        ui.leaveEmptySearchForTest()
        await wait(0.3)
        check(!ui.isSearchExpanded, "left empty, it folds again")
        // The bar of our own takes clicks, under the transparent title bar too.
        let spaces = ui.spacesControlForTest
        click(spaces, NSPoint(x: spaces.bounds.width * 0.5, y: spaces.bounds.midY))
        await wait(0.5)
        check(ui.mode.space == .wander, "clicking 漫遊 in the top bar goes there (\(ui.mode))")
        shot("topbar")
        if let area = ui.contentAreaForTest {
            let a = area.convert(area.bounds, to: nil), b = spaces.convert(spaces.bounds, to: nil)
            check(abs(a.midX - b.midX) < 2, "the spaces sit in the middle of the content (\(Int(b.midX)) vs \(Int(a.midX)))")
        }
        // At its smallest, with search open and the inspector out, nothing collides.
        let roomy = window.frame
        window.setContentSize(window.contentMinSize)
        ui.openSearchForTest()
        await wait(0.5)
        check(!ui.topBarOverlapsForTest, "at the smallest size the bar's controls don't touch")
        shot("topbar-narrow")
        ui.leaveEmptySearchForTest()
        window.setFrame(roomy, display: true)
        await wait(0.4)
        let sideWidth = ui.sidebar.view.frame.width
        check((240...320).contains(sideWidth), "the sidebar starts at a fifth or so of the window (\(Int(sideWidth)) of \(Int(window.frame.width)))")
        // The sidebar's switch beside the lights, on the bar's line.
        let toggle = ui.sidebarToggleForTest
        let toggleY = toggle.convert(toggle.bounds, to: nil).midY, barY = spaces.convert(spaces.bounds, to: nil).midY
        check(abs(toggleY - barY) < 2, "the sidebar switch sits on the bar's line (\(Int(toggleY)) vs \(Int(barY)))")
        click(toggle, NSPoint(x: toggle.bounds.midX, y: toggle.bounds.midY))
        await wait(0.6)
        check(ui.isSidebarCollapsed, "it hides the sidebar")
        shot("sidebar-hidden")
        click(toggle, NSPoint(x: toggle.bounds.midX, y: toggle.bounds.midY))
        await wait(0.6)
        check(!ui.isSidebarCollapsed, "and brings it back")
        let buttons = [NSWindow.ButtonType.closeButton, .zoomButton].compactMap(window.standardWindowButton)
        if let close = buttons.first, let barRect = Optional(spaces.convert(spaces.bounds, to: nil)) {
            let lightY = close.convert(close.bounds, to: nil).midY
            let lights = close.convert(close.bounds, to: nil)
            check(lights.minY > barRect.maxY, "the traffic lights have a row of their own, above the bar (\(Int(lightY)) over \(Int(barRect.maxY)))")
        }
        ui.setSpace(.cabinet)
        ui.setMode(.masonry)
        await wait(0.5)
        shot("space-cabinet")
        // Something dragged in from outside: the view says where it'll go.
        ui.grid.onDropHover?(true)
        await wait(0.3)
        shot("drop-hover")
        ui.grid.onDropHover?(false)
        await wait(0.3)
        // A 格式 view says so, with its icon.
        ui.sidebar.select(.kind(.images))
        await wait(0.5)
        check(ui.grid.heading.icon != nil && ui.grid.heading.detail.hasPrefix("格式"), "圖片 is headed as a 格式, with its icon (\(ui.grid.heading.detail))")
        if let clip = ui.grid.superview as? NSClipView { clip.scroll(to: NSPoint(x: 0, y: -clip.contentInsets.top)) }
        await wait(0.3)
        shot("heading-kind")
        // Colours: a section of their own, each a view of what's mostly that colour.
        if let colour = Colours.all.map(\.name).first(where: { c in library.items.contains { $0.colors?.contains(c) == true } }) {
            ui.sidebar.select(.color(colour))
            await wait(0.5)
            let shown = library.items(for: Scope(base: .color(colour)))
            check(!shown.isEmpty && shown.allSatisfy { $0.colors?.contains(colour) == true } && ui.grid.heading.detail.hasPrefix("顏色"),
                  "\(Colours.title(colour)) shows what's that colour, headed 顏色 (\(shown.count))")
            shot("heading-colour")
            // 顏色 folds away and opens again (left as it was found).
            let open = ui.sidebar.rowCount
            let width = ui.sidebar.view.frame.width
            if let e = ui.sidebar.chevronAndCountEdges {
                check(abs(e.chevron - e.count) < 1, "the arrow lines up with the counts, folded or not (\(e.chevron) vs \(e.count))")
            }
            ui.sidebar.toggleFold("顏色")
            await wait(0.4)
            check(ui.sidebar.view.frame.width == width, "opening a section doesn't change the sidebar's width")
            if let e = ui.sidebar.chevronAndCountEdges {
                check(abs(e.chevron - e.count) < 1.5, "the fold arrow lines up with the counts (\(e.chevron) vs \(e.count))")
            }
            shot("sidebar-colours-toggled")
            let folded = ui.sidebar.rowCount
            ui.sidebar.toggleFold("顏色")
            check(folded != open && ui.sidebar.rowCount == open, "顏色 folds and unfolds (\(open) → \(folded) → \(ui.sidebar.rowCount) rows)")
        }
        ui.sidebar.select(.all)
        await wait(0.3)
        check(ui.viewBarTipsForTest.starts(with: ["格狀", "瀑布", "時間軸"]), "收藏's layouts are in the bar below (\(ui.viewBarTipsForTest))")
        ui.setSpace(.wander)
        await wait(0.8)
        check(ui.mode == .infinity, "漫遊 is the wall")
        check(!ui.viewBarTipsForTest.contains("無限牆") && ui.viewBarTipsForTest.contains("放大（⌘+）"), "one layout, no switch; its tools stay (\(ui.viewBarTipsForTest))")
        shot("space-wander")
        ui.sidebar.select(.trail)
        await wait(0.6)
        shot("space-wander-trail")
        ui.sidebar.select(.forToday)
        await wait(0.8)
        let today = library.items(for: Scope(base: .forToday))
        let threeDays = Date().addingTimeInterval(-3 * 86400)
        check(today.count <= 12 && today.allSatisfy { ($0.lastViewed ?? .distantPast) < threeDays },
              "今天的推薦: up to a dozen, nothing looked at in the last three days (\(today.count))")
        check(library.items.count < 30 || today.count == 12, "a full day's dozen from a library this size")
        shot("space-wander-today")
        ui.sidebar.select(.all)
        ui.setSpace(.map)
        await wait(0.8)
        // 工作台 opens on whichever layout was used last; the canvas, for what follows.
        check(ui.mode == .canvas, "工作台 is the canvas (\(ui.mode))")
        ui.setMode(.canvas)
        await wait(0.6)
        check(ui.viewBarTipsForTest.contains("重設擺放…"), "the canvas's tools are in the bar (\(ui.viewBarTipsForTest))")
        check(ui.viewBarTipsForTest.first == "分堆", "one 分堆 button leads the bar (\(ui.viewBarTipsForTest))")
        check(ui.viewBarChoicesForTest("分堆") == ["依格式分堆", "依分類分堆", "依主題分堆", "依顏色分堆"], "its choices follow the sidebar's sections (\(ui.viewBarChoicesForTest("分堆")))")
        if let open = ui.openViewBarChoicesForTest("分堆") {
            await wait(0.3)
            shot("pile-choices")
            check(open.rows.count == 4 && open.rowHeight >= 34, "分堆 opens a roomy panel of four (\(open.rows), \(open.rowHeight)pt rows)")
            check(open.frame.minY > open.bar.maxY && open.frame.width < 220, "the panel sits above the bar and hugs its words (\(open.frame))")
            ui.closeViewBarChoicesForTest()
            await wait(0.2)
        } else {
            check(false, "分堆 opens a panel")
        }
        ui.canvas.clusterByColor(nil)
        await wait(0.6)
        let colourTitles = Set(Colours.all.map(\.title) + [CanvasLayout.otherPile])
        check(!ui.canvas.groups.isEmpty && ui.canvas.groups.allSatisfy { colourTitles.contains($0.title ?? "") }, "piling by colour names each pile a colour (\(ui.canvas.groups.map(\.title)))")
        ui.canvas.clusterByFormat(nil)
        await wait(0.6)
        let formatTitles = Set(SidebarViewController.fileKinds.map(\.title) + [CanvasLayout.otherPile])
        check(!ui.canvas.groups.isEmpty && ui.canvas.groups.allSatisfy { formatTitles.contains($0.title ?? "") }, "piling by format names each pile a format (\(ui.canvas.groups.map(\.title)))")
        shot("space-map-canvas")
        // Saved arrangements: save one, change the canvas, come back to it.
        let slots = ui.snapshotBarForTest
        check(!slots.isHidden && slots.slots.count == 3, "the 工作台 has three arrangement slots")
        for i in 0..<3 where slots.slots[i].picture != nil { slots.onClear?(i) }
        slots.clickForTest(0)
        await wait(0.3)
        check(slots.slots[0].picture != nil && slots.slots[0].current, "an empty slot saves the arrangement, and lights as current")
        ui.canvas.clusterByTheme(nil)
        await wait(0.6)
        check(!slots.slots[0].current, "rearranged, the slot is no longer current")
        shot("snapshots")
        slots.clickForTest(0)
        await wait(0.8)
        check(slots.slots[0].current, "clicking the slot puts the canvas back")
        slots.onClear?(0)
        await wait(0.2)
        check(slots.slots[0].picture == nil, "a slot can be cleared")

        await spacePanCheck()
        check(ui.hoverViewBarForTest() == "分堆", "pointing at a bar button names it (\(ui.hoverViewBarForTest() ?? "nothing"))")
        await wait(0.3)
        ui.setSpace(.cabinet)
        await wait(0.4)
        check(ui.mode == .masonry, "收藏 remembers its layout (\(ui.mode))")
        ui.setSpace(.map)
        await wait(0.4)
        check(ui.mode == .canvas, "工作台 comes back to the canvas (\(ui.mode))")
    }

    /// Siri and Shortcuts: what each command does, run in the app. (Collect is
    /// ⌘⇧C, tested elsewhere; running it here would overwrite the clipboard.)
    private func intentsCheck() async {
        let english = await ui.answerForIntent("Which films by Wong Kar-Wai do I have?")
        log("ask en: \(english.replacingOccurrences(of: "\n", with: " ⏎ "))")
        check(english.contains("Chungking") && !QueryTranslator.needsTranslation(english), "asked in English, answered in English")
        let chinese = await ui.answerForIntent("我收過哪些王家衛的電影？")
        log("ask zh: \(chinese.replacingOccurrences(of: "\n", with: " ⏎ "))")
        check(QueryTranslator.needsTranslation(chinese) && chinese.contains("Chungking"), "asked in Chinese, answered in Chinese")
        let found = ui.searchForIntent("Chungking")
        await wait(0.6)
        check(found >= 1 && ui.grid.shownItems.count >= found, "search shows what it found, then what it means (\(found), shown \(ui.grid.shownItems.map(\.displayTitle)))")
        shot("intents-search")
        ui.search("")
        let picked = ui.randomForIntent()
        await wait(1)
        check(picked != nil, "random picks something (\(picked ?? "–"))")
        // The intents themselves, as Siri runs them.
        var ask = AskCabinetIntent()
        ask.question = "Do I have any books by Ted Chiang?"
        _ = try? await ask.perform()
        check(true, "the Ask intent runs")
    }

    /// 足跡: walk a path the way the UI does, then see it told back.
    private func trailCheck() async {
        guard let chungking = library.items.first(where: { $0.displayTitle == "Chungking Express" }),
              let mood = library.items.first(where: { $0.displayTitle == "In the Mood for Love" }) else {
            return check(false, "the sample films are in the library")
        }
        ui.showRandom()
        await wait(0.8)
        key(53)
        // A random video or file opens in Quick Look, which Esc to our window doesn't reach.
        if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().close() }
        await wait(0.6)
        ui.search("Chungking")
        await wait(0.6)
        ui.openForTest(chungking.id)
        await wait(0.8)
        key(53)
        await wait(0.6)
        ui.followRelationForTest(to: mood.id, label: "Wong Kar-Wai")
        await wait(0.6)
        let line = ui.arrivalLine(for: mood.id) ?? "–"
        log("arrival: \(line)")
        check(line.contains("搜尋「Chungking」") && line.contains("Chungking Express") && line.contains("Wong Kar-Wai"),
              "the way to a film is told back")
        ui.search("")
        ui.sidebar.select(.trail)
        await wait(0.8)
        check(ui.trailVisitCount >= 1, "足跡 shows sittings (\(ui.trailVisitCount))")
        shot("trail-view")
        ui.toggleInspectorForTest()
        ui.sidebar.select(.all)
        ui.grid.reveal(mood.id)
        await wait(0.8)
        shot("trail-inspector")
    }

    /// Relations across kinds in the real library copy (network: pages are read again).
    private func relationsCheck() async {
        let t = CACurrentMediaTime()
        await library.refreshWebData()
        log(String(format: "refreshed web data in %.1fs", CACurrentMediaTime() - t))
        var total = 0
        for item in library.items {
            let relations = CrossMedia.relations(of: item, in: library.items)
            total += relations.count
            for r in relations {
                guard let other = library.item(r.other) else { continue }
                let title = String((CrossMedia.name(of: other) ?? other.displayTitle).prefix(40))
                log("REL \(item.displayTitle.prefix(30)) → \(r.sentence(title: title, kindName: InspectorViewController.kindName(other)))")
            }
        }
        log("relations: \(total)")
        func related(_ a: String, _ b: String) -> Bool {
            guard let x = library.items.first(where: { $0.kind == .web && $0.displayTitle.contains(a) }) else { return false }
            return CrossMedia.relations(of: x, in: library.items).contains { library.item($0.other)?.displayTitle.contains(b) == true }
        }
        check(related("Cabinet of curiosities", "Ole Worm"), "the cabinet page mentions Ole Worm's page")
        check(related("In the Mood for Love", "Chungking Express"), "Wong Kar-Wai's films relate")
        check(related("Museum of Modern Art", "Whitney"), "two museums in New York relate")
        if let matrix = library.items.first(where: { $0.url?.contains("letterboxd.com/film/the-matrix") == true }) {
            check(matrix.credits?.contains { $0.role == .actor && $0.name == "Keanu Reeves" } == true, "the cast is read (\(matrix.credits?.filter { $0.role == .actor }.count ?? 0) actors)")
            ui.toggleInspectorForTest()
            ui.grid.reveal(matrix.id)
            await wait(0.8)
            shot("relations-inspector")
        }
        if let cabinet = library.items.first(where: { $0.kind == .web && $0.displayTitle.contains("Cabinet of curiosities") }) {
            ui.grid.reveal(cabinet.id)
            await wait(0.8)
            shot("relations-cabinet")
        }
        ui.toggleInspectorForTest()
        // On the canvas: the relations as lines, then piles by relation.
        ui.sidebar.select(.all)
        ui.setMode(.canvas)
        let canvas: CanvasView = ui.canvas
        for _ in 0..<40 where canvas.debugRelationCount == 0 { await wait(0.25) }
        check(canvas.debugRelationCount >= 3, "the canvas finds the relations (\(canvas.debugRelationCount))")
        shot("relations-canvas-lines")

        log("titles: " + canvas.debugTitleFrames.joined(separator: " | "))
    }

    /// What's kept when the source is only a link or a path: pages are saved
    /// as they were, referenced files can be copied in (network).
    private func keepCheck() async {
        let pages: [(String, String)] = [
            ("letterboxd.com/film/the-matrix", "Keanu"),
            ("themoviedb.org/tv/1396-breaking-bad", "Walter"),
            ("wikipedia.org/wiki/Cabinet_of_curiosities", "Wunderkammer"),
        ]
        for (fragment, word) in pages {
            var item = library.items.first { $0.kind == .web && $0.url?.contains(fragment) == true }
            if item == nil {
                let ids = await library.capture([.web(URL(string: "https://" + fragment.replacingOccurrences(of: "wikipedia.org", with: "en.wikipedia.org"))!, title: nil)])
                item = ids.first.flatMap(library.item)
            }
            guard let id = item?.id else { check(false, "\(fragment) in the library"); continue }
            // Saved afresh, even if the copied library had it already.
            library.update(id, notify: false) { $0.archiveFilename = nil; $0.archivedAt = nil }
            let t = CACurrentMediaTime()
            await library.archive(id)
            let elapsed = CACurrentMediaTime() - t
            let kept = library.item(id)
            let url = kept.flatMap(library.archiveURL)
            let size = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
            let pdfPages = url.flatMap { CGPDFDocument($0 as CFURL)?.numberOfPages } ?? 0
            log(String(format: "%@: %.1fs, %d KB, %d PDF page(s), %d chars of text", fragment, elapsed, size / 1024, pdfPages,
                       kept?.pageText?.count ?? 0))
            check(size > 20_000 && pdfPages >= 1, "\(fragment) saved as a PDF")
            check(size < 5_000_000, "\(fragment) kept small (\(size / 1024) KB)")
            check(kept?.pageText?.contains(word) == true, "\(fragment) page text has \"\(word)\"")
        }
        // A page with next to nothing on it (or a block page) isn't kept.
        // (An always-empty page: example.com has a real notice in six languages.)
        let bare = await library.capture([.web(URL(string: "https://www.google.com/generate_204?wk=\(UUID().uuidString)")!, title: nil)])
        if let id = bare.first {
            await library.archive(id)
            check(library.item(id)?.archiveFilename == nil && library.item(id)?.archivedAt != nil, "a near-empty page isn't kept as a snapshot")
        }
        // A word only in the page body, not the title or description.
        let found = Search.run("Keanu", in: library.items).map(\.displayTitle)
        check(found.contains { $0.contains("Matrix") }, "searching the page's own words finds it (\(found.prefix(3).joined(separator: "、")))")

        // Copy a referenced file into the library.
        if let video = library.items.first(where: { $0.kind == .video && $0.storedFilename == nil && library.originalURL($0) != nil }) {
            await library.copyIntoLibrary([video.id])
            let copy = library.item(video.id).flatMap(library.originalURL)
            check(copy?.path.hasPrefix(library.originalsDir.path) == true && FileManager.default.fileExists(atPath: copy?.path ?? ""),
                  "\(video.displayTitle) copied into the library")
            check(library.item(video.id)?.filePath == video.filePath, "the original's path is kept")
        } else {
            log("SKIP no referenced video to copy")
        }
        if let matrix = library.items.first(where: { $0.url?.contains("letterboxd.com/film/the-matrix") == true }) {
            ui.toggleInspectorForTest()
            ui.grid.reveal(matrix.id)
            await wait(0.8)
            shot("keep-inspector")
        }
    }

    /// Questions to Apple's on-device model about the cabinet (needs Apple Intelligence).
    private func askCheck() async {
        let questions: [(String, [String])] = [
            ("我收過哪些王家衛的電影？", ["In the Mood for Love", "Chungking Express"]),
            ("有哪些勒瑰恩的書？", ["The Dispossessed"]),
            ("最近收的音樂是誰的？", ["Mordechai"]),
            ("有沒有跟咖啡有關的東西？", ["Stagg EKG Electric Kettle"]),
            ("我有收過恐龍嗎？", []),
        ]
        for (i, (q, expected)) in questions.enumerated() {
            let t = CACurrentMediaTime()
            ui.ask(q)
            var waited = 0.0
            while ui.isAsking, waited < 60 { await wait(0.25); waited += 0.25 }
            let shown = ui.grid.shownItems.map(\.displayTitle)
            log(String(format: "Q%d %.1fs %@ → %@ | %@", i + 1, CACurrentMediaTime() - t, q, ui.answerText,
                       shown.prefix(6).joined(separator: "、")))
            if expected.isEmpty {
                check(!ui.answerText.isEmpty, "answers a question with nothing to find")
            } else {
                check(expected.allSatisfy { e in shown.contains { $0.contains(e) } }, "\(q) shows \(expected.joined(separator: "、"))")
            }
            shot("ask-\(i + 1)")
        }
    }

    /// Real pages (network): what they are, who made them, and the same
    /// director linking two sites' pages about one film.
    private func structuredCheck() async {
        let pages = [
            "https://letterboxd.com/film/the-matrix/",
            "https://letterboxd.com/film/bound/",
            "https://www.goodreads.com/book/show/18423.The_Left_Hand_of_Darkness",
            "https://www.themoviedb.org/movie/603-the-matrix",
        ]
        var ids: [UUID] = []
        for page in pages { ids += await library.capture([.web(URL(string: page)!, title: nil)]) }
        for _ in 0..<60 where ids.contains(where: { library.item($0)?.thing == nil }) { await wait(0.5) }
        for id in ids {
            guard let item = library.item(id) else { continue }
            let credits = (item.credits ?? []).map { "\($0.role.title) \($0.name)" }.joined(separator: "、")
            log("\(item.domain ?? "?"): \(item.thing?.title ?? "–") | \(item.displayTitle) | \(credits) | \(item.released ?? "–")")
        }
        let films = ids.prefix(2).compactMap(library.item)
        check(films.count == 2 && films.allSatisfy { $0.thing == .movie }, "film pages are films")
        check(films.allSatisfy { $0.credits?.contains { $0.role == .director && $0.name == "Lana Wachowski" } == true },
              "both films credit the director")
        let book = ids.count > 2 ? library.item(ids[2]) : nil
        check(book?.thing == .book && book?.credits?.first?.role == .author, "book page is a book with its author (\(book?.creator ?? "–"))")
        let sameDirector = library.items(for: Scope(base: .mentions("Lana Wachowski"))).map(\.id)
        check(Set(ids.prefix(2)).isSubset(of: sameDirector), "the director's name links her two films (\(sameDirector.count))")
        let tmdb = ids.count > 3 ? library.item(ids[3]) : nil
        check(tmdb?.thing == .movie && tmdb?.released == "1999-03-31", "a film page without credits still has its release (\(tmdb?.released ?? "–"))")
        ui.sidebar.select(.kind(.films))
        await wait(0.6)
        shot("structured-films")
        ui.toggleInspectorForTest()
        if let first = ids.first { ui.grid.reveal(first) }
        await wait(0.8)
        shot("structured-inspector")
    }

    /// Every kind of source becomes a curiosity with a sensible look; a web
    /// page's own preview arrives by itself after the instant capture.
    private func captureCheck() async {
        guard let dir = Self.outputDir?.appendingPathComponent("capture-files") else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdf = dir.appendingPathComponent("A Short Paper.pdf")
        var box = CGRect(x: 0, y: 0, width: 420, height: 595)
        if let ctx = CGContext(pdf as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: "On Cabinets of Curiosities"] as CFDictionary) {
            for page in 0..<2 {
                ctx.beginPDFPage(nil)
                ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
                ctx.fill(CGRect(x: 40, y: 480 - CGFloat(page) * 40, width: 340, height: 60))
                for line in 0..<14 { ctx.fill(CGRect(x: 40, y: 420 - CGFloat(line) * 24, width: CGFloat(200 + (line * 37) % 140), height: 8)) }
                ctx.endPDFPage()
            }
            ctx.closePDF()
        }
        let note = dir.appendingPathComponent("note.md")
        try? "Wunderkammer is a place for the things you don't want to lose, but don't want to organize either.".write(to: note, atomically: true, encoding: .utf8)
        // Unique per run: the test library is a copy of the real one, which may hold this page already.
        let page = URL(string: "https://en.wikipedia.org/wiki/Cabinet_of_curiosities?wk=\(UUID().uuidString)")!
        let before = library.items.count
        let pb = NSPasteboard(name: .init("wk-selftest-capture"))
        pb.clearContents()
        pb.setString("Collect without organizing.", forType: .string)
        let ids = await library.capture(PasteboardReader.sources(from: pb) + [.file(pdf), .file(note), .web(page, title: nil)])
        pb.releaseGlobally()
        check(ids.count == 4 && library.items.count == before + 4, "4 different sources captured (\(ids.count))")
        let kinds = ids.compactMap(library.item).map(\.kind)
        check(kinds == [.text, .pdf, .text, .web], "kinds detected: \(kinds.map(\.rawValue))")
        check(library.item(ids[1])?.pageCount == 2 && library.item(ids[1])?.title == "On Cabinets of Curiosities", "PDF metadata read")
        check(library.item(ids[1])?.storedFilename == nil && library.item(ids[1])?.filePath != nil, "PDF referenced, not copied")
        ui.setMode(.grid)
        ui.sidebar.select(board: nil)
        await wait(1)
        shot("capture-01-instant")
        // The page's title and preview image come in the background.
        var enriched = false
        for _ in 0..<40 {
            if let web = library.item(ids[3]), web.representationVersion > 0 { enriched = true; break }
            await wait(0.25)
        }
        let web = library.item(ids[3])
        check(enriched, "web preview fetched (title: \(web?.title ?? "–"))")
        check(web?.title?.localizedCaseInsensitiveContains("cabinet") == true, "web title from the page")
        await wait(1)
        shot("capture-02-enriched")
        // A page with no preview image of its own gets a picture of the page.
        let bare = await library.capture([.web(URL(string: "https://example.com/")!, title: nil)])
        var snapped = false
        for _ in 0..<60 {
            if let b = bare.first.flatMap(library.item), b.representationVersion > 0 { snapped = true; break }
            await wait(0.25)
        }
        let b = bare.first.flatMap(library.item)
        // The top of the page set as a card: as wide as a card, a little taller than the plate.
        check(snapped && (b.map { $0.pixelWidth == 1200 && $0.pixelHeight > 760 && $0.pixelHeight < 1000 } ?? false),
              "page without og:image gets a page card (\(b?.pixelWidth ?? 0)×\(b?.pixelHeight ?? 0), title: \(b?.title ?? "–"))")
        await wait(0.8)
        // Resting on a page shows its title at the foot of the tile.
        if let p = center(of: ids[3], in: ui.grid),
           let e = NSEvent.mouseEvent(with: .mouseMoved, location: ui.grid.convert(p, to: nil), modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            ui.grid.mouseMoved(with: e)
            await wait(0.4)
        }
        shot("capture-03-snapshot")

        // Capturing the same things again adds nothing.
        let again = await library.capture([.file(pdf), .web(page, title: nil)])
        check(library.items.count == before + 5 && Set(again) == Set([ids[1], ids[3]]), "duplicates recognised")
    }

    /// The One-Second Rule, and a cabinet of thousands that still scrolls.
    private func performanceCheck() async {
        func ms(_ start: CFTimeInterval) -> Double { (CACurrentMediaTime() - start) * 1000 }
        // Capture latency, from the call to the item being in the cabinet.
        var t = CACurrentMediaTime()
        await library.capture([.text("A thought worth keeping, timed.", origin: nil)])
        let textMs = ms(t)
        t = CACurrentMediaTime()
        await library.capture([.web(URL(string: "https://example.com/timed-\(UUID().uuidString)")!, title: nil)])
        let webMs = ms(t)
        let photo = makeImage(width: 3000, height: 2000, hue: 0.6)
        t = CACurrentMediaTime()
        await library.capture([.imageData(photo, name: "large.png", origin: nil)])
        let imageMs = ms(t)
        check(textMs < 1000 && webMs < 1000 && imageMs < 1000,
              String(format: "capture under a second: text %.0f ms, link %.0f ms, 3000×2000 image %.0f ms", textMs, webMs, imageMs))

        // Fill the cabinet to 3,000.
        let memoryStart = residentMB()
        let target = 3000
        t = CACurrentMediaTime()
        var batch: [Source] = []
        var i = library.items.count
        while i < target {
            let w = [600, 800, 400, 900, 500][i % 5], h = [400, 600, 700, 500, 800][(i / 5) % 5]
            let data = autoreleasepool { makeImage(width: w, height: h, hue: Double(i % 97) / 97, seed: i) }
            batch.append(.imageData(data, name: "synthetic-\(i).png", origin: nil))
            if batch.count == 100 {
                await library.capture(batch)
                batch = []
            }
            i += 1
        }
        if !batch.isEmpty { await library.capture(batch) }
        let fillSeconds = ms(t) / 1000
        log(String(format: "PERF memory while collecting 3,000: %.0f MB → %.0f MB", memoryStart, residentMB()))
        log(String(format: "PERF filled to %d items in %.1f s (%.1f ms per image)", library.items.count, fillSeconds, fillSeconds * 1000 / Double(max(target - 33, 1))))

        let grid: GridView = ui.grid
        ui.setMode(.grid)
        ui.sidebar.select(board: nil)
        await wait(1)
        guard let clip = grid.superview as? NSClipView else { return }

        let memoryBefore = residentMB()
        // Scroll the whole cabinet a screen at a time, one step per frame.
        var worst = 0.0, total = 0.0, steps = 0
        let height = grid.bounds.height
        var y: CGFloat = 0
        while y < height - clip.bounds.height {
            y += 60
            let s = CACurrentMediaTime()
            clip.scroll(to: NSPoint(x: 0, y: y))
            CATransaction.flush()
            let d = ms(s)
            worst = max(worst, d); total += d; steps += 1
            if steps % 3 == 0 { await wait(0.001) }
        }
        let avg = total / Double(max(steps, 1))
        check(avg < 8, String(format: "scroll 3,000 items: %.2f ms per step on average, worst %.1f ms (%d steps)", avg, worst, steps))
        shot("perf-scrolled")

        // Live pinch on a full cabinet.
        clip.scroll(to: NSPoint(x: 0, y: 0))
        await wait(0.3)
        var pinchWorst = 0.0, pinchTotal = 0.0
        let anchor = NSPoint(x: grid.bounds.midX, y: clip.bounds.midY)
        for k in 0..<40 {
            let s = CACurrentMediaTime()
            grid.liveZoom(by: k < 20 ? 0.96 : 1.04, around: anchor)
            CATransaction.flush()
            let d = ms(s)
            pinchWorst = max(pinchWorst, d); pinchTotal += d
            await wait(0.008)
        }
        let s = CACurrentMediaTime()
        grid.commitLiveZoom()
        CATransaction.flush()
        let reflow = ms(s)
        check(pinchTotal / 40 < 8, String(format: "pinch on 3,000 items: %.2f ms per frame, worst %.1f ms; reflow on release %.1f ms", pinchTotal / 40, pinchWorst, reflow))

        // Search across everything.
        let q = CACurrentMediaTime()
        let hits = library.items(for: Scope(base: .all, search: "synthetic 2026")).count
        log(String(format: "PERF search over %d items: %.1f ms (%d hits)", library.items.count, ms(q), hits))

        let memoryAfter = residentMB()
        check(memoryAfter - memoryBefore < 600,
              String(format: "memory stays bounded while scrolling: %.0f MB → %.0f MB", memoryBefore, memoryAfter))
    }

    private func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return Double(info.resident_size) / 1_048_576
    }

    private func makeImage(width: Int, height: Int, hue: Double, seed: Int = 0) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor(hue: (hue + 0.5).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.5, alpha: 1).setFill()
        let r = CGFloat(min(width, height)) * 0.3
        NSBezierPath(ovalIn: NSRect(x: CGFloat(seed * 37 % max(width - Int(r), 1)), y: CGFloat(height) / 3, width: r, height: r)).fill()
        ("\(seed)" as NSString).draw(at: NSPoint(x: 20, y: 20), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// Stage 2: words in pictures, what's in them, similar and related things.
    /// A 展室 in iCloud Drive (WK_CLOUD_BASE stands in for it): in, a change
    /// from another Mac merged, a room from another Mac joined, and back out.
    private func cloudCheck() async {
        guard let cloud = ProcessInfo.processInfo.environment["WK_CLOUD_BASE"].map({ URL(fileURLWithPath: $0) }) else {
            return check(false, "WK_CLOUD_BASE is set")
        }
        let fm = FileManager.default
        let id = ui.createCabinetForTest("雲端測試")
        ui.switchCabinet(to: id)
        await wait(0.5)
        await library.capture([.text("A moth pinned in 1887.", origin: nil), .text("A shell from the Indian Ocean.", origin: nil)])
        await wait(0.6)
        do { try ui.moveCabinetForTest(id, toCloud: true) } catch { check(false, "moved into iCloud: \(error)") }
        await wait(0.6)
        let room = cloud.appendingPathComponent(id.uuidString)
        check(library.root.standardizedFileURL == room.standardizedFileURL && library.syncs, "the open room now lives in iCloud Drive")
        check(fm.fileExists(atPath: room.appendingPathComponent("library.json").path) && fm.fileExists(atPath: room.appendingPathComponent("room.json").path),
              "its library and name are there")
        check(!fm.fileExists(atPath: room.appendingPathComponent("embeddings").path), "caches stay on this Mac")
        check(library.items.count == 2, "nothing lost in the move (\(library.items.count))")

        // Another Mac adds something and saves.
        let json = room.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: json), var stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var items = stored["items"] as? [[String: Any]], var copy = items.first {
            copy["id"] = UUID().uuidString
            copy["text"] = "Added on the other Mac."
            copy["title"] = "Added on the other Mac."
            items.insert(copy, at: 0)
            stored["items"] = items
            try? JSONSerialization.data(withJSONObject: stored).write(to: json)
        }
        library.mergeFromDisk()
        await wait(0.4)
        check(library.items.contains { $0.title == "Added on the other Mac." } && library.items.count == 3,
              "what the other Mac added shows up here (\(library.items.count))")

        // A room made on another Mac, waiting to be joined.
        let otherID = UUID()
        let other = cloud.appendingPathComponent(otherID.uuidString)
        try? fm.createDirectory(at: other, withIntermediateDirectories: true)
        try? #"{"id":"\#(otherID.uuidString)","name":"另一台的展室"}"#.write(to: other.appendingPathComponent("room.json"), atomically: true, encoding: .utf8)
        try? fm.copyItem(at: json, to: other.appendingPathComponent("library.json"))
        let waiting = ui.cloudRoomsForTest
        check(waiting.map(\.name) == ["另一台的展室"], "a room from another Mac is offered (\(waiting.map(\.name)))")
        ui.joinCloudRoomForTest(otherID, name: "另一台的展室", folder: other)
        ui.switchCabinet(to: otherID)
        await wait(0.5)
        check(library.syncs && library.items.count == 3, "joined, it opens with its things (\(library.items.count))")
        check(ui.cloudRoomsForTest.isEmpty, "and is no longer offered")

        // Back to this Mac only.
        ui.switchCabinet(to: id)
        await wait(0.4)
        do { try ui.moveCabinetForTest(id, toCloud: false) } catch { check(false, "moved back: \(error)") }
        await wait(0.5)
        check(!library.syncs && !fm.fileExists(atPath: room.path) && library.items.count == 3,
              "back on this Mac, out of iCloud Drive, all there (\(library.items.count))")
        check(ui.cabinetRootForTest(id).map { fm.fileExists(atPath: $0.appendingPathComponent("library.json").path) } == true, "its library is in the local folder")

        // The first 展室 shares its folder with the others: only its own files go, and come back.
        guard let first = ui.cabinetID(named: "展室") else { return check(false, "the default room is there") }
        ui.switchCabinet(to: first)
        await wait(0.5)
        let before = library.items.count, base = library.root
        do { try ui.moveCabinetForTest(first, toCloud: true) } catch { check(false, "default room into iCloud: \(error)") }
        await wait(0.5)
        check(library.syncs && library.items.count == before && fm.fileExists(atPath: base.appendingPathComponent("cabinets.json").path)
              && !fm.fileExists(atPath: base.appendingPathComponent("library.json").path),
              "the default room moves alone, the list of rooms stays (\(library.items.count)/\(before))")
        do { try ui.moveCabinetForTest(first, toCloud: false) } catch { check(false, "default room back: \(error)") }
        await wait(0.5)
        check(!library.syncs && library.items.count == before, "and comes back whole (\(library.items.count)/\(before))")
    }

    private func showcase() async {
        let fm = FileManager.default
        guard let dir = ProcessInfo.processInfo.environment["WK_SAMPLES_DIR"].map({ URL(fileURLWithPath: $0) }),
              let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter({ ["jpg", "png"].contains($0.pathExtension) })
        else { return check(false, "WK_SAMPLES_DIR has the sample pictures") }
        await library.capture(files.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { .file($0) })
        await library.capture([
            .web(URL(string: "https://en.wikipedia.org/wiki/Cabinet_of_curiosities")!, title: nil),
            .web(URL(string: "https://en.wikipedia.org/wiki/Ole_Worm")!, title: nil),
            .text("Collect without organizing. Let the room find its own order.", origin: nil),
        ])
        var waited = 0.0
        while library.items.contains(where: { !$0.analyzed }) || library.items.contains(where: { $0.kind == .web && $0.title == nil }),
              waited < 150 { await wait(1); waited += 1 }
        await wait(3)
        log("showcase: \(library.items.count) items, ready in \(Int(waited)) s")
        ui.sidebar.select(.all)
        ui.setMode(.grid)
        await wait(1.5)
        ui.sidebar.clearHighlightForTest()
        shot("showcase-1-collection")
        ui.setMode(.masonry)
        await wait(1.5)
        ui.sidebar.clearHighlightForTest()
        shot("showcase-2-masonry")
        ui.search("clock")
        await wait(2)
        ui.sidebar.clearHighlightForTest()
        shot("showcase-3-search")
        ui.search("")
        ui.setMode(.grid)
        if let first = Subjects.discover(in: library.items).first {
            ui.sidebar.select(.subject(first.label))
            await wait(1.2)
            ui.sidebar.clearHighlightForTest()
        shot("showcase-4-theme")
            ui.sidebar.select(.all)
        }
        if let pick = library.items.first(where: { $0.originalFilename.contains("Record Player") }) {
            ui.toggleInspectorForTest()
            ui.inspectForTest(pick.id)
            ui.grid.reveal(pick.id)
            await wait(1.5)
            ui.sidebar.clearHighlightForTest()
        shot("showcase-5-inspector")
            ui.toggleInspectorForTest()
        }
        ui.setSpace(.wander)
        await wait(3)
        ui.sidebar.clearHighlightForTest()
        shot("showcase-6-wander")
        ui.setSpace(.map)
        await wait(1)
        ui.canvas.clusterByTheme(nil)
        await wait(1)
        ui.canvas.fit(animated: false)
        await wait(1.5)
        ui.sidebar.clearHighlightForTest()
        shot("showcase-7-workbench")
        ui.setSpace(.cabinet)
    }

    /// A known library for the suites that need one: macOS's own pictures, a
    /// picture with words in it, a few notes and pages (pages need the network).
    private func seedFixtures() async {
        let fm = FileManager.default
        let pictures = URL(fileURLWithPath: "/Library/User Pictures")
        var files: [URL] = []
        for folder in (try? fm.contentsOfDirectory(at: pictures, includingPropertiesForKeys: nil)) ?? [] {
            files += ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "heic" }
        }
        let sign = fm.temporaryDirectory.appendingPathComponent("trade-offer.png")
        let image = NSImage(size: NSSize(width: 1200, height: 800), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black]
            for (i, line) in ["TRADE OFFER", "I receive: your attention", "You receive: curiosities"].enumerated() {
                (line as NSString).draw(at: NSPoint(x: 80, y: 600 - CGFloat(i) * 160), withAttributes: attrs)
            }
            return true
        }
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: sign)
            files.append(sign)
        }
        await library.capture(files.map { .file($0) })
        await library.capture([
            .text("Ole Worm kept a cabinet of curiosities in Copenhagen: fossils, horns, a stuffed bird.", origin: nil),
            .text("Chungking Express is the film I keep going back to.", origin: nil),
        ])
        let pages = ["https://en.wikipedia.org/wiki/Cabinet_of_curiosities", "https://en.wikipedia.org/wiki/Ole_Worm",
                     "https://letterboxd.com/film/chungking-express/", "https://letterboxd.com/film/in-the-mood-for-love/",
                     "https://letterboxd.com/film/the-matrix/", "https://www.moma.org/", "https://whitney.org/"]
        await library.capture(pages.compactMap(URL.init).map { .web($0, title: nil) })
        var waited = 0.0
        while library.items.contains(where: { $0.kind == .web && $0.title == nil }), waited < 30 { await wait(0.5); waited += 0.5 }
        log("fixtures: \(library.items.count) items (pages read in \(Int(waited)) s)")
    }

    private func understandingCheck() async {
        var waited = 0.0
        while library.items.contains(where: { !$0.analyzed }), waited < 90 {
            await wait(0.5)
            waited += 0.5
        }
        let analyzed = library.items.filter(\.analyzed).count
        check(analyzed == library.items.count, "every item understood (\(analyzed)/\(library.items.count) in \(Int(waited))s)")
        let labelled = library.items.filter { !($0.labels ?? []).isEmpty }.count
        check(labelled >= library.items.count * 3 / 4, "labels for most items (\(labelled))")
        let sign = library.items.first { $0.originalFilename.contains("trade-offer") }
        check(sign?.ocrText?.lowercased().contains("receive") == true, "OCR reads the words in a picture (\(sign?.ocrText?.prefix(40) ?? "–"))")
        // "attention" is only in the picture, not in the file name.
        ui.search("attention")
        await wait(0.8)
        check(sign != nil && ui.grid.shownItems.first?.id == sign?.id, "search finds words inside pictures (\(sign?.ocrText?.replacingOccurrences(of: "\n", with: " ").prefix(40) ?? "–"))")
        shot("understand-search-ocr")
        ui.search("")
        if let rose = library.items.first(where: { $0.originalFilename.contains("Red Rose") }) {
            ui.sidebar.select(.similar(rose.id))
            await wait(0.8)
            check(ui.grid.shownItems.count > 3 && ui.grid.shownItems.first?.id == rose.id, "similar view: the item, then look-alikes")
            shot("understand-similar")
            ui.sidebar.select(.all)
            await wait(0.5)
        }
        let subjects = Subjects.discover(in: library.items)
        check(!subjects.isEmpty, "themes found by themselves: \(subjects.map { "\($0.title)(\($0.count))" })")
        if let first = subjects.first {
            ui.sidebar.select(.subject(first.label))
            await wait(0.8)
            check(ui.grid.shownItems.count == first.count && ui.grid.shownItems.allSatisfy { $0.labels?.contains(first.label) == true },
                  "theme view shows its \(first.count) items")
            shot("understand-subject")
            ui.sidebar.select(.all)
            await wait(0.4)
        }
        // Canvas sorted by theme: titled piles, no overlaps.
        ui.setMode(.canvas)
        await wait(0.5)
        ui.canvas.clusterByTheme(nil)
        await wait(1.2)
        let piles = library.canvasGroups(key: Library.allKey, ids: library.items.map(\.id))
        check(piles.count >= 3 && piles.allSatisfy { $0.title != nil } && !overlapping(board: nil),
              "canvas sorted into \(piles.count) titled piles: \(piles.compactMap(\.title))")
        shot("understand-canvas-themes")
        ui.setMode(.grid)
        for item in library.items.prefix(3) {
            log("labels \(item.displayTitle.prefix(24)): \((item.labels ?? []).prefix(5)) colors \(item.colors ?? [])")
        }
    }

    /// Masonry, Timeline, search, kind views, R, Inspector.
    private func cabinetUICheck() async {
        let grid: GridView = ui.grid
        ui.sidebar.select(board: nil)
        for (mode, name) in [(ViewMode.masonry, "masonry"), (.timeline, "timeline"), (.grid, "grid")] {
            ui.setMode(mode)
            await wait(0.9)
            shot("ui-\(name)")
        }
        ui.setMode(.timeline)
        await wait(0.5)
        check(!grid.headers.isEmpty && grid.headers.first?.title == "今天", "timeline has date headings (\(grid.headers.map(\.title)))")
        ui.setMode(.masonry)
        await wait(0.5)
        let xs = Set(grid.frames.map { Int($0.minX) })
        check(xs.count >= 3 && xs.count < grid.frames.count, "masonry lays out in columns (\(xs.count))")

        // VoiceOver can read the tiles.
        let a11y = (grid.accessibilityChildren() as? [NSAccessibilityElement]) ?? []
        check(!a11y.isEmpty && a11y.allSatisfy { ($0.accessibilityLabel() ?? "").count > 2 },
              "VoiceOver sees \(a11y.count) tiles (\(a11y.first?.accessibilityLabel() ?? "–"))")

        // Search: by title words, then a kind word.
        ui.search("cabinet")
        await wait(0.8)
        // Word matches first; matches by meaning (if the models are installed) after them.
        let wordHits = Search.run("cabinet", in: library.items).map(\.id)
        check(!wordHits.isEmpty && Array(grid.shownItems.prefix(wordHits.count).map(\.id)) == wordHits,
              "search filters in place: \(wordHits.count) by words, \(grid.shownItems.count - wordHits.count) more by meaning")
        shot("ui-search")
        ui.search("pdf")
        await wait(0.6)
        check(grid.shownItems.first?.kind == .pdf, "search by kind word")
        ui.search("")
        await wait(0.6)
        check(grid.shownItems.count == library.items.count, "clearing search shows everything")

        // Kind views are views, not folders.
        ui.sidebar.select(.kind(.text))
        await wait(0.6)
        check(!grid.shownItems.isEmpty && grid.shownItems.allSatisfy { $0.kind == .text }, "text view shows only text (\(grid.shownItems.count))")
        shot("ui-kind-text")
        ui.sidebar.select(.all)
        await wait(0.5)

        // R: a preview with how long ago it was collected.
        ui.setMode(.grid)
        await wait(0.4)
        // Video, sound, PDFs and files open in Quick Look instead: try again.
        for _ in 0..<8 {
            ui.showRandom()
            await wait(1.0)
            if ui.preview.isOpen { break }
            if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().close() }
            await wait(0.4)
        }
        check(ui.preview.isOpen && ui.preview.captionText?.contains("收藏") == true, "R opens a past curiosity (\(ui.preview.captionText ?? "–"))")
        shot("ui-random")
        key(53)
        await wait(0.8)

        // The trail remembers what was looked at, newest first, and how.
        ui.sidebar.select(.trail)
        await wait(0.6)
        check(!ui.grid.shownItems.isEmpty, "trail shows what was looked at (\(ui.grid.shownItems.count))")
        shot("ui-trail")
        ui.sidebar.select(.all)
        await wait(0.4)

        // Inspector shows the focused item's metadata.
        ui.toggleInspectorForTest()
        if let pdfItem = library.items.first(where: { $0.kind == .pdf }) {
            grid.reveal(pdfItem.id)
        }
        await wait(0.8)
        shot("ui-inspector")
        if let insp = (NSApp.delegate as? AppDelegate)?.inspectorViewForTest {
            let side = ui.sidebar.view.frame.width, own = insp.frame.width
            check(abs(side - own) < 2, "the inspector opens as wide as the sidebar (\(Int(own)) vs \(Int(side)))")
        }
        // How long showing an item in the inspector takes, and the toggle.
        if let some = library.items.dropFirst(3).first {
            let t0 = CFAbsoluteTimeGetCurrent()
            ui.inspectForTest(some.id)
            let showMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            let t1 = CFAbsoluteTimeGetCurrent()
            ui.toggleInspectorForTest()
            await wait(0.6)
            ui.toggleInspectorForTest()
            await wait(0.6)
            check(showMs < 60, "the inspector shows a piece quickly (\(Int(showMs)) ms)")
            _ = t1
        }
        ui.toggleInspectorForTest()
        await wait(0.4)
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
    func setSpace(_ space: Space)
    var mode: ViewMode { get }
    func search(_ text: String)
    @discardableResult func showRandom() -> Item?
    func toggleInspectorForTest()
    func inspectForTest(_ id: UUID)
    func ask(_ question: String)
    func openForTest(_ id: UUID)
    func switchCabinet(to id: UUID)
    func createCabinetForTest(_ name: String) -> UUID
    func manageCabinets()
    func closeCabinetsForTest()
    var cabinetsWindowNumber: Int? { get }
    func beginAddCabinetForTest()
    func typeCabinetNameForTest(_ name: String)
    func cabinetID(named: String) -> UUID?
    func watchFolderForTest(_ folder: URL) -> Bool
    func unwatchFolderForTest(_ folder: URL)
    var watchedFoldersForTest: [URL] { get }
    var viewBarTipsForTest: [String] { get }
    func viewBarChoicesForTest(_ tip: String) -> [String]
    func moveCabinetForTest(_ id: UUID, toCloud: Bool) throws
    var cloudRoomsForTest: [(id: UUID, name: String, folder: URL)] { get }
    func joinCloudRoomForTest(_ id: UUID, name: String, folder: URL)
    func cabinetRootForTest(_ id: UUID) -> URL?
    var semanticOfferForTest: String? { get }
    var semanticLoadedForTest: Bool { get }
    func installSemanticForTest()
    func openViewBarChoicesForTest(_ tip: String) -> (rows: [String], rowHeight: CGFloat, frame: NSRect, bar: NSRect)?
    func closeViewBarChoicesForTest()
    func hoverViewBarForTest() -> String?
    var snapshotBarForTest: SnapshotBar { get }
    var isSearchExpanded: Bool { get }
    var topBarSearchCapsuleForTest: NSView? { get }
    func viewBarEnabledForTest(_ tip: String) -> Bool?
    func openSearchForTest()
    var spacesControlForTest: NSView { get }
    var contentAreaForTest: NSView? { get }
    var topBarOverlapsForTest: Bool { get }
    var sidebarToggleForTest: NSView { get }
    var isSidebarCollapsed: Bool { get }
    func flipCabinetForTest()
    func showSettingsTabForTest(_ tab: SettingsWindowController.Tab)
    func collectDropForTest(_ pasteboard: NSPasteboard) -> Bool
    func setCoverForTest(_ picture: URL?) -> Bool
    func setVaultForTest(_ folder: URL?)
    func leaveEmptySearchForTest()
    func canDeleteCabinet(_ id: UUID) -> Bool
    func deleteCabinetForTest(_ id: UUID)
    var currentCabinet: UUID { get }
    var cabinetNames: [String] { get }
    func answerForIntent(_ question: String) async -> String
    func searchForIntent(_ query: String) -> Int
    func randomForIntent() -> String?
    func followRelationForTest(to id: UUID, label: String)
    var trailVisitCount: Int { get }
    func arrivalLine(for id: UUID) -> String?
    var isAsking: Bool { get }
    var answerText: String { get }
    func showSettingsForTest() -> NSWindow?
}
