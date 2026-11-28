import AppKit
import SwiftUI

// Android, over the cable. Everything here goes through `adb`, which treats an emulator and a phone
// plugged in the same way, so this works on both. The first tool is the log: pick a connected device and
// one of its apps, launch it, and watch its logcat with the reason when it crashes — the Android twin of
// the Registro tool for iOS. It needs no window, so a physical phone is fine.

struct AndroidDevice: Identifiable, Hashable {
    let serial: String
    let name: String
    /// True once the phone has accepted this Mac for USB debugging.
    let ready: Bool
    let emulator: Bool
    var id: String { serial }
}

struct AndroidApp: Identifiable, Hashable {
    let pkg: String
    var id: String { pkg }
    /// A short name from the package, for the list: "mx.diri" → "Diri".
    var name: String {
        let last = pkg.split(separator: ".").last.map(String.init) ?? pkg
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}

struct AndroidFacts: Equatable {
    var version = "—"
    var build = "—"
    var minSdk = "—"
    var targetSdk = "—"
    var debuggable = false
}

extension ADB {
    /// Serial of a device, needed before every command.
    static func on(_ serial: String, _ args: [String]) -> [String] { ["-s", serial] + args }

    /// Devices adb sees now: an emulator shows as "emulator-5554", a phone by its serial.
    static func devices() -> [AndroidDevice] {
        guard let text = output(["devices", "-l"]) else { return [] }
        var result: [AndroidDevice] = []
        for line in text.split(separator: "\n").dropFirst() {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { String($0) }
            guard parts.count >= 2, ["device", "unauthorized", "offline"].contains(parts[1]) else { continue }
            let serial = parts[0]
            let emulator = serial.hasPrefix("emulator-")
            var name = emulator ? "Emulador " + String(serial.dropFirst(9)) : serial
            if let field = parts.first(where: { $0.hasPrefix("model:") }) {
                name = String(field.dropFirst(6)).replacingOccurrences(of: "_", with: " ")
            }
            result.append(AndroidDevice(serial: serial, name: name, ready: parts[1] == "device", emulator: emulator))
        }
        return result
    }

    /// The device's third-party apps (not the ones that come with Android), by package, sorted.
    static func apps(_ serial: String) -> [AndroidApp] {
        guard let text = output(on(serial, ["shell", "pm", "list", "packages", "-3"])) else { return [] }
        return text.split(separator: "\n")
            .compactMap { $0.hasPrefix("package:") ? String($0.dropFirst(8)).trimmingCharacters(in: .whitespaces) : nil }
            .sorted().map(AndroidApp.init)
    }

    /// What `dumpsys` says about an installed app: version, build and whether it is debuggable.
    static func facts(_ serial: String, _ pkg: String) -> AndroidFacts {
        var facts = AndroidFacts()
        guard let text = output(on(serial, ["shell", "dumpsys", "package", pkg])) else { return facts }
        func value(_ key: String) -> String? {
            guard let range = text.range(of: key) else { return nil }
            return String(text[range.upperBound...].prefix { $0 != " " && $0 != "\n" && $0 != "\t" })
        }
        facts.version = value("versionName=") ?? "—"
        facts.build = value("versionCode=") ?? "—"
        facts.minSdk = value("minSdk=") ?? "—"
        facts.targetSdk = value("targetSdk=") ?? "—"
        facts.debuggable = text.contains("DEBUGGABLE")
        return facts
    }

