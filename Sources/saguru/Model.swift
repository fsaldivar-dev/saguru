import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Tool: String {
    case context, push, gallery, camera, url, location, privacy, appearance, statusBar, accessibility, data, network, console, grid, colors
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
    @Published var openTool: Tool? {
        didSet { if let openTool { lastTool = openTool } }
    }
    /// What the panel shows when it is unfolded again.
    var lastTool = Tool.context

    /// Opens the panel: on the app chooser until there is an app (and the permission it needs), then where it was left.
    func unfold() {
        openTool = app == nil || !SimulatorAX.trusted ? .context : lastTool
    }
    /// Name of the button under the cursor (shown as a tooltip) and the last action's outcome.
    @Published var hint = ""
    @Published var status = ""
    @Published var cleanBar = false
    @Published var dropTargeted = false
    /// Whether macOS lets Saguru see which simulator its window shows (needs Accessibility).
    @Published var knowsWindowDevice = false

    // Accessibility
    @Published var contentSize = "large"
    @Published var increaseContrast = false

    // App data
    @Published var defaults: [DefaultsEntry] = []

    // Design tools
    @Published var gridOn = false
    @Published var gridSpacing = 8.0
    @Published var measuring = false
    @Published var guides: [CGPoint] = []
    @Published var cursor: CGPoint?
    @Published var screenPoints = CGSize(width: 402, height: 874)

    private var statusToken = 0
    private let work = DispatchQueue(label: "saguru.work")

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
    var needsOverlay: Bool { gridOn || measuring || split != nil || !axMarks.isEmpty }

    /// Layout grid: number of columns (0 = none), side margin and space between columns, in points.
    @Published var gridColumns = UserDefaults.standard.integer(forKey: "grid.columns") {
        didSet { UserDefaults.standard.set(gridColumns, forKey: "grid.columns") }
    }
    @Published var gridMargin = UserDefaults.standard.object(forKey: "grid.margin") as? Double ?? 16 {
        didSet { UserDefaults.standard.set(gridMargin, forKey: "grid.margin") }
    }
    @Published var gridGutter = UserDefaults.standard.object(forKey: "grid.gutter") as? Double ?? 8 {
        didSet { UserDefaults.standard.set(gridGutter, forKey: "grid.gutter") }
    }
    /// The elements' boxes and measurements the grid draws over the screen.
    @Published var gridMarks: [AXMark] = []
    private(set) lazy var grid = GridModel(panel: self)
    private(set) lazy var palette = PaletteModel(panel: self)

    /// Accessibility inspector: its state, the rectangles it draws over the screen, and where the
    /// Simulator window is (top-left coordinates), which the panel controller keeps up to date.
    private(set) lazy var inspector = InspectorModel(panel: self)
    /// The app-data browser's state.
    private(set) lazy var data = DataModel(panel: self)
    /// The network monitor lives in a window of its own; this is whether it is open.
    @Published var networkOpen = false
    private(set) lazy var network = NetworkModel(panel: self)
    private(set) lazy var camera = CameraModel(panel: self)
    private(set) lazy var console = ConsoleModel(panel: self)

    /// The app instance Saguru launched with its agent inside.
    struct AgentRun: Equatable {
        let key: String
        let pid: Int32
        let camera: Bool
    }

    @Published private(set) var agentRun: AgentRun?

    /// The chosen app is the instance Saguru launched, and it is still running.
    var agentAlive: Bool {
        guard let run = agentRun, let udid = selected, run.key == "\(udid)|\(appID)" else { return false }
        return kill(run.pid, 0) == 0
    }

    /// The one way Saguru launches an app with its agent. Whichever tool asks, the app gets everything that
    /// needs to be there from launch: the network is always reported, and the camera is in it if it was asked
    /// for. So turning on one tool never takes another away.
    func launchWithAgent(arguments: [String] = [], completion: ((String?) -> Void)? = nil) {
        guard let udid = selected, !appID.isEmpty else { completion?("Elige una app."); return }
        let bundleID = appID, key = "\(udid)|\(bundleID)"
        var environment = ["SAGURU_NET_FOLDER": network.beginSession(for: key).path]
        let cameraFolder = camera.folderForLaunch(of: key)
        if let cameraFolder { environment["SAGURU_CAM_FOLDER"] = cameraFolder.path }
        // What the app prints is kept, so it is not lost for want of Xcode's console.
        let console = self.console
        let session = console.beginSession()
        let name = app?.name ?? bundleID
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AgentLauncher.launch(udid: udid, bundleID: bundleID, environment: environment, arguments: arguments,
                                              output: { data in DispatchQueue.main.async { console.receive(data, session: session) } },
                                              ended: { DispatchQueue.main.async { self.checkAgent() } })
            DispatchQueue.main.async {
                if let pid = result.pid, result.failure == nil {
                    self.agentRun = AgentRun(key: key, pid: pid, camera: cameraFolder != nil)
                    self.camera.launched(key, camera: cameraFolder != nil)
                    self.console.launched(pid: pid, udid: udid, name: name)
                } else {
                    self.agentRun = nil
                }
                completion?(result.failure ?? (result.pid == nil ? "No se pudo saber si la app arrancó." : nil))
            }
        }
    }

    /// Called every second: an app closed, or launched again from Xcode or the home screen, has no agent any more.
    func checkAgent() {
        guard let run = agentRun, kill(run.pid, 0) != 0 else { return }
        agentRun = nil
        network.agentWentAway()
        camera.agentWentAway()
        console.appEnded()
    }

    @Published var axMarks: [AXMark] = []
    var simulatorWindow: CGRect?

    // Split view: a picture over one side of the screen, with a divider to drag.
    enum Split { case appearance }
    /// What is being compared with the live app, if anything.
    @Published var split: Split?
    /// Where the divider is, from 0 (left edge) to 1 (right edge). The picture covers the left side.
    @Published var splitPosition = 0.5
    /// The app in the other appearance: a still picture, since a device has one appearance at a time.
    @Published var splitImage: NSImage?
    /// Names of the two sides, picture first ("Oscuro", "Claro").
    @Published var splitLabels = ("", "")
    @Published var capturing = false
    /// Width of the device screen on this Mac, so a drag in points becomes a fraction.
    var splitWidth: CGFloat = 1
    @Published var appearance = "light"

    var splitPicture: NSImage? {
        switch split {
        case .appearance: return splitImage
        case nil: return nil
        }
    }

    /// Puts back the appearance of any simulator that a previous run left switched mid-comparison.
    func restoreInterruptedAppearances() {
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix("restoreAppearance.") {
            guard let appearance = value as? String else { continue }
            let udid = String(key.dropFirst("restoreAppearance.".count))
            UserDefaults.standard.removeObject(forKey: key)
            DispatchQueue.global(qos: .userInitiated).async { try? Simctl.setAppearance(udid, appearance) }
        }
    }

    func loadAppearance() {
        guard let udid = selected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let value = Simctl.appearance(udid)
            DispatchQueue.main.async { if udid == self.selected, value != self.appearance { self.appearance = value } }
        }
    }

    func setAppearance(_ value: String) {
        appearance = value
        // While comparing, the watcher sees the screen change and retakes the picture by itself.
        splitQueue.async { self.liveAppearance = value }
        perform(value == "dark" ? "Apariencia oscura" : "Apariencia clara") { try Simctl.setAppearance($0.udid, value) }
    }

    /// The live side, held still while the simulator is briefly in the other appearance, so that the
    /// switch back and forth is not seen.
    @Published var freezeImage: NSImage?

    private let splitQueue = DispatchQueue(label: "saguru.split")
    private var splitTimer: DispatchSourceTimer?
    /// Whether the comparison is on. Main thread only; a retake in flight checks it before showing anything.
    private var comparing = false
    // Only touched on `splitQueue`:
    private var lastLook: [UInt8]?
    private var changed = false
    /// The appearance the simulator is in while comparing, so it is not asked on every retake.
    private var liveAppearance = "light"

    /// Compares light and dark: shows the other appearance over the left side of the screen and keeps
    /// it up to date as the app is used.
    func toggleAppearanceSplit() {
        if split == .appearance || capturing { return stopAppearanceSplit() }
        guard requireAccessibility(), let udid = selected else { return }
        capturing = true
        comparing = true
        splitQueue.async {
            self.lastLook = nil
            self.changed = false
            self.liveAppearance = Simctl.appearance(udid)
            self.retake(udid, current: try? Simctl.screenshot(udid))
            let timer = DispatchSource.makeTimerSource(queue: self.splitQueue)
            // A look is a screenshot, about 0.4 s of work: they run one after another, with no idle wait,
            // so a screen that stopped moving is noticed as soon as two looks in a row agree.
            timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
            timer.setEventHandler { [weak self] in self?.look(udid) }
            timer.resume()
            self.splitTimer = timer
        }
    }

    func stopAppearanceSplit() {
        comparing = false
        split = nil
        splitImage = nil
        freezeImage = nil
        capturing = false
        splitQueue.async {
            self.splitTimer?.cancel()
            self.splitTimer = nil
        }
    }

    /// One look at the simulator. When the screen changes and then holds still, the other side is retaken.
    private func look(_ udid: String) {
        guard let png = try? Simctl.screenshot(udid), let now = Self.look(png) else { return }
        guard let last = lastLook else { lastLook = now; return }
        if Self.differ(now, last) {
            // Still moving (a scroll, a transition): wait for it to settle.
            lastLook = now
            changed = true
        } else if changed {
            changed = false
            retake(udid, current: png)
        }
    }

    /// Switches the simulator to the other appearance for a moment, photographs it and switches back.
    private func retake(_ udid: String, current png: Data?) {
        DispatchQueue.main.sync {
            self.capturing = true
            // Cover the live side with its own picture while the simulator is in the other appearance.
            if self.comparing, self.split == .appearance { self.freezeImage = png.flatMap(NSImage.init(data:)) }
        }
        var picture: NSImage?
        var names = ("", "")
        var failure: String?
        do {
            let current = liveAppearance
            let other = current == "dark" ? "light" : "dark"
            // If Saguru dies in the next second the simulator would be left in the wrong appearance:
            // note what to put back, so the next launch can do it.
            UserDefaults.standard.set(current, forKey: "restoreAppearance.\(udid)")
            defer { UserDefaults.standard.removeObject(forKey: "restoreAppearance.\(udid)") }
            try Simctl.setAppearance(udid, other)
            // The app animates the change; photograph it once it has settled.
            Thread.sleep(forTimeInterval: 0.4)
            let shot = try Simctl.screenshot(udid)
            try Simctl.setAppearance(udid, current)
            Thread.sleep(forTimeInterval: 0.35)
            picture = NSImage(data: shot)
            names = (other == "dark" ? "Oscuro" : "Claro", current == "dark" ? "Oscuro" : "Claro")
        } catch {
            failure = "\(error)"
        }
        // The next look, taken once the switch back has finished animating, becomes the baseline:
        // only what changes from then on counts. (Comparing with a look from before the retake would
        // mistake the tail of that animation for a change and retake again.)
        lastLook = nil
        changed = false
        DispatchQueue.main.sync {
            self.capturing = false
            self.freezeImage = nil
            // Stopped while this was running: leave everything off.
            guard self.comparing else { return }
            if let picture {
                self.splitImage = picture
                self.splitLabels = names
                self.split = .appearance
            } else {
                self.say(failure ?? "No se pudo capturar la pantalla")
            }
        }
    }

    /// A tiny grey copy of a screenshot, to tell whether the screen changed. The status bar is left out:
    /// its clock changes by itself.
    private static func look(_ png: Data) -> [UInt8]? {
        guard let image = NSImage(data: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = 30, height = 60
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Rows are stored top first; drop the top 7 % (status bar).
        return Array(pixels[(width * 4)...])
    }

    private static func differ(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return true }
        var different = 0
        for index in a.indices where abs(Int(a[index]) - Int(b[index])) > 10 { different += 1 }
        return different > a.count / 200
    }

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
        if split == .appearance || capturing { stopAppearanceSplit() }
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

    var galleryOpen: Bool {
        get { openTool == .gallery }
        set { if newValue { openTool = .gallery } else if openTool == .gallery { openTool = nil } }
    }
    /// The gallery's contents; kept here so they survive closing and reopening its popover.
    private(set) lazy var gallery = GalleryModel(panel: self)

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

    // MARK: Deep links

    /// What the active app declares (schemes and domains).
    @Published var links = Simctl.AppLinks()
    /// Deep links saved and recently opened for the active app.
    @Published var favoriteLinks: [String] = []
    @Published var recentLinks: [String] = []

    func loadLinks() {
        let bundleID = appID
        favoriteLinks = UserDefaults.standard.stringArray(forKey: "links.favorites.\(bundleID)") ?? []
        recentLinks = UserDefaults.standard.stringArray(forKey: "links.recent.\(bundleID)") ?? []
        guard let app else { links = Simctl.AppLinks(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let links = Simctl.links(of: app)
            DispatchQueue.main.async { if bundleID == self.appID { self.links = links } }
        }
    }

    func setFavorite(_ url: String, _ on: Bool) {
        favoriteLinks.removeAll { $0 == url }
        if on { favoriteLinks.insert(url, at: 0) }
        UserDefaults.standard.set(favoriteLinks, forKey: "links.favorites.\(appID)")
    }

    func forgetRecent(_ url: String) {
        recentLinks.removeAll { $0 == url }
        UserDefaults.standard.set(recentLinks, forKey: "links.recent.\(appID)")
    }

    func openURL(_ raw: String) {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let bundleID = appID
        perform("Enlace abierto", then: {
            // Only links that did open are worth remembering.
            guard bundleID == self.appID else { return }
            self.recentLinks.removeAll { $0 == url }
            self.recentLinks.insert(url, at: 0)
            self.recentLinks = Array(self.recentLinks.prefix(8))
            UserDefaults.standard.set(self.recentLinks, forKey: "links.recent.\(bundleID)")
        }) { try Simctl.openURL($0.udid, url) }
    }

    /// What each simulator was last told to simulate, as text. The simulator cannot be asked, so this is
    /// only what Saguru itself set during this session.
    @Published var simulatedLocations: [String: String] = [:]

    func setLocation(latitude: Double, longitude: Double) {
        let udid = selected
        let text = String(format: "%.5f, %.5f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
        perform("Ubicación establecida", then: { if let udid { self.simulatedLocations[udid] = text } }) {
            try Simctl.setLocation($0.udid, latitude: latitude, longitude: longitude)
        }
    }

    func clearLocation() {
        let udid = selected
        perform("Ubicación restablecida", then: { if let udid { self.simulatedLocations[udid] = nil } }) {
            try Simctl.clearLocation($0.udid)
        }
    }

    // MARK: Permissions

    /// What the active app holds right now, read from the simulator.
    @Published var permissions: [Permission: Permission.Choice] = [:]

    /// What the active app declares in its Info.plist.
    @Published var declared = DeclaredPermissions()

    func loadPermissions() {
        guard let udid = selected, !appID.isEmpty else { permissions = [:]; declared = DeclaredPermissions(); return }
        let bundleID = appID
        let declared = app.map(DeclaredPermissions.init) ?? DeclaredPermissions()
        if declared != self.declared { self.declared = declared }
        DispatchQueue.global(qos: .userInitiated).async {
            let permissions = Simctl.permissions(udid, bundleID: bundleID)
            DispatchQueue.main.async {
                if bundleID == self.appID, permissions != self.permissions { self.permissions = permissions }
            }
        }
        refreshPushPermission()
    }

    func setPermission(_ permission: Permission, to choice: Permission.Choice) {
        let bundleID = appID
        // Show the choice at once; the reload afterwards says what the simulator really did.
        permissions[permission] = choice
        perform("\(permission.name): \(permission.label(choice).lowercased())", then: { self.loadPermissions() }) { device in
            try Simctl.setPermission(device.udid, bundleID: bundleID, permission, to: choice)
        }
    }

    func resetPermissions() {
        let bundleID = appID
        perform("Permisos restablecidos", then: { self.loadPermissions() }) { device in
            try Simctl.resetPermissions(device.udid, bundleID: bundleID)
        }
    }

    // MARK: Device look

    func toggleAppearance() {
        perform("Apariencia cambiada") { device in
            try Simctl.setAppearance(device.udid, Simctl.appearance(device.udid) == "dark" ? "light" : "dark")
        }
    }

    /// The status bar to show while it is overridden (`cleanBar`). Remembered between launches.
    @Published var statusBar: Simctl.StatusBar = {
        let saved = UserDefaults.standard.data(forKey: "statusBar")
        return saved.flatMap { try? JSONDecoder().decode(Simctl.StatusBar.self, from: $0) } ?? .catalog
    }() {
        // Applied from here rather than from the form, so it does not depend on the form being on screen.
        didSet { if statusBar != oldValue { applyStatusBar() } }
    }

    private var statusBarToken = 0

    /// Turning the override on or off is sent at once and is never dropped in favour of a later edit.
    func setStatusBar(on: Bool) {
        cleanBar = on
        statusBarToken += 1
        send(announce: true)
    }

    /// An edit to the chosen status bar. Sent once the edits pause, so typing the time or dragging the
    /// battery does not send every step.
    func applyStatusBar() {
        UserDefaults.standard.set(try? JSONEncoder().encode(statusBar), forKey: "statusBar")
        guard cleanBar else { return }
        statusBarToken += 1
        let token = statusBarToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if token == self.statusBarToken, self.cleanBar { self.send(announce: false) }
        }
    }

    private func send(announce: Bool) {
        guard let device else { return }
        let on = cleanBar, bar = statusBar
        work.async {
            do {
                try on ? Simctl.overrideStatusBar(device.udid, bar) : Simctl.resetStatusBar(device.udid)
                if announce { DispatchQueue.main.async { self.say(on ? "Barra de estado personalizada" : "Barra de estado restaurada") } }
            } catch {
                DispatchQueue.main.async { self.say("\(error)") }
            }
        }
    }

    /// The Simulator's Debug › Slow Animations.
    @Published var slowAnimations = SlowAnimations.isOn

    func setSlowAnimations(_ on: Bool) {
        guard requireAccessibility() else { return }
        slowAnimations = on
        SlowAnimations.set(on) { worked in
            self.slowAnimations = SlowAnimations.isOn
            self.say(worked ? (on ? "Animaciones lentas" : "Animaciones a velocidad normal")
                            : "No se pudo cambiar: la ventana del Simulador tiene que estar a la vista")
        }
    }

    /// The simulator's accessibility switches (see `AXSetting`), by preference key.
    @Published var axSettings: [String: Bool] = [:]

    func setAccessibility(_ setting: AXSetting, on: Bool) {
        axSettings[setting.key] = on
        perform("\(setting.name): \(on ? "activado" : "desactivado")") { try Simctl.setAccessibility($0.udid, setting, on: on) }
    }

    func loadAccessibility() {
        guard let udid = selected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let size = Simctl.contentSize(udid), contrast = Simctl.increaseContrast(udid)
            let settings = Simctl.accessibilitySettings(udid)
            DispatchQueue.main.async {
                if udid == self.selected { self.axSettings = settings }
                self.slowAnimations = SlowAnimations.isOn
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
        // An app Saguru is watching (network, camera) is relaunched with all of that still in it.
        if bundleID == appID, agentRun != nil {
            var arguments: [String] = []
            if !language.isEmpty {
                arguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", region.isEmpty ? language : "\(language)_\(region)"]
            }
            launchWithAgent(arguments: arguments) { failure in
                self.say(failure ?? (language.isEmpty ? "App reiniciada" : "App reiniciada en «\(language)»"))
            }
            return
        }
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
        say("Permite Accesibilidad para Saguru y vuelve a intentarlo")
        return false
    }

    func toggleGrid() {
        guard gridOn || requireAccessibility() else { return }
        gridOn.toggle()
        grid.sync()
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
