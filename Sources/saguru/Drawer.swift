import AppKit
import SwiftUI

/// The panel docked beside the Simulator. Every tool of the rail opens here, one at a time, so they all
/// read as one more part of the Simulator instead of as loose windows and balloons.
struct DrawerView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        ZStack {
            // One or the other: a field of the panel left underneath would keep the keyboard and show its focus ring.
            if model.onboarding {
                OnboardingView(model: model).transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    ToolBar(model: model)
                    Rectangle().fill(.white.opacity(0.09)).frame(height: 1)
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .transition(.opacity)
            }
        }
        .frame(minWidth: 590)
        // Escape leaves the full-screen panel, as it does a full-screen window.
        .onExitCommand { if model.expanded { model.expanded = false } }
        .modifier(MediaDrop(model: model))
        .background(Color(red: 0.13, green: 0.13, blue: 0.145))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        // An accessory app is rarely "active", and macOS greys the accent of inactive apps.
        .tint(Color(nsColor: .systemBlue))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch model.openTool {
        case .network:
            NetworkView(model: model.network, panel: model, embedded: true)
                .frame(minWidth: 560, idealWidth: 760)
        case .gallery:
            GalleryView(model: model.gallery, panel: model)
        case .context:
            HomeView(model: model)
        case nil:
            Color.clear.frame(width: 1)
        default:
            // A tool fills the panel, and scrolls instead of being cut when the Simulator is short.
            GeometryReader { area in
                ScrollView(.vertical) {
                    form.frame(minHeight: area.size.height, alignment: .top)
                }
            }
            .frame(minWidth: 590, idealWidth: 660)
        }
    }

    @ViewBuilder
    private var form: some View {
        switch model.openTool {
        case .push: PushForm(model: model)
        case .camera: CameraForm(model: model, camera: model.camera)
        case .url: URLForm(model: model)
        case .location: LocationForm(model: model)
        case .privacy: PrivacyForm(model: model)
        case .appearance: AppearanceForm(model: model)
        case .statusBar: StatusBarForm(model: model)
        case .accessibility: AccessibilityForm(model: model)
        case .data: DataForm(model: model)
        case .console: ConsoleView(console: model.console, panel: model)
        case .android: AndroidForm(model: model, android: model.android)
        case .grid: GridForm(model: model)
        case .colors: ColorsForm(model: model)
        default: EmptyView()
        }
    }
}

/// The tray behind the Simulator, the rail and the panel: it makes the three read as one piece.
struct BackdropView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(Color(red: 0.2, green: 0.2, blue: 0.22).opacity(0.78))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.16)))
    }
}

/// Borderless windows refuse the keyboard by default; the panel has text fields.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Saguru has no menu bar, and a panel can hold the keyboard while another app is in front, so the
    /// editing shortcuts are handed to whatever field is being typed in rather than left to a menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let keys = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard keys == .command || keys == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let action: Selector?
        switch (key, keys.contains(.shift)) {
        case ("x", false): action = #selector(NSText.cut(_:))
        case ("c", false): action = #selector(NSText.copy(_:))
        case ("v", false): action = #selector(NSText.paste(_:))
        case ("a", false): action = #selector(NSText.selectAll(_:))
        case ("z", false): action = Selector(("undo:"))
        case ("z", true): action = Selector(("redo:"))
        default: action = nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

/// Where the panel opens: the permission Saguru needs, the app everything applies to, and that app's details.
struct HomeView: View {
    @ObservedObject var model: PanelModel
    @State private var trusted = SimulatorAX.trusted
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if !trusted {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "accessibility")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(Color(nsColor: .systemOrange).opacity(0.25), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Falta el permiso de Accesibilidad").font(.headline)
                        Text("Con él Saguru sabe a qué simulador está pegado, y funcionan el inspector de accesibilidad, la cuadrícula y la comparación de apariencia. Actívalo en Configuración del Sistema y vuelve a abrir Saguru.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Dar permiso") {
                        SimulatorAX.requestAccess()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(14)
                .background(Color(nsColor: .systemOrange).opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding([.horizontal, .top], 14)
            }
            HStack(alignment: .top, spacing: 0) {
                ContextForm(model: model)
                Rectangle().fill(.white.opacity(0.09)).frame(width: 1)
                AppCard(model: model)
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onReceive(clock) { _ in
            let now = SimulatorAX.trusted
            if now != trusted { trusted = now }
        }
    }
}

/// What is known about the chosen app from its bundle on this Mac.
private struct AppCard: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        if let app = model.app {
            let info = AppFacts(app: app)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        AppBadge(app: app, size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tr(app.name)).font(.title2.weight(.semibold)).lineLimit(1)
                            Text(tr(app.bundleID)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    HStack(spacing: 10) {
                        fact("Versión", info.version)
                        fact("Compilación", info.build)
                        fact("iOS mínimo", info.minimumOS)
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        row("Compilada", info.built)
                        row("SDK", info.sdk)
                        row("Xcode", info.xcode)
                        row("Tamaño", info.size)
                        row("Esquemas URL", model.links.schemes.isEmpty ? "Ninguno" : model.links.schemes.joined(separator: ", "))
                    }
                    HStack(spacing: 8) {
                        Button("Ver la app en Finder") { reveal(app.path) }.disabled(app.path == nil)
                        Button("Ver sus datos") {
                            if let udid = model.selected, let folder = try? Simctl.dataContainer(udid, bundleID: app.bundleID) { reveal(folder.path) }
                        }
                    }
                    .controlSize(.small)
                }
                .padding(20)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "app.dashed").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                Text("Elige una app").font(.title3.weight(.semibold))
                Text("Las notificaciones, los permisos, los datos y la red se aplican a la app que elijas aquí.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tr(title)).font(.caption).foregroundStyle(.secondary)
            Text(tr(value)).font(.title3.weight(.semibold).monospacedDigit()).textSelection(.enabled).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(tr(title)).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(tr(value)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private func reveal(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}

struct AppFacts {
    var version = "—", build = "—", minimumOS = "—", sdk = "—", xcode = "—", built = "—", size = "—"

    init(app: SimApp) {
        guard let path = app.path else { return }
        let bundle = URL(fileURLWithPath: path)
        let plist = (NSDictionary(contentsOf: bundle.appendingPathComponent("Info.plist")) as? [String: Any]) ?? [:]
        func text(_ key: String) -> String { (plist[key] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—" }
        version = text("CFBundleShortVersionString")
        build = text("CFBundleVersion")
        minimumOS = text("MinimumOSVersion")
        sdk = text("DTSDKName")
        if let number = plist["DTXcode"] as? String, let value = Int(number) {
            xcode = "\(value / 100).\(value / 10 % 10)" + (plist["DTXcodeBuild"] as? String).map { " (\($0))" }.orEmpty
        }
        let executable = bundle.appendingPathComponent(plist["CFBundleExecutable"] as? String ?? "")
        if let date = (try? FileManager.default.attributesOfItem(atPath: executable.path))?[.modificationDate] as? Date {
            let formatter = RelativeDateTimeFormatter()
            // Dates read in the language Saguru is running in.
            let language = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "es")
            formatter.locale = language
            let exact = DateFormatter()
            exact.locale = language
            exact.dateFormat = "d MMM, HH:mm"
            built = "\(exact.string(from: date)) · \(formatter.localizedString(for: date, relativeTo: Date()))"
        }
        var total = 0
        if let files = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in files { total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        }
        if total > 0 { size = NetFormat.size(total) }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