    /// The running app's process id, or 0 if it is not running.
    static func pid(_ serial: String, _ pkg: String) -> Int32 {
        Int32(output(on(serial, ["shell", "pidof", pkg]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    /// Launches the app's main screen, the way the launcher does.
    static func launch(_ serial: String, _ pkg: String) {
        _ = output(on(serial, ["shell", "monkey", "-p", pkg, "-c", "android.intent.category.LAUNCHER", "1"]))
    }
}

/// Why an app crashed on Android, read from its logcat.
struct AndroidCrash: Equatable {
    var kind: String        // "Excepción no atrapada", "Señal nativa", "ANR"
    var reason: String      // the exception line, the signal, or the ANR reason
    var stack: [String]     // "at ..." lines of the Java/Kotlin stack
}

final class AndroidModel: ObservableObject {
    @Published var devices: [AndroidDevice] = []
    @Published var serial: String? { didSet { if serial != oldValue { chose() } } }
    @Published var apps: [AndroidApp] = []
    @Published var pkg = "" { didSet { if pkg != oldValue { chose() } } }
    @Published var facts = AndroidFacts()
    private(set) var lines: [LogLine] = []
    @Published private(set) var revision = 0
    @Published private(set) var crash: AndroidCrash?
    @Published var problem: String?
    @Published var running = false

    unowned let panel: PanelModel
    private let queue = DispatchQueue(label: "saguru.android")
    private var logcat: Process?
    private var rest = Data()
    private var count = 0
    private var appPid: Int32 = 0
    private var capturing = false
    private var dirty = false
    private var flusher: Timer?
    private static let limit = 6000

    var device: AndroidDevice? { devices.first { $0.serial == serial } }
    var app: AndroidApp? { apps.first { $0.pkg == pkg } }

    init(panel: PanelModel) {
        self.panel = panel
        flusher = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.dirty else { return }
            self.dirty = false
            self.revision += 1
        }
    }

    /// The panel hangs off a particular Android window: point the tool at that device. `emulator` says the
    /// window is an emulator (so an "emulator-…" serial), otherwise a phone's mirror. The title, when macOS
    /// gives it (only with Screen Recording), refines the choice when several of the same kind are connected.
    func focus(onWindow title: String, emulator: Bool) {
        queue.async {
            let devices = ADB.devices()
            var pick: String?
            // The emulator's title, if available, is "Android Emulator - <avd>:<port>".
            if emulator, let colon = title.lastIndex(of: ":") {
                let port = String(title[title.index(after: colon)...].prefix { $0.isNumber })
                if !port.isEmpty, devices.contains(where: { $0.serial == "emulator-\(port)" }) { pick = "emulator-\(port)" }
            }
            // A phone's mirror names the device in its title.
            if pick == nil, !emulator, !title.isEmpty {
                pick = devices.first { !$0.serial.hasPrefix("emulator-") && !$0.name.isEmpty && title.localizedCaseInsensitiveContains($0.name) }?.serial
            }
            // No title to go by: the kind alone picks it, as long as only one of that kind is connected.
            if pick == nil {
                let ofKind = devices.filter { $0.serial.hasPrefix("emulator-") == emulator }
                pick = ofKind.first { $0.ready }?.serial ?? ofKind.first?.serial
            }
            DispatchQueue.main.async {
                self.devices = devices
                if let pick, devices.contains(where: { $0.serial == pick }) {
                    if self.serial != pick { self.serial = pick }
                } else if self.serial == nil || !devices.contains(where: { $0.serial == self.serial }) {
                    self.serial = devices.first { $0.ready }?.serial ?? devices.first?.serial
                }
                self.problem = self.device?.ready == false ? tr("Acepta «Permitir depuración USB» en el teléfono.") : nil
            }
        }
    }

    /// Looks again for devices and, for the chosen one, its apps. Safe to call often.
    func reload() {
        if ADB.path == nil { problem = tr("No se encontró adb. Instala Android platform-tools."); return }
        queue.async {
            let devices = ADB.devices()
            DispatchQueue.main.async {
                self.devices = devices
                if self.serial == nil || !devices.contains(where: { $0.serial == self.serial }) {
                    self.serial = devices.first { $0.ready }?.serial ?? devices.first?.serial
                }
                self.problem = devices.isEmpty ? tr("Conecta un Android por USB (con la depuración USB aceptada) o arranca un emulador.")
                    : (self.device?.ready == false ? tr("Acepta «Permitir depuración USB» en el teléfono.") : self.problem)
            }
        }
    }

    private func chose() {
        guard let serial, device?.ready == true else { apps = []; facts = AndroidFacts(); return }
        let pkg = self.pkg
        queue.async {
            let apps = ADB.apps(serial)
            let facts = pkg.isEmpty ? AndroidFacts() : ADB.facts(serial, pkg)
            DispatchQueue.main.async {
                self.apps = apps
                if !pkg.isEmpty, !apps.contains(where: { $0.pkg == pkg }) { self.pkg = "" }
                else { self.facts = facts }
            }
        }
    }

    func choose(_ app: AndroidApp) {
        pkg = app.pkg
        UserDefaults.standard.set(app.pkg, forKey: "android.app.\(serial ?? "")")
    }

    // MARK: The log

    /// Launches the app with a clean log and follows it.
    func launchWithLog() {
        guard let serial, let pkg = app?.pkg else { return }
        stop()
        lines = []
        crash = nil
        problem = nil
        appPid = 0
        count = 0
        dirty = true
        queue.async {
            _ = ADB.output(ADB.on(serial, ["logcat", "-c"]))
            ADB.launch(serial, pkg)
            // The process takes a moment to appear.
            var pid: Int32 = 0
            for _ in 0..<20 { pid = ADB.pid(serial, pkg); if pid != 0 { break }; Thread.sleep(forTimeInterval: 0.15) }
            DispatchQueue.main.async { self.appPid = pid; self.running = true; self.add(tr("%@ lanzada · proceso %@", "\(pkg)", "\(pid)"), .note) }
            self.follow(serial: serial, pkg: pkg)
        }
    }

    /// Follows the whole log and keeps the lines that belong to the app, plus any crash it causes.
    private func follow(serial: String, pkg: String) {
        guard let process = ADB.process(ADB.on(serial, ["logcat", "-v", "threadtime"])) else { return }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { self?.read(data, pkg: pkg) }
        }
        try? process.run()
        logcat = process
        // The pid can change if the app restarts; check it now and then.
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refreshPid(serial: serial, pkg: pkg) }
    }

    private func refreshPid(serial: String, pkg: String) {
        guard logcat != nil else { return }
        let pid = ADB.pid(serial, pkg)
        if pid != 0, pid != appPid { DispatchQueue.main.async { self.appPid = pid } }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refreshPid(serial: serial, pkg: pkg) }
    }

