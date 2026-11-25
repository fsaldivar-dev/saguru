import Foundation

struct SimDevice: Identifiable, Hashable {
    let udid: String
    let name: String
    let runtime: String
    let deviceType: String
    var id: String { udid }

    func matches(_ filter: String) -> Bool {
        udid.lowercased().hasPrefix(filter.lowercased()) || name.lowercased().contains(filter.lowercased())
    }
}

struct SimApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let isUser: Bool
    var id: String { bundleID }
}

struct SimError: Error, CustomStringConvertible {
    let description: String
}

/// Thin wrapper over `xcrun simctl`: everything Simuru does to a simulator goes through here.
enum Simctl {
    static func process(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["simctl"] + args
        return p
    }

    @discardableResult
    static func run(_ args: [String], input: Data? = nil) throws -> Data {
        let p = process(args)
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        p.standardOutput = out
        p.standardError = err
        if input != nil { p.standardInput = stdin }
        do { try p.run() } catch { throw SimError(description: "no se pudo ejecutar xcrun simctl (¿está instalado Xcode?)") }
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        // Drain stderr on the side so a chatty command cannot block on a full pipe.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SimError(description: message.isEmpty ? "simctl \(args.first ?? "") falló" : message)
        }
        return data
    }

    // MARK: Devices and apps

    static func booted() -> [SimDevice] {
        guard let data = try? run(["list", "devices", "booted", "-j"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = json["devices"] as? [String: [[String: Any]]] else { return [] }
        var result: [SimDevice] = []
        for (key, devices) in runtimes {
            // "com.apple.CoreSimulator.SimRuntime.iOS-18-2" -> "iOS 18.2"
            let parts = (key.components(separatedBy: "SimRuntime.").last ?? key).split(separator: "-")
            let runtime = parts.isEmpty ? key : "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
            for d in devices {
                guard let udid = d["udid"] as? String, let name = d["name"] as? String else { continue }
                result.append(SimDevice(udid: udid, name: name, runtime: runtime,
                                        deviceType: d["deviceTypeIdentifier"] as? String ?? ""))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Installed apps, the user's own first.
    static func apps(_ udid: String) -> [SimApp] {
        guard let data = try? run(["listapps", udid]),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]]
        else { return [] }
        return plist.map { id, info in
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? id
            return SimApp(bundleID: id, name: name, isUser: (info["ApplicationType"] as? String) == "User")
        }.sorted { ($0.isUser ? 0 : 1, $0.name.lowercased()) < ($1.isUser ? 0 : 1, $1.name.lowercased()) }
    }

    // MARK: Actions

    static func pushPayload(title: String, body: String, badge: Int?) -> Data {
        var aps: [String: Any] = ["alert": ["title": title, "body": body], "sound": "default"]
        if let badge { aps["badge"] = badge }
        return (try? JSONSerialization.data(withJSONObject: ["aps": aps], options: [.prettyPrinted])) ?? Data()
    }

    static func push(_ udid: String, bundleID: String, payload: Data) throws {
        guard (try? JSONSerialization.jsonObject(with: payload)) is [String: Any] else {
            throw SimError(description: "el payload no es un JSON válido")
        }
        try run(["push", udid, bundleID, "-"], input: payload)
    }

    static func addMedia(_ udid: String, files: [URL]) throws {
        guard !files.isEmpty else { throw SimError(description: "no se indicó ningún archivo") }
        for file in files where !FileManager.default.fileExists(atPath: file.path) {
            throw SimError(description: "no existe \(file.path)")
        }
        try run(["addmedia", udid] + files.map(\.path))
    }

    static func openURL(_ udid: String, _ url: String) throws {
        try run(["openurl", udid, url])
    }

    static func appearance(_ udid: String) -> String {
        let data = (try? run(["ui", udid, "appearance"])) ?? Data()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "light"
    }

    static func setAppearance(_ udid: String, _ value: String) throws {
        try run(["ui", udid, "appearance", value])
    }

    /// Marketing-style status bar: 9:41, full battery, full signal.
    static func cleanStatusBar(_ udid: String) throws {
        try run(["status_bar", udid, "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active",
                 "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
                 "--batteryState", "charged", "--batteryLevel", "100"])
    }

    static func resetStatusBar(_ udid: String) throws {
        try run(["status_bar", udid, "clear"])
    }

    static func setLocation(_ udid: String, latitude: Double, longitude: Double) throws {
        try run(["location", udid, "set", "\(latitude),\(longitude)"])
    }

    static func clearLocation(_ udid: String) throws {
        try run(["location", udid, "clear"])
    }

    static let privacyServices = ["all", "photos", "photos-add", "camera", "microphone", "location", "location-always",
                                  "contacts", "calendar", "reminders", "media-library", "motion", "siri"]

    static func privacy(_ udid: String, action: String, service: String, bundleID: String) throws {
        try run(["privacy", udid, action, service, bundleID])
    }

    // MARK: Accessibility

    static let contentSizes = ["extra-small", "small", "medium", "large", "extra-large", "extra-extra-large",
                               "extra-extra-extra-large", "accessibility-medium", "accessibility-large",
                               "accessibility-extra-large", "accessibility-extra-extra-large",
                               "accessibility-extra-extra-extra-large"]

    private static func text(_ args: [String]) -> String {
        let data = (try? run(args)) ?? Data()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func contentSize(_ udid: String) -> String { text(["ui", udid, "content_size"]) }

    /// `value` is one of `contentSizes`, or "increment" / "decrement".
    static func setContentSize(_ udid: String, _ value: String) throws {
        try run(["ui", udid, "content_size", value])
    }

    static func increaseContrast(_ udid: String) -> Bool { text(["ui", udid, "increase_contrast"]) == "enabled" }

    static func setIncreaseContrast(_ udid: String, _ on: Bool) throws {
        try run(["ui", udid, "increase_contrast", on ? "enabled" : "disabled"])
    }

    // MARK: App data

    static func dataContainer(_ udid: String, bundleID: String) throws -> URL {
        let path = (try? run(["get_app_container", udid, bundleID, "data"]))
            .flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { throw SimError(description: "\(bundleID) no está instalada en este simulador") }
        return URL(fileURLWithPath: path)
    }

    static func terminate(_ udid: String, bundleID: String) {
        _ = try? run(["terminate", udid, bundleID])
    }

    /// Relaunches the app, optionally forcing a language ("es") and region ("MX") for that launch.
    static func relaunch(_ udid: String, bundleID: String, language: String? = nil, region: String? = nil) throws {
        terminate(udid, bundleID: bundleID)
        var args = ["launch", udid, bundleID]
        if let language, !language.isEmpty {
            args += ["-AppleLanguages", "(\(language))"]
            args += ["-AppleLocale", region.map { $0.isEmpty ? language : "\(language)_\($0)" } ?? language]
        }
        try run(args)
    }

    /// Empties the app's Documents, Library and tmp. The app is terminated first.
    static func eraseData(_ udid: String, bundleID: String) throws {
        let container = try dataContainer(udid, bundleID: bundleID)
        terminate(udid, bundleID: bundleID)
        let fm = FileManager.default
        for folder in ["Documents", "Library", "tmp"] {
            let url = container.appendingPathComponent(folder)
            for item in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                try fm.removeItem(at: item)
            }
        }
    }

    // MARK: User Defaults (through the simulator's own `defaults`, so running apps see the change)

    static func defaults(_ udid: String, bundleID: String) -> [String: Any] {
        guard let data = try? run(["spawn", udid, "defaults", "export", bundleID, "-"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return plist
    }

    /// `type` is "string", "bool", "int" or "float".
    static func writeDefault(_ udid: String, bundleID: String, key: String, type: String, value: String) throws {
        try run(["spawn", udid, "defaults", "write", bundleID, key, "-\(type)", value])
    }

    static func deleteDefault(_ udid: String, bundleID: String, key: String) throws {
        try run(["spawn", udid, "defaults", "delete", bundleID, key])
    }

    // MARK: Screen metrics

    /// The device's screen in points (portrait), read from its device-type profile.
    static func screenPoints(_ device: SimDevice) -> CGSize? {
        guard let data = try? run(["list", "devicetypes", "-j"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let types = json["devicetypes"] as? [[String: Any]],
              let bundle = types.first(where: { ($0["identifier"] as? String) == device.deviceType })?["bundlePath"] as? String,
              let profile = NSDictionary(contentsOfFile: bundle + "/Contents/Resources/profile.plist"),
              let width = profile["mainScreenWidth"] as? Double, let height = profile["mainScreenHeight"] as? Double,
              let scale = profile["mainScreenScale"] as? Double, scale > 0 else { return nil }
        return CGSize(width: width / scale, height: height / scale)
    }
}
