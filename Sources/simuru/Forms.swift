import SwiftUI

/// Shared layout for every popover: a title and a narrow column of controls.
private struct FormBox<Content: View>: View {
    let title: String
    var width: CGFloat = 264
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .textFieldStyle(.roundedBorder)
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(14)
        .frame(width: width, alignment: .leading)
    }
}

private struct AppPicker: View {
    @ObservedObject var model: PanelModel
    @Binding var bundleID: String

    var body: some View {
        Picker("App", selection: $bundleID) {
            if model.apps.isEmpty { Text("Sin apps").tag("") }
            ForEach(model.apps) { app in
                Text(app.isUser ? app.name : "\(app.name) (sistema)").tag(app.bundleID)
            }
        }
        .onAppear(perform: fix)
        .onChange(of: model.apps) { fix() }
    }

    /// Falls back to the first (user) app when the remembered one is not installed on this simulator.
    private func fix() {
        if !model.apps.contains(where: { $0.bundleID == bundleID }) { bundleID = model.apps.first?.bundleID ?? "" }
    }
}

struct PushForm: View {
    @ObservedObject var model: PanelModel
    @AppStorage("app") private var bundleID = ""
    @AppStorage("push.title") private var title = "Hola"
    @AppStorage("push.body") private var message = "Notificación de prueba"
    @AppStorage("push.badge") private var badge = ""

    var body: some View {
        FormBox(title: "Notificación push") {
            AppPicker(model: model, bundleID: $bundleID)
            TextField("Título", text: $title)
            TextField("Texto", text: $message)
            TextField("Badge (opcional)", text: $badge)
            HStack {
                Spacer()
                Button("Enviar") { model.sendPush(bundleID: bundleID, title: title, body: message, badge: Int(badge)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(bundleID.isEmpty)
            }
        }
        .onAppear { model.reloadApps() }
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
    @AppStorage("app") private var bundleID = ""
    @AppStorage("privacy.service") private var service = "photos"

    var body: some View {
        FormBox(title: "Permisos") {
            AppPicker(model: model, bundleID: $bundleID)
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
    @AppStorage("app") private var bundleID = ""
    @AppStorage("data.language") private var language = ""
    @AppStorage("data.region") private var region = ""
    @State private var search = ""

    private var entries: [DefaultsEntry] {
        search.isEmpty ? model.defaults : model.defaults.filter { $0.key.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        FormBox(title: "Datos de la app", width: 340) {
            AppPicker(model: model, bundleID: $bundleID)
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
        .onChange(of: bundleID) { model.loadDefaults(bundleID: bundleID) }
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
