import Foundation
import SQLite3
import SwiftUI

/// A permission an app can hold in the simulator, as the Settings app would list it.
enum Permission: String, CaseIterable, Identifiable {
    case location, photos, contacts, calendar, reminders, microphone, motion, mediaLibrary, siri
    var id: String { rawValue }

    var name: String {
        switch self {
        case .location: return "Ubicación"
        case .photos: return "Fotos"
        case .contacts: return "Contactos"
        case .calendar: return "Calendario"
        case .reminders: return "Recordatorios"
        case .microphone: return "Micrófono"
        case .motion: return "Movimiento"
        case .mediaLibrary: return "Música y medios"
        case .siri: return "Siri"
        }
    }

    var symbol: String {
        switch self {
        case .location: return "location.fill"
        case .photos: return "photo.on.rectangle"
        case .contacts: return "person.crop.circle"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .microphone: return "mic.fill"
        case .motion: return "figure.walk"
        case .mediaLibrary: return "music.note"
        case .siri: return "waveform"
        }
    }

    /// Tile colour, as in the Settings app.
    var color: Color {
        switch self {
        case .location: return Color(nsColor: .systemBlue)
        case .photos: return Color(nsColor: .systemPink)
        case .contacts: return Color(nsColor: .systemGray)
        case .calendar: return Color(nsColor: .systemRed)
        case .reminders: return Color(nsColor: .systemOrange)
        case .microphone: return Color(nsColor: .systemOrange)
        case .motion: return Color(nsColor: .systemGreen)
        case .mediaLibrary: return Color(nsColor: .systemPink)
        case .siri: return Color(nsColor: .systemPurple)
        }
    }

    /// The states this permission can be put in, in the order they are offered.
    var choices: [Choice] {
        switch self {
        case .location: return [.ask, .partial, .allow, .deny]
        case .photos: return [.ask, .partial, .allow, .deny]
        default: return [.ask, .allow, .deny]
        }
    }

    func label(_ choice: Choice) -> String {
        switch (self, choice) {
        case (_, .ask): return "Preguntar"
        case (_, .deny): return "Nunca"
        case (.location, .partial): return "Al usar"
        case (.location, .allow): return "Siempre"
        case (.photos, .partial): return "Solo añadir"
        case (.photos, .allow): return "Todas"
        default: return "Permitir"
        }
    }

    enum Choice: String {
        /// Not decided: the app will show the system prompt the next time it asks.
        case ask
        /// The narrower grant some permissions have: location while in use, add-only photos.
        case partial
        case allow
        case deny
    }

    /// simctl's name for this permission.
    fileprivate var service: String {
        switch self {
        case .mediaLibrary: return "media-library"
        default: return rawValue
        }
    }

    /// The name the simulator's permission database uses.
    fileprivate var tccService: String {
        switch self {
        case .location: return ""
        case .photos: return "kTCCServicePhotos"
        case .contacts: return "kTCCServiceAddressBook"
        case .calendar: return "kTCCServiceCalendar"
        case .reminders: return "kTCCServiceReminders"
        case .microphone: return "kTCCServiceMicrophone"
        case .motion: return "kTCCServiceMotion"
        case .mediaLibrary: return "kTCCServiceMediaLibrary"
        case .siri: return "kTCCServiceSiri"
        }
    }
}

/// What an app says it will ask for. An app can only request a permission whose usage text it declares
/// in its Info.plist, so this is the list that matters for that app.
struct DeclaredPermissions: Equatable {
    /// Permissions Simuru can change, with the choices that make sense for this app.
    var choices: [Permission: [Permission.Choice]] = [:]
    /// Declared permissions the simulator gives no way to change (camera, Face ID…).
    var fixed: [(name: String, symbol: String)] = []

    static func == (a: DeclaredPermissions, b: DeclaredPermissions) -> Bool {
        a.choices == b.choices && a.fixed.map(\.name) == b.fixed.map(\.name)
    }

    var isEmpty: Bool { choices.isEmpty && fixed.isEmpty }

    init() {}

