import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Tool: String {
    case context, push, url, location, privacy, accessibility, data, overlay, grid
}

struct DefaultsEntry: Identifiable, Hashable {
    enum Kind: String { case string, bool, int, float, other }
    let key: String
    let kind: Kind
    let text: String
    var id: String { key }
}

/// State shared by the rail, its popovers and the design overlay.
final class PanelModel: ObservableObject {
    @Published var devices: [SimDevice] = []
    @Published var selected: String?
    @Published var apps: [SimApp] = []
    /// The app every app-specific action (push, permissions, app data) applies to. Chosen once, in the
    /// context popover, and remembered per simulator.
    @Published var appID = ""
    /// Whether iOS will show a notification sent to `appID`.
    @Published var pushPermission = Simctl.NotificationPermission.unknown
    /// Popover currently open, if any.
    @Published var openTool: Tool?
    /// Name of the button under the cursor (shown as a tooltip) and the last action's outcome.
    @Published var hint = ""
    @Published var status = ""
    @Published var cleanBar = false
    @Published var dropTargeted = false
    /// Whether macOS lets Simuru see which simulator its window shows (needs Accessibility).
    @Published var knowsWindowDevice = false

    // Accessibility
    @Published var contentSize = "large"
    @Published var increaseContrast = false

    // App data
    @Published var defaults: [DefaultsEntry] = []

    // Design tools
    @Published var overlayImage: NSImage?
    @Published var overlayVisible = true
    @Published var overlayOpacity = 0.5
    @Published var gridOn = false
    @Published var gridSpacing = 8.0
    @Published var measuring = false
    @Published var guides: [CGPoint] = []
    @Published var cursor: CGPoint?
    @Published var screenPoints = CGSize(width: 402, height: 874)

    private var statusToken = 0
    private let work = DispatchQueue(label: "simuru.work")

    var device: SimDevice? { devices.first { $0.udid == selected } }
    var app: SimApp? { apps.first { $0.bundleID == appID } }
    /// "SajaruBox en iPhone 17": where an app-specific action is about to land.
    var target: String {
        guard let device else { return "Ningún simulador arrancado" }
        return app.map { "\($0.name) en \(device.name)" } ?? "Elige una app · \(device.name)"
    }

    func chooseApp(_ bundleID: String) {
        appID = bundleID
        if let selected { UserDefaults.standard.set(bundleID, forKey: "app.\(selected)") }
        refreshPushPermission()
    }

    func refreshPushPermission() {
        guard let udid = selected, !appID.isEmpty else { pushPermission = .unknown; return }
        let bundleID = appID
        DispatchQueue.global(qos: .userInitiated).async {
            let permission = Simctl.notificationPermission(udid, bundleID: bundleID)
            DispatchQueue.main.async { if bundleID == self.appID { self.pushPermission = permission } }
        }
    }
    var needsOverlay: Bool { (overlayImage != nil && overlayVisible) || gridOn || measuring }

    // MARK: Devices

    func refreshDevices() {
        DispatchQueue.global(qos: .utility).async {
            let devices = Simctl.booted()
            DispatchQueue.main.async {
                if devices != self.devices { self.devices = devices }
                if self.device == nil { self.select(devices.first?.udid) }
            }
        }
    }

    func select(_ udid: String?) {
        guard udid != selected else { return }
        selected = udid
        cleanBar = false
        reloadApps()
        guard let device else { return }
        DispatchQueue.global(qos: .utility).async {
            let points = Simctl.screenPoints(device)
            DispatchQueue.main.async { if let points, device.udid == self.selected { self.screenPoints = points } }
        }
    }

    /// Selects the booted device whose name matches a Simulator window title ("iPhone 17 – iOS 26.0").
    func select(windowTitle: String) {
        let name = windowTitle.components(separatedBy: " – ").first ?? windowTitle
        if let match = devices.first(where: { $0.name == name }) { select(match.udid) }
    }

    func reloadApps() {
        guard let udid = selected else { apps = []; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = Simctl.apps(udid)
            DispatchQueue.main.async {
                guard udid == self.selected else { return }
                if apps != self.apps { self.apps = apps }
                // Keep the remembered app for this simulator; otherwise start on the first app of the user's.
                let remembered = UserDefaults.standard.string(forKey: "app.\(udid)") ?? self.appID
                let valid = apps.contains { $0.bundleID == remembered } ? remembered : (apps.first?.bundleID ?? "")
                if valid != self.appID { self.appID = valid }
                self.refreshPushPermission()
            }
        }
    }

