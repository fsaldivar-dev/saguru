import SwiftUI
import UniformTypeIdentifiers

/// Same look as the Simulator's own toolbar capsule: dark glass whatever the system appearance,
/// so the rail reads as a piece of the Simulator. Liquid Glass on macOS 26, a dark blur before that.
struct Chrome: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular.tint(.black.opacity(0.62)), in: .rect(cornerRadius: radius))
            } else {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.12)))
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

struct RailButton: View {
    @ObservedObject var model: PanelModel
    let symbol: String
    let name: String
    var active = false
    let action: () -> Void
    /// The gallery's own button keeps it open; every other button of the rail closes it.
    var keepsGallery = false
    @State private var hovering = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(Color(nsColor: .systemBlue)) : AnyShapeStyle(.primary.opacity(hovering ? 1 : 0.82)))
                .frame(width: 32, height: 28)
                .background(
                    active ? AnyShapeStyle(Color(nsColor: .systemBlue).opacity(0.26)) : AnyShapeStyle(.primary.opacity(hovering ? 0.14 : 0)),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr(name))
        .onHover { inside in
            hovering = inside
            if inside { model.hint = name } else if model.hint == name { model.hint = "" }
        }
    }
}

/// A rail button whose action is a form in a native popover.
struct RailPopover<Form: View>: View {
    @ObservedObject var model: PanelModel
    let tool: Tool
    let symbol: String
    let name: String
    var active = false
    @ViewBuilder let form: () -> Form

    var body: some View {
        RailButton(model: model, symbol: symbol, name: name, active: active || model.openTool == tool) {
            model.openTool = model.openTool == tool ? nil : tool
        }
    }
}

/// Popovers are solid: over the desktop a translucent one lets the wallpaper through and text gets hard to read.
struct PopoverSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .presentationBackground(Color(red: 0.13, green: 0.13, blue: 0.145))
            // An accessory app is rarely "active", and macOS greys the accent of inactive apps.
            .tint(Color(nsColor: .systemBlue))
            .environment(\.colorScheme, .dark)
    }
}

/// Top of the rail: the app everything applies to. Opens the simulator and app chooser.
struct ContextButton: View {
    @ObservedObject var model: PanelModel
    @State private var hovering = false

