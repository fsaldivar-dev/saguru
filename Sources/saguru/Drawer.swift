import AppKit
import SwiftUI

/// The panel docked beside the Simulator. Every tool of the rail opens here, one at a time, so they all
/// read as one more part of the Simulator instead of as loose windows and balloons.
struct DrawerView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        case nil:
            Color.clear.frame(width: 1)
        default:
            // Forms keep their own width; the panel takes it, and scrolls when the Simulator is short.
            ScrollView(.vertical) { form }
        }
    }

    @ViewBuilder
    private var form: some View {
        switch model.openTool {
        case .context: ContextForm(model: model)
        case .push: PushForm(model: model)
        case .url: URLForm(model: model)
        case .location: LocationForm(model: model)
        case .privacy: PrivacyForm(model: model)
        case .appearance: AppearanceForm(model: model)
        case .statusBar: StatusBarForm(model: model)
        case .accessibility: AccessibilityForm(model: model)
        case .data: DataForm(model: model)
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
}
