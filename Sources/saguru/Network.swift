import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The network monitor. There is no proxy and no certificate: Saguru launches the app with a small
// library inside it (agent/SaguruAgent.m) that reports every URLSession request and can answer chosen
// ones with a saved response. The two talk through a folder (see the agent for the format).

struct NetHeader: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var value: String
}

/// One request the app made, and its response once it arrives.
struct NetEntry: Identifiable, Equatable {
    let id: String
    var method = "GET"
    var url = ""
    var started = Date()
    var requestHeaders: [NetHeader] = []
    var requestSize = 0
    var requestBody: URL?
    var finished = false
    var status: Int?
    var duration: Double?
    var responseHeaders: [NetHeader] = []
    var responseSize = 0
    var responseBody: URL?
    var mime = ""
    var error: String?
    var mocked = false
    /// "HTTP/2", when the request really went to the network.
    var version = ""

    var parts: URLComponents? { URLComponents(string: url) }
    var host: String { parts?.host ?? "" }
    var path: String {
        guard let parts else { return url }
        return parts.path.isEmpty ? "/" : parts.path
    }
    var query: [NetHeader] { (parts?.queryItems ?? []).map { NetHeader(name: $0.name, value: $0.value ?? "") } }
    /// What a mock is matched against: the URL without its query.
    var route: String {
        guard var parts else { return url }
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? url
    }

    /// The message as it travels: start line, headers, an empty line and the body (when it is text).
    func raw(request: Bool) -> String {
        let file = request ? requestBody : responseBody
        var lines: [String]
        if request {
            let target = path + (parts?.percentEncodedQuery.map { "?\($0)" } ?? "")
            lines = ["\(method) \(target)" + (version.isEmpty ? "" : " \(version)")]
            if !requestHeaders.contains(where: { $0.name.lowercased() == "host" }), !host.isEmpty { lines.append("Host: \(host)") }
            lines += requestHeaders.map { "\($0.name): \($0.value)" }
        } else {
            lines = [(version.isEmpty ? "HTTP" : version) + " \(status.map(String.init) ?? "")"]
            lines += responseHeaders.map { "\($0.name): \($0.value)" }
        }
        guard let file, let data = try? Data(contentsOf: file), !data.isEmpty else { return lines.joined(separator: "\n") }
        lines.append("")
        if case .text(let text, _) = BodyContent.read(data, mime: request ? "" : mime) {
            lines.append(text)
        } else {
            lines.append("(\(NetFormat.size(data.count)) de contenido binario)")
        }
        return lines.joined(separator: "\n")
    }

    /// "JSON", "Imagen", "HTML"…: what the table shows as the kind of answer.
    var kind: String {
        let type = mime.lowercased()
        if type.contains("json") { return "JSON" }
        if type.hasPrefix("image/") { return "Imagen" }
        if type.contains("html") { return "HTML" }
        if type.contains("xml") { return "XML" }
        if type.contains("javascript") { return "JS" }
        if type.hasPrefix("text/") { return "Texto" }
        if type.hasPrefix("video/") { return "Video" }
        if type.hasPrefix("audio/") { return "Audio" }
        if type.contains("pdf") { return "PDF" }
        if type.contains("zip") || type.contains("octet-stream") { return "Binario" }
        return type.isEmpty ? "" : (type.split(separator: "/").last.map(String.init) ?? type)
    }
}

/// A saved response that replaces the real one for a method and URL.
struct NetMock: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var method: String
    var url: String
    var status: Int
    var headers: [NetHeader]
    /// Milliseconds the answer waits, to imitate the network.
    var delay: Int
    var enabled = true
}

enum NetFormat {
    static func duration(_ seconds: Double?) -> String {
        guard let seconds else { return "…" }
        return seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.2f s", seconds)
    }

    static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    static func color(status: Int?, error: String?) -> Color {
        if error != nil { return Color(nsColor: .systemRed) }
        guard let status else { return .secondary }
        switch status {
        case 200..<300: return Color(nsColor: .systemGreen)
        case 300..<400: return Color(nsColor: .systemTeal)
        case 400..<500: return Color(nsColor: .systemOrange)
        default: return Color(nsColor: .systemRed)
        }
    }
}

final class NetworkModel: ObservableObject {
    enum StatusFilter: String, CaseIterable { case all = "Todas", ok = "2xx", redirect = "3xx", client = "4xx", server = "5xx", failed = "Error", mocked = "Mock" }