    init(app: SimApp) {
        guard let path = app.path, let info = NSDictionary(contentsOfFile: path + "/Info.plist") else { return }
        func declares(_ keys: String...) -> Bool { keys.contains { info["NS\($0)UsageDescription"] != nil } }

        if declares("LocationWhenInUse", "LocationAlwaysAndWhenInUse", "LocationAlways", "Location") {
            let always = declares("LocationAlwaysAndWhenInUse", "LocationAlways")
            choices[.location] = always ? [.ask, .partial, .allow, .deny] : [.ask, .partial, .deny]
        }
        let allPhotos = declares("PhotoLibrary"), addPhotos = declares("PhotoLibraryAdd")
        if allPhotos || addPhotos {
            choices[.photos] = [.ask] + (addPhotos ? [.partial] : []) + (allPhotos ? [.allow] : []) + [.deny]
        }
        let simple: [(Permission, [String])] = [
            (.contacts, ["Contacts"]), (.calendar, ["Calendars", "CalendarsFullAccess", "CalendarsWriteOnlyAccess"]),
            (.reminders, ["Reminders", "RemindersFullAccess"]), (.microphone, ["Microphone"]), (.motion, ["Motion"]),
            (.mediaLibrary, ["AppleMusic"]), (.siri, ["Siri"]),
        ]
        for (permission, keys) in simple where keys.contains(where: { info["NS\($0)UsageDescription"] != nil }) {
            choices[permission] = permission.choices
        }
        let others: [(String, String, [String])] = [
            ("Cámara", "camera.fill", ["Camera"]), ("Face ID", "faceid", ["FaceID"]),
            ("Seguimiento", "hand.raised.fill", ["UserTracking"]),
            ("Bluetooth", "dot.radiowaves.left.and.right", ["BluetoothAlways", "BluetoothPeripheral"]),
            ("Red local", "network", ["LocalNetwork"]), ("Reconocimiento de voz", "waveform.badge.mic", ["SpeechRecognition"]),
            ("Salud", "heart.fill", ["HealthShare", "HealthUpdate"]), ("Casa", "house.fill", ["HomeKit"]),
        ]
        fixed = others.filter { entry in entry.2.contains { info["NS\($0)UsageDescription"] != nil } }.map { ($0.0, $0.1) }
    }
}

extension Simctl {
    private static func data(_ udid: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/data", isDirectory: true)
    }

    /// What the app holds right now. simctl can only change permissions, so this reads the two places the
    /// simulator keeps them (read-only): its permission database, and the location service's own list.
    static func permissions(_ udid: String, bundleID: String) -> [Permission: Permission.Choice] {
        var result = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, Permission.Choice.ask) })

        var granted: [String: Int32] = [:]
        var handle: OpaquePointer?
        if sqlite3_open_v2(data(udid).appendingPathComponent("Library/TCC/TCC.db").path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(handle, "SELECT service, auth_value FROM access WHERE client = ?", -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (bundleID as NSString).utf8String, -1, nil)
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let service = sqlite3_column_text(statement, 0) {
                        granted[String(cString: service)] = sqlite3_column_int(statement, 1)
                    }
                }
            }
            sqlite3_finalize(statement)
        }
        sqlite3_close(handle)
        // auth_value: 0 denied, 2 allowed.
        for permission in Permission.allCases where permission != .location {
            if let value = granted[permission.tccService] { result[permission] = value == 0 ? .deny : .allow }
        }
        if result[.photos] == .ask, granted["kTCCServicePhotosAdd"] == 2 { result[.photos] = .partial }

        // Location: 1 denied, 2 while in use, 4 always.
        let clients = NSDictionary(contentsOf: data(udid).appendingPathComponent("Library/Caches/locationd/clients.plist"))
        if let authorization = (clients?["i\(bundleID):"] as? [String: Any])?["Authorization"] as? Int {
            result[.location] = authorization == 1 ? .deny : (authorization == 4 ? .allow : (authorization == 2 ? .partial : .ask))
        }
        return result
    }

    static func setPermission(_ udid: String, bundleID: String, _ permission: Permission, to choice: Permission.Choice) throws {
        func privacy(_ action: String, _ service: String) throws { try run(["privacy", udid, action, service, bundleID]) }
        switch (permission, choice) {
        case (.location, .partial):
            // Going down from "always" needs a clean start.
            try privacy("reset", "location")
            try privacy("grant", "location")
        case (.location, .allow):
            try privacy("grant", "location-always")
        case (.photos, .ask):
            try privacy("reset", "photos")
            try privacy("reset", "photos-add")
        case (.photos, .partial):
            try privacy("reset", "photos")
            try privacy("grant", "photos-add")
        case (.photos, .deny):
            try privacy("revoke", "photos")
            try privacy("revoke", "photos-add")
        case (_, .ask):
            try privacy("reset", permission.service)
        case (_, .deny):
            try privacy("revoke", permission.service)
        default:
            try privacy("grant", permission.service)
        }
    }

    static func resetPermissions(_ udid: String, bundleID: String) throws {
        try run(["privacy", udid, "reset", "all", bundleID])
    }
}

