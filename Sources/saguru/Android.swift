import CoreMedia
import Foundation
import Network
import VideoToolbox

// An Android phone as the camera's source. macOS does not list it as a camera, so its camera is asked for
// over USB: scrcpy's server (shipped inside Saguru.app, see vendor/scrcpy) runs on the phone in camera mode
// and sends H.264, which is decoded here. Nothing is installed on the phone for good: the
// server is a file in its temporary folder that removes itself.

enum ADB {
    static let path: String? = {
        let home = NSHomeDirectory()
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/adb" }
        if let sdk = ProcessInfo.processInfo.environment["ANDROID_HOME"] { candidates.append("\(sdk)/platform-tools/adb") }
        candidates += ["\(home)/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func process(_ args: [String]) -> Process? {
        guard let path else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        return p
    }

    /// Runs adb and returns what it printed (nil if adb is missing or could not start).
    static func output(_ args: [String]) -> String? {
        guard let p = process(args) else { return nil }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Phones connected with USB debugging accepted: serial and model.
    static func phones() -> [(serial: String, name: String)] {
        guard let text = output(["devices", "-l"]) else { return [] }
        return text.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2, parts[1] == "device" else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }?.dropFirst(6).replacingOccurrences(of: "_", with: " ")
            return (parts[0], model ?? parts[0])
        }
    }
}

final class AndroidCamera {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onProblem: ((String) -> Void)?

    private let serial: String
    private let queue: DispatchQueue
    private let decoder = H264Decoder()
    private var server: Process?
    private var connection: NWConnection?
    private var port: UInt16 = 0
    private var running = false

    /// scrcpy's server file and the version it must be started with: the one that ships inside Saguru.app.
    static let scrcpy: (server: String, version: String)? = {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let server = resources.appendingPathComponent("scrcpy-server").path
        guard FileManager.default.fileExists(atPath: server),
              let version = try? String(contentsOf: resources.appendingPathComponent("scrcpy-server.version"), encoding: .utf8)
        else { return nil }
        return (server, version.trimmingCharacters(in: .whitespacesAndNewlines))
    }()

    /// `queue` is the serial queue frames are delivered on.
    init(serial: String, queue: DispatchQueue) {
        self.serial = serial
        self.queue = queue
        decoder.onFrame = { [weak self] buffer in self?.onFrame?(buffer) }
    }

    /// Call on `queue`.
    func start() {
        guard let scrcpy = Self.scrcpy else { onProblem?("Falta el servidor de cámara en Saguru.app. Vuelve a construir con scripts/build.sh."); return }
        guard ADB.path != nil else { onProblem?("No se encontró adb. Instala Android platform-tools."); return }
        running = true
        // Saguru's sessions carry a recognisable id, so one left behind (Saguru was killed while a phone was
        // the source) can be told from the user's own scrcpy and cleared here.
        for line in (ADB.output(["-s", serial, "forward", "--list"]) ?? "").split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 3, parts[2].hasPrefix("localabstract:scrcpy_5a60") { _ = ADB.output(["-s", serial, "forward", "--remove", String(parts[1])]) }
        }
        let id = String(format: "5a60%04x", UInt32.random(in: 0...0xFFFF))
        let jar = "/data/local/tmp/saguru-camera.jar"
        // The server deletes its own file when it starts, so it is copied every time.
        _ = ADB.output(["-s", serial, "push", scrcpy.server, jar])
        guard let assigned = ADB.output(["-s", serial, "forward", "tcp:0", "localabstract:scrcpy_\(id)"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), let port = UInt16(assigned) else {
            onProblem?("No se pudo abrir el canal USB con el teléfono.")
            return
        }
        self.port = port
        guard let process = ADB.process(["-s", serial, "shell", "CLASSPATH=\(jar)", "app_process", "/", "com.genymobile.scrcpy.Server", scrcpy.version,
                                         "scid=\(id)", "log_level=warn", "video_source=camera", "camera_facing=back", "audio=false", "control=false",
                                         "tunnel_forward=true", "raw_stream=true", "max_size=1280", "video_bit_rate=6000000"]) else { return }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { onProblem?("No se pudo ejecutar adb."); return }
        server = process
        decoder.reset()
        connect(attempt: 0)
    }

