import AppKit
import MapKit
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
struct FormBox<Content: View>: View {
    let title: String
    /// Simulator the action applies to, shown so it is never a guess when several are open.
    var device: String?
    var width: CGFloat = 264
    /// When set, the header shows the app and simulator the form acts on.
    var target: PanelModel?
    /// For forms that act on the simulator rather than on an app: a symbol in place of the app icon.
    var symbol: String?
    @ViewBuilder let content: () -> Content

    private var roomy: Bool { target != nil || symbol != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: roomy ? 16 : 10) {
            if let symbol {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.title3.weight(.semibold))
                        Text(device ?? "Ningún simulador arrancado").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else if let target {
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
        .controlSize(roomy ? .regular : .small)
        .padding(roomy ? 20 : 14)
        .frame(width: width, alignment: .leading)
    }
}

/// A field with its name above it, so the name stays visible while typing.
struct Labeled<Content: View>: View {
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

/// Lays its children out left to right, wrapping to a new line when the row is full.
private struct Flow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, origin) in arrange(width: bounds.width, subviews: subviews).origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: min(widest, width), height: y + rowHeight), origins)
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
                    .buttonStyle(PrimaryButtonStyle())
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
    @AppStorage("url") private var url = ""
    @FocusState private var typing: Bool

    private var trimmed: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        FormBox(title: "Deep links", width: 400, target: model) {
            Labeled("Enlace") {
                HStack(spacing: 8) {
                    TextField("miapp://ruta o https://…", text: $url)
                        .focused($typing)
                        .onSubmit { model.openURL(url) }
                    let saved = model.favoriteLinks.contains(trimmed)
                    Button {
                        model.setFavorite(trimmed, !saved)
                    } label: {
                        Image(systemName: saved ? "star.fill" : "star")
                    }
                    .help(saved ? "Quitar de favoritos" : "Guardar en favoritos")
                    .accessibilityLabel(saved ? "Quitar de favoritos" : "Guardar en favoritos")
                    .disabled(trimmed.isEmpty)
                }
            }
            declared
            if !model.favoriteLinks.isEmpty {
                Divider()
                list("Favoritos", model.favoriteLinks, symbol: "star.slash", help: "Quitar de favoritos") {
                    model.setFavorite($0, false)
                }
            }
            if !model.recentLinks.isEmpty {
                Divider()
                list("Recientes", model.recentLinks, symbol: "xmark", help: "Quitar del historial") {
                    model.forgetRecent($0)
                }
            }
            HStack {
                Spacer()
                Button("Abrir") { model.openURL(url) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(trimmed.isEmpty)
            }
        }
        .onAppear {
            model.loadLinks()
            typing = true
        }
        .onChange(of: model.appID) { model.loadLinks() }
    }

    /// What the app itself declares. Tapping one starts the link with it.
    @ViewBuilder
    private var declared: some View {
        let links = model.links
        VStack(alignment: .leading, spacing: 6) {
            Text("Declarados por la app").font(.callout).foregroundStyle(.secondary)
            if links.schemes.isEmpty && links.domains.isEmpty {
                Text(links.hidden > 0
                     ? "Solo declara esquemas de inicio de sesión o web, no enlaces propios."
                     : "Esta app no declara esquemas ni dominios.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            } else {
                Flow(spacing: 6) {
                    ForEach(links.schemes, id: \.self) { scheme in chip("\(scheme)://") }
                    ForEach(links.domains, id: \.self) { domain in chip("https://\(domain)/") }
                }
            }
            Text("Las rutas no se pueden leer de la app: guarda en favoritos las que uses.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chip(_ prefix: String) -> some View {
        Button {
            url = prefix
            typing = true
        } label: {
            Text(prefix).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
        }
        .controlSize(.small)
        .help("Empezar el enlace con \(prefix)")
    }

    private func list(_ title: String, _ items: [String], symbol: String, help: String,
                      remove: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            ForEach(items, id: \.self) { item in
                HStack(spacing: 8) {
                    Button {
                        url = item
                        model.openURL(item)
                    } label: {
                        Text(item).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Abrir \(item)")
                    Button {
                        remove(item)
                    } label: {
                        Image(systemName: symbol)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(help)
                    .accessibilityLabel("\(help): \(item)")
                }
            }
        }
    }
}

struct LocationForm: View {
    @ObservedObject var model: PanelModel
    @AppStorage("location.lat") private var latitude = "19.4326"
    @AppStorage("location.lon") private var longitude = "-99.1332"
    @State private var camera = MapCameraPosition.automatic
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var nothingFound = false

    private var point: CLLocationCoordinate2D? {
        guard let lat = Double(latitude), let lon = Double(longitude),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var body: some View {
        FormBox(title: "Ubicación", device: model.device?.name, width: 420, symbol: "location") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Buscar un lugar o una dirección", text: $query).onSubmit(search)
                    if searching { ProgressView().controlSize(.small) }
                }
                ForEach(results, id: \.self) { item in
                    Button {
                        move(to: item.placemark.coordinate, zoom: true)
                        results = []
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name ?? "Lugar").lineLimit(1)
                            if let detail = item.placemark.title, detail != item.name {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if nothingFound { Text("Sin resultados").font(.callout).foregroundStyle(.secondary) }
            }
            MapReader { proxy in
                Map(position: $camera) {
                    if let point { Marker("", coordinate: point).tint(Color(nsColor: .systemBlue)) }
                }
                .onTapGesture { position in
                    if let coordinate = proxy.convert(position, from: .local) { move(to: coordinate, zoom: false) }
                }
            }
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .help("Haz clic en el mapa para elegir el punto")
            HStack(spacing: 10) {
                Labeled("Latitud") { TextField("", text: $latitude) }
                Labeled("Longitud") { TextField("", text: $longitude) }
            }
            if let current = model.device.flatMap({ model.simulatedLocations[$0.udid] }) {
                Label("Simulando \(current)", systemImage: "location.fill")
                    .font(.callout).foregroundStyle(Color(nsColor: .systemGreen))
            } else {
                Text("Haz clic en el mapa para elegir el punto.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Restablecer") { model.clearLocation() }
                    .help("Deja de simular una ubicación")
                Spacer()
                Button("Establecer aquí") {
                    if let point { model.setLocation(latitude: point.latitude, longitude: point.longitude) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(point == nil || model.device == nil)
            }
        }
        .onAppear { if let point { camera = Self.region(point, wide: true) } }
        .onChange(of: latitude) { recenter() }
        .onChange(of: longitude) { recenter() }
    }

    private static func region(_ center: CLLocationCoordinate2D, wide: Bool) -> MapCameraPosition {
        let span = wide ? 0.08 : 0.02
        return .region(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))
    }

    /// Typing coordinates moves the map to them. A point chosen on the map or from the search has
    /// already put the map where it should be, so those coordinates are left alone.
    @State private var placedByMap = ""

    private func recenter() {
        guard "\(latitude)|\(longitude)" != placedByMap else { return }
        if let point { camera = Self.region(point, wide: true) }
    }

    private func move(to coordinate: CLLocationCoordinate2D, zoom: Bool) {
        let format = { (value: Double) in String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), value) }
        placedByMap = "\(format(coordinate.latitude))|\(format(coordinate.longitude))"
        latitude = String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), coordinate.latitude)
        longitude = String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), coordinate.longitude)
        if zoom { camera = Self.region(coordinate, wide: false) }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { results = []; return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        searching = true
        nothingFound = false
        MKLocalSearch(request: request).start { response, _ in
            searching = false
            results = Array((response?.mapItems ?? []).prefix(4))
            nothingFound = results.isEmpty
        }
    }
}

