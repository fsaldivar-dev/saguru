import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared pieces

/// Icons of the apps installed in a simulator, read from their bundles on this Mac.
enum AppIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for app: SimApp) -> NSImage? {
        guard let path = app.path else { return nil }
        if let cached = cache.object(forKey: path as NSString) { return cached }
        // Xcode leaves "AppIcon60x60@2x.png" (or the name the app chose) next to the binary.
        let bundle = URL(fileURLWithPath: path)
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Info.plist"))
        let primary = (info?["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
        var names = (primary?["CFBundleIconFiles"] as? [String])?.reversed().map { "\($0)@2x.png" } ?? []
        names.append("AppIcon60x60@2x.png")
        guard let image = names.lazy.compactMap({ NSImage(contentsOf: bundle.appendingPathComponent($0)) }).first
        else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

/// An app's icon, or its initials on a tile when it has none.
struct AppBadge: View {
    let app: SimApp?
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let app, let icon = AppIcons.icon(for: app) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(.white.opacity(0.12))
                    .overlay {
                        if let app {
                            Text(String(app.name.prefix(2))).font(.system(size: size * 0.38, weight: .semibold))
                        } else {
                            Image(systemName: "app.dashed").font(.system(size: size * 0.5))
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

/// Shared layout for every popover. `roomy` forms have a header with the target and labels above fields.
private struct FormBox<Content: View>: View {
    let title: String
    /// Simulator the action applies to, shown so it is never a guess when several are open.
    var device: String?
    var width: CGFloat = 264
    /// When set, the header shows the app and simulator the form acts on.
    var target: PanelModel?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: target == nil ? 10 : 16) {
            if let target {
                HStack(spacing: 12) {
                    AppBadge(app: target.app, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.title3.weight(.semibold))
                        Text(target.target).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    if let device { Text(device).font(.caption).foregroundStyle(.secondary) }
                }
            }
            content()
        }
        .textFieldStyle(.roundedBorder)
        .toggleStyle(.switch)
        .controlSize(target == nil ? .small : .regular)
        .padding(target == nil ? 14 : 20)
        .frame(width: width, alignment: .leading)
    }
}

/// A field with its name above it, so the name stays visible while typing.
private struct Labeled<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Context: simulator and app, chosen once

struct ContextForm: View {
    @ObservedObject var model: PanelModel
    @AppStorage("context.onlyMine") private var onlyMine = true
    @State private var search = ""
    @FocusState private var searching: Bool

    private var apps: [SimApp] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        return model.apps.filter { app in
            (!onlyMine || app.isUser || app.bundleID == model.appID)
                && (needle.isEmpty || app.name.localizedCaseInsensitiveContains(needle)
                    || app.bundleID.localizedCaseInsensitiveContains(needle))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Labeled("Simulador") {
                if model.devices.count > 1 {
                    Picker("", selection: Binding(get: { model.selected ?? "" }, set: { model.select($0) })) {
                        ForEach(model.devices) { device in
                            Text("\(device.name) · \(device.runtime)").tag(device.udid)
                        }
                    }
                    .labelsHidden()
                    if !model.knowsWindowDevice {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Simuru no puede ver a qué simulador está pegado.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button("Permitir") {
                                SimulatorAX.requestAccess()
                                model.say("Activa Simuru en Accesibilidad y vuelve a abrirlo")
                            }
                            .controlSize(.small)
                            .help("Con el permiso de Accesibilidad, Simuru lee el título de la ventana y elige el simulador solo")
                        }
                    }
                } else {
                    Text(model.device.map { "\($0.name) · \($0.runtime)" } ?? "Ningún simulador arrancado")
                }
            }
            Labeled("App") {
                TextField("Buscar app", text: $search).focused($searching)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(apps) { app in row(app) }
                        if apps.isEmpty {
                            Text(model.apps.isEmpty ? "Este simulador no tiene apps" : "Sin resultados")
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                        }
                    }
                }
                .frame(height: 252)
            }
            Toggle("Solo mis apps", isOn: $onlyMine)
        }
        .textFieldStyle(.roundedBorder)
        .toggleStyle(.switch)
        .padding(20)
        .frame(width: 360, alignment: .leading)
        .onAppear {
            model.reloadApps()
            searching = true
        }
    }

