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
    /// The .app bundle on this Mac (simulator apps live in the host file system).
    var path: String?
    var id: String { bundleID }
}

struct SimError: Error, CustomStringConvertible {
    let description: String
}

/// Thin wrapper over `xcrun simctl`: everything Saguru does to a simulator goes through here.
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
            return SimApp(bundleID: id, name: name, isUser: (info["ApplicationType"] as? String) == "User",
                          path: info["Path"] as? String)
        }.sorted { ($0.isUser ? 0 : 1, $0.name.lowercased()) < ($1.isUser ? 0 : 1, $1.name.lowercased()) }
    }

    // MARK: Actions

    /// `data` goes next to "aps", which is where an app reads its own fields (ids, deep links…).
    static func pushPayload(title: String, subtitle: String = "", body: String, badge: Int?, sound: Bool = true,
                            data: [(key: String, value: Any)] = []) -> Data {
        var alert = ["title": title, "body": body]
        if !subtitle.isEmpty { alert["subtitle"] = subtitle }
        var aps: [String: Any] = ["alert": alert]
        if sound { aps["sound"] = "default" }
        if let badge { aps["badge"] = badge }
        var payload: [String: Any] = ["aps": aps]
        for (key, value) in data where !key.isEmpty && key != "aps" { payload[key] = value }
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Sends the notification and reports whether iOS will actually show it.
    /// `simctl push` succeeds even when the app is missing or may not show notifications, so both are checked here.
    @discardableResult
    static func push(_ udid: String, bundleID: String, payload: Data) throws -> NotificationPermission {
        guard (try? JSONSerialization.jsonObject(with: payload)) is [String: Any] else {
            throw SimError(description: "el payload no es un JSON válido")
        }
        guard apps(udid).contains(where: { $0.bundleID == bundleID }) else {
            throw SimError(description: "\(bundleID) no está instalada en este simulador")
        }
        try run(["push", udid, bundleID, "-"], input: payload)
        return notificationPermission(udid, bundleID: bundleID)
    }

    enum NotificationPermission {
        case allowed, denied, neverAsked, unknown

        /// nil when the notification will be shown; otherwise why it will not, for the user.
        var warning: String? {
            switch self {
            case .allowed, .unknown: return nil
            case .denied: return "la app tiene las notificaciones denegadas, iOS no la mostrará"
            case .neverAsked: return "la app aún no ha pedido permiso de notificaciones, iOS no la mostrará"
            }
        }
    }

    /// Reads the simulator's own notification settings. There is no simctl command for this, so it looks at
    /// the file where iOS keeps them; if Apple changes that file the answer is `.unknown` and nothing is assumed.
    static func notificationPermission(_ udid: String, bundleID: String) -> NotificationPermission {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/data/Library/BulletinBoard/VersionedSectionInfo.plist")
        guard let data = try? Data(contentsOf: file),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let sections = root["sectionInfo"] as? [String: Any] else { return .unknown }
        guard let archived = sections[bundleID] as? Data else { return .neverAsked }
        guard let archive = try? PropertyListSerialization.propertyList(from: archived, format: nil) as? [String: Any],
              let objects = archive["$objects"] as? [Any],
              let status = objects.lazy.compactMap({ ($0 as? [String: Any])?["authorizationStatus"] as? Int }).first
        else { return .unknown }
        // UNAuthorizationStatus: 0 not determined, 1 denied, 2 authorized, 3 provisional, 4 ephemeral.
        switch status {
        case 0: return .neverAsked
        case 1: return .denied
        default: return .allowed
        }
    }

    static func addMedia(_ udid: String, files: [URL]) throws {
        guard !files.isEmpty else { throw SimError(description: "no se indicó ningún archivo") }
        for file in files where !FileManager.default.fileExists(atPath: file.path) {
            throw SimError(description: "no existe \(file.path)")
        }
        try run(["addmedia", udid] + files.map(\.path))
    }

    static func openURL(_ udid: String, _ url: String) throws {
        do {
            try run(["openurl", udid, url])
        } catch let error as SimError {
            // simctl only gives an OSStatus; these two are the ones a person can act on.
            if error.description.contains("-10814") {
                let scheme = url.components(separatedBy: ":").first ?? url
                throw SimError(description: "ninguna app de este simulador abre «\(scheme)://»")
            }
            if error.description.contains("code=-50") { throw SimError(description: "«\(url)» no es una URL válida") }
            throw error
        }
    }

    /// The doors an app declares: its URL schemes (Info.plist) and its universal-link domains (entitlements).
    /// The routes behind them are only in the app's code, so they cannot be listed.
    struct AppLinks: Equatable {
        var schemes: [String] = []
        var domains: [String] = []
        /// Schemes that exist for sign-in callbacks or are plain web, not for navigating the app.
        var hidden = 0
    }

    static func links(of app: SimApp) -> AppLinks {
        guard let path = app.path else { return AppLinks() }
        var result = AppLinks()
        let info = NSDictionary(contentsOfFile: path + "/Info.plist")
        let types = info?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        for scheme in types.flatMap({ $0["CFBundleURLSchemes"] as? [String] ?? [] }) {
            let lower = scheme.lowercased()
            if ["http", "https"].contains(lower) || lower.hasPrefix("com.googleusercontent.apps.")
                || lower.range(of: "^fb[0-9]+$", options: .regularExpression) != nil {
                result.hidden += 1
            } else if !result.schemes.contains(scheme) {
                result.schemes.append(scheme)
            }
        }
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["-d", "--entitlements", "-", "--xml", path]
        let out = Pipe()
        codesign.standardOutput = out
        codesign.standardError = FileHandle.nullDevice
        if (try? codesign.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            codesign.waitUntilExit()
            let entitlements = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            for entry in entitlements?["com.apple.developer.associated-domains"] as? [String] ?? [] where entry.hasPrefix("applinks:") {
                // "applinks:example.com?mode=developer" -> "example.com"
                let domain = String(entry.dropFirst("applinks:".count)).components(separatedBy: "?")[0]
                if !domain.isEmpty, !result.domains.contains(domain) { result.domains.append(domain) }
            }
        }
        return result
    }

    static func appearance(_ udid: String) -> String {
        let data = (try? run(["ui", udid, "appearance"])) ?? Data()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "light"
    }

    static func setAppearance(_ udid: String, _ value: String) throws {
        try run(["ui", udid, "appearance", value])
    }

    /// PNG of the device's screen as it is right now.
    static func screenshot(_ udid: String) throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("saguru-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try run(["io", udid, "screenshot", "--type=png", file.path])
        return try Data(contentsOf: file)
    }

    /// Marketing-style status bar: 9:41, full battery, full signal.
    /// What the status bar shows while it is overridden. Every part is chosen, nothing is left as it happens to be.
    struct StatusBar: Codable, Equatable {
        var time = "9:41"
        var wifiOn = true
        var wifiBars = 3
        /// simctl's cellular mode: active, searching, failed (no service) or notSupported (hidden).
        var cellular = "active"
        var cellularBars = 4
        /// Mobile data shown next to the bars when Wi-Fi is off: 5g, 5g+, lte, 4g, 3g, or hide for none.
        var data = "5g"
        var batteryLevel = 100
        var charging = false

        /// The look of Apple's own marketing pictures: 9:41, full signal, full battery, not charging.
        static let catalog = StatusBar()
        static let cellularModes: [(id: String, name: String)] = [
            ("active", "Con señal"), ("searching", "Buscando"), ("failed", "Sin servicio"), ("notSupported", "Oculta"),
        ]
        static let dataTypes: [(id: String, name: String)] = [
            ("5g", "5G"), ("5g+", "5G+"), ("lte", "LTE"), ("4g", "4G"), ("3g", "3G"), ("hide", "Sin datos"),
        ]
    }

    static func overrideStatusBar(_ udid: String, _ bar: StatusBar) throws {
        // Overrides pile up, and a Wi-Fi mode left from before would keep the Wi-Fi icon on screen: start clean.
        try run(["status_bar", udid, "clear"])
        var arguments = ["status_bar", udid, "override",
                         "--cellularMode", bar.cellular, "--cellularBars", "\(min(max(bar.cellularBars, 0), 4))",
                         "--batteryState", bar.charging ? "charging" : "discharging",
                         "--batteryLevel", "\(min(max(bar.batteryLevel, 0), 100))"]
        if bar.wifiOn {
            arguments += ["--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "\(min(max(bar.wifiBars, 0), 3))"]
        } else {
            // Wi-Fi off means no Wi-Fi flags at all: any Wi-Fi mode, even "failed", draws its icon
            // and hides the 5G / LTE label.
            arguments += ["--dataNetwork", bar.cellular == "active" ? bar.data : "hide"]
        }
        try run(arguments)
        // The time goes on its own: the simulator rejects some values (anything that is not H:MM, and,
        // oddly, times on the hour such as 12:00), and a rejected time would otherwise undo the rest.
        let time = bar.time.trimmingCharacters(in: .whitespaces)
        do {
            try run(["status_bar", udid, "override", "--time", time.isEmpty ? "9:41" : time])
        } catch {
            throw SimError(description: "el simulador no acepta la hora «\(time)». Usa el formato 9:41; las horas en punto (12:00) las rechaza, prueba 12:01")
        }
    }

    static func cleanStatusBar(_ udid: String) throws {
        try overrideStatusBar(udid, .catalog)
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

    /// The services `simctl privacy` accepts (it has none for the camera or notifications).
    static let privacyServices = ["all", "photos", "photos-add", "microphone", "location", "location-always",
                                  "contacts", "contacts-limited", "calendar", "reminders", "media-library", "motion", "siri"]

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

    /// The app's preferences domain, as a path. An app's User Defaults live in a file inside its own data
    /// container; asking the simulator for the bundle identifier looks elsewhere and finds nothing.
    private static func defaultsDomain(_ udid: String, bundleID: String) throws -> String {
        try dataContainer(udid, bundleID: bundleID).appendingPathComponent("Library/Preferences/\(bundleID)").path
    }

    static func defaults(_ udid: String, bundleID: String) -> [String: Any] {
        guard let domain = try? defaultsDomain(udid, bundleID: bundleID),
              let data = try? run(["spawn", udid, "defaults", "export", domain, "-"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return plist
    }

    /// `type` is "string", "bool", "int" or "float". The app reads the new value the next time it starts.
    static func writeDefault(_ udid: String, bundleID: String, key: String, type: String, value: String) throws {
        try run(["spawn", udid, "defaults", "write", defaultsDomain(udid, bundleID: bundleID), key, "-\(type)", value])
    }

    static func deleteDefault(_ udid: String, bundleID: String, key: String) throws {
        try run(["spawn", udid, "defaults", "delete", defaultsDomain(udid, bundleID: bundleID), key])
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