    @Published var entries: [NetEntry] = []
    @Published var selection: NetEntry.ID?
    @Published var mocks: [NetMock] = []
    @Published var mockSelection: NetMock.ID?
    @Published var search = ""
    @Published var statusFilter = StatusFilter.all
    @Published var showingMocks = false
    /// "udid|bundle" of the app being watched, while it is.
    @Published private(set) var watching: String?
    @Published var problem: String?

    unowned let panel: PanelModel
    private var folder: URL?
    private var offset: UInt64 = 0
    private var pending = Data()
    private var timer: Timer?
    private var mocksOwner = ""
    private var index: [String: Int] = [:]

    init(panel: PanelModel) {
        self.panel = panel
    }

    private var key: String? {
        guard let udid = panel.selected, !panel.appID.isEmpty else { return nil }
        return "\(udid)|\(panel.appID)"
    }

    /// Whether the app chosen in the rail is the one being watched.
    /// The chosen app is running, launched by Saguru, and reporting its network.
    var isWatching: Bool { watching != nil && watching == key && panel.agentInside }

    var filtered: [NetEntry] {
        let text = search.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { entry in
            if !text.isEmpty, !entry.url.lowercased().contains(text), !entry.method.lowercased().contains(text) { return false }
            switch statusFilter {
            case .all: return true
            case .ok: return (200..<300).contains(entry.status ?? 0)
            case .redirect: return (300..<400).contains(entry.status ?? 0)
            case .client: return (400..<500).contains(entry.status ?? 0)
            case .server: return (entry.status ?? 0) >= 500
            case .failed: return entry.error != nil
            case .mocked: return entry.mocked
            }
        }
    }

    var selected: NetEntry? { selection.flatMap { id in index[id].map { entries[$0] } } }

    // MARK: Watching

    /// Shows the app's network. An app launched by Saguru is already reporting it; otherwise it is relaunched,
    /// because an app can only be watched from its launch.
    func start() {
        guard panel.selected != nil, !panel.appID.isEmpty else { problem = "Elige una app para ver su red."; return }
        if panel.agentInside, watching == key { return }
        relaunch()
    }

    /// Launches the app again, to capture from its start.
    func relaunch() {
        problem = nil
        panel.launchWithAgent { failure in if let failure { self.problem = failure } }
    }

