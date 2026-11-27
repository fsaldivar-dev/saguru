import AVFoundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

// The pretend camera. The Simulator has no camera, so Saguru's agent hands the app one whose pictures
// come from here: an image, this Mac's camera, or an iPhone used as a camera (macOS lists it like any other).
// Frames travel through a file both sides map into memory; see agent/SaguruCamera.m for the layout.

/// The shared file the agent reads frames from.
final class FrameChannel {
    let folder: URL
    private let pointer: UnsafeMutableRawPointer
    private let capacity: Int
    private var sequence: UInt32 = 0
    static let maxSide = 1920

    init?(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        capacity = 64 + Self.maxSide * Self.maxSide * 4
        let file = open(folder.appendingPathComponent("frame.bgra").path, O_RDWR | O_CREAT, 0o644)
        guard file >= 0, ftruncate(file, off_t(capacity)) == 0,
              let map = mmap(nil, capacity, PROT_READ | PROT_WRITE, MAP_SHARED, file, 0), map != MAP_FAILED else {
            if file >= 0 { close(file) }
            return nil
        }
        close(file)
        pointer = map
        pointer.storeBytes(of: 0x4D43_4753, as: UInt32.self)
    }

    deinit { munmap(pointer, capacity) }

    /// Writes one frame. The sequence is odd while the pixels are being written, so the reader skips it.
    func write(width: Int, height: Int, fill: (UnsafeMutableRawPointer, Int) -> Void) {
        guard width > 0, height > 0, width <= Self.maxSide, height <= Self.maxSide else { return }
        sequence &+= 1
        pointer.storeBytes(of: sequence, toByteOffset: 4, as: UInt32.self)
        pointer.storeBytes(of: UInt32(width), toByteOffset: 8, as: UInt32.self)
        pointer.storeBytes(of: UInt32(height), toByteOffset: 12, as: UInt32.self)
        pointer.storeBytes(of: UInt32(width * 4), toByteOffset: 16, as: UInt32.self)
        fill(pointer + 64, width * 4)
        sequence &+= 1
        pointer.storeBytes(of: sequence, toByteOffset: 4, as: UInt32.self)
    }
}

struct CameraDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let isPhone: Bool
    /// An Android phone reached through adb rather than a camera macOS lists.
    var isAndroid = false
    /// What is missing before it can be used (a phone that has not accepted USB debugging yet); nil when ready.
    var pending: String?
}

