import AppKit

/// Lets an AI assistant on this Mac use Wunder over the Model Context Protocol.
/// The assistant starts `Wunder --mcp`, which speaks MCP on stdin and stdout
/// and hands each tool call to the running app over a socket only this user
/// can open; the app answers from its own library. Nothing listens on the
/// network, and it's off until turned on in Settings → Privacy.
enum MCP {
    static let enabledKey = "mcp.enabled"
    static let writeKey = "mcp.write"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var canWrite: Bool { UserDefaults.standard.bool(forKey: writeKey) }

    /// Next to the library; a self-test keeps its own beside its screenshots.
    static var socketURL: URL {
        if let test = ProcessInfo.processInfo.environment["WK_SELFTEST"] {
            return URL(fileURLWithPath: test).deletingLastPathComponent().appendingPathComponent("mcp.sock")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wunderkammer/mcp.sock")
    }

    /// What to paste into an assistant's MCP settings.
    static var settingsSnippet: String {
        let path = Bundle.main.executablePath ?? "/Applications/Wunder.app/Contents/MacOS/Wunder"
        return """
        {
          "mcpServers": {
            "wunder": {
              "command": "\(path)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    struct Tool {
        var name: String
        var description: String
        var properties: [String: [String: Any]]
        var required: [String] = []
        var writes = false

        var json: [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
        }
    }

    private static func text(_ about: String) -> [String: Any] { ["type": "string", "description": about] }

    nonisolated(unsafe) static let tools: [Tool] = [
        Tool(name: "overview",
             description: "What's in Wunder: the rooms (separate collections, one open at a time), how many things of each kind the open room holds, the themes and colours it found, and the user's pinned boards. Start here.",
             properties: [:]),
        Tool(name: "search",
             description: "Find things in the open room by words (titles, text in pictures, sites, names, years, colours) and by what they look like, from a description in any language.",
             properties: ["query": text("What to look for, e.g. \"red chair\" or \"receipts from 2024\"."),
                          "limit": ["type": "integer", "description": "At most this many (default 20)."]],
             required: ["query"]),
        Tool(name: "browse",
             description: "List things in the open room by a group: recent, a kind (images, web, text, media, documents, books, films, music, products, places), a theme, a colour, a pinned board, or rediscovery (for_today, on_this_day, forgotten).",
             properties: ["by": ["type": "string", "enum": ["recent", "kind", "theme", "color", "board", "for_today", "on_this_day", "forgotten"]],
                          "value": text("The kind, theme, colour or board name, when `by` needs one."),
                          "limit": ["type": "integer", "description": "At most this many (default 20)."]],
             required: ["by"]),
        Tool(name: "get_item",
             description: "Everything Wunder knows about one thing: title, kind, when it was collected, where it came from, the file, its text or the text found in it, themes, colours, people and places named, and the boards it's on.",
             properties: ["id": text("The thing's id, as given by search or browse.")],
             required: ["id"]),
        Tool(name: "random",
             description: "Something collected a while ago, picked at random, to rediscover.",
             properties: [:]),
        Tool(name: "ask",
             description: "Ask a question about the collection, answered on this Mac by Apple Intelligence (macOS 26 or later).",
             properties: ["question": text("The question.")],
             required: ["question"]),
        Tool(name: "collect",
             description: "Collect something into the open room: a web page by its URL, some text, or a file on this Mac. Optionally put it on a pinned board. Needs the user to allow collecting.",
             properties: ["url": text("A web page to collect."), "text": text("Text to collect."),
                          "file_path": text("A file on this Mac to collect (kept where it is)."),
                          "board": text("A pinned board to put it on; made if it doesn't exist.")],
             writes: true),
        Tool(name: "add_to_board",
             description: "Put things on a pinned board, making the board if needed. Needs the user to allow collecting.",
             properties: ["ids": ["type": "array", "items": ["type": "string"], "description": "The things' ids."],
                          "board": text("The board's name.")],
             required: ["ids", "board"], writes: true),
    ]

    static let instructions = """
    Wunder is the user's cabinet of curiosities on this Mac: pictures, web pages, text, files and media they collected, \
    sorted by the app into kinds, themes and colours. Use overview first, then search or browse; get_item for details. \
    Ids are UUIDs. collect and add_to_board only work if the user allowed collecting in Wunder's settings.
    """

    // MARK: Socket address

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    /// Reads one line (up to a newline) from a socket.
    static func readLine(_ fd: Int32) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { return line.isEmpty ? nil : line }
            if byte == 10 { return line }
            line.append(byte)
        }
    }

    static func write(_ fd: Int32, _ data: Data) -> Bool {
        let all = data + Data([10])
        return all.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }
}

// MARK: - The assistant's side: `Wunder --mcp`

/// Runs instead of the app when started with `--mcp`: MCP over stdio, each
/// tool call passed on to the app (opened in the background if it isn't).
enum MCPServer {
    static func run() -> Never {
        while let line = Swift.readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = message["id"] else { continue }
            let params = message["params"] as? [String: Any] ?? [:]
            switch message["method"] as? String ?? "" {
            case "initialize":
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                reply(id, result: ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                                   "capabilities": ["tools": [String: Any]()],
                                   "serverInfo": ["name": "wunder", "version": version],
                                   "instructions": MCP.instructions])
            case "ping":
                reply(id, result: [String: Any]())
            case "tools/list":
                reply(id, result: ["tools": MCP.tools.map(\.json)])
            case "tools/call":
                let (text, failed) = call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
                reply(id, result: ["content": [["type": "text", "text": text]], "isError": failed])
            case let method:
                reply(id, error: ["code": -32601, "message": "Method not found: \(method)"])
            }
        }
        exit(0)
    }

    private static func reply(_ id: Any, result: Any? = nil, error: [String: Any]? = nil) {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let error { message["error"] = error } else { message["result"] = result ?? [String: Any]() }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        FileHandle.standardOutput.write(data + Data([10]))
    }

    private static func call(_ tool: String, _ arguments: [String: Any]) -> (String, Bool) {
        let request: [String: Any] = ["tool": tool, "arguments": arguments]
        if let answer = send(request) { return answer }
        let off = "Wunder isn't letting assistants in. Turn on 「讓 AI 助手使用 Wunder」 (Let AI assistants use Wunder) in Wunder → Settings → Privacy."
        // Running but switched off: say so straight away.
        if !NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").isEmpty {
            return (off, true)
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-j", Bundle.main.bundlePath]
        try? open.run()
        for _ in 0..<40 {
            usleep(250_000)
            if let answer = send(request) { return answer }
        }
        return (off, true)
    }

    /// One request to the app, one answer; nil if the app isn't listening.
    private static func send(_ request: [String: Any]) -> (String, Bool)? {
        guard var addr = MCP.address(MCP.socketURL.path),
              let body = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, MCP.write(fd, body), let line = MCP.readLine(fd),
              let answer = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        return (answer["text"] as? String ?? "", answer["isError"] as? Bool ?? false)
    }
}

// MARK: - The app's side

/// Listens on the socket while assistants are allowed in; each line in is a
/// tool call, each line out its answer, worked out on the main actor.
final class MCPHost: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (_ tool: String, _ arguments: Data) async -> (String, Bool)

    private let handler: Handler
    private var listener: Int32 = -1
    private let lock = NSLock()

    init(handler: @escaping Handler) { self.handler = handler }

    var isRunning: Bool { lock.withLock { listener >= 0 } }

    func start() {
        guard !isRunning else { return }
        let path = MCP.socketURL.path
        try? FileManager.default.createDirectory(at: MCP.socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(path)
        guard var addr = MCP.address(path) else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // Only this user can open it.
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); return }
        lock.withLock { listener = fd }
        Thread { [weak self] in self?.accepting(fd) }.start()
    }

    func stop() {
        let fd = lock.withLock { () -> Int32 in
            let fd = listener
            listener = -1
            return fd
        }
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(MCP.socketURL.path)
    }

    private func accepting(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            DispatchQueue.global().async { [weak self] in self?.serve(client) }
        }
    }

    private final class Answer: @unchecked Sendable { var value = ("", true) }

    private func serve(_ client: Int32) {
        defer { close(client) }
        while let line = MCP.readLine(client) {
            guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let tool = request["tool"] as? String else { return }
            let arguments = (try? JSONSerialization.data(withJSONObject: request["arguments"] ?? [String: Any]())) ?? Data("{}".utf8)
            let answer = Answer(), done = DispatchSemaphore(value: 0)
            let handler = handler
            Task { @MainActor in
                answer.value = await handler(tool, arguments)
                done.signal()
            }
            done.wait()
            let out: [String: Any] = ["text": answer.value.0, "isError": answer.value.1]
            guard let data = try? JSONSerialization.data(withJSONObject: out), MCP.write(client, data) else { return }
        }
    }
}

// MARK: - The tools, answered from the open room

/// Turns tool calls into plain-text answers an assistant can read.
@MainActor
struct MCPTools {
    var library: Library
    var rooms: () -> [(name: String, count: Int, current: Bool)]
    var semantic: (String, [Item]) async -> [UUID]
    var ask: (String) async -> String
    var collected: () -> Void

    func call(_ tool: String, _ data: Data) async -> (String, Bool) {
        let args = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let spec = MCP.tools.first(where: { $0.name == tool }) else { return ("No tool called \(tool).", true) }
        if spec.writes, !MCP.canWrite {
            return ("Collecting is off. The user can turn on 「也讓它收藏」 (Let it collect too) in Wunder → Settings → Privacy.", true)
        }
        let limit = max(1, min(args["limit"] as? Int ?? 20, 200))
        switch tool {
        case "overview": return (overview(), false)
        case "search":
            let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return ("Give a query.", true) }
            var found = Search.run(query, in: library.items)
            let known = Set(found.map(\.id))
            found += await semantic(query, library.items).filter { !known.contains($0) }.compactMap(library.item)
            return (list(found, limit: limit, empty: "Nothing matches “\(query)”."), false)
        case "browse": return browse(args["by"] as? String ?? "", value: args["value"] as? String, limit: limit)
        case "get_item":
            guard let item = item(args["id"]) else { return ("No thing with that id.", true) }
            return (describe(item), false)
        case "random":
            guard let item = library.items.randomElement() else { return ("The room is empty.", false) }
            return (describe(item), false)
        case "ask":
            let question = args["question"] as? String ?? ""
            return question.isEmpty ? ("Ask a question.", true) : (await ask(question), false)
        case "collect": return await collect(args)
        case "add_to_board":
            let ids = (args["ids"] as? [String] ?? []).compactMap { item($0)?.id }
            guard !ids.isEmpty, let name = args["board"] as? String, !name.isEmpty else { return ("Give ids and a board name.", true) }
            let board = board(named: name)
            library.add(ids, to: board.id)
            return ("Put \(ids.count) on “\(board.name)”.", false)
        default: return ("No tool called \(tool).", true)
        }
    }

    private func overview() -> String {
        var lines = ["Rooms:"]
        for room in rooms() { lines.append("- \(room.name): \(room.count) things\(room.current ? " (open)" : "")") }
        let items = library.items
        lines.append("\nThe open room holds \(items.count) things.")
        let kinds = Dictionary(grouping: items, by: \.kind).map { "\($0.key.rawValue) \($0.value.count)" }.sorted()
        lines.append("Kinds: " + kinds.joined(separator: ", "))
        lines.append("Themes: " + top(items.flatMap { $0.labels ?? [] }, 40))
        lines.append("Colours: " + top(items.flatMap { $0.colors ?? [] }, 20))
        let boards = library.collections.map { "\($0.name) (\($0.itemIDs.count))" }
        lines.append("Pinned boards: " + (boards.isEmpty ? "none" : boards.joined(separator: ", ")))
        return lines.joined(separator: "\n")
    }

    private func top(_ names: [String], _ n: Int) -> String {
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +).sorted { $0.value > $1.value }
        return counts.isEmpty ? "none yet" : counts.prefix(n).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    private func browse(_ by: String, value: String?, limit: Int) -> (String, Bool) {
        let base: Scope.Base
        switch by {
        case "recent": return (list(library.items.sorted { $0.dateAdded > $1.dateAdded }, limit: limit, empty: "The room is empty."), false)
        case "kind":
            guard let k = Scope.KindView(rawValue: value ?? "") else {
                return ("Kinds: " + Scope.KindView.allCases.map(\.rawValue).joined(separator: ", "), true)
            }
            base = .kind(k)
        case "theme": base = .subject(value ?? "")
        case "color": base = .color(value ?? "")
        case "board":
            guard let b = library.collections.first(where: { $0.name.localizedCaseInsensitiveCompare(value ?? "") == .orderedSame }) else {
                return ("No board called “\(value ?? "")”.", true)
            }
            base = .board(b.id)
        case "for_today": base = .forToday
        case "on_this_day": base = .onThisDay
        case "forgotten": base = .forgotten
        default: return ("`by` is one of recent, kind, theme, color, board, for_today, on_this_day, forgotten.", true)
        }
        return (list(library.items(for: Scope(base: base)), limit: limit, empty: "Nothing there."), false)
    }

    private func collect(_ args: [String: Any]) async -> (String, Bool) {
        var sources: [Source] = []
        if let s = args["url"] as? String, let url = URL(string: s), url.scheme?.hasPrefix("http") == true { sources.append(.web(url, title: nil)) }
        if let s = args["text"] as? String, !s.isEmpty { sources.append(.text(s, origin: nil)) }
        if let s = args["file_path"] as? String, !s.isEmpty {
            let url = URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { return ("No file at \(url.path).", true) }
            sources.append(.file(url))
        }
        guard !sources.isEmpty else { return ("Give a url, some text or a file_path.", true) }
        let board = (args["board"] as? String).flatMap { $0.isEmpty ? nil : self.board(named: $0) }
        let ids = await library.capture(sources, into: board?.id, sourceApp: "AI assistant")
        guard !ids.isEmpty else { return ("Nothing could be collected from that.", true) }
        collected()
        let items = ids.compactMap(library.item)
        return ("Collected\(board.map { " onto “\($0.name)”" } ?? ""):\n" + items.map(line).joined(separator: "\n"), false)
    }

    private func board(named name: String) -> Board {
        library.collections.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
            ?? library.createCollection(named: name)
    }

    private func item(_ value: Any?) -> Item? {
        guard let s = value as? String else { return nil }
        if let id = UUID(uuidString: s) { return library.item(id) }
        return library.items.first { $0.id.uuidString.lowercased().hasPrefix(s.lowercased()) }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func line(_ item: Item) -> String {
        var parts = [item.kind.rawValue, Self.day.string(from: item.dateAdded)]
        if let d = item.domain { parts.append(d) }
        if let labels = item.labels?.prefix(3), !labels.isEmpty { parts.append(labels.joined(separator: ", ")) }
        return "- \(item.displayTitle) (\(parts.joined(separator: " · "))) id: \(item.id.uuidString)"
    }

    private func list(_ items: [Item], limit: Int, empty: String) -> String {
        guard !items.isEmpty else { return empty }
        let shown = items.prefix(limit).map(line).joined(separator: "\n")
        return items.count > limit ? "\(items.count) found, the first \(limit):\n\(shown)" : "\(items.count) found:\n\(shown)"
    }

    private func describe(_ item: Item) -> String {
        var lines = ["\(item.displayTitle)", "id: \(item.id.uuidString)", "kind: \(item.kind.rawValue)",
                     "collected: \(Self.day.string(from: item.dateAdded))"]
        if let url = item.url { lines.append("from: \(url)") }
        if let path = item.filePath { lines.append("file: \(path)") } else if let url = library.originalURL(item) { lines.append("file: \(url.path)") }
        if let creator = item.creator { lines.append("by: \(creator)") }
        if let credits = item.credits, !credits.isEmpty { lines.append("credits: " + credits.map { "\($0.name)" }.joined(separator: ", ")) }
        if let released = item.released { lines.append("released: \(released)") }
        if let place = item.locality { lines.append("place: \(place)") }
        if let labels = item.labels, !labels.isEmpty { lines.append("themes: " + labels.joined(separator: ", ")) }
        if let colors = item.colors, !colors.isEmpty { lines.append("colours: " + colors.joined(separator: ", ")) }
        if let names = item.entities, !names.isEmpty { lines.append("names: " + names.map(\.name).joined(separator: ", ")) }
        let boards = library.collections.filter { $0.itemIDs.contains(item.id) }.map(\.name)
        if !boards.isEmpty { lines.append("boards: " + boards.joined(separator: ", ")) }
        lines.append("picture: \(library.thumbnailURL(item).path)")
        if let text = item.text ?? item.pageText, !text.isEmpty { lines.append("\ntext:\n" + String(text.prefix(2000))) }
        if let ocr = item.ocrText, !ocr.isEmpty { lines.append("\ntext in it:\n" + String(ocr.prefix(1500))) }
        return lines.joined(separator: "\n")
    }
}