    private func row(_ app: SimApp) -> some View {
        let chosen = app.bundleID == model.appID
        return Button {
            model.chooseApp(app.bundleID)
            model.openTool = nil
        } label: {
            HStack(spacing: 12) {
                AppBadge(app: app, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.body).lineLimit(1)
                    Text(app.isUser ? app.bundleID : "\(app.bundleID) · sistema")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if chosen { Image(systemName: "checkmark").foregroundStyle(Color(nsColor: .systemBlue)) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(chosen ? AnyShapeStyle(Color(nsColor: .systemBlue).opacity(0.22)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Push

/// One extra field of the payload, next to "aps".
private struct PushDatum: Identifiable, Codable, Equatable {
    var id = UUID()
    var key = ""
    var value = ""

    /// "42" is sent as a number and "true" as a boolean; anything else as text.
    /// The JSON view is there for the cases where that guess is wrong.
    var typed: Any {
        let text = value.trimmingCharacters(in: .whitespaces)
        if text == "true" { return true }
        if text == "false" { return false }
        if let integer = Int(text) { return integer }
        if let number = Double(text), text.contains(".") { return number }
        return value
    }
}

struct PushForm: View {
    @ObservedObject var model: PanelModel
    @AppStorage("push.title") private var title = "Hola"
    @AppStorage("push.subtitle") private var subtitle = ""
    @AppStorage("push.body") private var message = "Notificación de prueba"
    @AppStorage("push.badge") private var badge = ""
    @AppStorage("push.sound") private var sound = true
    @AppStorage("push.data") private var storedData = "[]"
    @State private var data: [PushDatum] = []
    @State private var showJSON = false
    @State private var json = ""

    private var formPayload: Data {
        Simctl.pushPayload(title: title, subtitle: subtitle, body: message, badge: Int(badge), sound: sound,
                           data: data.map { ($0.key.trimmingCharacters(in: .whitespaces), $0.typed) })
    }

    private var jsonIsValid: Bool {
        (try? JSONSerialization.jsonObject(with: Data(plainQuotes(json).utf8))) is [String: Any]
    }

    /// macOS turns typed quotes into curly ones in text editors, which is not JSON.
    private func plainQuotes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
    }

    var body: some View {
        FormBox(title: "Notificación push", width: 400, target: model) {
            if showJSON { jsonEditor } else { fields }
            permission
            HStack {
                Button(showJSON ? "Ver formulario" : "Ver JSON") {
                    if !showJSON { json = String(decoding: formPayload, as: UTF8.self) }
                    showJSON.toggle()
                }
                if showJSON { Button("Abrir .apns…") { openFile() } }
                Spacer()
                Button("Enviar") { model.sendPush(payload: showJSON ? Data(plainQuotes(json).utf8) : formPayload) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.appID.isEmpty || (showJSON && !jsonIsValid))
            }
        }
        .onAppear {
            badge = badge.filter(\.isNumber)
            data = (try? JSONDecoder().decode([PushDatum].self, from: Data(storedData.utf8))) ?? []
            model.reloadApps()
        }
        .onChange(of: data) {
            storedData = (try? JSONEncoder().encode(data)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        }
    }

    @ViewBuilder
    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Labeled("Título") { TextField("", text: $title) }
            Labeled("Subtítulo") { TextField("Opcional", text: $subtitle) }
            Labeled("Texto") { TextField("", text: $message, axis: .vertical).lineLimit(2...4) }
        }
        Divider()
        HStack {
            Text("Badge")
            TextField("", text: $badge)
                .frame(width: 64)
                .onChange(of: badge) { badge = badge.filter(\.isNumber) }
            Spacer()
            Toggle("Sonido", isOn: $sound)
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Datos para la app").font(.headline)
                Spacer()
                Button {
                    data.append(PushDatum())
                } label: {
                    Label("Añadir", systemImage: "plus")
                }
                .controlSize(.small)
            }
            if data.isEmpty {
                Text("Campos propios del payload, como un identificador o un deep link.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach($data) { $datum in
                HStack(spacing: 8) {
                    TextField("clave", text: $datum.key).frame(width: 120)
                    TextField("valor", text: $datum.value)
                    Button {
                        data.removeAll { $0.id == datum.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Quitar \(datum.key)")
                }
            }
        }
    }

    private var jsonEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $json)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(height: 260)
            if !jsonIsValid {
                Label("El JSON no es válido", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Color(nsColor: .systemOrange))
            }
        }
    }

    /// Says before sending whether iOS will show it, instead of finding out afterwards.
    @ViewBuilder
    private var permission: some View {
        switch model.pushPermission {
        case .allowed:
            Label("La app tiene permiso de notificaciones", systemImage: "checkmark.circle")
                .font(.callout).foregroundStyle(Color(nsColor: .systemGreen))
        case .denied, .neverAsked:
            Label(model.pushPermission == .denied
                    ? "La app tiene las notificaciones denegadas: iOS no la mostrará."
                    : "La app aún no ha pedido permiso de notificaciones: iOS no la mostrará.",
                  systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(Color(nsColor: .systemOrange))
                .fixedSize(horizontal: false, vertical: true)
        case .unknown:
            EmptyView()
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "apns") ?? .json]
        panel.begin { response in
            guard response == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            json = text
        }
    }
}

struct URLForm: View {
    @ObservedObject var model: PanelModel
    @AppStorage("url") private var url = "https://apple.com"

    var body: some View {
        FormBox(title: "Abrir URL") {
            TextField("miapp://ruta o https://…", text: $url)
            HStack {
                Spacer()
                Button("Abrir") { model.openURL(url) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

struct LocationForm: View {
    @ObservedObject var model: PanelModel
    @AppStorage("location.lat") private var latitude = "19.4326"
    @AppStorage("location.lon") private var longitude = "-99.1332"

    private let presets: [(String, String, String)] = [
        ("Ciudad de México", "19.4326", "-99.1332"), ("Madrid", "40.4168", "-3.7038"),
        ("Cupertino", "37.3349", "-122.0090"), ("Tokio", "35.6762", "139.6503"),
    ]

    var body: some View {
        FormBox(title: "Ubicación") {
            HStack {
                TextField("Latitud", text: $latitude)
                TextField("Longitud", text: $longitude)
            }
            Menu("Lugares") {
                ForEach(presets, id: \.0) { preset in
                    Button(preset.0) { latitude = preset.1; longitude = preset.2 }
                }
            }
            HStack {
                Button("Restablecer") { model.clearLocation() }
                Spacer()
                Button("Establecer") {
                    if let lat = Double(latitude), let lon = Double(longitude) { model.setLocation(latitude: lat, longitude: lon) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(Double(latitude) == nil || Double(longitude) == nil)
            }
        }
    }
}

struct PrivacyForm: View {
    @ObservedObject var model: PanelModel
    @AppStorage("privacy.service") private var service = "photos"
    private var bundleID: String { model.appID }

    var body: some View {
        FormBox(title: "Permisos", width: 340, target: model) {
            Picker("Permiso", selection: $service) {
                ForEach(Simctl.privacyServices, id: \.self) { Text($0 == "all" ? "Todos" : $0).tag($0) }
            }
            HStack {
                Button("Restablecer") { model.privacy(action: "reset", service: service, bundleID: bundleID) }
                Spacer()
                Button("Revocar") { model.privacy(action: "revoke", service: service, bundleID: bundleID) }
                Button("Conceder") { model.privacy(action: "grant", service: service, bundleID: bundleID) }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(bundleID.isEmpty)
        }
        .onAppear { model.reloadApps() }
    }
}

struct AccessibilityForm: View {
    @ObservedObject var model: PanelModel

    private var index: Binding<Double> {
        Binding(get: { Double(Simctl.contentSizes.firstIndex(of: model.contentSize) ?? 3) },
                set: { model.setContentSize(Simctl.contentSizes[Int($0.rounded())]) })
    }

    var body: some View {
        FormBox(title: "Accesibilidad") {
            Text("Tamaño de texto").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: "textformat.size.smaller")
                Slider(value: index, in: 0...Double(Simctl.contentSizes.count - 1), step: 1)
                Image(systemName: "textformat.size.larger")
            }
            Text(model.contentSize).font(.caption).foregroundStyle(.secondary)
            Toggle("Aumentar contraste", isOn: Binding(get: { model.increaseContrast },
                                                       set: { model.setIncreaseContrast($0) }))
        }
        .onAppear { model.loadAccessibility() }
    }
}

struct DataForm: View {
    @ObservedObject var model: PanelModel
    private var bundleID: String { model.appID }
    @AppStorage("data.language") private var language = ""
    @AppStorage("data.region") private var region = ""
    @State private var search = ""

    private var entries: [DefaultsEntry] {
        search.isEmpty ? model.defaults : model.defaults.filter { $0.key.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        FormBox(title: "Datos de la app", width: 380, target: model) {
            HStack {
                Button("Abrir carpeta") { model.openDataFolder(bundleID: bundleID) }
                Spacer()
                Button("Borrar datos…", role: .destructive) { model.eraseData(bundleID: bundleID) }
            }
            HStack {
                TextField("Idioma: es", text: $language).frame(width: 96)
                TextField("Región: MX", text: $region).frame(width: 100)
                Spacer()
                Button("Reiniciar") { model.relaunch(bundleID: bundleID, language: language, region: region) }
            }
            Divider()
            HStack {
                Text("User Defaults").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                TextField("Buscar", text: $search).frame(width: 130)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if entries.isEmpty {
                        Text("Sin valores guardados").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        DefaultsRow(model: model, bundleID: bundleID, entry: entry)
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(height: entries.isEmpty ? 22 : min(200, CGFloat(entries.count) * 46))
        }
        .disabled(bundleID.isEmpty)
        .onAppear {
            model.reloadApps()
            model.loadDefaults(bundleID: bundleID)
        }
        .onChange(of: model.appID) { model.loadDefaults(bundleID: model.appID) }
    }
}

private struct DefaultsRow: View {
    @ObservedObject var model: PanelModel
    let bundleID: String
    let entry: DefaultsEntry
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.key).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 6) {
                switch entry.kind {
                case .bool:
                    Toggle("", isOn: Binding(
                        get: { entry.text == "true" },
                        set: { model.writeDefault(bundleID: bundleID, key: entry.key, kind: .bool, value: $0 ? "true" : "false") }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    Spacer()
                case .other:
                    Text(entry.text).font(.callout)
                    Spacer()
                default:
                    TextField("", text: $text)
                        .onSubmit { model.writeDefault(bundleID: bundleID, key: entry.key, kind: entry.kind, value: text) }
                }
                Button {
                    model.deleteDefault(bundleID: bundleID, key: entry.key)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Eliminar \(entry.key)")
            }
        }
        .onAppear { text = entry.text }
        .onChange(of: entry.text) { text = entry.text }
    }
}

struct OverlayForm: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        FormBox(title: "Superponer diseño") {
            if model.overlayImage == nil {
                Text("Elige la imagen del diseño para compararla con la app.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Toggle("Mostrar", isOn: $model.overlayVisible)
                HStack(spacing: 8) {
                    Image(systemName: "circle.dotted")
                    Slider(value: $model.overlayOpacity, in: 0.05...1)
                    Image(systemName: "circle.fill")
                }
            }
            HStack {
                if model.overlayImage != nil {
                    Button("Quitar") { model.overlayImage = nil }
                }
                Spacer()
                Button(model.overlayImage == nil ? "Elegir imagen…" : "Cambiar…") { model.pickOverlay() }
            }
        }
    }
}

struct GridForm: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        FormBox(title: "Cuadrícula") {
            Toggle("Mostrar", isOn: Binding(get: { model.gridOn }, set: { _ in model.toggleGrid() }))
            Picker("Separación", selection: $model.gridSpacing) {
                ForEach([4.0, 8, 10, 16, 20, 24], id: \.self) { Text("\(Int($0)) pt").tag($0) }
            }
        }
    }
}
