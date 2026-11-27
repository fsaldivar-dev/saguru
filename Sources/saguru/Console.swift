import AppKit
import SwiftUI

// The app's console. An app launched from Xcode prints there; launched any other way, what it prints is
// lost, and when it closes nobody says why. Saguru keeps both: it stays connected to what the app writes
// (see AgentLauncher), follows the system log for that process, and when the process ends it says why:
// what the app wrote last, how the system says it ended, and the crash report macOS writes, whose stack
// and reason it reads. The report can take a while, so the first two are shown at once.

struct LogLine: Identifiable {
    enum Kind { case output, error, system, fault, note }
    let id: Int
    let text: String
    let kind: Kind
}

/// Why the app closed, read from the crash report macOS wrote for it.
struct CrashReport: Equatable {
    var title: String
    var reason: String
    /// Innermost first. The app's own frames are marked so they can stand out.
    var frames: [Frame]
    var file: URL?

    struct Frame: Equatable, Identifiable {
        let id: Int
        let image: String
        let symbol: String
        let place: String
        let own: Bool
    }

    var text: String {
        ([title, reason, ""] + frames.map { "\($0.id)  \($0.image)  \($0.symbol)\($0.place.isEmpty ? "" : "  (\($0.place))")" }).joined(separator: "\n")
    }
}

final class ConsoleModel: ObservableObject {
    /// Not published: the system can log thousands of lines a second, and telling the view about each one
    /// would stall it. `revision` moves a few times a second instead, when there is something new.
    private(set) var lines: [LogLine] = []
    @Published private(set) var revision = 0
    private var dirty = false
    private var flusher: Timer?
    @Published private(set) var crash: CrashReport?
    /// The app closed with an error and the tool has not been opened since.
    @Published var unseen = false
    /// Everything the system logs for the process, not only what the app prints and its errors.
    @Published var showSystem = false { didSet { dirty = true } }
    @Published private(set) var appName = ""
    /// The crash report is still being looked for: the stack may yet arrive.
    @Published private(set) var waiting = false
    /// The run that ended had nothing of Saguru's in it.
    @Published private(set) var plain = false

    unowned let panel: PanelModel
    private var rest = Data()
    private var stream: Process?
    private var streamRest = Data()
    private var count = 0
    private var session = 0
    private var launchedAt = Date()
    private var pid: Int32 = 0
    private var udid = ""
    private static let limit = 6000

