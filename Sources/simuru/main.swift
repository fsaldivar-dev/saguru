import AppKit
import Foundation

let version = "0.1.0"
let bundleIdentifier = "dev.simuru.app"

let usage = """
Simuru \(version) — superpoderes para el Simulador de iOS.

USO
  simuru                                  Acopla el panel a la ventana del Simulador
  simuru quit                             Cierra el panel

  simuru devices                          Simuladores arrancados
  simuru apps                             Apps instaladas

  simuru push <app> [-t título] [-b texto] [--badge n] [--payload a.json]
  simuru media <archivo>…                 Añade fotos y videos a la librería
  simuru url <url>                        Abre una URL o deep link
  simuru location <lat> <lon> | clear     Simula la ubicación
  simuru privacy <grant|revoke|reset> <permiso> <app>
  simuru query <app> "<SQL>" [--db base]   Consulta de solo lectura a una base SQLite de la app

  simuru appearance <dark|light|toggle>
  simuru statusbar <clean|reset>          9:41, batería y señal llenas
  simuru textsize <tamaño|increment|decrement>
  simuru contrast <on|off>

  simuru data open <app>                  Abre la carpeta de datos en Finder
  simuru data erase <app> --yes           Vacía los datos de la app
  simuru defaults <app>                   Lista sus User Defaults
  simuru defaults <app> <clave> <valor> [--type string|bool|int|float]
  simuru defaults <app> <clave> --delete
  simuru relaunch <app> [--lang es] [--region MX]

OPCIONES
  -d, --device <texto>   Nombre (o parte) o UDID, si hay varios simuladores arrancados
  <app>                  Bundle ID, p. ej. com.miempresa.miapp
  permisos:              \(Simctl.privacyServices.joined(separator: " "))
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("simuru: \(message)\n".utf8))
    exit(1)
}

// MARK: Arguments

var arguments = Array(CommandLine.arguments.dropFirst())

func option(_ names: String...) -> String? {
    for name in names {
        guard let index = arguments.firstIndex(of: name) else { continue }
        guard index + 1 < arguments.count else { fail("falta el valor de \(name)") }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...index + 1)
        return value
    }
    return nil
}

func flag(_ names: String...) -> Bool {
    var found = false
    for name in names {
        while let index = arguments.firstIndex(of: name) {
            arguments.remove(at: index)
            found = true
        }
    }
    return found
}

/// Next positional argument, or exit with `what` explained.
func next(_ what: String) -> String {
    guard !arguments.isEmpty else { fail("falta \(what)\n\n\(usage)") }
    return arguments.removeFirst()
}

let deviceFilter = option("-d", "--device")
if flag("-h", "--help") { print(usage); exit(0) }
if flag("-v", "--version") { print(version); exit(0) }
let command = arguments.isEmpty ? "panel" : arguments.removeFirst()

func device() -> SimDevice {
    let booted = Simctl.booted()
    var matches = booted.filter { d in deviceFilter.map(d.matches) ?? true }
    // "iPhone 17" also matches "iPhone 17 Pro": an exact name or UDID wins.
    if let filter = deviceFilter?.lowercased(),
       let exact = matches.first(where: { $0.name.lowercased() == filter || $0.udid.lowercased() == filter }) {
        matches = [exact]
    }
    guard let first = matches.first else {
        fail(booted.isEmpty ? "no hay ningún simulador arrancado (prueba: open -a Simulator)"
                            : "ningún simulador coincide con «\(deviceFilter ?? "")»")
    }
    // Never guess which simulator was meant: acting on the wrong one goes unnoticed.
    guard matches.count == 1 else {
        let list = matches.map { "  \($0.name) (\($0.runtime))" }.joined(separator: "\n")
        fail("hay \(matches.count) simuladores arrancados; elige uno con -d:\n\(list)")
    }
    return first
}

func attempt(_ done: String, _ action: () throws -> Void) {
    do {
        try action()
        print(done)
    } catch {
        fail("\(error)")
    }
}

// MARK: Commands

switch command {
case "help":
    print(usage)

case "devices":
    let booted = Simctl.booted()
    if booted.isEmpty { print("No hay simuladores arrancados.") }
    for d in booted {
        print("\(d.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(d.runtime.padding(toLength: 12, withPad: " ", startingAt: 0)) \(d.udid)")
    }

case "apps":
    for app in Simctl.apps(device().udid) {
        print("\(app.bundleID.padding(toLength: 44, withPad: " ", startingAt: 0)) \(app.name)\(app.isUser ? "" : " (sistema)")")
    }

case "push":
    let title = option("-t", "--title") ?? "Hola"
    let body = option("-b", "--body") ?? "Notificación de prueba"
    let badge = option("--badge").flatMap(Int.init)
    let payloadPath = option("--payload")
    let bundleID = next("el bundle ID de la app")
    var payload = Simctl.pushPayload(title: title, body: body, badge: badge)
    if let payloadPath {
        guard let data = FileManager.default.contents(atPath: (payloadPath as NSString).expandingTildeInPath) else {
            fail("no se pudo leer \(payloadPath)")
        }
        payload = data
    }
    let target = device()
    do {
        let permission = try Simctl.push(target.udid, bundleID: bundleID, payload: payload)
        print("Notificación enviada a \(bundleID) en \(target.name)")
        if let warning = permission.warning {
            FileHandle.standardError.write(Data("simuru: aviso: \(warning)\n".utf8))
        }
    } catch {
        fail("\(error)")
    }

case "media":
    let files = arguments.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    attempt("\(files.count) archivo(s) añadidos a Fotos") { try Simctl.addMedia(device().udid, files: files) }

case "url":
    let url = next("la URL")
    attempt("URL abierta") { try Simctl.openURL(device().udid, url) }

case "location":
    let first = next("la latitud o «clear»")
    if first == "clear" {
        attempt("Ubicación restablecida") { try Simctl.clearLocation(device().udid) }
    } else {
        guard let latitude = Double(first), let longitude = Double(next("la longitud")) else { fail("latitud y longitud deben ser números") }
        attempt("Ubicación establecida en \(latitude), \(longitude)") {
            try Simctl.setLocation(device().udid, latitude: latitude, longitude: longitude)
        }
    }

case "privacy":
    let action = next("la acción (grant, revoke o reset)")
    guard ["grant", "revoke", "reset"].contains(action) else { fail("acción desconocida: \(action)") }
    let service = next("el permiso")
    let bundleID = next("el bundle ID de la app")
    attempt("Hecho: \(action) \(service) para \(bundleID)") {
        try Simctl.privacy(device().udid, action: action, service: service, bundleID: bundleID)
    }

case "appearance":
    let udid = device().udid
    var value = next("dark, light o toggle")
    if value == "toggle" { value = Simctl.appearance(udid) == "dark" ? "light" : "dark" }
    guard ["dark", "light"].contains(value) else { fail("apariencia desconocida: \(value)") }
    attempt("Apariencia: \(value)") { try Simctl.setAppearance(udid, value) }

case "statusbar":
    switch next("clean o reset") {
    case "clean": attempt("Barra de estado limpia") { try Simctl.cleanStatusBar(device().udid) }
    case "reset": attempt("Barra de estado restaurada") { try Simctl.resetStatusBar(device().udid) }
    case let other: fail("opción desconocida: \(other)")
    }

case "textsize":
    let udid = device().udid
    let value = next("el tamaño (\(Simctl.contentSizes.joined(separator: ", ")), increment o decrement)")
    guard Simctl.contentSizes.contains(value) || ["increment", "decrement"].contains(value) else { fail("tamaño desconocido: \(value)") }
    attempt("Tamaño de texto cambiado") { try Simctl.setContentSize(udid, value) }
    print(Simctl.contentSize(udid))

case "contrast":
    let value = next("on u off")
    guard ["on", "off"].contains(value) else { fail("usa on u off") }
    attempt("Aumentar contraste: \(value)") { try Simctl.setIncreaseContrast(device().udid, value == "on") }

case "query":
    let wanted = option("--db")
    let bundleID = next("el bundle ID de la app")
    let sql = next("la consulta SQL")
    let container: URL
    do { container = try Simctl.dataContainer(device().udid, bundleID: bundleID) } catch { fail("\(error)") }
    var databases: [(path: String, url: URL)] = []
    let prefix = container.resolvingSymlinksInPath().path + "/"
    if let files = FileManager.default.enumerator(at: container, includingPropertiesForKeys: nil) {
        for case let url as URL in files where !url.path.hasSuffix("-wal") && !url.path.hasSuffix("-shm") && SQLiteReader.isDatabase(url) {
            let path = url.resolvingSymlinksInPath().path
            databases.append((path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent, url))
        }
    }
    databases.sort { $0.path < $1.path }
    let matches = wanted.map { name in databases.filter { $0.path == name || $0.path.hasSuffix("/" + name) || $0.url.lastPathComponent == name } } ?? databases
    guard !matches.isEmpty else { fail(databases.isEmpty ? "\(bundleID) no tiene bases de datos SQLite" : "ninguna base coincide con «\(wanted ?? "")»") }
    guard matches.count == 1 else {
        fail("hay \(matches.count) bases de datos; elige una con --db:\n" + matches.map { "  \($0.path)" }.joined(separator: "\n"))
    }
    let result = SQLiteReader.query(matches[0].url, sql)
    if let error = result.error { fail(error) }
    print(result.columns.joined(separator: "\t"))
    for row in result.rows { print(row.joined(separator: "\t")) }
    if result.truncated { FileHandle.standardError.write(Data("simuru: se muestran las primeras \(SQLiteReader.rowLimit) filas\n".utf8)) }

case "data":
    let action = next("open o erase")
    let confirmed = flag("--yes")
    let bundleID = next("el bundle ID de la app")
    switch action {
    case "open":
        attempt("Carpeta abierta") {
            let url = try Simctl.dataContainer(device().udid, bundleID: bundleID)
            print(url.path)
            NSWorkspace.shared.open(url)
        }
    case "erase":
        guard confirmed else { fail("esto vacía Documents, Library y tmp de \(bundleID) y no se puede deshacer; repite con --yes") }
        attempt("Datos de \(bundleID) borrados") { try Simctl.eraseData(device().udid, bundleID: bundleID) }
    default:
        fail("acción desconocida: \(action)")
    }

case "defaults":
    let type = option("--type") ?? "string"
    let delete = flag("--delete")
    let bundleID = next("el bundle ID de la app")
    let udid = device().udid
    if arguments.isEmpty {
        let values = Simctl.defaults(udid, bundleID: bundleID)
        if values.isEmpty { print("Sin valores guardados.") }
        for key in values.keys.sorted() { print("\(key) = \(values[key]!)") }
    } else {
        let key = arguments.removeFirst()
        if delete {
            attempt("Clave \(key) eliminada") { try Simctl.deleteDefault(udid, bundleID: bundleID, key: key) }
        } else {
            guard ["string", "bool", "int", "float"].contains(type) else { fail("tipo desconocido: \(type)") }
            let value = next("el valor")
            attempt("\(key) = \(value)") { try Simctl.writeDefault(udid, bundleID: bundleID, key: key, type: type, value: value) }
        }
    }

case "relaunch":
    let language = option("--lang", "--language")
    let region = option("--region")
    let bundleID = next("el bundle ID de la app")
    attempt("App reiniciada") { try Simctl.relaunch(device().udid, bundleID: bundleID, language: language, region: region) }

case "quit":
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    running.forEach { $0.terminate() }
    print(running.isEmpty ? "Simuru no estaba abierto." : "Simuru cerrado.")

case "panel":
    // From a terminal, hand over to Simuru.app through LaunchServices: the command returns at once,
    // a second call reuses the running panel, and permissions belong to Simuru rather than the terminal.
    let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if bundle.pathExtension == "app", ProcessInfo.processInfo.environment["SIMURU_APP"] == nil {
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-a", bundle.path, "--env", "SIMURU_APP=1"]
        do { try launcher.run() } catch { fail("no se pudo abrir \(bundle.path)") }
        launcher.waitUntilExit()
        if Simctl.booted().isEmpty { print("Panel listo. Aparecerá junto al Simulador cuando arranques uno.") }
        exit(launcher.terminationStatus)
    }
    let app = NSApplication.shared
    let controller = PanelController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()

default:
    fail("comando desconocido: \(command)\n\n\(usage)")
}