    /// The server takes a moment to listen: the connection is retried for a few seconds.
    private func connect(attempt: Int) {
        guard running, let port = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        self.connection = connection
        var received = false
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, done, error in
                guard let self, self.running, self.connection === connection else { return }
                if let data, !data.isEmpty {
                    received = true
                    self.decoder.feed(data, on: self.queue)
                }
                if done || error != nil {
                    connection.cancel()
                    if !received, attempt < 12 {
                        self.queue.asyncAfter(deadline: .now() + 0.4) { self.connect(attempt: attempt + 1) }
                    } else if self.running {
                        self.onProblem?(received ? "El teléfono dejó de enviar la cámara." : "El teléfono no entregó su cámara. Desbloquéalo y vuelve a elegirlo.")
                    }
                    return
                }
                read()
            }
        }
        connection.start(queue: queue)
        read()
    }

    /// Call on `queue`.
    func stop() {
        running = false
        connection?.cancel()
        connection = nil
        server?.terminate()
        server = nil
        if port != 0 { _ = ADB.output(["-s", serial, "forward", "--remove", "tcp:\(port)"]) }
        decoder.reset()
    }
}

/// Raw H.264 (Annex B) to pictures.
final class H264Decoder {
    var onFrame: ((CVPixelBuffer) -> Void)?

    private var buffer = [UInt8]()
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var sawKeyframe = false
    private var flush: DispatchWorkItem?

    func reset() {
        flush?.cancel()
        buffer.removeAll(keepingCapacity: true)
        sps = nil
        pps = nil
        invalidate()
    }

    private func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        sawKeyframe = false
    }

    /// `queue` is the serial queue this decoder is used on.
    func feed(_ data: Data, on queue: DispatchQueue) {
        buffer.append(contentsOf: data)
        drain(final: false)
        // A NAL unit is only known to be complete when the next start code shows up. On a static
        // screen nothing follows, so after a short quiet period treat what we have as complete.
        flush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.drain(final: true) }
        flush = work
        queue.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    private func drain(final: Bool) {
        var consumed = 0
        var units: [[UInt8]] = []
        buffer.withUnsafeBufferPointer { b in
            let n = b.count
            func startCode(from: Int) -> Int? {
                var i = from
                while i + 2 < n {
                    if b[i + 2] > 1 { i += 3 }
                    else if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { return i }
                    else { i += 1 }
                }
                return nil
            }
            guard var start = startCode(from: 0) else {
                consumed = max(0, n - 3)
                return
            }
            while true {
                let payload = start + 3
                if let next = startCode(from: payload) {
                    var end = next
                    while end > payload, b[end - 1] == 0 { end -= 1 }
                    if end > payload { units.append(Array(b[payload..<end])) }
                    start = next
                    consumed = next
                } else {
                    if final {
                        if n > payload { units.append(Array(b[payload..<n])) }
                        consumed = n
                    } else {
                        consumed = start
                    }
                    break
                }
            }
        }
        if consumed > 0 { buffer.removeFirst(consumed) }
        units.forEach(handle)
    }

    private func handle(_ nal: [UInt8]) {
        switch nal[0] & 0x1F {
        case 7:
            if sps != nal { sps = nal; invalidate() }
        case 8:
            if pps != nal { pps = nal; invalidate() }
        case 5:
            sawKeyframe = true
            decode(nal)
        case 1:
            if sawKeyframe { decode(nal) }
        default:
            break
        }
    }

    private func prepareSession() -> Bool {
        if session != nil { return true }
        guard let sps, let pps else { return false }
        var description: CMVideoFormatDescription?
        sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers = [s.baseAddress!, p.baseAddress!]
                let sizes = [s.count, p.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard let description else { return false }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var created: VTDecompressionSession?
        VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
                                     decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
                                     outputCallback: nil, decompressionSessionOut: &created)
        guard let created else { return false }
        format = description
        session = created
        return true
    }

    private func decode(_ nal: [UInt8]) {
        guard prepareSession(), let session, let format else { return }
        let length = nal.count + 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == noErr, let block else { return }
        var header = UInt32(nal.count).bigEndian
        CMBlockBufferReplaceDataBytes(with: &header, blockBuffer: block, offsetIntoDestination: 0, dataLength: 4)
        nal.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 4, dataLength: nal.count)
        }
        var sample: CMSampleBuffer?
        var sizes = [length]
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
            sampleBufferOut: &sample) == noErr, let sample else { return }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            [weak self] status, _, image, _, _ in
            if status == noErr, let image { self?.onFrame?(image) }
        }
        if status == kVTInvalidSessionErr { invalidate() }
    }
}