// MARK: - Form

struct PrivacyForm: View {
    @ObservedObject var model: PanelModel
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// The grid's columns. Every permission has "ask", "allow" and "never"; only some have a middle grant.
    private let columns: [(choice: Permission.Choice, title: String)] = [
        (.ask, "Preguntar"), (.partial, "Limitado"), (.allow, "Permitir"), (.deny, "Nunca"),
    ]
    private let columnWidth: CGFloat = 74

    /// Only what the app declares: granting anything else would do nothing, since iOS does not let an
    /// app use what it has no usage text for.
    private var rows: [(permission: Permission, choices: [Permission.Choice])] {
        Permission.allCases.compactMap { permission in
            model.declared.choices[permission].map { (permission, $0) }
        }
    }

    var body: some View {
        FormBox(title: "Permisos", width: 520, target: model) {
            VStack(spacing: 0) {
                if !rows.isEmpty {
                    HStack(spacing: 0) {
                        Spacer()
                        ForEach(columns, id: \.choice) { column in
                            Text(column.title)
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(width: columnWidth)
                        }
                    }
                    .padding(.trailing, 6)
                    .padding(.bottom, 8)
                }
                // One grouped list, like a page of the Settings app.
                VStack(spacing: 0) {
                    ForEach(rows, id: \.permission) { entry in
                        row(entry.permission, choices: entry.choices)
                        Divider().padding(.leading, 50)
                    }
                    ForEach(model.declared.fixed, id: \.name) { entry in
                        info(entry.name, symbol: entry.symbol, color: Color(nsColor: .systemGray),
                             value: "Declarado", note: "el simulador no deja cambiarlo")
                        Divider().padding(.leading, 50)
                    }
                    notifications
                }
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
            }
            if model.declared.isEmpty {
                Text("Esta app no declara ningún permiso en su Info.plist, así que iOS no le dejará pedir ninguno.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Se aplican al momento. iOS puede cerrar la app al cambiar un permiso.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Restablecer todos") { model.resetPermissions() }
                    .help("Deja todos los permisos de la app en «Preguntar»")
                    .disabled(rows.isEmpty)
            }
        }
        .disabled(model.appID.isEmpty)
        .onAppear { model.loadPermissions() }
        .onChange(of: model.appID) { model.loadPermissions() }
        // A permission accepted inside the simulator shows up here without reopening the form.
        .onReceive(refresh) { _ in model.loadPermissions() }
    }

    private func tile(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
    }

    private func row(_ permission: Permission, choices: [Permission.Choice]) -> some View {
        let current = model.permissions[permission] ?? .ask
        return HStack(spacing: 0) {
            tile(permission.symbol, permission.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(permission.name).lineLimit(1)
                // What "limited" means here, for the two permissions that have it.
                if choices.contains(.partial) {
                    Text("Limitado: \(permission.label(.partial).lowercased())")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 12)
            Spacer(minLength: 8)
            ForEach(columns, id: \.choice) { column in
                Group {
                    if choices.contains(column.choice) {
                        radio(on: current == column.choice, label: "\(permission.name): \(permission.label(column.choice))") {
                            model.setPermission(permission, to: column.choice)
                        }
                    } else {
                        Text("–").foregroundStyle(.tertiary)
                    }
                }
                .frame(width: columnWidth)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
    }

    /// A radio button with no title: the column header says what it is.
    private func radio(on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(on ? Color(nsColor: .systemBlue) : .white.opacity(0.08))
                Circle().strokeBorder(.white.opacity(on ? 0 : 0.3), lineWidth: 1)
                if on { Circle().fill(.white).frame(width: 6, height: 6) }
            }
            .frame(width: 16, height: 16)
            .frame(width: 34, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// A row that only informs: a permission that cannot be changed from outside the simulator.
    private func info(_ name: String, symbol: String, color: Color, value: String, note: String) -> some View {
        HStack(spacing: 12) {
            tile(symbol, color)
            Text(name)
            Spacer(minLength: 8)
            Text(value)
            Text("· \(note)").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// Notifications are not declared in the Info.plist and cannot be granted from outside: only the app can ask.
    private var notifications: some View {
        let value: String
        switch model.pushPermission {
        case .allowed: value = "Permitidas"
        case .denied: value = "Denegadas"
        case .neverAsked: value = "Sin pedir"
        case .unknown: value = "Desconocido"
        }
        return info("Notificaciones", symbol: "bell.badge.fill", color: Color(nsColor: .systemRed),
                    value: value, note: "solo la app puede pedirlo")
    }
}