final class CameraModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Source: Hashable { case image, device(String), android(String) }
    /// How the picture fills the frame the app asked for: cut to cover it, or shown whole with black around.
    enum Framing: String, CaseIterable { case fill = "Rellenar", fit = "Completa" }

    @Published var source = Source.image { didSet { if source != oldValue { restart() } } }
    @Published var framing = Framing.fill { didSet { if framing != oldValue { renderImage() } } }
    /// Quarter turns to the right, for sources that arrive lying on their side.
    @Published var turns = 0 { didSet { if turns != oldValue { renderImage() } } }
    @Published var devices: [CameraDevice] = []
    /// Cameras that appeared while the tool was open, marked until one is chosen or a while passes.
    @Published private(set) var fresh = Set<String>()
    private var listed = false
    private var watch: Timer?
    @Published var preview: CGImage?
    @Published var imageURL: URL? { didSet { renderImage() } }
    /// The pictures at hand: one is sent, and clicking another swaps it while the app keeps running.
    @Published private(set) var images: [URL] = []
    // How the picture sits in the frame, as if the phone moved: nearer or farther, turned, tilted, off to a side.
    @Published var zoom = 1.0 { didSet { if zoom != oldValue { renderImage() } } }
    /// Degrees, clockwise.
    @Published var roll = 0.0 { didSet { if roll != oldValue { renderImage() } } }
    /// Degrees the picture leans away, top to bottom and side to side.
    @Published var pitch = 0.0 { didSet { if pitch != oldValue { renderImage() } } }
    @Published var yaw = 0.0 { didSet { if yaw != oldValue { renderImage() } } }
    /// Fractions of the frame, right and down.
    @Published var offset = CGSize.zero { didSet { if offset != oldValue { renderImage() } } }
    /// Where the picture's corners fall in the frame (0…1, from the top left): top left, top right, bottom
    /// right, bottom left. The view draws its handles there.
    @Published private(set) var outline: [CGPoint] = []
    var isAdjusted: Bool { zoom != 1 || roll != 0 || pitch != 0 || yaw != 0 || offset != .zero }
    static let zoomRange = 0.25...4.0

    func resetAdjustments() { zoom = 1; roll = 0; pitch = 0; yaw = 0; offset = .zero }
    func zoom(by factor: Double) { zoom = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound) }
    @Published var problem: String?
    /// "udid|bundle" of the app that was launched with the camera.
    @Published private(set) var active: String?
    @Published var visible = false { didSet { if visible != oldValue { restart(); watchDevices() } } }

    unowned let panel: PanelModel
    private(set) var channel: FrameChannel?
    private var session: AVCaptureSession?
    private var android: AndroidCamera?
    private let queue = DispatchQueue(label: "saguru.camera")
    private let context = CIContext()
    private var frames = 0
    private var still: (url: URL, image: CIImage)?
    private var thumbnails: [URL: CGImage] = [:]
    /// The frame size the app's camera session asked for, as the agent reports it (a phone held upright).
    private var want = (width: 1080, height: 1920)
    private var wantTimer: Timer?

    init(panel: PanelModel) {
        self.panel = panel
        super.init()
        images = (UserDefaults.standard.stringArray(forKey: "camera.images") ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if let saved = UserDefaults.standard.string(forKey: "camera.image") {
            let url = URL(fileURLWithPath: saved)
            if !images.contains(url), FileManager.default.fileExists(atPath: saved) { images.insert(url, at: 0) }
            imageURL = images.contains(url) ? url : images.first
        } else { imageURL = images.first }
        wantTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.readWant() }
    }

    /// The agent writes the size down when the app starts its session or changes its preset.
    private func readWant() {
        guard active != nil, let folder = channel?.folder else { return }
        queue.async {
            guard let text = try? String(contentsOf: folder.appendingPathComponent("want"), encoding: .utf8) else { return }
            let parts = text.split(separator: " ").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0, parts[0] <= FrameChannel.maxSide, parts[1] <= FrameChannel.maxSide,
                  (parts[0], parts[1]) != self.want else { return }
            self.want = (parts[0], parts[1])
            DispatchQueue.main.async { self.renderImage() }
        }
    }

    private var key: String? {
        guard let udid = panel.selected, !panel.appID.isEmpty else { return nil }
        return "\(udid)|\(panel.appID)"
    }

    /// The chosen app is running, launched by Saguru, with the camera in it.
    var isActive: Bool { active != nil && active == key && panel.agentAlive && panel.agentRun?.camera == true }
    /// Apps the camera has been asked for; they keep it on every relaunch Saguru does.
    private var wanted = Set<String>()

    /// Where the pictures go, when the app about to be launched is one that wants the camera.
    func folderForLaunch(of key: String) -> URL? {
        wanted.contains(key) ? ensureChannel()?.folder : nil
    }

    /// Called when Saguru has launched an app, with or without the camera.
    func launched(_ key: String, camera: Bool) {
        active = camera ? key : nil
        restart()
        renderImage()
    }

    func agentWentAway() {
        guard active != nil else { return }
        active = nil
        problem = "La app se cerró o se lanzó fuera de Saguru: ya no tiene la cámara."
        restart()
    }

    /// The cameras this Mac lists (its own, an iPhone nearby or plugged in, a USB webcam) and the Android
    /// phones adb sees. Called when the tool opens and again whenever something is plugged in or out.
    func reloadDevices() {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                     mediaType: .video, position: .unspecified).devices
        let cameras = found.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName, isPhone: $0.deviceType == .continuityCamera || $0.modelID.hasPrefix("iPhone")) }
        show(cameras + devices.filter(\.isAndroid))
        reloadPhones()
    }

    private func reloadPhones() {
        DispatchQueue.global(qos: .utility).async {
            let phones = ADB.phones().map { phone in
                CameraDevice(id: phone.serial, name: phone.name, isPhone: true, isAndroid: true,
                             pending: phone.ready ? nil : (phone.state == "offline" ? "Sin conexión: vuelve a conectar el cable"
                                                                                      : "Acepta «Permitir depuración USB» en el teléfono"))
            }
            DispatchQueue.main.async {
                self.show(self.devices.filter { !$0.isAndroid } + phones)
                self.listed = true
            }
        }
    }

    /// Takes a new list, says what arrived or left, and falls back to the image if the source in use is gone.
    private func show(_ list: [CameraDevice]) {
        guard list != devices else { return }
        let before = devices
        devices = list
        if listed {
            for device in list {
                let was = before.first { $0.id == device.id }
                if was == nil {
                    fresh.insert(device.id)
                    panel.say(device.pending == nil ? "Se conectó \(device.name): elígela en Fuente para usarla" : "\(device.name) conectado. \(device.pending!)")
                    let id = device.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.fresh.remove(id) }
                } else if was?.pending != nil, device.pending == nil {
                    fresh.insert(device.id)
                    panel.say("\(device.name) ya está listo para usarse como cámara")
                }
            }
            for gone in before where !list.contains(where: { $0.id == gone.id }) {
                fresh.remove(gone.id)
                if source == .device(gone.id) || source == .android(gone.id) { panel.say("Se desconectó \(gone.name): vuelvo a la imagen") }
            }
        }
        switch source {
        case .device(let id) where !list.contains(where: { $0.id == id && !$0.isAndroid }): source = .image
        case .android(let serial) where !list.contains(where: { $0.id == serial && $0.isAndroid && $0.pending == nil }): source = .image
        default: break
        }
    }

    /// While the tool is open, macOS says when a camera comes or goes; adb does not, so phones are asked for
    /// every few seconds.
    private func watchDevices() {
        watch?.invalidate()
        watch = nil
        NotificationCenter.default.removeObserver(self, name: AVCaptureDevice.wasConnectedNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        guard visible else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(camerasChanged), name: AVCaptureDevice.wasConnectedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(camerasChanged), name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        watch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.reloadPhones() }
    }

    @objc private func camerasChanged() { DispatchQueue.main.async { self.reloadDevices() } }

    private func ensureChannel() -> FrameChannel? {
        if channel == nil {
            channel = FrameChannel(folder: FileManager.default.temporaryDirectory.appendingPathComponent("saguru-cam/\(UUID().uuidString)"))
        }
        return channel
    }

    // MARK: Giving the camera to the app

    /// Relaunches the app with the camera. An app only gets it from its launch.
    func activate() {
        guard let udid = panel.selected, !panel.appID.isEmpty, let key else { problem = "Elige una app para darle la cámara."; return }
        guard ensureChannel() != nil else { problem = "No se pudo preparar el canal de imagen."; return }
        let bundleID = panel.appID
        wanted.insert(key)
        problem = nil
        // Already running with the camera in it: there is nothing to relaunch.
        if panel.agentAlive, panel.agentRun?.camera == true { launched(key, camera: true); return }
        DispatchQueue.global(qos: .userInitiated).async {
            // The app must not stop at the permission alert: the camera it will see is ours.
            _ = try? Simctl.run(["privacy", udid, "grant", "camera", bundleID])
            DispatchQueue.main.async {
                self.panel.launchWithAgent { failure in
                    if let failure { self.problem = failure } else { self.panel.say("Cámara activa en \(self.panel.app?.name ?? bundleID)") }
                }
            }
        }
    }

    /// The app keeps the pretend camera until its next launch; Saguru just stops asking for it.
    func deactivate() {
        if let key { wanted.remove(key) }
        active = nil
        restart()
    }

    // MARK: Sources

    /// Runs the Mac's capture only while someone is looking: the panel, or an app using the camera.
    private func restart() {
        let looking = visible || active != nil
        let wanted: String? = { if case .device(let id) = source, looking { return id } else { return nil } }()
        let phone: String? = { if case .android(let serial) = source, looking { return serial } else { return nil } }()
        queue.async {
            self.session?.stopRunning()
            self.session = nil
            self.android?.stop()
            self.android = nil
            if let phone {
                let camera = AndroidCamera(serial: phone, queue: self.queue)
                camera.onFrame = { [weak self] pixels in self?.send(CIImage(cvPixelBuffer: pixels)) }
                camera.onProblem = { [weak self] message in DispatchQueue.main.async { self?.problem = message } }
                self.android = camera
                camera.start()
                return
            }
            guard let wanted else { return }
            guard let device = AVCaptureDevice(uniqueID: wanted), let input = try? AVCaptureDeviceInput(device: device) else {
                DispatchQueue.main.async { self.problem = "No se pudo abrir esa cámara." }
                return
            }
            let session = AVCaptureSession()
            session.sessionPreset = .hd1280x720
            guard session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: self.queue)
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            self.session = session
            session.startRunning()
        }
        if wanted == nil, phone == nil { renderImage() }
    }

    func choose(_ device: CameraDevice) {
        problem = nil
        fresh.remove(device.id)
        if let pending = device.pending { problem = "\(device.name) aún no se puede usar. \(pending)."; return }
        if device.isAndroid { source = .android(device.id); return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            source = .device(device.id)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { if granted { self.source = .device(device.id) } else { self.problem = "Saguru no tiene permiso para usar la cámara." } }
            }
        default:
            problem = "Saguru no tiene permiso para usar la cámara. Actívalo en Configuración del Sistema › Privacidad › Cámara."
        }
    }

    /// Sends this picture from now on, adding it to the ones at hand if it is new.
    func chooseImage(_ url: URL) {
        if !images.contains(url) { images.append(url); saveImages() }
        UserDefaults.standard.set(url.path, forKey: "camera.image")
        imageURL = url
        source = .image
        renderImage()
    }

    func addImages(_ urls: [URL]) {
        let fresh = urls.filter { !images.contains($0) && (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) ?? false) }
        images += fresh
        saveImages()
        if let first = fresh.first ?? urls.first(where: images.contains) { chooseImage(first) }
    }

    func removeImage(_ url: URL) {
        guard let index = images.firstIndex(of: url) else { return }
        images.remove(at: index)
        thumbnails[url] = nil
        saveImages()
        guard imageURL == url else { return }
        if images.isEmpty { UserDefaults.standard.removeObject(forKey: "camera.image"); imageURL = nil }
        else { chooseImage(images[min(index, images.count - 1)]) }
    }

    private func saveImages() { UserDefaults.standard.set(images.map(\.path), forKey: "camera.images") }

    func thumbnail(for url: URL) -> CGImage? {
        if let made = thumbnails[url] { return made }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary) else { return nil }
        thumbnails[url] = image
        return image
    }

    func pickImage() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.image]
        open.allowsMultipleSelection = true
        if open.runModal() == .OK { addImages(open.urls) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        send(CIImage(cvPixelBuffer: pixels))
    }

    private func renderImage() {
        guard source == .image else { return }
        let url = imageURL
        queue.async {
            guard let url, let image = self.loadStill(url) else {
                DispatchQueue.main.async { self.preview = nil }
                return
            }
            self.frames = 0
            self.send(image)
        }
    }

    /// The picture decoded once, no larger than is useful, so moving a slider does not read the file again.
    private func loadStill(_ url: URL) -> CIImage? {
        if let still, still.url == url { return still.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 3000] as CFDictionary) else { return nil }
        let made = CIImage(cgImage: image)
        still = (url, made)
        return made
    }

    /// Crops and scales a picture to what the app will get, publishes it to the agent and to the panel.
    private func send(_ image: CIImage) {
        var picture = image
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        if turns % 4 != 0 { picture = picture.oriented(orientations[turns % 4]) }
        picture = picture.transformed(by: CGAffineTransform(translationX: -picture.extent.minX, y: -picture.extent.minY))
        // The agent would cut the picture to the app's frame anyway; doing it here shows the user what the app gets.
        let width = want.width & ~1, height = want.height & ~1
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let across = CGFloat(width) / picture.extent.width, down = CGFloat(height) / picture.extent.height
        let scale = (framing == .fill ? max(across, down) : min(across, down)) * CGFloat(zoom)
        // Where each corner of the picture lands: scaled, turned, leaned back in depth, then moved.
        let size = picture.extent.size, canvas = CGSize(width: width, height: height)
        let turn = -roll * .pi / 180, lean = pitch * .pi / 180, swing = yaw * .pi / 180
        let depth = 1.2 * max(size.width * scale, size.height * scale, canvas.width, canvas.height)
        let shift = offset
        func place(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let px = (x - size.width / 2) * scale, py = (y - size.height / 2) * scale
            var a = px * cos(turn) - py * sin(turn), b = px * sin(turn) + py * cos(turn)
            var z = -a * sin(swing)
            a *= cos(swing)
            let far = b * sin(lean) + z * cos(lean)
            b = b * cos(lean) - z * sin(lean)
            z = far
            let near = depth / (depth + z)
            return CGPoint(x: canvas.width / 2 + a * near + shift.width * canvas.width, y: canvas.height / 2 + b * near - shift.height * canvas.height)
        }
        let warp = CIFilter.perspectiveTransform()
        warp.inputImage = picture
        warp.topLeft = place(0, size.height); warp.topRight = place(size.width, size.height)
        warp.bottomLeft = place(0, 0); warp.bottomRight = place(size.width, 0)
        picture = (warp.outputImage ?? picture).composited(over: CIImage(color: .black)).cropped(to: bounds)
        channel?.write(width: width, height: height) { memory, row in
            context.render(picture, toBitmap: memory, rowBytes: row, bounds: bounds, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        frames += 1
        let corners = [warp.topLeft, warp.topRight, warp.bottomRight, warp.bottomLeft].map { CGPoint(x: $0.x / canvas.width, y: 1 - $0.y / canvas.height) }
        if frames % 3 == 1, visible, let shown = context.createCGImage(picture, from: bounds) {
            DispatchQueue.main.async { self.preview = shown; if self.outline != corners { self.outline = corners } }
        }
    }
}

/// Launches an app with Saguru's agent inside. Returns what went wrong, if anything.
enum AgentLauncher {
    /// Returns the launched app's process, or what went wrong.
    static func launch(udid: String, bundleID: String, environment extra: [String: String], arguments: [String] = [], options: [String] = []) -> (pid: Int32?, failure: String?) {
        guard let agent = Bundle.main.resourceURL?.appendingPathComponent("SaguruAgent.dylib"),
              FileManager.default.fileExists(atPath: agent.path) else {
            return (nil, "Falta SaguruAgent.dylib en Saguru.app. Vuelve a construir con scripts/build.sh.")
        }
        let process = Simctl.process(["launch", "--terminate-running-process"] + options + [udid, bundleID] + arguments)
        var environment = ProcessInfo.processInfo.environment
        environment["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = agent.path
        for (name, value) in extra { environment["SIMCTL_CHILD_\(name)"] = value }
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
            // "dev.example.app: 12345"
            let printed = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return (nil, message.isEmpty ? "No se pudo lanzar la app." : message)
            }
            let pid = printed.split(separator: ":").last.flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return (pid, nil)
        } catch {
            return (nil, "No se pudo ejecutar xcrun simctl.")
        }
    }
}