    init(panel: PanelModel) {
        self.panel = panel
        flusher = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.dirty else { return }
            self.dirty = false
            self.revision += 1
        }
    }

    var shown: [LogLine] { showSystem ? lines : lines.filter { $0.kind != .system } }

    /// Before a launch. What arrives later from an earlier launch is told apart by the number returned.
    func beginSession() -> Int {
        stopStream()
        session += 1
        pid = 0
        rest = Data()
        lines = []
        dirty = true
        crash = nil
        unseen = false
        count = 0
        return session
    }

    /// What the app wrote to standard output or error, as it comes.
    func receive(_ data: Data, session: Int) {
        guard session == self.session else { return }
        var all = rest + data
        while let newline = all.firstIndex(of: 0x0A) {
            var text = String(decoding: all[all.startIndex..<newline], as: UTF8.self)
            while text.hasSuffix("\r") { text.removeLast() }
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { add(text, Self.isFailure(text) ? .error : .output) }
            all = all[all.index(after: newline)...]
        }
        rest = Data(all)
    }

    /// Lines the runtime writes when it gives up: Swift's failures and an uncaught exception.
    private static func isFailure(_ text: String) -> Bool {
        text.contains("Fatal error") || text.contains("Terminating app due to") || text.contains("*** First throw call stack")
            || text.contains("Precondition failed") || text.contains("Assertion failed") || text.contains("libc++abi: terminating")
    }

    /// The app is running: follow the system log for its process.
    func launched(pid: Int32, udid: String, name: String, plain: Bool = false) {
        self.plain = plain
        self.pid = pid
        self.udid = udid
        appName = name
        launchedAt = Date()
        add("\(name) lanzada por Saguru · proceso \(pid)\(plain ? " · app intacta, sin nada de Saguru dentro" : "")", .note)
        let process = Simctl.process(["spawn", udid, "log", "stream", "--style", "compact", "--level", "info", "--predicate", "processIdentifier == \(pid)"])
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.readSystem(data) }
        }
        try? process.run()
        stream = process
    }

    /// The process is gone. What the app wrote last is known at once; how the system says it ended takes a
    /// moment; the crash report, with the stack, can take many seconds for a large app. Each is shown as it comes.
    func appEnded() {
        guard pid != 0 else { return }
        let ended = pid, name = appName, mine = session, since = launchedAt, device = udid
        pid = 0
        if !rest.isEmpty { receive(Data([0x0A]), session: mine) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in if self?.session == mine { self?.stopStream() } }

        let said = lastWords()
        var announced = false
        func show(_ report: CrashReport) {
            guard session == mine else { return }
            crash = report
            unseen = panel.openTool != .console
            guard !announced else { return }
            announced = true
            let why = report.reason.split(separator: "\n").first.map(String.init) ?? report.title
            add("\(name) se cerró: \(report.title)", .fault)
            panel.say("\(name) se cerró: \(why.prefix(110)). Míralo en Registro")
        }
        if !said.isEmpty { show(CrashReport(title: "Error fatal", reason: said, frames: [], file: nil)) }

        waiting = true
        DispatchQueue.global(qos: .userInitiated).async {
            defer { DispatchQueue.main.async { if self.session == mine { self.waiting = false } } }
            // The report macOS writes: up to about a minute for it to appear.
            var report: CrashReport?
            for attempt in 0..<45 {
                if let found = Self.report(for: ended, since: since) { report = found; break }
                if attempt == 2 {
                    // Meanwhile, how the simulator itself says the process ended.
                    let status = Self.exitStatus(pid: ended, udid: device)
                    DispatchQueue.main.async {
                        guard self.session == mine, self.crash == nil, let status else { return }
                        if status.failure { show(CrashReport(title: status.title, reason: status.reason, frames: [], file: nil)) }
                        else { self.add("\(name) terminó: \(status.reason)", .note) ; announced = true }
                    }
                }
                Thread.sleep(forTimeInterval: 1.3)
                if attempt == 8 {
                    var quiet = false
                    DispatchQueue.main.sync { quiet = self.crash == nil && announced }
                    if quiet { return }   // it ended on purpose: no report is coming
                }
            }
            DispatchQueue.main.async {
                guard self.session == mine else { return }
                if var report {
                    // The report knows the stack; the app's own last words say it best.
                    if !said.isEmpty { report.reason = said + (report.reason.isEmpty ? "" : "\n" + report.reason) }
                    show(report)
                } else if self.crash == nil, !announced {
                    self.add("\(name) terminó sin que el sistema dejara un motivo", .note)
                }
            }
        }
    }

    /// The failure lines at the end of what the app wrote, if it said anything on its way out.
    private func lastWords() -> String {
        let tail = lines.suffix(60).filter { $0.kind == .error }.map(\.text).filter { !$0.contains("First throw call stack") }
        return tail.suffix(3).joined(separator: "\n")
    }

    /// What a fatal signal usually means, in words a person can act on.
    static func meaning(of signal: String) -> String {
        switch signal {
        case "SIGSEGV", "SIGBUS":
            return "Acceso a memoria inválido (EXC_BAD_ACCESS): se usó un objeto ya liberado, un puntero nulo o memoria que no era suya. No deja mensaje; el dónde está en la pila. Suele venir de código unsafe, de C u Objective-C, de una librería, o de un objeto usado desde dos hilos a la vez."
        case "SIGTRAP":
            return "El runtime de Swift detuvo la app: un fatalError, un opcional forzado que era nil, un índice fuera de rango o un desbordamiento."
        case "SIGABRT":
            return "La app se abortó a sí misma: una excepción sin atrapar, un assert o una comprobación del sistema que falló."
        case "SIGILL":
            return "Instrucción inválida: normalmente una comprobación del runtime que falló."
        case "SIGKILL":
            return "El sistema o una herramienta la mató sin darle ocasión de responder."
        default:
            return "El proceso recibió la señal \(signal)."
        }
    }

    /// How SpringBoard recorded the end of the process: "domain:signal(2) code:SIGABRT(6)", "domain:tcc(11) code:0"…
    static func exitStatus(pid: Int32, udid: String) -> (title: String, reason: String, failure: Bool)? {
        let predicate = "process == \"SpringBoard\" AND subsystem == \"com.apple.FrontBoard\" AND eventMessage CONTAINS \"Process exited\" AND eventMessage CONTAINS \":\(pid)]\""
        guard let data = try? Simctl.run(["spawn", udid, "log", "show", "--last", "40s", "--style", "compact", "--predicate", predicate]),
              let line = String(data: data, encoding: .utf8)?.split(separator: "\n").last(where: { $0.contains("domain:") }) else { return nil }
        func field(_ name: String) -> String {
            guard let start = line.range(of: name + ":") else { return "" }
            return String(line[start.upperBound...].prefix { $0 != " " && $0 != ">" })
        }
        let domain = field("domain"), code = field("code")
        let kind = String(domain.prefix { $0 != "(" }), what = String(code.prefix { $0 != "(" })
        switch kind {
        case "tcc": return ("Permiso cambiado", "el sistema la cerró porque cambió un permiso de privacidad (es lo normal al conceder o quitar uno)", false)
        case "frontboard", "springboard": return ("Cierre pedido", "la cerró el usuario, Saguru u otra herramienta", false)
        case "jetsam": return ("Sin memoria", "El sistema la cerró por usar demasiada memoria (\(what)).", true)
        case "watchdog", "runningboard": return ("Cerrada por el sistema", "El sistema la cerró: tardó demasiado en responder o incumplió una regla (\(domain) \(code)).", true)
        case "signal": return ("Señal \(what)", meaning(of: what), !["SIGKILL", "SIGTERM"].contains(what))
        default: return ("Terminó", "salió con \(domain) \(code)", false)
        }
    }

    func clear() { lines = []; dirty = true }

    private func stopStream() {
        stream?.terminate()
        stream = nil
        streamRest = Data()
    }

    private func add(_ text: String, _ kind: LogLine.Kind) {
        count += 1
        lines.append(LogLine(id: count, text: text, kind: kind))
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit + 500) }
        dirty = true
    }

    /// Lines look like "2026-11-27 11:36:36.036 E  App[123:abc] [subsystem:category] message".
    private func readSystem(_ data: Data) {
        var all = streamRest + data
        while let newline = all.firstIndex(of: 0x0A) {
            let text = String(decoding: all[all.startIndex..<newline], as: UTF8.self)
            all = all[all.index(after: newline)...]
            let parts = text.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, parts[0].count == 10, parts[0].contains("-") else {
                // A message that runs over several lines: the rest belongs to the line before.
                if !text.isEmpty, !text.hasPrefix("Timestamp"), !text.hasPrefix("Filtering"), let last = lines.last, last.kind == .system || last.kind == .fault {
                    add("    " + text, last.kind)
                }
                continue
            }
            let level = parts[2], kind: LogLine.Kind = level == "F" || level == "E" ? .fault : .system
            // "App[123:abc] rest" → keep what comes after the process tag, with the time in front.
            var message = String(parts[3])
            if let close = message.firstIndex(of: "]") { message = String(message[message.index(after: close)...]).trimmingCharacters(in: .whitespaces) }
            add("\(parts[1].prefix(12))  \(message)", kind)
        }
        streamRest = Data(all)
    }

    // MARK: Crash reports

    /// The crash report macOS wrote for this process, if there is one yet.
    static func report(for pid: Int32, since: Date) -> CrashReport? {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "ips" {
            guard let changed = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, changed > since.addingTimeInterval(-2),
                  let report = parse(file), report.pid == pid else { continue }
            return report.crash
        }
        return nil
    }

    /// A report is one line of JSON (a summary) followed by a JSON document with everything else.
    static func parse(_ file: URL) -> (pid: Int32, crash: CrashReport)? {
        guard let text = try? String(contentsOf: file, encoding: .utf8), let split = text.firstIndex(of: "\n"),
              let body = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: split)...].utf8)) as? [String: Any],
              let pid = body["pid"] as? Int else { return nil }
        let exception = body["exception"] as? [String: Any] ?? [:]
        var title = [exception["type"] as? String, (exception["signal"] as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        if title.isEmpty { title = "La app se cerró" }
        // What the runtime said before dying ("Fatal error: …", an uncaught exception's reason), when it said anything.
        var reasons: [String] = []
        for (_, said) in (body["asi"] as? [String: Any]) ?? [:] { reasons += (said as? [String]) ?? [] }
        if let subtype = exception["subtype"] as? String { reasons.append(subtype) }
        if let signal = exception["signal"] as? String { reasons.append(meaning(of: signal)) }
        if reasons.isEmpty, let end = body["termination"] as? [String: Any], let why = end["indicator"] as? String { reasons.append(why) }

        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let name = (body["procName"] as? String) ?? ""
        var raw = (body["lastExceptionBacktrace"] as? [[String: Any]]) ?? []
        if raw.isEmpty, let threads = body["threads"] as? [[String: Any]], let crashed = threads.first(where: { $0["triggered"] as? Bool == true }) {
            raw = (crashed["frames"] as? [[String: Any]]) ?? []
        }
        let frames = raw.prefix(40).enumerated().map { index, frame -> CrashReport.Frame in
            let image = (frame["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0]["name"] as? String : nil } ?? "?"
            let place = (frame["sourceFile"] as? String).map { "\($0):\(frame["sourceLine"] as? Int ?? 0)" } ?? ""
            return CrashReport.Frame(id: index, image: image, symbol: (frame["symbol"] as? String) ?? "(sin símbolo)", place: place,
                                     own: image == name || image.hasPrefix(name + "."))
        }
        return (Int32(pid), CrashReport(title: title, reason: reasons.joined(separator: "\n"), frames: frames, file: file))
    }
}

// MARK: - View

struct ConsoleView: View {
    @ObservedObject var console: ConsoleModel
    @ObservedObject var panel: PanelModel
    @State private var filter = ""
    @State private var wholeStack = false

    /// What the log shows right now, for copying. Asked for only then: it can be thousands of lines.
    private func visible() -> [LogLine] {
        let all = console.shown
        return filter.isEmpty ? all : all.filter { $0.text.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        FormBox(title: "Registro", target: panel) {
            VStack(alignment: .leading, spacing: 12) {
                if let crash = console.crash { card(crash) }
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                    TextField("Filtrar", text: $filter).textFieldStyle(.plain)
                    Toggle("Sistema", isOn: $console.showSystem).toggleStyle(.checkbox)
                        .help("Incluye todo lo que el sistema registra para la app, no solo lo que imprime y sus errores")
                    Button("Copiar") { copy(visible().map(\.text).joined(separator: "\n")) }.disabled(console.lines.isEmpty)
                    Button("Limpiar") { console.clear() }.disabled(console.lines.isEmpty)
                    Toggle("App intacta", isOn: $panel.plainLaunch).toggleStyle(.checkbox)
                        .help("Lanza la app sin nada de Saguru dentro (sin cámara ni red), para descartar que un cierre venga de Saguru")
                    Button(panel.agentAlive ? "Relanzar" : "Lanzar con registro") { launch() }.disabled(panel.app == nil)
                }
                .controlSize(.small)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                log
            }
        }
        .onAppear { console.unseen = false }
    }

    private func launch() {
        panel.launchWithAgent(plain: panel.plainLaunch) { failure in if let failure { panel.say(failure) } }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        panel.say("Copiado")
    }

    @ViewBuilder private var log: some View {
        if console.lines.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "terminal").font(.system(size: 30, weight: .light))
                Text(panel.agentAlive ? "La app aún no ha escrito nada" : "Lanza la app desde aquí para ver lo que escribe\ny, si se cierra, por qué")
                    .multilineTextAlignment(.center)
                if !panel.agentAlive {
                    Button("Lanzar \(panel.app?.name ?? "la app") con registro") { launch() }
                        .buttonStyle(PrimaryButtonStyle()).disabled(panel.app == nil)
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LogText(console: console, revision: console.revision, filter: filter, system: console.showSystem)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Why the app closed: the kind of failure, what the runtime said, and where it happened.
    private func card(_ crash: CrashReport) -> some View {
        let own = crash.frames.filter(\.own)
        let frames = wholeStack || own.isEmpty ? crash.frames : own
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Color(nsColor: .systemRed))
                Text("\(console.appName) se cerró").font(.headline)
                Text(crash.title).font(.callout.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button("Copiar") { copy(crash.text) }
                if let file = crash.file { Button("Ver informe") { NSWorkspace.shared.open(file) } }
            }
            .controlSize(.small)
            if !crash.reason.isEmpty {
                Text(crash.reason).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !frames.isEmpty {
                let list = VStack(alignment: .leading, spacing: 2) {
                    ForEach(frames.prefix(wholeStack ? 40 : 8)) { frame in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(frame.id)").frame(width: 20, alignment: .trailing).foregroundStyle(.tertiary)
                            Text(frame.symbol + (frame.place.isEmpty ? "" : "  · \(frame.place)")).foregroundStyle(frame.own ? .primary : .secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text(frame.image).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        .font(.system(size: 11, design: .monospaced))
                    }
                }
                // A long stack scrolls inside the card; a short one takes only the room it needs.
                if wholeStack && frames.count > 12 { ScrollView { list }.frame(height: 200) } else { list }
                Button(wholeStack ? "Solo el código de la app" : "Ver la pila completa") { wholeStack.toggle() }
                    .buttonStyle(.borderless).controlSize(.small)
            } else if console.waiting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Buscando el informe de macOS con la pila; en una app grande tarda hasta un minuto…")
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("macOS no dejó un informe con la pila para este cierre. Míralo en ~/Library/Logs/DiagnosticReports o en la app Consola › Informes de fallos.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !console.plain {
                Text("¿Es tu app o es Saguru? Marca «App intacta» y relanza: si sin Saguru dentro no se cierra, el fallo es nuestro y nos interesa el informe.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color(nsColor: .systemRed).opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .systemRed).opacity(0.35)))
    }
}

/// The log as one text view. A list of SwiftUI texts cannot keep up with a busy app; a text view takes
/// thousands of lines, and only the new ones are added each time.
struct LogText: NSViewRepresentable {
    let console: ConsoleModel
    let revision: Int
    let filter: String
    let system: Bool

    final class Coordinator {
        var last = 0            // id of the last line drawn
        var filter = ""
        var system = false
        var drawn = 0           // lines in the view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 8, height: 8)
            view.isAutomaticLinkDetectionEnabled = false
            view.layoutManager?.allowsNonContiguousLayout = true
        }
        return scroll
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static func color(_ kind: LogLine.Kind) -> NSColor {
        switch kind {
        case .output: return .labelColor
        case .error: return .systemOrange
        case .fault: return .systemRed
        case .system: return .secondaryLabelColor
        case .note: return .systemBlue
        }
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        let state = context.coordinator
        let lines = console.lines
        // Start over when what is shown changes shape: another filter, the log cleared or trimmed, a new launch.
        let restart = state.filter != filter || state.system != system || (lines.first?.id ?? 0) > state.last + 1 || lines.isEmpty || state.drawn > 9000
        let last = state.last
        let fresh: ArraySlice<LogLine> = restart ? lines.suffix(4000) : lines[(lines.lastIndex(where: { $0.id <= last }).map { $0 + 1 } ?? 0)...]
        let chosen = fresh.filter { (system || $0.kind != .system) && (filter.isEmpty || $0.text.localizedCaseInsensitiveContains(filter)) }
        guard restart || !chosen.isEmpty else { state.last = lines.last?.id ?? state.last; return }

        let visible = scroll.contentView.bounds
        let atEnd = restart || visible.maxY >= (view.frame.height - 24)
        let added = NSMutableAttributedString()
        for line in chosen {
            added.append(NSAttributedString(string: line.text + "\n", attributes: [.font: Self.font, .foregroundColor: Self.color(line.kind)]))
        }
        storage.beginEditing()
        if restart { storage.setAttributedString(added); state.drawn = chosen.count } else { storage.append(added); state.drawn += chosen.count }
        storage.endEditing()
        state.last = lines.last?.id ?? 0
        state.filter = filter
        state.system = system
        if atEnd { view.scrollToEndOfDocument(nil) }
    }
}