    /// A launch by Saguru is about to happen: a fresh folder for the agent to report to. Every such launch
    /// is watched, whichever tool asked for it.
    func beginSession(for key: String) -> URL {
        loadMocksIfNeeded()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("saguru-net/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        clear()
        offset = 0
        pending = Data()
        publishMocks()
        watching = key
        if timer == nil {
            let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in self?.poll() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        return folder
    }

    func agentWentAway() {
        guard watching != nil else { return }
        problem = "La app se cerró o se lanzó fuera de Saguru: ya no se captura."
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        watching = nil
    }

    func clear() {
        entries = []
        index = [:]
        selection = nil
    }

    /// Reads what the agent has written since the last look.
    private func poll() {
        guard let folder, let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent("events.jsonl")) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)
        pending.append(data)
        var changed = entries
        var touched = false
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.subdata(in: pending.startIndex..<newline)
            pending.removeSubrange(pending.startIndex...newline)
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let phase = event["phase"] as? String, let id = event["id"] as? String else { continue }
            let headers = ((event["headers"] as? [String: Any]) ?? [:])
                .map { NetHeader(name: $0.key, value: "\($0.value)") }
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
            let body = (event["body"] as? String).map { URL(fileURLWithPath: $0) }
            if phase == "start" {
                var entry = NetEntry(id: id)
                entry.method = event["method"] as? String ?? "GET"
                entry.url = event["url"] as? String ?? ""
                entry.started = Date(timeIntervalSince1970: event["time"] as? Double ?? Date().timeIntervalSince1970)
                entry.requestHeaders = headers
                entry.requestSize = event["size"] as? Int ?? 0
                entry.requestBody = body
                index[id] = changed.count
                changed.append(entry)
                touched = true
            } else if phase == "end", let position = index[id] {
                changed[position].finished = true
                changed[position].status = event["status"] as? Int
                changed[position].duration = event["duration"] as? Double
                changed[position].responseHeaders = headers
                changed[position].responseSize = event["size"] as? Int ?? 0
                changed[position].responseBody = body
                changed[position].mime = event["mime"] as? String ?? ""
                changed[position].error = event["error"] as? String
                changed[position].mocked = event["mocked"] as? Bool ?? false
                if let name = event["protocol"] as? String {
                    changed[position].version = ["h2": "HTTP/2", "h3": "HTTP/3", "http/1.1": "HTTP/1.1"][name.lowercased()] ?? name.uppercased()
                }
                if let sent = event["sent"] as? [String: Any], !sent.isEmpty {
                    changed[position].requestHeaders = sent.map { NetHeader(name: $0.key, value: "\($0.value)") }
                        .sorted { $0.name.lowercased() < $1.name.lowercased() }
                }
                touched = true
            }
        }
        if touched { entries = changed }
    }

    // MARK: Mocks

    private var store: URL? {
        guard !panel.appID.isEmpty, let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return support.appendingPathComponent("Saguru/mocks/\(panel.appID)")
    }

    func bodyFile(of mock: NetMock) -> URL? { store?.appendingPathComponent("\(mock.id).body") }

    /// Mocks are kept per app, on this Mac.
    func loadMocksIfNeeded() {
        guard mocksOwner != panel.appID else { return }
        mocksOwner = panel.appID
        mockSelection = nil
        guard let store, let data = try? Data(contentsOf: store.appendingPathComponent("mocks.json")),
              let saved = try? JSONDecoder().decode([NetMock].self, from: data) else { mocks = []; return }
        mocks = saved
        mockSelection = saved.first?.id
    }

    func mock(for entry: NetEntry) -> NetMock? {
        mocks.first { $0.method == entry.method.uppercased() && $0.url == entry.route }
    }

    /// Turns a captured request into a mock: from now on the app gets this same answer without the network.
    func createMock(from entry: NetEntry) {
        if let existing = mock(for: entry) {
            mockSelection = existing.id
            showingMocks = true
            return
        }
        guard let store else { return }
        // The body was saved already decoded, and its length may change when edited.
        let dropped = ["content-encoding", "content-length", "transfer-encoding"]
        var mock = NetMock(method: entry.method.uppercased(), url: entry.route, status: entry.status ?? 200,
                           headers: entry.responseHeaders.filter { !dropped.contains($0.name.lowercased()) }, delay: 0)
        if mock.headers.isEmpty, !entry.mime.isEmpty { mock.headers = [NetHeader(name: "Content-Type", value: entry.mime)] }
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let target = store.appendingPathComponent("\(mock.id).body")
        if let body = entry.responseBody { try? FileManager.default.copyItem(at: body, to: target) } else { try? Data().write(to: target) }
        mocks.append(mock)
        saveMocks()
        mockSelection = mock.id
        showingMocks = true
        panel.say("Mock creado: \(entry.method) \(entry.path)")
    }

    func update(_ mock: NetMock) {
        guard let position = mocks.firstIndex(where: { $0.id == mock.id }), mocks[position] != mock else { return }
        mocks[position] = mock
        saveMocks()
    }

    func writeBody(_ data: Data, of mock: NetMock) {
        guard let file = bodyFile(of: mock) else { return }
        try? data.write(to: file, options: .atomic)
    }

    func delete(_ mock: NetMock) {
        if let file = bodyFile(of: mock) { try? FileManager.default.removeItem(at: file) }
        mocks.removeAll { $0.id == mock.id }
        if mockSelection == mock.id { mockSelection = nil }
        saveMocks()
    }

    private func saveMocks() {
        guard let store else { return }
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(mocks) { try? data.write(to: store.appendingPathComponent("mocks.json"), options: .atomic) }
        publishMocks()
    }

    /// Hands the enabled mocks to the agent. It notices the change on the app's next request.
    private func publishMocks() {
        guard let folder else { return }
        let list: [[String: Any]] = mocks.filter(\.enabled).map { mock in
            var headers: [String: String] = [:]
            for header in mock.headers where !header.name.isEmpty { headers[header.name] = header.value }
            return ["method": mock.method, "url": mock.url, "status": mock.status, "headers": headers,
                    "body": bodyFile(of: mock)?.path ?? "", "delay": mock.delay]
        }
        if let data = try? JSONSerialization.data(withJSONObject: list) {
            try? data.write(to: folder.appendingPathComponent("mocks.json"), options: .atomic)
        }
    }

    // MARK: Sharing a request

    func curl(_ entry: NetEntry) -> String {
        var lines = ["curl -X \(entry.method) '\(entry.url)'"]
        for header in entry.requestHeaders { lines.append("  -H '\(header.name): \(header.value.replacingOccurrences(of: "'", with: "'\\''"))'") }
        if let body = entry.requestBody, let data = try? Data(contentsOf: body), let text = String(data: data, encoding: .utf8) {
            lines.append("  --data-binary '\(text.replacingOccurrences(of: "'", with: "'\\''"))'")
        }
        return lines.joined(separator: " \\\n")
    }
}