// MARK: - View

struct CameraForm: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var camera: CameraModel
    @State private var dropping = false
    @State private var showLimits = false

    var body: some View {
        FormBox(title: "Cámara", target: model) {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 10) {
                    strip
                    picture
                }
                VStack(alignment: .leading, spacing: 16) {
                    Labeled("Fuente") {
                        VStack(spacing: 4) {
                            row("Imagen", detail: camera.imageURL?.lastPathComponent ?? "Elige o arrastra una o varias", symbol: "photo", chosen: camera.source == .image) {
                                if camera.imageURL == nil { camera.pickImage() } else { camera.source = .image }
                            }
                            ForEach(camera.devices) { device in
                                row(device.name, detail: device.pending ?? (device.isAndroid ? "Android por USB" : (device.isPhone ? "iPhone como cámara" : "Cámara de esta Mac")),
                                    symbol: device.isAndroid ? "smartphone" : (device.isPhone ? "iphone" : "web.camera"),
                                    new: camera.fresh.contains(device.id), waiting: device.pending != nil,
                                    chosen: camera.source == (device.isAndroid ? .android(device.id) : .device(device.id))) { camera.choose(device) }
                            }
                        }
                    }
                    Labeled("Encuadre") {
                        Picker("Encuadre", selection: $camera.framing) {
                            ForEach(CameraModel.Framing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    Divider()
                    if camera.isActive {
                        Label("\(model.app?.name ?? "La app") ve esta cámara", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color(nsColor: .systemGreen))
                        HStack {
                            Button("Relanzar") { camera.activate() }
                            Button("Quitar") { camera.deactivate() }
                        }
                    } else {
                        Button("Dar la cámara a \(model.app?.name ?? "la app")") { camera.activate() }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(model.app == nil)
                        Text("Saguru relanza la app. Cambiar de fuente después no requiere relanzar.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let problem = camera.problem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.callout)
                            .foregroundStyle(Color(nsColor: .systemOrange)).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button { showLimits.toggle() } label: { Label("Alcance y límites", systemImage: "info.circle") }
                        .buttonStyle(.borderless).controlSize(.small)
                        .popover(isPresented: $showLimits, arrowEdge: .leading) { limits.padding(16).frame(width: 300) }
                }
                .frame(width: 250)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .onAppear {
            camera.reloadDevices()
            camera.visible = true
        }
        .onDisappear { camera.visible = false }
    }

    /// What the pretend camera covers and what it does not, where it is used rather than only in the README.
    private var limits: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Alcance y límites").font(.callout.weight(.semibold)).padding(.bottom, 3)
            ForEach(Self.works, id: \.self) { line(it: $0, good: true) }
            ForEach(Self.fails, id: \.self) { line(it: $0, good: false) }
            Text("La app solo recibe la cámara si Saguru la lanzó; al lanzarla desde Xcode hay que volver a dársela.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
    }

    private func line(it text: String, good: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: good ? "checkmark" : "xmark").font(.caption.weight(.bold))
                .foregroundStyle(good ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed)).frame(width: 12)
            Text(text).font(.caption).foregroundStyle(good ? .primary : .secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let works = [
        "Visor y fotogramas en vivo",
        "Foto, con cámara trasera y frontal (la frontal, espejada en el visor)",
        "Tamaño del preset, giro y espejo de cada conexión",
        "Varias imágenes para cambiar en vivo, con zoom, giro e inclinación",
        "Lectura de QR",
        "Pantalla de cámara del sistema (UIImagePickerController)",
        "Vision: códigos, texto, rectángulos y documentos",
    ]
    private static let fails = [
        "Escáner de documentos de Apple y DataScanner: la app se cierra",
        "Otros códigos de barras por el aviso de iOS (solo QR)",
        "Vision: puntos de la cara, personas y clasificación",
        "Video grabado; zoom, linterna y enfoque se aceptan pero no cambian la imagen",
        "La frontal muestra la misma fuente que la trasera",
        "Android: solo cámara trasera, Android 12 o posterior",
    ]

    // MARK: Handles on the picture, as in a shape editor

    private static let blue = Color(nsColor: .systemBlue)

    /// Where the frame is drawn inside the picture view (fitted, with the view's padding).
    private var frameRect: CGRect {
        let room = CGSize(width: max(pictureSize.width - 12, 1), height: max(pictureSize.height - 12, 1))
        let frame = camera.preview.map { CGSize(width: $0.width, height: $0.height) } ?? room
        let fitted = min(room.width / frame.width, room.height / frame.height)
        let size = CGSize(width: frame.width * fitted, height: frame.height * fitted)
        return CGRect(x: (pictureSize.width - size.width) / 2, y: (pictureSize.height - size.height) / 2, width: size.width, height: size.height)
    }

    private enum Grip { case roll, tilt, move }
    private static let gyroRadius: CGFloat = 62

    /// A gyroscope in the middle of the picture, as in a 3D editor: the outer ring turns it, dragging
    /// inside leans it in depth (across for one axis, up and down for the other), and the hub moves it.
    @ViewBuilder private var gyroscope: some View {
        let rect = frameRect
        let points = camera.outline.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
        if points.count == 4 {
            let radius = Self.gyroRadius
            let middle = CGPoint(x: (points[0].x + points[1].x + points[2].x + points[3].x) / 4, y: (points[0].y + points[1].y + points[2].y + points[3].y) / 4)
            // Kept inside the view, so it can always be reached however far the picture is moved.
            let centre = CGPoint(x: min(max(middle.x, radius + 8), max(pictureSize.width - radius - 8, radius + 8)),
                                 y: min(max(middle.y, radius + 8), max(pictureSize.height - radius - 8, radius + 8)))
            let held = grip?.kind
            ZStack {
                Circle().fill(.black.opacity(0.22))
                // Leaning rings: each is a circle seen almost edge-on, and opens as the picture leans its way.
                ring(Color(nsColor: .systemRed), lit: held == .tilt)
                    .rotation3DEffect(.degrees(68 - abs(camera.pitch) * 0.5), axis: (x: 1, y: 0, z: 0), perspective: 0.35)
                ring(Color(nsColor: .systemGreen), lit: held == .tilt)
                    .rotation3DEffect(.degrees(68 - abs(camera.yaw) * 0.5), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
                // Turning ring, with a bead that shows the angle.
                ring(Self.blue, lit: held == .roll)
                Circle().fill(.white).frame(width: 9, height: 9).overlay(Circle().strokeBorder(Self.blue, lineWidth: 1.5))
                    .offset(y: -radius).rotationEffect(.degrees(camera.roll))
                Circle().fill(.white).frame(width: held == .move ? 11 : 8, height: held == .move ? 11 : 8)
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
            .frame(width: radius * 2, height: radius * 2)
            .shadow(color: .black.opacity(0.45), radius: 3)
            .contentShape(Circle().inset(by: -9))
            .position(centre)
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("picture"))
                .onChanged { drag in
                    let from = CGPoint(x: drag.startLocation.x - centre.x, y: drag.startLocation.y - centre.y)
                    let now = grip ?? {
                        let reach = hypot(from.x, from.y)
                        let kind: Grip = reach > radius - 11 ? .roll : (reach < 13 ? .move : .tilt)
                        return (kind, centre, camera.roll, camera.yaw, camera.pitch, camera.offset)
                    }()
                    grip = now
                    switch now.kind {
                    case .roll:
                        let start = atan2(drag.startLocation.y - now.centre.y, drag.startLocation.x - now.centre.x)
                        let end = atan2(drag.location.y - now.centre.y, drag.location.x - now.centre.x)
                        var turned = now.roll + (end - start) * 180 / .pi
                        while turned > 180 { turned -= 360 }
                        while turned < -180 { turned += 360 }
                        // A little pull towards the straight angles, so they are easy to land on.
                        for straight in [-180.0, -90, 0, 90, 180] where abs(turned - straight) < 2.5 { turned = straight }
                        camera.roll = turned
                    case .tilt:
                        camera.yaw = max(-60, min(60, now.yaw + drag.translation.width * 0.7))
                        camera.pitch = max(-60, min(60, now.pitch + drag.translation.height * 0.7))
                    case .move:
                        camera.offset = CGSize(width: now.offset.width + drag.translation.width / rect.width,
                                               height: now.offset.height + drag.translation.height / rect.height)
                    }
                }
                .onEnded { _ in grip = nil })
            .onTapGesture(count: 2) { camera.roll = 0; camera.yaw = 0; camera.pitch = 0 }
            .help("Anillo azul: girar · dentro: inclinar · centro: mover · doble clic: enderezar")
            .accessibilityElement().accessibilityLabel("Giroscopio")
            .accessibilityValue(String(format: "giro %.0f, inclinación %.0f y %.0f grados", camera.roll, camera.yaw, camera.pitch))
            .accessibilityAdjustableAction { camera.roll = max(-180, min(180, camera.roll + ($0 == .increment ? 15 : -15))) }
        }
    }

    private func ring(_ color: Color, lit: Bool) -> some View {
        Circle().strokeBorder(color.opacity(lit ? 1 : 0.9), lineWidth: lit ? 3 : 2)
            .shadow(color: color.opacity(lit ? 0.9 : 0), radius: 5)
    }

    /// Zoom, quarter turns and reset, floating over the bottom of the picture.
    private var controls: some View {
        HStack(spacing: 2) {
            pill("minus", "Alejar") { camera.zoom(by: 1 / 1.25) }
            Button { camera.zoom = 1 } label: { Text(String(format: "%.2f×", camera.zoom)).font(.caption.monospacedDigit()).frame(width: 46) }
                .buttonStyle(.plain).help("Volver a 1×").accessibilityLabel("Zoom")
            pill("plus", "Acercar") { camera.zoom(by: 1.25) }
            Divider().frame(height: 16).padding(.horizontal, 4)
            pill("rotate.right", "Girar 90°") { camera.turns = (camera.turns + 1) % 4 }
            Text(String(format: "%.0f°", camera.roll)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36)
            Divider().frame(height: 16).padding(.horizontal, 4)
            pill("arrow.counterclockwise", "Restablecer") { camera.resetAdjustments() }.disabled(!camera.isAdjusted)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
    }

    private func pill(_ symbol: String, _ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(name).accessibilityLabel(name)
    }

    /// The pictures at hand. Clicking one sends it at once; ⌘1 to ⌘9 do the same from the keyboard.
    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(camera.images.enumerated()), id: \.element) { index, url in
                    let chosen = camera.source == .image && camera.imageURL == url
                    let tile = Button { camera.chooseImage(url) } label: {
                        VStack(spacing: 3) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black)
                                if let thumbnail = camera.thumbnail(for: url) {
                                    Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                }
                            }
                            .frame(width: 62, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(chosen ? Color(nsColor: .systemBlue) : Color.white.opacity(0.14), lineWidth: chosen ? 2.5 : 1))
                            Text(url.deletingPathExtension().lastPathComponent).font(.caption2).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(chosen ? .primary : .secondary).frame(width: 66)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Imagen \(url.lastPathComponent)")
                    .help(index < 9 ? "\(url.lastPathComponent) · ⌘\(index + 1)" : url.lastPathComponent)
                    .contextMenu {
                        Button("Quitar de la lista") { camera.removeImage(url) }
                        Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    if index < 9 { tile.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command) } else { tile }
                }
                Button { camera.pickImage() } label: {
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(width: 62, height: 62)
                            .overlay(Image(systemName: "plus").font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary))
                        Text("Añadir").font(.caption2).foregroundStyle(.secondary).frame(width: 66)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Añadir imágenes")
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 84)
    }

    @State private var dragStart: CGSize?
    @State private var pinchStart: Double?
    @State private var grip: (kind: Grip, centre: CGPoint, roll: Double, yaw: Double, pitch: Double, offset: CGSize)?
    @State private var pictureSize = CGSize(width: 300, height: 300)

    private var picture: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black)
            if let preview = camera.preview {
                Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)).padding(6)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "camera").font(.system(size: 30, weight: .light))
                    Text("Arrastra aquí una o varias imágenes\no elige una cámara").multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            }
            if camera.preview != nil {
                gyroscope
                VStack {
                    Spacer()
                    controls
                }
                .padding(12)
            }
        }
        .coordinateSpace(name: "picture")
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(dropping ? Color(nsColor: .systemBlue) : Color.white.opacity(0.12), lineWidth: dropping ? 2 : 1))
        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
        .background(GeometryReader { box in Color.clear.onAppear { pictureSize = box.size }.onChange(of: box.size) { pictureSize = $0 } })
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { drag in
                let start = dragStart ?? camera.offset
                dragStart = start
                // The frame is shown fitted inside this view: a drag is measured against the frame as drawn.
                let rect = frameRect
                camera.offset = CGSize(width: start.width + drag.translation.width / rect.width,
                                       height: start.height + drag.translation.height / rect.height)
            }
            .onEnded { _ in dragStart = nil })
        .simultaneousGesture(MagnificationGesture()
            .onChanged { pinch in
                let start = pinchStart ?? camera.zoom
                pinchStart = start
                camera.zoom = min(max(start * pinch, CameraModel.zoomRange.lowerBound), CameraModel.zoomRange.upperBound)
            }
            .onEnded { _ in pinchStart = nil })
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            let group = DispatchGroup()
            var urls: [URL] = []
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    DispatchQueue.main.async { if let url { urls.append(url) }; group.leave() }
                }
            }
            group.notify(queue: .main) { camera.addImages(urls) }
            return true
        }
    }

    private func row(_ name: String, detail: String, symbol: String, new: Bool = false, waiting: Bool = false, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15)).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(waiting ? AnyShapeStyle(Color(nsColor: .systemOrange)) : AnyShapeStyle(.secondary))
                        .lineLimit(waiting ? 2 : 1).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if new, !chosen {
                    Text("Nueva").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(nsColor: .systemBlue), in: Capsule())
                }
                if chosen { Image(systemName: "checkmark").foregroundStyle(Color(nsColor: .systemBlue)) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(chosen ? Color(nsColor: .systemBlue).opacity(0.22) : Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
