import AVFoundation
import AppKit
import CoreImage
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
}

final class CameraModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Source: Hashable { case image, device(String), android(String) }
    enum Framing: String, CaseIterable { case portrait = "Vertical", original = "Original" }

    @Published var source = Source.image { didSet { if source != oldValue { restart() } } }
    @Published var framing = Framing.portrait { didSet { if framing != oldValue { renderImage() } } }
    /// Quarter turns to the right, for sources that arrive lying on their side.
    @Published var turns = 0 { didSet { if turns != oldValue { renderImage() } } }
    @Published var devices: [CameraDevice] = []
    @Published var preview: CGImage?
    @Published var imageURL: URL? { didSet { renderImage() } }
    @Published var problem: String?
    /// "udid|bundle" of the app that was launched with the camera.
    @Published private(set) var active: String?
    @Published var visible = false { didSet { if visible != oldValue { restart() } } }

    unowned let panel: PanelModel
    private(set) var channel: FrameChannel?
    private var session: AVCaptureSession?
    private var android: AndroidCamera?
    private let queue = DispatchQueue(label: "saguru.camera")
    private let context = CIContext()
    private var frames = 0
    private var still: CIImage?

    init(panel: PanelModel) {
        self.panel = panel
        super.init()
        if let saved = UserDefaults.standard.string(forKey: "camera.image") { imageURL = URL(fileURLWithPath: saved) }
    }

    private var key: String? {
        guard let udid = panel.selected, !panel.appID.isEmpty else { return nil }
        return "\(udid)|\(panel.appID)"
    }

    var isActive: Bool { active != nil && active == key }
    /// The folder the agent is pointed at, while an app is using the camera.
    var agentFolder: URL? { active == nil ? nil : channel?.folder }

    func reloadDevices() {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                     mediaType: .video, position: .unspecified).devices
        devices = found.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName, isPhone: $0.deviceType == .continuityCamera || $0.modelID.hasPrefix("iPhone")) }
        if case .device(let id) = source, !devices.contains(where: { $0.id == id }) { source = .image }
        DispatchQueue.global(qos: .userInitiated).async {
            let phones = ADB.phones().map { CameraDevice(id: $0.serial, name: $0.name, isPhone: true, isAndroid: true) }
            DispatchQueue.main.async {
                self.devices = self.devices.filter { !$0.isAndroid } + phones
                if case .android(let serial) = self.source, !phones.contains(where: { $0.id == serial }) { self.source = .image }
            }
        }
    }

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
        active = key
        problem = nil
        restart()
        renderImage()
        let environment = panel.agentEnvironment()
        DispatchQueue.global(qos: .userInitiated).async {
            // The app must not stop at the permission alert: the camera it will see is ours.
            _ = try? Simctl.run(["privacy", udid, "grant", "camera", bundleID])
            let failure = AgentLauncher.launch(udid: udid, bundleID: bundleID, environment: environment)
            DispatchQueue.main.async {
                if let failure { self.problem = failure; self.active = nil } else { self.panel.say("Cámara activa en \(self.panel.app?.name ?? bundleID)") }
            }
        }
    }

    func deactivate() {
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

    func chooseImage(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "camera.image")
        imageURL = url
        source = .image
        renderImage()
    }

    func pickImage() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.image]
        if open.runModal() == .OK, let url = open.url { chooseImage(url) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        send(CIImage(cvPixelBuffer: pixels))
    }

    private func renderImage() {
        guard source == .image else { return }
        let url = imageURL
        queue.async {
            guard let url, let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                DispatchQueue.main.async { self.preview = nil }
                return
            }
            self.frames = 0
            self.send(image)
        }
    }

    /// Crops and scales a picture to what the app will get, publishes it to the agent and to the panel.
    private func send(_ image: CIImage) {
        var picture = image
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        if turns % 4 != 0 { picture = picture.oriented(orientations[turns % 4]) }
        picture = picture.transformed(by: CGAffineTransform(translationX: -picture.extent.minX, y: -picture.extent.minY))
        if framing == .portrait, picture.extent.width > picture.extent.height {
            // A phone is held upright: keep the middle of a landscape picture, three wide by four tall.
            let width = (picture.extent.height * 3 / 4).rounded()
            picture = picture.cropped(to: CGRect(x: ((picture.extent.width - width) / 2).rounded(), y: 0, width: width, height: picture.extent.height))
            picture = picture.transformed(by: CGAffineTransform(translationX: -picture.extent.minX, y: 0))
        }
        let scale = min(1, 1440 / max(picture.extent.width, picture.extent.height))
        if scale < 1 { picture = picture.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        let width = Int(picture.extent.width) & ~1, height = Int(picture.extent.height) & ~1
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        channel?.write(width: width, height: height) { memory, row in
            context.render(picture, toBitmap: memory, rowBytes: row, bounds: bounds, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        frames += 1
        if frames % 3 == 1, visible, let shown = context.createCGImage(picture, from: bounds) {
            DispatchQueue.main.async { self.preview = shown }
        }
    }
}

/// Launches an app with Saguru's agent inside. Returns what went wrong, if anything.
enum AgentLauncher {
    static func launch(udid: String, bundleID: String, environment extra: [String: String]) -> String? {
        guard let agent = Bundle.main.resourceURL?.appendingPathComponent("SaguruAgent.dylib"),
              FileManager.default.fileExists(atPath: agent.path) else {
            return "Falta SaguruAgent.dylib en Saguru.app. Vuelve a construir con scripts/build.sh."
        }
        let process = Simctl.process(["launch", "--terminate-running-process", udid, bundleID])
        var environment = ProcessInfo.processInfo.environment
        environment["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = agent.path
        for (name, value) in extra { environment["SIMCTL_CHILD_\(name)"] = value }
        process.environment = environment
        let errors = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errors
        do {
            try process.run()
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return message.isEmpty ? "No se pudo lanzar la app." : message
            }
            return nil
        } catch {
            return "No se pudo ejecutar xcrun simctl."
        }
    }
}

// MARK: - View

struct CameraForm: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var camera: CameraModel
    @State private var dropping = false

    var body: some View {
        FormBox(title: "Cámara", target: model) {
            HStack(alignment: .top, spacing: 20) {
                picture
                VStack(alignment: .leading, spacing: 16) {
                    Labeled("Fuente") {
                        VStack(spacing: 4) {
                            row("Imagen", detail: camera.imageURL?.lastPathComponent ?? "Elige o arrastra una", symbol: "photo", chosen: camera.source == .image) {
                                if camera.imageURL == nil { camera.pickImage() } else { camera.source = .image }
                            }
                            ForEach(camera.devices) { device in
                                row(device.name, detail: device.isAndroid ? "Android por USB" : (device.isPhone ? "iPhone como cámara" : "Cámara de esta Mac"),
                                    symbol: device.isAndroid ? "smartphone" : (device.isPhone ? "iphone" : "web.camera"),
                                    chosen: camera.source == (device.isAndroid ? .android(device.id) : .device(device.id))) { camera.choose(device) }
                            }
                        }
                        if camera.source == .image { Button("Elegir otra imagen…") { camera.pickImage() }.controlSize(.small) }
                    }
                    Labeled("Encuadre") {
                        Picker("Encuadre", selection: $camera.framing) {
                            ForEach(CameraModel.Framing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        Button { camera.turns = (camera.turns + 1) % 4 } label: { Label("Girar", systemImage: "rotate.right") }
                            .controlSize(.small)
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
                    Text("Funciona con apps que manejan la cámara ellas mismas: visor, fotogramas (Vision, OCR), lectura de QR y foto. No cubre las pantallas de cámara de Apple, como el escáner de documentos.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

    private var picture: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black)
            if let preview = camera.preview {
                Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)).padding(6)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "camera").font(.system(size: 30, weight: .light))
                    Text("Arrastra aquí una imagen\no elige una cámara").multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(dropping ? Color(nsColor: .systemBlue) : Color.white.opacity(0.12), lineWidth: dropping ? 2 : 1))
        .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { camera.chooseImage(url) } }
            }
            return true
        }
    }

    private func row(_ name: String, detail: String, symbol: String, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15)).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
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