// MARK: - Window

final class NetworkWindow: NSObject, NSWindowDelegate {
    static let shared = NetworkWindow()
    private var window: NSWindow?
    private weak var panel: PanelModel?

    func toggle(_ panel: PanelModel) {
        if let window, window.isVisible {
            window.close()
        } else {
            show(panel)
        }
    }

    func show(_ panel: PanelModel) {
        self.panel = panel
        panel.network.loadMocksIfNeeded()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Red"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 820, height: 480)
            window.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.125, alpha: 1)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: NetworkView(model: panel.network, panel: panel))
            window.delegate = self
            window.setFrameAutosaveName("saguru.network")
            if window.frame.origin == .zero { window.center() }
            self.window = window
            Self.installEditMenu()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        panel.networkOpen = true
    }

    func windowWillClose(_ notification: Notification) {
        panel?.networkOpen = false
    }

    /// Saguru has no menu bar of its own; without an Edit menu, ⌘C, ⌘V and ⌘A do nothing in a window.
    static func installEditMenu() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Salir de Saguru", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edición")
        edit.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Rehacer", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}

// MARK: - Views

private let surface = Color(red: 0.11, green: 0.11, blue: 0.125)
private let raised = Color(red: 0.15, green: 0.15, blue: 0.17)
private let hairline = Color.white.opacity(0.09)