    // threadtime: "11-27 10:00:00.000  1234  1234 E Tag: message"
    private static let row = try! NSRegularExpression(pattern: #"^\d\d-\d\d \d\d:\d\d:\d\d\.\d\d\d\s+(\d+)\s+\d+\s+([VDIWEF])\s+([^:]*?):\s?(.*)$"#)

    private func read(_ data: Data, pkg: String) {
        var all = rest + data
        while let newline = all.firstIndex(of: 0x0A) {
            let text = String(decoding: all[all.startIndex..<newline], as: UTF8.self)
            all = all[all.index(after: newline)...]
            line(text, pkg: pkg)
        }
        rest = Data(all)
    }

    private func line(_ text: String, pkg: String) {
        guard let m = Self.row.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            // A continuation (an exception stack): belongs to the line before if we are capturing.
            if capturing, let r = Range(NSRange(location: 0, length: 0), in: text) { _ = r }
            if capturing { addStack(text.trimmingCharacters(in: .whitespaces)) }
            return
        }
        func field(_ i: Int) -> String { Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
        let pid = Int32(field(1)) ?? 0, level = field(2), tag = field(3).trimmingCharacters(in: .whitespaces), message = field(4)

        // A Java/Kotlin crash: AndroidRuntime logs it, starting with FATAL EXCEPTION.
        if tag == "AndroidRuntime", level == "E" {
            if message.hasPrefix("FATAL EXCEPTION") {
                capturing = true
                crash = AndroidCrash(kind: tr("Excepción no atrapada"), reason: "", stack: [])
                add(message, .fault)
                return
            }
            if capturing {
                if message.hasPrefix("Process:") { add(message, .fault); return }
                if crash?.reason.isEmpty == true, !message.isEmpty { crash?.reason = message }
                addStack(message)
                add(message, .fault)
                return
            }
        }
        // A chatty app logs between the crash lines, so the block is NOT ended by other tags: only the
        // AndroidRuntime lines above build it, and addStack caps how much is kept.

        // A native crash and an ANR are logged by the system, not by the app's own process.
        if tag == "libc", message.contains("Fatal signal") {
            crash = AndroidCrash(kind: tr("Señal nativa"), reason: message, stack: [])
            add(message, .fault); return
        }
        if tag == "ActivityManager", message.hasPrefix("ANR in \(pkg)") {
            crash = AndroidCrash(kind: "ANR", reason: message, stack: [])
            add(message, .fault); return
        }

        // Otherwise, keep what the chosen app itself logged.
        guard pid == appPid, appPid != 0 else { return }
        let kind: LogLine.Kind = level == "E" || level == "F" ? .error : (level == "W" ? .error : .output)
        add("\(level)  \(tag): \(message)", kind)
    }

    private func addStack(_ text: String) {
        guard var crash else { return }
        if text.hasPrefix("at ") || text.hasPrefix("Caused by") || text.hasPrefix("... ") {
            if crash.stack.count < 60 { crash.stack.append(text) }
            self.crash = crash
        }
    }

    private func add(_ text: String, _ kind: LogLine.Kind) {
        count += 1
        lines.append(LogLine(id: count, text: text, kind: kind))
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit + 500) }
        dirty = true
    }