    // MARK: Feedback

    func say(_ message: String) {
        status = message
        statusToken += 1
        let token = statusToken
        // Long messages (warnings) stay long enough to be read.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(2.5, Double(message.count) * 0.06)) {
            if token == self.statusToken { self.status = "" }
        }
    }

    /// Runs a simctl action off the main thread and reports the outcome.
    func perform(_ success: String, then: (() -> Void)? = nil, _ action: @escaping (SimDevice) throws -> Void) {
        guard let device else { return say("No hay ningún simulador arrancado") }
        work.async {
            do {
                try action(device)
                DispatchQueue.main.async {
                    self.say(success)
                    then?()
                }
            } catch {
                DispatchQueue.main.async { self.say("\(error)") }
            }
        }
    }

    // MARK: Inject

    func sendPush(payload: Data) {
        guard let device else { return say("No hay ningún simulador arrancado") }
        let bundleID = appID
        guard !bundleID.isEmpty else { return say("Elige una app primero") }
        work.async {
            let message: String
            do {
                let permission = try Simctl.push(device.udid, bundleID: bundleID, payload: payload)
                // Sent, but iOS drops it without notification permission: say so instead of "sent".
                message = permission.warning.map { "No se verá: \($0)" } ?? "Notificación enviada a \(device.name)"
            } catch {
                message = "\(error)"
            }
            DispatchQueue.main.async { self.say(message) }
        }
    }

    func addMedia(_ files: [URL]) {
        guard !files.isEmpty else { return }
        perform(files.count == 1 ? "1 archivo añadido a Fotos" : "\(files.count) archivos añadidos a Fotos") { device in
            try Simctl.addMedia(device.udid, files: files)
        }
    }

    func pickMedia() {
        pickFiles(types: [.image, .movie], multiple: true, prompt: "Añadir a Fotos") { self.addMedia($0) }
    }

    private func pickFiles(types: [UTType], multiple: Bool, prompt: String, done: @escaping ([URL]) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.allowedContentTypes = types
        panel.prompt = prompt
        panel.begin { response in
            if response == .OK { done(panel.urls) }
        }
    }

    func openURL(_ url: String) {
        perform("URL abierta") { try Simctl.openURL($0.udid, url) }
    }

    func setLocation(latitude: Double, longitude: Double) {
        perform("Ubicación establecida") { try Simctl.setLocation($0.udid, latitude: latitude, longitude: longitude) }
    }

    func clearLocation() {
        perform("Ubicación restablecida") { try Simctl.clearLocation($0.udid) }
    }

    func privacy(action: String, service: String, bundleID: String) {
        let done = ["grant": "Permiso concedido", "revoke": "Permiso revocado", "reset": "Permiso restablecido"][action] ?? "Hecho"
        perform(done) { try Simctl.privacy($0.udid, action: action, service: service, bundleID: bundleID) }
    }

    // MARK: Device look

    func toggleAppearance() {
        perform("Apariencia cambiada") { device in
            try Simctl.setAppearance(device.udid, Simctl.appearance(device.udid) == "dark" ? "light" : "dark")
        }
    }

    func toggleCleanBar() {
        let clean = !cleanBar
        cleanBar = clean
        perform(clean ? "Barra de estado limpia" : "Barra de estado restaurada") { device in
            try clean ? Simctl.cleanStatusBar(device.udid) : Simctl.resetStatusBar(device.udid)
        }
    }

    func loadAccessibility() {
        guard let udid = selected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let size = Simctl.contentSize(udid), contrast = Simctl.increaseContrast(udid)
            DispatchQueue.main.async {
                if Simctl.contentSizes.contains(size) { self.contentSize = size }
                self.increaseContrast = contrast
            }
        }
    }

    func setContentSize(_ size: String) {
        contentSize = size
        perform("Tamaño de texto cambiado") { try Simctl.setContentSize($0.udid, size) }
    }

    func setIncreaseContrast(_ on: Bool) {
        increaseContrast = on
        perform(on ? "Contraste aumentado" : "Contraste normal") { try Simctl.setIncreaseContrast($0.udid, on) }
    }

    // MARK: App data

    func openDataFolder(bundleID: String) {
        perform("Carpeta abierta en Finder") { device in
            let url = try Simctl.dataContainer(device.udid, bundleID: bundleID)
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }

    func relaunch(bundleID: String, language: String, region: String) {
        perform(language.isEmpty ? "App reiniciada" : "App reiniciada en «\(language)»") { device in
            try Simctl.relaunch(device.udid, bundleID: bundleID, language: language, region: region)
        }
    }

    func eraseData(bundleID: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "¿Borrar los datos de \(apps.first { $0.bundleID == bundleID }?.name ?? bundleID)?"
        alert.informativeText = "Se vacían Documents, Library y tmp de la app en este simulador. No se puede deshacer."
        alert.addButton(withTitle: "Borrar datos").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform("Datos borrados", then: { self.loadDefaults(bundleID: bundleID) }) { device in
            try Simctl.eraseData(device.udid, bundleID: bundleID)
        }
    }

    func loadDefaults(bundleID: String) {
        guard let udid = selected, !bundleID.isEmpty else { defaults = []; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = Simctl.defaults(udid, bundleID: bundleID).map { key, value -> DefaultsEntry in
                switch value {
                case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
                    return DefaultsEntry(key: key, kind: .bool, text: number.boolValue ? "true" : "false")
                case let number as NSNumber:
                    let isInt = CFNumberIsFloatType(number) == false
                    return DefaultsEntry(key: key, kind: isInt ? .int : .float, text: number.stringValue)
                case let string as String:
                    return DefaultsEntry(key: key, kind: .string, text: string)
                case let array as [Any]:
                    return DefaultsEntry(key: key, kind: .other, text: "Lista (\(array.count))")
                case let dictionary as [String: Any]:
                    return DefaultsEntry(key: key, kind: .other, text: "Diccionario (\(dictionary.count))")
                default:
                    return DefaultsEntry(key: key, kind: .other, text: "\(value)")
                }
            }.sorted { $0.key.lowercased() < $1.key.lowercased() }
            DispatchQueue.main.async { self.defaults = entries }
        }
    }

    func writeDefault(bundleID: String, key: String, kind: DefaultsEntry.Kind, value: String) {
        guard kind != .other, !key.isEmpty else { return }
        perform("Valor guardado", then: { self.loadDefaults(bundleID: bundleID) }) { device in
            try Simctl.writeDefault(device.udid, bundleID: bundleID, key: key, type: kind.rawValue, value: value)
        }
    }

    func deleteDefault(bundleID: String, key: String) {
        perform("Clave eliminada", then: { self.loadDefaults(bundleID: bundleID) }) { device in
            try Simctl.deleteDefault(device.udid, bundleID: bundleID, key: key)
        }
    }

    // MARK: Design tools

    /// Design tools need the exact screen rectangle, which macOS only gives with Accessibility access.
    func requireAccessibility() -> Bool {
        if SimulatorAX.trusted { return true }
        SimulatorAX.requestAccess()
        say("Permite Accesibilidad para Simuru y vuelve a intentarlo")
        return false
    }

    func pickOverlay() {
        guard requireAccessibility() else { return }
        pickFiles(types: [.image], multiple: false, prompt: "Superponer") { urls in
            if let url = urls.first { self.setOverlay(url) }
        }
    }

    func setOverlay(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return say("No se pudo leer la imagen") }
        overlayImage = image
        overlayVisible = true
        say("Diseño superpuesto")
    }

    func toggleGrid() {
        guard gridOn || requireAccessibility() else { return }
        gridOn.toggle()
    }

    func toggleMeasuring() {
        guard measuring || requireAccessibility() else { return }
        measuring.toggle()
        if !measuring { cursor = nil; guides = [] }
        say(measuring ? "⌥ fija una guía · pulsa Reglas otra vez para salir" : "Reglas desactivadas")
    }

    func pickColor() {
        NSColorSampler().show { color in
            guard let rgb = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X", Int(round(rgb.redComponent * 255)),
                             Int(round(rgb.greenComponent * 255)), Int(round(rgb.blueComponent * 255)))
            let swift = String(format: "Color(red: %.3f, green: %.3f, blue: %.3f) // %@",
                               rgb.redComponent, rgb.greenComponent, rgb.blueComponent, hex)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(swift, forType: .string)
            self.say("\(hex) copiado como Color de SwiftUI")
        }
    }
}
