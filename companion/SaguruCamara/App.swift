import AVFoundation
import Network
import SwiftUI
import VideoToolbox

// Saguru Cámara: the iPhone's camera, sent to Saguru on the Mac through the USB cable.
//
// The app listens on a port of the phone itself. The Mac reaches that port through the cable (macOS's own
// tunnel to a connected iPhone), so nothing travels over Wi-Fi and no account is involved. What is sent is
// plain H.264 with start codes, the same thing Saguru already reads from an Android phone.
// The Mac can send one-letter orders back: F and B choose the front or back camera, T turns the torch.

@main
struct SaguruCamaraApp: App {
    var body: some Scene { WindowGroup { Screen() } }
}

struct Screen: View {
    @StateObject private var camera = Camera()

    var body: some View {
        ZStack {
            Preview(session: camera.session).ignoresSafeArea()
            VStack {
                HStack(spacing: 8) {
                    Circle().fill(camera.sending ? Color.green : Color.orange).frame(width: 10, height: 10)
                    Text(camera.status).font(.callout.weight(.medium))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 12)
                Spacer()
                HStack(spacing: 28) {
                    Button { camera.toggleTorch() } label: { Image(systemName: camera.torch ? "flashlight.on.fill" : "flashlight.off.fill") }
                    Button { camera.flip() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera") }
                }
                .font(.system(size: 24)).foregroundStyle(.white)
                .padding(.horizontal, 26).padding(.vertical, 14)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 24)
            }
        }
        .background(Color.black)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true; camera.start() }
    }
}

struct Preview: UIViewRepresentable {
    let session: AVCaptureSession
    final class View: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    }
    func makeUIView(context: Context) -> View {
        let view = View()
        (view.layer as? AVCaptureVideoPreviewLayer)?.session = session
        (view.layer as? AVCaptureVideoPreviewLayer)?.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: View, context: Context) {}
}

final class Camera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let port: UInt16 = 27183

    @Published var status = "Esperando a Saguru por USB"
    @Published var sending = false
    @Published var torch = false

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "saguru.camera")
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var position = AVCaptureDevice.Position.back
    private var listener: NWListener?
    private var client: NWConnection?
    private var encoder: VTCompressionSession?
    private var encoderSize = CGSize.zero
    private var wantKeyframe = true

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { DispatchQueue.main.async { self.status = "Sin permiso de cámara: actívalo en Ajustes" }; return }
            self.queue.async { self.configure(); self.listen() }
        }
    }

    // MARK: Camera

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080
        session.inputs.forEach(session.removeInput)
        if let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) {
            session.addInput(input)
            device = camera
            if (try? camera.lockForConfiguration()) != nil {
                if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
                camera.unlockForConfiguration()
            }
        }
        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        // Upright pictures: the sensor lies on its side.
        if let connection = output.connection(with: .video) {
            if #available(iOS 17.0, *) { if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 } }
            else if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
            // What Saguru gets is the scene, not a mirror of it; the app using it decides about mirroring.
            if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
        }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
    }

    func flip() { queue.async { self.choose(self.position == .back ? .front : .back) } }

    private func choose(_ wanted: AVCaptureDevice.Position) {
        guard wanted != position else { return }
        position = wanted
        setTorch(false)
        configure()
        wantKeyframe = true
    }

    func toggleTorch() { queue.async { self.setTorch(!self.torch) } }

    private func setTorch(_ on: Bool) {
        guard let device, device.hasTorch, (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
        DispatchQueue.main.async { self.torch = on }
    }

    // MARK: The connection from the Mac

    private func listen() {
        let parameters = NWParameters.tcp
        // Only this phone's own address: the cable's tunnel arrives there, and nothing on the network can.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            DispatchQueue.main.async { self.status = "No se pudo abrir el puerto" }
            return
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// One Mac at a time: a new connection takes over from the one before.
    private func accept(_ connection: NWConnection) {
        client?.cancel()
        client = connection
        wantKeyframe = true
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.client === connection else { return }
            switch state {
            case .ready: DispatchQueue.main.async { self.sending = true; self.status = "Enviando a Saguru" }
            case .failed, .cancelled:
                self.client = nil
                DispatchQueue.main.async { self.sending = false; self.status = "Esperando a Saguru por USB" }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self] data, _, done, error in
            guard let self, self.client === connection else { return }
            for order in data ?? Data() {
                switch order {
                case UInt8(ascii: "F"): self.choose(.front)
                case UInt8(ascii: "B"): self.choose(.back)
                case UInt8(ascii: "T"): self.setTorch(!self.torch)
                default: break
                }
            }
            if done || error != nil { connection.cancel(); return }
            self.receive(on: connection)
        }
    }

    // MARK: Encoding

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard client != nil, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        if encoder == nil || size != encoderSize { makeEncoder(size) }
        guard let encoder else { return }
        var properties: CFDictionary?
        if wantKeyframe { properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary; wantKeyframe = false }
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixels, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                        duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, encoded in
            guard status == noErr, let encoded, let self else { return }
            self.queue.async { self.send(encoded) }
        }
    }

    private func makeEncoder(_ size: CGSize) {
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        var made: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &made) == noErr, let made else { return }
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_AverageBitRate, value: 10_000_000 as CFNumber)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(made)
        encoder = made
        encoderSize = size
        wantKeyframe = true
    }

    /// The encoder gives each piece with its length in front; Saguru expects a start code instead, and the
    /// parameter sets (how to read the stream) again before every keyframe.
    private func send(_ sample: CMSampleBuffer) {
        guard let client, let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return }
        let start: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        let attachments = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?.first
        let keyframe = !((attachments?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        if keyframe {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    out.append(contentsOf: start)
                    out.append(pointer, count: size)
                }
            }
        }
        var length = 0
        var bytes: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &bytes) == noErr, let bytes else { return }
        var offset = 0
        while offset + 4 <= length {
            var size: UInt32 = 0
            memcpy(&size, bytes + offset, 4)
            let unit = Int(UInt32(bigEndian: size))
            guard unit > 0, offset + 4 + unit <= length else { break }
            out.append(contentsOf: start)
            bytes.advanced(by: offset + 4).withMemoryRebound(to: UInt8.self, capacity: unit) { out.append($0, count: unit) }
            offset += 4 + unit
        }
        client.send(content: out, completion: .contentProcessed { _ in })
    }
}