struct NetworkView: View {
    @ObservedObject var model: NetworkModel
    @ObservedObject var panel: PanelModel
    /// Inside the docked panel rather than in a window of its own.
    var embedded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(hairline).frame(height: 1)
            if model.showingMocks {
                MocksView(model: model)
            } else if !model.isWatching && model.entries.isEmpty {
                welcome
            } else {
                VSplitView {
                    VStack(spacing: 0) {
                        filters
                        RequestTable(model: model)
                    }
                    .frame(minHeight: 150, idealHeight: 250)
                    Group {
                        if let entry = model.selected {
                            EntryDetail(model: model, entry: entry)
                        } else {
                            Text("Elige una petición para ver su detalle").foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minHeight: 260, idealHeight: 430)
                    .background(surface)
                }
            }
        }
        .background(surface)
        .tint(Color(nsColor: .systemBlue))
        .environment(\.colorScheme, .dark)
        .onChange(of: panel.appID) { _, _ in model.loadMocksIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppBadge(app: panel.app, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(panel.app?.name ?? "Elige una app en el riel").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(model.isWatching ? Color(nsColor: .systemGreen) : Color.secondary.opacity(0.6)).frame(width: 7, height: 7)
                    Text(model.isWatching ? "Capturando · \(model.entries.count) peticiones" : "Sin capturar")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("", selection: $model.showingMocks) {
                Text("Peticiones").tag(false)
                Text(model.mocks.isEmpty ? "Mocks" : "Mocks (\(model.mocks.count))").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer()
            if embedded {
                Button { NetworkWindow.shared.show(panel); panel.openTool = nil } label: { Image(systemName: "macwindow") }
                    .help("Abrir en una ventana aparte")
            }
            if model.isWatching {
                Button("Limpiar") { model.clear() }
                Button("Relanzar") { model.relaunch() }
                    .help("Vuelve a lanzar la app y captura desde su arranque")
            } else {
                Button("Capturar") { model.start() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(panel.app == nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, embedded ? 12 : 30)
        .padding(.bottom, 12)
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "network").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text("Mira lo que tu app le pide a la red").font(.title2.weight(.semibold))
            Text("Saguru relanza la app y captura cada petición: URL, tiempo, cabeceras, cuerpo y respuesta.\nSin proxy ni certificados. Si la lanzas desde Xcode, vuelve a pulsar Capturar.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(3)
            Button("Capturar \(panel.app?.name ?? "")") { model.start() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(panel.app == nil)
                .padding(.top, 4)
            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(Color(nsColor: .systemOrange)).multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filters: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filtrar por URL o método", text: $model.search).textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: 380)
            HStack(spacing: 4) {
                ForEach(NetworkModel.StatusFilter.allCases, id: \.self) { filter in
                    Button { model.statusFilter = filter } label: {
                        Text(filter.rawValue).font(.callout.weight(.medium))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .foregroundStyle(model.statusFilter == filter ? Color.white : Color.secondary)
                            .background(model.statusFilter == filter ? Color(nsColor: .systemBlue).opacity(0.85) : raised,
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(Color(nsColor: .systemOrange)).lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct RequestTable: View {
    @ObservedObject var model: NetworkModel

    var body: some View {
        Table(model.filtered, selection: $model.selection) {
            TableColumn("Estado") { entry in
                HStack(spacing: 6) {
                    Circle().fill(NetFormat.color(status: entry.status, error: entry.error)).frame(width: 7, height: 7)
                    Text(entry.error != nil && entry.status == nil ? "Error" : entry.status.map(String.init) ?? "…")
                        .monospacedDigit()
                    if entry.mocked {
                        Text("mock").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .foregroundStyle(.white)
                            .background(Color(nsColor: .systemPurple), in: Capsule())
                    }
                }
            }
            .width(min: 70, ideal: 96, max: 130)
            TableColumn("Método") { entry in
                Text(entry.method).font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(entry.method == "GET" ? Color(nsColor: .systemBlue) : Color(nsColor: .systemOrange))
            }
            .width(min: 50, ideal: 64, max: 80)
            TableColumn("Servidor") { entry in Text(entry.host).lineLimit(1).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 120)
            TableColumn("Ruta") { entry in
                Text(entry.path + (entry.parts?.query.map { "?\($0)" } ?? "")).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Tipo") { entry in Text(entry.kind).foregroundStyle(.secondary) }
                .width(min: 50, ideal: 62, max: 100)
            TableColumn("Tamaño") { entry in
                Text(entry.finished ? NetFormat.size(entry.responseSize) : "").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 66, max: 100)
            TableColumn("Tiempo") { entry in
                Text(NetFormat.duration(entry.duration)).monospacedDigit()
                    .foregroundStyle((entry.duration ?? 0) > 1 ? Color(nsColor: .systemOrange) : Color.secondary)
            }
            .width(min: 56, ideal: 66, max: 100)
        }
        .scrollContentBackground(.hidden)
        .background(surface)
        .contextMenu(forSelectionType: NetEntry.ID.self) { ids in
            if let entry = model.entries.first(where: { ids.contains($0.id) }) {
                Button("Copiar URL") { copy(entry.url) }
                Button("Copiar como cURL") { copy(model.curl(entry)) }
                Divider()
                Button(model.mock(for: entry) == nil ? "Crear mock" : "Editar mock") { model.createMock(from: entry) }
                    .disabled(!entry.finished)
            }
        }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Everything about one request: the line that sums it up, and request and response side by side.
private struct EntryDetail: View {
    @ObservedObject var model: NetworkModel
    let entry: NetEntry
    @State private var requestTab = "Cabeceras"
    @State private var responseTab = "Cuerpo"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(entry.method).font(.system(.callout, design: .monospaced).weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(raised, in: RoundedRectangle(cornerRadius: 5))
                if let status = entry.status {
                    Text("\(status)").font(.callout.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .foregroundStyle(.white)
                        .background(NetFormat.color(status: status, error: nil).opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
                }
                (Text((entry.parts?.scheme ?? "https") + "://").foregroundStyle(.secondary)
                    + Text(entry.host).foregroundStyle(Color(nsColor: Highlight.key))
                    + Text(entry.path).foregroundStyle(.primary)
                    + Text(entry.parts?.percentEncodedQuery.map { "?\($0)" } ?? "").foregroundStyle(Color(nsColor: Highlight.string)))
                    .font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize()
                Button("Copiar cURL") { copy(model.curl(entry)); model.panel.say("cURL copiado") }
                Button(model.mock(for: entry) == nil ? "Crear mock" : "Editar mock") { model.createMock(from: entry) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!entry.finished)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Rectangle().fill(hairline).frame(height: 1)
            HSplitView {
                side(title: "Petición", tabs: ["Cabeceras", "Query", "Cuerpo", "Raw"], tab: $requestTab) {
                    switch requestTab {
                    case "Raw": RawView(entry: entry, request: true)
                    case "Query": HeaderList(headers: entry.query, empty: "La URL no lleva parámetros")
                    case "Cuerpo": BodyView(file: entry.requestBody, mime: contentType(entry.requestHeaders), size: entry.requestSize,
                                            empty: "La petición no lleva cuerpo")
                    default: HeaderList(headers: entry.requestHeaders, empty: "La app no añadió cabeceras")
                    }
                }
                side(title: entry.mocked ? "Respuesta · mock" : "Respuesta", tabs: ["Cabeceras", "Cuerpo", "Raw"], tab: $responseTab) {
                    if let error = entry.error, entry.status == nil {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(Color(nsColor: .systemRed))
                            Text(error).multilineTextAlignment(.center).textSelection(.enabled)
                        }
                        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !entry.finished {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if responseTab == "Raw" {
                        RawView(entry: entry, request: false)
                    } else if responseTab == "Cabeceras" {
                        HeaderList(headers: entry.responseHeaders, empty: "Sin cabeceras")
                    } else {
                        BodyView(file: entry.responseBody, mime: entry.mime, size: entry.responseSize, empty: "La respuesta llegó sin cuerpo")
                    }
                }
            }
        }
    }

    private var summary: String {
        guard entry.finished else { return "En curso…" }
        return "\(NetFormat.duration(entry.duration)) · \(NetFormat.size(entry.responseSize))"
    }

    private func contentType(_ headers: [NetHeader]) -> String {
        headers.first { $0.name.lowercased() == "content-type" }?.value ?? ""
    }

    private func side<Content: View>(title: String, tabs: [String], tab: Binding<String>, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Spacer(minLength: 6)
                Picker("", selection: tab) { ForEach(tabs, id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 260)
    }
}

private struct HeaderList: View {
    let headers: [NetHeader]
    let empty: String

    var body: some View {
        if headers.isEmpty {
            Text(empty).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 7) {
                    ForEach(headers) { header in
                        GridRow {
                            Text(header.name).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            Text(header.value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
    }
}

/// What a body turned out to be, so each kind is shown the way it is best read.
enum BodyContent {
    case image(NSImage)
    case text(String, json: Bool)
    case binary(preview: String)

    static let textLimit = 400_000

    /// Indents valid JSON without parsing it into objects, so keys keep the order the server sent
    /// and numbers keep their exact spelling.
    static func prettyJSON(_ source: String) -> String {
        var out = "", depth = 0, inString = false, escaped = false
        let characters = Array(source)
        func newline() { out += "\n" + String(repeating: "  ", count: depth) }
        for (position, character) in characters.enumerated() {
            if inString {
                out.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true; out.append(character)
            case "{", "[":
                out.append(character)
                // Empty objects and lists stay on one line.
                let next = characters[(position + 1)...].first { !$0.isWhitespace }
                if next != "}" && next != "]" { depth += 1; newline() }
            case "}", "]":
                let previous = out.last
                if previous != "{" && previous != "[" { depth = max(depth - 1, 0); newline() }
                out.append(character)
            case ",": out.append(character); newline()
            case ":": out += ": "
            case let space where space.isWhitespace: break
            default: out.append(character)
            }
        }
        return out
    }

    static func read(_ data: Data, mime: String) -> BodyContent {
        let type = mime.lowercased()
        if type.hasPrefix("image/") || data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: [0xFF, 0xD8, 0xFF]) || data.starts(with: [0x47, 0x49, 0x46]),
           let image = NSImage(data: data), image.size.width > 0 {
            return .image(image)
        }
        let looksBinary = data.prefix(2048).contains(0)
        if !looksBinary, let text = String(data: data.prefix(textLimit), encoding: .utf8) ?? (data.count > textLimit ? String(decoding: data.prefix(textLimit), as: UTF8.self) : nil) {
            if data.count <= textLimit, let first = text.first(where: { !$0.isWhitespace }), first == "{" || first == "[",
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                return .text(prettyJSON(text), json: true)
            }
            return .text(text, json: false)
        }
        // The first bytes, the way a hex viewer shows them.
        let rows = stride(from: 0, to: min(data.count, 256), by: 16).map { start -> String in
            let slice = data[data.startIndex + start..<data.startIndex + min(start + 16, data.count)]
            let hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(slice.map { (32..<127).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%04x  ", start) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + " " + ascii
        }
        return .binary(preview: rows.joined(separator: "\n"))
    }
}

private struct BodyView: View {
    let file: URL?
    let mime: String
    let size: Int
    let empty: String
    @State private var content: BodyContent?
    @State private var stored = 0
    @State private var filter = ""

    var body: some View {
        Group {
            if file == nil {
                Text(empty).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let content {
                VStack(spacing: 0) {
                    switch content {
                    case .image(let image):
                        ZStack {
                            Checkerboard()
                            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                                .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                                .padding(12)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .text(let text, let json):
                        CodeView(text: text, language: json ? .json : .plain, filter: filter)
                    case .binary(let preview):
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Contenido binario: no se puede leer como texto", systemImage: "doc.zipper").foregroundStyle(.secondary)
                            ScrollView([.vertical, .horizontal]) {
                                Text(preview).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    Rectangle().fill(hairline).frame(height: 1)
                    HStack(spacing: 10) {
                        Text(caption(content)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if case .text(let text, _) = content {
                            LineFilter(text: $filter)
                            Button("Copiar") { copy(text) }
                        }
                        Button("Guardar…") { save() }
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: file) {
            content = nil
            guard let file else { return }
            let mime = mime
            let loaded = await Task.detached { () -> (BodyContent, Int)? in
                guard let data = try? Data(contentsOf: file) else { return nil }
                return (BodyContent.read(data, mime: mime), data.count)
            }.value
            content = loaded?.0 ?? .binary(preview: "No se pudo leer el archivo")
            stored = loaded?.1 ?? 0
        }
    }

    private func caption(_ content: BodyContent) -> String {
        var pieces = [NetFormat.size(size)]
        if !mime.isEmpty { pieces.append(mime) }
        switch content {
        case .image(let image):
            let pixels = image.representations.first.map { "\($0.pixelsWide) × \($0.pixelsHigh) px" } ?? ""
            if !pixels.isEmpty { pieces.append(pixels) }
        case .text(_, let json):
            if json { pieces.append("JSON con formato") }
        case .binary: break
        }
        if stored < size { pieces.append("guardados los primeros \(NetFormat.size(stored))") }
        return pieces.joined(separator: " · ")
    }

    private func save() {
        guard let file else { return }
        let panel = NSSavePanel()
        let type = UTType(mimeType: mime.components(separatedBy: ";").first ?? "")
        panel.nameFieldStringValue = "respuesta." + (type?.preferredFilenameExtension ?? "bin")
        if panel.runModal() == .OK, let target = panel.url {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: file, to: target)
        }
    }
}

/// The small field that narrows a body down to the lines containing a text.
private struct LineFilter: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            TextField("Filtrar líneas", text: $text).textFieldStyle(.plain).frame(width: 120)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(raised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// The request or the response as one text, the way it goes over the wire.
private struct RawView: View {
    let entry: NetEntry
    let request: Bool
    @State private var text = ""
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            CodeView(text: text, language: .http, filter: filter)
            Rectangle().fill(hairline).frame(height: 1)
            HStack(spacing: 10) {
                Spacer()
                LineFilter(text: $filter)
                Button("Copiar") { copy(text) }
            }
            .controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
        .task(id: entry) {
            let entry = entry, request = request
            text = await Task.detached { entry.raw(request: request) }.value
        }
    }
}

/// Behind images, so transparent ones can be told from white ones.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let side: CGFloat = 10
            for row in 0...Int(size.height / side) {
                for column in 0...Int(size.width / side) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)),
                                 with: .color(.white.opacity(0.045)))
                }
            }
        }
    }
}

// MARK: - Mocks

private struct MocksView: View {
    @ObservedObject var model: NetworkModel

    var body: some View {
        if model.mocks.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                Text("Aún no hay mocks").font(.title2.weight(.semibold))
                Text("Elige una petición capturada y pulsa «Crear mock».\nLa app recibirá esa respuesta, tal cual o editada, sin pasar por la red.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(3)
            }
            .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.mocks) { mock in MockRow(model: model, mock: mock) }
                    }
                    .padding(10)
                }
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                Group {
                    if let mock = model.mocks.first(where: { $0.id == model.mockSelection }) {
                        MockEditor(model: model, mock: mock).id(mock.id)
                    } else {
                        Text("Elige un mock para editarlo").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 420)
            }
        }
    }
}

private struct MockRow: View {
    @ObservedObject var model: NetworkModel
    let mock: NetMock

    var body: some View {
        let chosen = model.mockSelection == mock.id
        let parts = URLComponents(string: mock.url)
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { mock.enabled }, set: { on in var copy = mock; copy.enabled = on; model.update(copy) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mock.method).font(.system(.caption, design: .monospaced).weight(.bold))
                    Text((parts?.path).flatMap { $0.isEmpty ? nil : $0 } ?? "/").lineLimit(1).truncationMode(.middle)
                }
                Text(parts?.host ?? mock.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("\(mock.status)").font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(NetFormat.color(status: mock.status, error: nil))
        }
        .opacity(mock.enabled ? 1 : 0.55)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(chosen ? Color(nsColor: .systemBlue).opacity(0.28) : raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.mockSelection = mock.id }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.mockSelection = mock.id }
    }
}

private struct MockEditor: View {
    @ObservedObject var model: NetworkModel
    @State var mock: NetMock
    /// The whole response as one text: status line, headers and, when it is text, the body.
    @State private var document = ""
    /// Bodies that are not text (an image, a file) stay as a file beside the document.
    @State private var binary: BodyContent?
    @State private var bodySize = 0
    @State private var loaded = false
    @State private var readable = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(mock.method).font(.system(.callout, design: .monospaced).weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(raised, in: RoundedRectangle(cornerRadius: 5))
                Text(mock.url).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help("Responde a cualquier \(mock.method) a esta URL, lleve los parámetros que lleve")
                Spacer(minLength: 12)
                HStack(spacing: 5) {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    TextField("0", text: digits(\.delay)).textFieldStyle(.plain).frame(width: 44).multilineTextAlignment(.trailing)
                    Text("ms").foregroundStyle(.secondary)
                }
                .font(.callout.monospacedDigit())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .help("Espera antes de responder, para imitar una red lenta")
                Button { model.delete(mock) } label: { Image(systemName: "trash") }
                    .help("Eliminar el mock")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Rectangle().fill(hairline).frame(height: 1)

            HTTPEditor(text: $document)

            if let binary {
                Rectangle().fill(hairline).frame(height: 1)
                HStack(spacing: 12) {
                    if case .image(let image) = binary {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 120, maxHeight: 72)
                    } else {
                        Image(systemName: "doc.zipper").font(.title2).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("El cuerpo es un archivo").font(.callout.weight(.medium))
                        Text(NetFormat.size(bodySize)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }

            Rectangle().fill(hairline).frame(height: 1)
            HStack(spacing: 10) {
                if !readable {
                    Label("La primera línea debe ser como «HTTP/1.1 200 OK»", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color(nsColor: .systemOrange)).lineLimit(1)
                } else if jsonProblem {
                    Label("El JSON del cuerpo no es válido", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color(nsColor: .systemOrange))
                } else {
                    Text("Guardado · se aplica en la siguiente petición").foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if binary == nil, isJSON { Button("Formatear JSON") { format() }.disabled(jsonProblem) }
                Button("Cuerpo desde archivo…") { replaceBody() }
            }
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 7)
        }
        .onAppear(perform: load)
        .onChange(of: document) { _, changed in
            guard loaded else { return }
            apply(changed)
        }
        .onChange(of: mock) { _, changed in model.update(changed) }
    }

    private var parsed: (status: Int?, headers: [(name: String, value: String)], body: String) { MockDocument.parse(document) }

    private var isJSON: Bool {
        parsed.headers.contains { $0.name.lowercased() == "content-type" && $0.value.lowercased().contains("json") }
    }

    private var jsonProblem: Bool {
        guard binary == nil, isJSON else { return false }
        let body = parsed.body
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed])) == nil
    }

    /// A number edited as text, so each keystroke counts without having to leave the field.
    private func digits(_ path: WritableKeyPath<NetMock, Int>) -> Binding<String> {
        Binding(get: { String(mock[keyPath: path]) },
                set: { mock[keyPath: path] = Int($0.filter(\.isNumber).prefix(6)) ?? 0 })
    }

    private func load() {
        let data = model.bodyFile(of: mock).flatMap { try? Data(contentsOf: $0) } ?? Data()
        bodySize = data.count
        let type = mock.headers.first { $0.name.lowercased() == "content-type" }?.value ?? ""
        var text = ""
        binary = nil
        if !data.isEmpty {
            switch BodyContent.read(data, mime: type) {
            case .text(let value, _) where data.count <= BodyContent.textLimit: text = value
            case let other: binary = other
            }
        }
        document = MockDocument.compose(status: mock.status, headers: mock.headers, body: text)
        // The editor reports the text it was just given as a change; that one is not an edit.
        DispatchQueue.main.async { loaded = true }
    }

    /// Reads the document back into the mock. A first line that cannot be read keeps the last good status.
    private func apply(_ text: String) {
        let result = MockDocument.parse(text)
        readable = result.status != nil
        var changed = mock
        if let status = result.status { changed.status = status }
        let headers = result.headers
        if headers.map(\.name) != mock.headers.map(\.name) || headers.map(\.value) != mock.headers.map(\.value) {
            changed.headers = headers.map { NetHeader(name: $0.name, value: $0.value) }
        }
        if changed != mock { mock = changed }
        if binary == nil { model.writeBody(Data(result.body.utf8), of: mock) }
    }

    private func format() {
        let result = parsed
        document = MockDocument.compose(status: result.status ?? mock.status,
                                        headers: result.headers.map { NetHeader(name: $0.name, value: $0.value) },
                                        body: BodyContent.prettyJSON(result.body))
    }

    private func replaceBody() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        loaded = false
        model.writeBody(data, of: mock)
        load()
    }
}
