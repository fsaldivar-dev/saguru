import AppKit
import SwiftUI

// The app's console. An app launched from Xcode prints there; launched any other way, what it prints is
// lost, and when it closes nobody says why. Saguru keeps both: it launches the app with its output sent to
// two files, follows the system log for that process, and when the process ends it looks for the crash
// report macOS writes and reads the reason and the stack out of it.

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
    @Published private(set) var lines: [LogLine] = []
    @Published private(set) var crash: CrashReport?
    /// The app closed with an error and the tool has not been opened since.
    @Published var unseen = false
    /// Everything the system logs for the process, not only what the app prints and its errors.
    @Published var showSystem = false
    @Published private(set) var appName = ""

    unowned let panel: PanelModel
    private var folder: URL?
    private var readers: [(handle: FileHandle, kind: LogLine.Kind, rest: Data)] = []
    private var timer: Timer?
    private var stream: Process?
    private var streamRest = Data()
    private var count = 0
    private var launchedAt = Date()
    private var pid: Int32 = 0
    private static let limit = 6000

    init(panel: PanelModel) { self.panel = panel }

    var shown: [LogLine] { showSystem ? lines : lines.filter { $0.kind != .system } }

    /// Before a launch: the two files the app's output will go to.
    func beginSession() -> (output: String, error: String) {
        stop()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("saguru-log/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("stdout.log"), error = folder.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: error.path, contents: nil)
        self.folder = folder
        lines = []
        crash = nil
        unseen = false
        count = 0
        return (output.path, error.path)
    }

    /// The app is running: follow its two files and the system log for its process.
    func launched(pid: Int32, udid: String, name: String) {
        guard let folder else { return }
        self.pid = pid
        appName = name
        launchedAt = Date()
        readers = [("stdout.log", LogLine.Kind.output), ("stderr.log", .error)].compactMap { file, kind in
            (try? FileHandle(forReadingFrom: folder.appendingPathComponent(file))).map { ($0, kind, Data()) }
        }
        add("\(name) lanzada por Saguru · proceso \(pid)", .note)
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in self?.readFiles() }

        let process = Simctl.process(["spawn", udid, "log", "stream", "--style", "compact", "--level", "debug", "--predicate", "processIdentifier == \(pid)"])
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.readSystem(data) }
        }
        try? process.run()
        stream = process
    }

    /// The process is gone. A crash report takes a moment to be written, so it is looked for a few times.
    func appEnded() {
        guard pid != 0 else { return }
        readFiles()
        let ended = pid, name = appName
        pid = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.stopStream() }
        var tries = 0
        func look() {
            tries += 1
            if let report = Self.report(for: ended, since: launchedAt) ?? (tries >= 6 ? fallback() : nil) {
                crash = report
                unseen = panel.openTool != .console
                add("\(name) se cerró: \(report.title)", .fault)
                panel.say("\(name) se cerró: \(report.reason.isEmpty ? report.title : String(report.reason.prefix(90))). Míralo en Registro")
            } else if tries < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { look() }
            } else {
                add("\(name) terminó sin informe de error (la cerraste tú, el sistema u otra herramienta)", .note)
            }
        }
        look()
    }

    /// With no report, a Swift runtime failure still leaves its own line in what the app printed.
    private func fallback() -> CrashReport? {
        guard let fatal = lines.last(where: { $0.kind == .error && ($0.text.contains("Fatal error") || $0.text.contains("Terminating app") || $0.text.contains("Thread 1: ")) }) else { return nil }
        return CrashReport(title: "Error fatal", reason: fatal.text, frames: [], file: nil)
    }

    func clear() { lines = []; count = 0 }

    private func stop() {
        timer?.invalidate(); timer = nil
        readers.forEach { try? $0.handle.close() }
        readers = []
        stopStream()
        pid = 0
    }

    private func stopStream() {
        stream?.terminate()
        stream = nil
        streamRest = Data()
    }

    private func add(_ text: String, _ kind: LogLine.Kind) {
        count += 1
        lines.append(LogLine(id: count, text: text, kind: kind))
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
    }

    private func readFiles() {
        for index in readers.indices {
            guard let data = try? readers[index].handle.readToEnd(), !data.isEmpty else { continue }
            var all = readers[index].rest + data
            while let newline = all.firstIndex(of: 0x0A) {
                let text = String(decoding: all[all.startIndex..<newline], as: UTF8.self)
                if !text.isEmpty { add(text, readers[index].kind) }
                all = all[all.index(after: newline)...]
            }
            readers[index].rest = Data(all)
        }
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

    private var visible: [LogLine] {
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
                    Button("Copiar") { copy(visible.map(\.text).joined(separator: "\n")) }.disabled(visible.isEmpty)
                    Button("Limpiar") { console.clear() }.disabled(console.lines.isEmpty)
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
        panel.launchWithAgent { failure in if let failure { panel.say(failure) } }
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visible) { line in
                            Text(line.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(color(line.kind))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id(line.id)
                        }
                    }
                    .padding(10)
                }
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onChange(of: console.lines.last?.id) { last in if let last { proxy.scrollTo(last, anchor: .bottom) } }
                .onAppear { if let last = visible.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func color(_ kind: LogLine.Kind) -> Color {
        switch kind {
        case .output: return .primary
        case .error: return Color(nsColor: .systemOrange)
        case .fault: return Color(nsColor: .systemRed)
        case .system: return .secondary
        case .note: return Color(nsColor: .systemBlue)
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
            }
        }
        .padding(12)
        .background(Color(nsColor: .systemRed).opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .systemRed).opacity(0.35)))
    }
}