    var body: some View {
        Button {
            model.openTool = model.openTool == .context ? nil : .context
        } label: {
            AppBadge(app: model.app, size: 26)
                .frame(width: 32, height: 32)
                .background(.white.opacity(hovering || model.openTool == .context ? 0.14 : 0),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("App y simulador")
        .onHover { inside in
            hovering = inside
            let name = model.app?.name ?? tr("Elegir app")
            if inside { model.hint = name } else if model.hint == name { model.hint = "" }
        }
    }
}

struct RailView: View {
    @ObservedObject var model: PanelModel

    /// Folded, Saguru is one button beside the Simulator. Everything else lives in the panel it unfolds.
    var body: some View {
        RailButton(model: model, symbol: "chevron.right.2", name: tr("Abrir Saguru")) { model.unfold() }
            .padding(5)
            .modifier(Chrome(radius: 19))
            .overlay {
                if model.dropTargeted {
                    RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(.tint, lineWidth: 2)
                }
            }
            .modifier(MediaDrop(model: model))
            .padding(1)
    }
}

/// Dropping photos or videos adds them to the simulator's library.
struct MediaDrop: ViewModifier {
    @ObservedObject var model: PanelModel

    func body(content: Content) -> some View {
        content.onDrop(of: [.fileURL], isTargeted: $model.dropTargeted) { providers in
            let group = DispatchGroup()
            var urls: [URL] = []
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    DispatchQueue.main.async {
                        if let url { urls.append(url) }
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) { model.addMedia(urls) }
            return true
        }
    }
}

/// The tools, in a row along the top of the panel.
struct ToolBar: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 2) {
            RailButton(model: model, symbol: "chevron.left.2", name: tr("Plegar")) { model.openTool = nil }
            ContextButton(model: model)
            separator
            RailPopover(model: model, tool: .push, symbol: "bell.badge", name: tr("Notificación push")) { EmptyView() }
            RailPopover(model: model, tool: .gallery, symbol: "photo.on.rectangle.angled", name: tr("Galería")) { EmptyView() }
            RailPopover(model: model, tool: .camera, symbol: "camera", name: tr("Cámara"), active: model.camera.isActive) { EmptyView() }
            RailPopover(model: model, tool: .url, symbol: "link", name: tr("Deep links")) { EmptyView() }
            RailPopover(model: model, tool: .location, symbol: "location", name: tr("Ubicación")) { EmptyView() }
            RailPopover(model: model, tool: .privacy, symbol: "hand.raised", name: tr("Permisos")) { EmptyView() }
            separator
            RailPopover(model: model, tool: .appearance, symbol: "circle.lefthalf.filled", name: tr("Apariencia"),
                        active: model.split == .appearance) { EmptyView() }
            RailPopover(model: model, tool: .statusBar, symbol: "antenna.radiowaves.left.and.right", name: tr("Barra de estado"),
                        active: model.cleanBar) { EmptyView() }
            RailPopover(model: model, tool: .accessibility, symbol: "accessibility", name: tr("Accesibilidad")) { EmptyView() }
            RailPopover(model: model, tool: .data, symbol: "externaldrive", name: tr("Datos de la app")) { EmptyView() }
            RailPopover(model: model, tool: .network, symbol: "network", name: tr("Red"), active: model.networkOpen) { EmptyView() }
            RailPopover(model: model, tool: .console, symbol: "terminal", name: tr("Registro"), active: model.console.unseen) { EmptyView() }
            separator
            RailPopover(model: model, tool: .grid, symbol: "grid", name: tr("Cuadrícula"), active: model.gridOn) { EmptyView() }
            RailButton(model: model, symbol: "ruler", name: tr("Reglas"), active: model.measuring) { model.toggleMeasuring() }
            RailPopover(model: model, tool: .colors, symbol: "eyedropper", name: tr("Colores")) { EmptyView() }
            Spacer(minLength: 8)
            RailButton(model: model, symbol: model.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       name: model.expanded ? "Reducir el panel" : tr("Ampliar a pantalla completa"), active: model.expanded) { model.expanded.toggle() }
            menu
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 18).padding(.horizontal, 5)
    }

    private var menu: some View {
        Menu {
            if model.devices.isEmpty {
                Text("Ningún simulador arrancado")
            }
            ForEach(model.devices) { device in
                Button {
                    model.select(device.udid)
                } label: {
                    Text("\(device.udid == model.selected ? "✓ " : "")\(device.name) · \(device.runtime)")
                }
            }
            Divider()
            Button(model.expanded ? "Reducir el panel" : tr("Ampliar a pantalla completa")) { model.expanded.toggle() }
            Button("Ver la introducción") { model.onboarding = true }
            // Each language is named in itself; choosing one restarts Saguru, since macOS sets it at launch.
            Menu("Idioma · Language") {
                ForEach(Language.allCases, id: \.self) { language in
                    Button("\(language == Language.chosen ? "✓ " : "")\(language.name)") { Language.choose(language) }
                }
            }
            Divider()
            Button("Salir de Saguru") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Simulador y opciones")
    }
}

/// Tooltip / confirmation capsule shown beside the rail, level with the cursor.
struct ToastView: View {
    let text: String

    var body: some View {
        Text(tr(text))
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .modifier(Chrome(radius: 12))
            .padding(1)
            .fixedSize()
    }
}

/// The main button of a form. Drawn by hand: in a popover of an app that is not the active one, the system's
/// prominent style paints its blue background but leaves the title out.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Color(nsColor: .systemBlue).opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