    func clear() { lines = []; count = 0; dirty = true }

    func stop() {
        logcat?.terminate()
        logcat = nil
        rest = Data()
        capturing = false
        running = false
    }

    deinit { stop() }
}

// MARK: - View

struct AndroidForm: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var android: AndroidModel
    @State private var filter = ""
    @State private var search = ""
    @State private var wholeStack = false

    private var visibleLines: [LogLine] {
        filter.isEmpty ? android.lines : android.lines.filter { $0.text.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        FormBox(title: "Android", device: android.device?.name ?? tr("Ningún Android conectado"), symbol: "candybarphone") {
            VStack(alignment: .leading, spacing: 12) {
                if let problem = android.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.callout)
                        .foregroundStyle(Color(nsColor: .systemOrange)).fixedSize(horizontal: false, vertical: true)
                }
                if android.app == nil {
                    chooser
                } else {
                    header
                    if let crash = android.crash { card(crash) }
                    controls
                    log
                }
            }
        }
        .onAppear { android.reload() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in if android.app == nil { android.reload() } }
    }

    // MARK: Choosing a device and an app

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            if android.devices.count > 1 {
                Picker(tr("Dispositivo"), selection: Binding(get: { android.serial ?? "" }, set: { android.serial = $0 })) {
                    ForEach(android.devices) { Text($0.name).tag($0.serial) }
                }
                .pickerStyle(.menu).labelsHidden().frame(maxWidth: 260)
            }
            if android.device?.ready == true {
                Text("Elige la app que quieres seguir").font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(tr("Buscar app"), text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(android.apps.filter { search.isEmpty || $0.pkg.localizedCaseInsensitiveContains(search) }) { app in
                            Button { android.choose(app) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "shippingbox").foregroundStyle(.secondary).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(app.name).lineLimit(1)
                                        Text(app.pkg).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: The app's log

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill").font(.system(size: 16)).frame(width: 36, height: 36)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(android.app?.name ?? "").font(.title3.weight(.semibold))
                Text(android.app?.pkg ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(tr("Versión %@ · build %@", "\(android.facts.version)", "\(android.facts.build)")).font(.caption)
                Text(tr("SDK mín. %@ · objetivo %@", "\(android.facts.minSdk)", "\(android.facts.targetSdk)")).font(.caption).foregroundStyle(.secondary)
            }
            Button(tr("Cambiar")) { android.pkg = "" }.controlSize(.small)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            TextField(tr("Filtrar"), text: $filter).textFieldStyle(.plain)
            Button(tr("Copiar")) { copy(visibleLines.map(\.text).joined(separator: "\n")) }.disabled(android.lines.isEmpty)
            Button(tr("Limpiar")) { android.clear() }.disabled(android.lines.isEmpty)
            Button(android.running ? tr("Relanzar") : tr("Lanzar con registro")) { android.launchWithLog() }
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder private var log: some View {
        if android.lines.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "candybarphone").font(.system(size: 30, weight: .light))
                Text("Lanza la app desde aquí para ver su registro\ny, si se cierra, por qué").multilineTextAlignment(.center)
                Button(tr("Lanzar %@ con registro", "\(android.app?.name ?? "")")) { android.launchWithLog() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LogText(lines: android.lines, revision: android.revision, filter: filter)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func card(_ crash: AndroidCrash) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Color(nsColor: .systemRed))
                Text(tr("%@ se cerró", "\(android.app?.name ?? "")")).font(.headline)
                Text(crash.kind).font(.callout.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Copiar")) { copy(([crash.kind, crash.reason] + crash.stack).joined(separator: "\n")) }.controlSize(.small)
            }
            if !crash.reason.isEmpty {
                Text(crash.reason).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !crash.stack.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(crash.stack.prefix(wholeStack ? 60 : 6).enumerated()), id: \.offset) { _, frame in
                            Text(frame).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: wholeStack ? 220 : 110)
                if crash.stack.count > 6 {
                    Button(wholeStack ? tr("Menos") : tr("Ver la pila completa")) { wholeStack.toggle() }
                        .buttonStyle(.borderless).controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .systemRed).opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .systemRed).opacity(0.35)))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.say("Copiado")
    }
}
