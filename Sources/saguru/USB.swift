import CoreVideo
import Foundation

// An iPhone as the camera's source, over the cable. macOS already keeps a tunnel to every iPhone plugged
// in (usbmuxd, the same one Xcode and Finder use); asking it for a port of the phone gives a plain
// connection that never touches Wi-Fi and needs no iCloud account. On the phone, Saguru's companion app
// (companion/) listens on that port and sends its camera as H.264, which is decoded like an Android's.

enum USBMux {
    private static let path = "/var/run/usbmuxd"

    /// Opens a connection to the tunnel service itself.
    private static func open() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.withCString { _ = strlcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, raw.count) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) } }
        guard ok == 0 else { close(fd); return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// A request is a property list behind a 16-byte header: total length, version 1, kind 8 (property list), a tag.
    private static func ask(_ fd: Int32, _ message: [String: Any]) -> [String: Any]? {
        var all = message
        all["ClientVersionString"] = "saguru"
        all["ProgName"] = "saguru"
        guard let body = try? PropertyListSerialization.data(fromPropertyList: all, format: .xml, options: 0) else { return nil }
        var packet = Data()
        for value in [UInt32(16 + body.count), 1, 8, 1] { withUnsafeBytes(of: value.littleEndian) { packet.append(contentsOf: $0) } }
        packet.append(body)
        guard packet.withUnsafeBytes({ write(fd, $0.baseAddress, packet.count) }) == packet.count,
              let header = read(fd, 16) else { return nil }
        let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard length >= 16, length < 1 << 20, let answer = read(fd, length - 16) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: answer, options: [], format: nil)) as? [String: Any]
    }

    private static func read(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var got = 0
        while got < count {
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, count - got) }
            guard n > 0 else { return nil }
            got += n
        }
        return data
    }

    /// iPhones plugged in with a cable: the number the tunnel knows each by, and its identifier.
    static func phones() -> [(id: Int, serial: String)] {
        guard let fd = open() else { return [] }
        defer { close(fd) }
        guard let answer = ask(fd, ["MessageType": "ListDevices"]), let list = answer["DeviceList"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let id = entry["DeviceID"] as? Int, let properties = entry["Properties"] as? [String: Any],
                  properties["ConnectionType"] as? String == "USB", let serial = properties["SerialNumber"] as? String else { return nil }
            return (id, serial)
        }
    }

    /// A connection to a port of the phone, through the cable. Nil when nothing listens there (the app is not open).
    static func connect(serial: String, port: UInt16) -> Int32? {
        guard let phone = phones().first(where: { $0.serial == serial }), let fd = open() else { return nil }
        // The port travels in network byte order, inside a field read in this machine's.
        guard let answer = ask(fd, ["MessageType": "Connect", "DeviceID": phone.id, "PortNumber": Int(port.bigEndian)]),
              answer["Number"] as? Int == 0 else { close(fd); return nil }
        return fd
    }
}

/// The camera of an iPhone running Saguru's companion app, received through the cable.
final class CableCamera {
    static let port: UInt16 = 27183
    enum Lens: UInt8 { case back = 0x42, front = 0x46 }   // "B", "F"

    var onFrame: ((CVPixelBuffer) -> Void)?
    var onProblem: ((String) -> Void)?

    private let serial: String
    private let queue: DispatchQueue
    private let decoder = H264Decoder()
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var running = false

    /// `queue` is the serial queue frames are delivered on.
    init(serial: String, queue: DispatchQueue) {
        self.serial = serial
        self.queue = queue
        decoder.onFrame = { [weak self] buffer in self?.onFrame?(buffer) }
    }

    /// Whether the companion app is open and listening on this phone.
    static func isListening(serial: String) -> Bool {
        guard let fd = USBMux.connect(serial: serial, port: port) else { return false }
        close(fd)
        return true
    }

    /// Call on `queue`.
    func start() {
        running = true
        connect(attempt: 0)
    }

    private func connect(attempt: Int) {
        guard running else { return }
        guard let fd = USBMux.connect(serial: serial, port: Self.port) else {
            if attempt < 4 { queue.asyncAfter(deadline: .now() + 0.6) { self.connect(attempt: attempt + 1) } }
            else { onProblem?("Abre la app Saguru Cámara en el iPhone y déjala en pantalla.") }
            return
        }
        self.fd = fd
        decoder.reset()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var buffer = [UInt8](repeating: 0, count: 1 << 18)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 { self.decoder.feed(Data(buffer[0..<n]), on: self.queue) }
            else {
                source.cancel()
                if self.running { self.onProblem?("El iPhone dejó de enviar la cámara. Mantén abierta la app Saguru Cámara.") }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func choose(_ lens: Lens) {
        guard fd >= 0, source?.isCancelled == false else { return }
        var order = lens.rawValue
        _ = write(fd, &order, 1)
    }

    func stop() {
        running = false
        source?.cancel()
        source = nil
        fd = -1
    }
}