struct AppearanceForm: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        FormBox(title: "Apariencia", device: model.device?.name, width: 340, symbol: "circle.lefthalf.filled") {
            Picker("Apariencia", selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) })) {
                Text("Claro").tag("light")
                Text("Oscuro").tag("dark")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Divider()
            HStack {
                Toggle("Comparar claro y oscuro", isOn: Binding(get: { model.split == .appearance || model.capturing },
                                                                set: { _ in model.toggleAppearanceSplit() }))
                Spacer()
                if model.capturing { ProgressView().controlSize(.small) }
            }
            if model.split == .appearance {
                Text("\(model.splitLabels.0) a la izquierda, \(model.splitLabels.1) a la derecha.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("El lado derecho es la app en vivo. El izquierdo es una foto de la otra apariencia, que Simuru vuelve a tomar sola cuando la pantalla cambia y se queda quieta. Arrastra el tirador para comparar.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.loadAppearance() }
    }
}

struct StatusBarForm: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        FormBox(title: "Barra de estado", device: model.device?.name, width: 420, symbol: "antenna.radiowaves.left.and.right") {
            Toggle("Personalizar la barra de estado", isOn: Binding(get: { model.cleanBar }, set: { model.setStatusBar(on: $0) }))
            VStack(alignment: .leading, spacing: 14) {
                Labeled("Hora") { TextField("9:41", text: $model.statusBar.time).frame(width: 90) }
                Divider()
                Labeled("Wi-Fi") {
                    Picker("Wi-Fi", selection: $model.statusBar.wifiOn) {
                        Text("Conectado").tag(true)
                        Text("Apagado").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if model.statusBar.wifiOn { level("Intensidad", $model.statusBar.wifiBars, upTo: 3) }
                }
                Divider()
                Labeled("Red celular") {
                    Picker("Red celular", selection: $model.statusBar.cellular) {
                        ForEach(Simctl.StatusBar.cellularModes, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if model.statusBar.cellular == "active" {
                        level("Barras", $model.statusBar.cellularBars, upTo: 4)
                        HStack(spacing: 10) {
                            Text("Datos").foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                            Picker("Datos", selection: $model.statusBar.data) {
                                ForEach(Simctl.StatusBar.dataTypes, id: \.id) { Text($0.name).tag($0.id) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        .disabled(model.statusBar.wifiOn)
                        if model.statusBar.wifiOn {
                            Text("El tipo de datos se ve en la barra cuando el Wi-Fi está apagado, como en un iPhone.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Divider()
                Labeled("Batería") {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { Double(model.statusBar.batteryLevel) },
                                              set: { model.statusBar.batteryLevel = Int($0.rounded()) }), in: 0...100)
                        Text("\(model.statusBar.batteryLevel) %").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                    Toggle("Cargando", isOn: $model.statusBar.charging)
                }
            }
            .disabled(!model.cleanBar)
            .opacity(model.cleanBar ? 1 : 0.5)
            HStack {
                Text("Solo cambia lo que se ve; se pierde al reiniciar el simulador.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Valores de catálogo") { model.statusBar = .catalog }
                    .help("9:41, señal completa y batería llena, como en las imágenes de Apple")
            }
        }
    }

    private func level(_ name: String, _ value: Binding<Int>, upTo top: Int) -> some View {
        HStack(spacing: 10) {
            Text(name).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            Picker(name, selection: value) {
                ForEach(0...top, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
