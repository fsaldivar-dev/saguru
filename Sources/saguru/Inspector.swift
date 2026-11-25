import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

// MARK: - The app's accessibility tree

/// One element of the app on screen, as the accessibility system describes it.
struct AXNode: Identifiable {
    /// Position in the tree ("0.2.1"): stable while the screen does not change.
    let id: String
    let element: AXUIElement
    let role: String
    let label: String
    let value: String
    let identifier: String
    /// Top-left screen coordinates on this Mac.
    let frame: CGRect
    let enabled: Bool
    let depth: Int
    let childCount: Int

    static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField", "AXSwitch", "AXCheckBox", "AXSlider",
        "AXPopUpButton", "AXMenuButton", "AXRadioButton", "AXIncrementor", "AXSecureTextField",
    ]

    var interactive: Bool { Self.interactiveRoles.contains(role) }
    var isText: Bool { role == "AXStaticText" || role == "AXHeading" }

    /// What VoiceOver stops on: controls, text, labelled images, and labelled elements with nothing inside.
    var isStop: Bool {
        interactive || isText || (role == "AXImage" && !label.isEmpty) || (childCount == 0 && !(label.isEmpty && value.isEmpty))
    }

    /// The kind of element, the way VoiceOver says it after the label.
    var kind: String {
        switch role {
        case "AXButton", "AXPopUpButton", "AXMenuButton": return "botón"
        case "AXHeading": return "encabezado"
        case "AXLink": return "enlace"
        case "AXTextField", "AXTextArea", "AXSecureTextField": return "campo de texto"
        case "AXSearchField": return "campo de búsqueda"
        case "AXImage": return "imagen"
        case "AXSwitch", "AXCheckBox": return "interruptor"
        case "AXSlider", "AXIncrementor": return "ajustable"
        case "AXRadioButton": return "pestaña"
        default: return ""
        }
    }

    var symbol: String {
        switch role {
        case "AXButton", "AXPopUpButton", "AXMenuButton": return "hand.tap"
        case "AXHeading": return "textformat.size"
        case "AXStaticText": return "text.alignleft"
        case "AXLink": return "link"
        case "AXTextField", "AXTextArea", "AXSearchField", "AXSecureTextField": return "character.cursor.ibeam"
        case "AXImage": return "photo"
        case "AXSwitch", "AXCheckBox": return "switch.2"
        case "AXSlider", "AXIncrementor": return "slider.horizontal.3"
        case "AXGroup": return "square.dashed"
        default: return "circle"
        }
    }

    /// Roughly what VoiceOver would read: label, value, kind and state.
    var spoken: String {
        var parts = [label, value == label ? "" : value, kind].filter { !$0.isEmpty }
        if !enabled { parts.append("atenuado") }
        return parts.isEmpty ? "(sin etiqueta)" : parts.joined(separator: ", ")
    }

    /// Short name for lists: the label, or the role when there is none.
    var title: String {
        if !label.isEmpty { return label }
        if !value.isEmpty { return value }
        return role.replacingOccurrences(of: "AX", with: "")
    }
}

extension SimulatorAX {
    private static func text(_ element: AXUIElement, _ name: String) -> String {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (value as? [AXUIElement]) ?? []
    }

    private static func rect(_ element: AXUIElement) -> CGRect {
        var position: AnyObject?, size: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size)
        var origin = CGPoint.zero, extent = CGSize.zero
        if let position { AXValueGetValue(position as! AXValue, .cgPoint, &origin) }
        if let size { AXValueGetValue(size as! AXValue, .cgSize, &extent) }
        return CGRect(origin: origin, size: extent)
    }

    /// The tree of the app shown in the Simulator window at `windowFrame`, flattened depth-first in the order
    /// VoiceOver navigates, plus the device screen's rectangle. nil when the window cannot be read (no
    /// permission, or the window is on another desktop: macOS only describes windows on the current one).
    static func tree(at windowFrame: CGRect) -> (nodes: [AXNode], screen: CGRect)? {
        guard trusted, let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator").first
        else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        for window in elements(root, kAXWindowsAttribute) {
            let frame = rect(window)
            guard abs(frame.minX - windowFrame.minX) < 3, abs(frame.minY - windowFrame.minY) < 3,
                  abs(frame.width - windowFrame.width) < 3 else { continue }
            guard let content = elements(window, kAXChildrenAttribute).first(where: { text($0, kAXSubroleAttribute) == "iOSContentGroup" })
            else { return nil }
            var nodes: [AXNode] = []
            func walk(_ element: AXUIElement, path: String, depth: Int) {
                // Runaway trees (web views) are cut off rather than freezing the panel.
                guard nodes.count < 600, depth < 24 else { return }
                var children = elements(element, "AXChildrenInNavigationOrder")
                if children.isEmpty { children = elements(element, kAXChildrenAttribute) }
                var enabled: AnyObject?
                AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
                var label = text(element, kAXDescriptionAttribute)
                if label.isEmpty { label = text(element, kAXTitleAttribute) }
                nodes.append(AXNode(id: path, element: element, role: text(element, kAXRoleAttribute), label: label,
                                    value: text(element, kAXValueAttribute), identifier: text(element, "AXIdentifier"),
                                    frame: rect(element), enabled: (enabled as? Bool) ?? true, depth: depth,
                                    childCount: children.count))
                for (index, child) in children.enumerated() { walk(child, path: "\(path).\(index)", depth: depth + 1) }
            }
            var top = elements(content, "AXChildrenInNavigationOrder")
            if top.isEmpty { top = elements(content, kAXChildrenAttribute) }
            for (index, child) in top.enumerated() { walk(child, path: "\(index)", depth: 0) }
            return (nodes, rect(content))
        }
        return nil
    }
}

// MARK: - Accessibility settings

/// A switch of Settings › Accessibility that can be flipped from outside. `simctl` only has text size and
/// contrast; these are written into the simulator's own accessibility preferences, followed by the
/// notification iOS listens for. Only the ones seen to take effect are listed.
struct AXSetting: Identifiable {
    let name: String
    let key: String
    /// Notifications to post after writing: the one that refreshes iOS's cached value, and the public one apps observe.
    let notifications: [String]
    var id: String { key }

    private static func cache(_ suffix: String) -> String { "com.apple.accessibility.cache.\(suffix)" }

    static let all = [
        AXSetting(name: "Texto en negrita", key: "EnhancedTextLegibilityEnabled",
                  notifications: [cache("enhance.text.legibility")]),
        AXSetting(name: "Reducir transparencia", key: "EnhancedBackgroundContrastEnabled",
                  notifications: [cache("enhance.background.contrast")]),
        AXSetting(name: "Reducir movimiento", key: "ReduceMotionEnabled",
                  notifications: [cache("reduce.motion"), "com.apple.accessibility.reduce.motion.status"]),
        AXSetting(name: "Invertir colores", key: "InvertColorsEnabled",
                  notifications: [cache("invert.colors")]),
        AXSetting(name: "Formas de botón", key: "ButtonShapesEnabled",
                  notifications: [cache("button.shapes.enabled"), "com.apple.accessibility.button.shapes"]),
        AXSetting(name: "Etiquetas de encendido y apagado", key: "IncreaseButtonLegibilityEnabled",
                  notifications: [cache("increase.button.legibility"), "com.apple.accessibility.increase.button.legibility"]),
        AXSetting(name: "Diferenciar sin color", key: "DifferentiateWithoutColor",
                  notifications: [cache("differentiate.without.color"), "com.apple.accessibility.differentiate.without.color.status"]),
    ]
}

extension Simctl {
    /// Which of `AXSetting.all` are on.
    static func accessibilitySettings(_ udid: String) -> [String: Bool] {
        guard let data = try? run(["spawn", udid, "defaults", "export", "com.apple.Accessibility", "-"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return Dictionary(uniqueKeysWithValues: AXSetting.all.map { ($0.key, plist[$0.key] as? Bool ?? false) })
    }

    static func setAccessibility(_ udid: String, _ setting: AXSetting, on: Bool) throws {
        try run(["spawn", udid, "defaults", "write", "com.apple.Accessibility", setting.key, "-bool", on ? "YES" : "NO"])
        for notification in setting.notifications { try run(["spawn", udid, "notifyutil", "-p", notification]) }
    }
}

// MARK: - Slow animations

/// The Simulator's own Debug › Slow Animations. It is the Simulator app that slows the device down, and it
/// offers no command for it: the menu item is pressed through Accessibility, which the Simulator only
/// accepts while one of its device windows has the focus.
enum SlowAnimations {
    /// Read from the Simulator's preferences, where it records the switch.
    static var isOn: Bool {
        CFPreferencesAppSynchronize("com.apple.iphonesimulator" as CFString)
        return CFPreferencesCopyAppValue("SlowMotionAnimation" as CFString, "com.apple.iphonesimulator" as CFString) as? Bool ?? false
    }

    private static func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    private static func menuItem(_ app: NSRunningApplication) -> AXUIElement? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar = value(root, kAXMenuBarAttribute) else { return nil }
        for top in (value(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            where (value(top, kAXTitleAttribute) as? String) == "Debug" {
            for menu in (value(top, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                for item in (value(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? []
                    where (value(item, kAXTitleAttribute) as? String) == "Slow Animations" { return item }
            }
        }
        return nil
    }

    /// Switches it to `on`. Calls back on the main queue with whether it ended up as asked.
    static func set(_ on: Bool, done: @escaping (Bool) -> Void) {
        guard SimulatorAX.trusted,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator").first
        else { return done(false) }
        guard isOn != on else { return done(true) }
        // Give the Simulator the focus for a moment: without it the menu item is disabled.
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let item = menuItem(app) { AXUIElementPerformAction(item, kAXPressAction as CFString) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done(isOn == on) }
        }
    }
}

// MARK: - Audit

struct AXFinding: Identifiable {
    enum Rule: String, CaseIterable {
        case noLabel = "Sin etiqueta"
        case smallTarget = "Objetivo táctil pequeño"
        case lowContrast = "Contraste bajo (estimado)"
        case duplicateLabel = "Etiqueta repetida"
        case duplicateIdentifier = "Identificador repetido"

        var explanation: String {
            switch self {
            case .noLabel: return "VoiceOver no puede decir qué es este control."
            case .smallTarget: return "Menos de 44 × 44 puntos: cuesta acertar con el dedo."
            case .lowContrast: return "El texto se distingue poco de su fondo. Medido sobre una captura: revísalo a ojo."
            case .duplicateLabel: return "Varios controles se leen igual en esta pantalla."
            case .duplicateIdentifier: return "Los tests no pueden distinguir estos elementos."
            }
        }
    }

    let rule: Rule
    let node: AXNode
    let detail: String
    var id: String { "\(rule.rawValue)|\(node.id)" }
}

/// A rectangle to draw over the device screen, in fractions of its size.
struct AXMark: Identifiable, Equatable {
    enum Tone { case accent, warning, good, measure }

    let id: String
    let rect: CGRect
    var number: Int?
    /// Text drawn with the mark: a size, a distance.
    var label: String?
    var strong = false
    var tone = Tone.accent
}

// MARK: - Inspector state

final class InspectorModel: ObservableObject {
    enum Tab: String, CaseIterable { case navigator = "Navegador", tree = "Árbol", audit = "Auditoría", settings = "Ajustes" }
    enum Rotor: String, CaseIterable {
        case all = "Todo", headings = "Encabezados", buttons = "Botones", links = "Enlaces", fields = "Campos", images = "Imágenes"

        func accepts(_ node: AXNode) -> Bool {
            switch self {
            case .all: return true
            case .headings: return node.role == "AXHeading"
            case .buttons: return ["AXButton", "AXPopUpButton", "AXMenuButton"].contains(node.role)
            case .links: return node.role == "AXLink"
            case .fields: return ["AXTextField", "AXTextArea", "AXSearchField", "AXSecureTextField"].contains(node.role)
            case .images: return node.role == "AXImage"
            }
        }
    }

    @Published var tab = Tab.navigator { didSet { updateMarks() } }
    @Published var nodes: [AXNode] = []
    @Published var rotor = Rotor.all { didSet { focus = nil; updateMarks() } }
    /// id of the element the navigator is on.
    @Published var focus: String? {
        didSet {
            updateMarks()
            if focus != oldValue { speakFocus() }
        }
    }
    /// Reads each element aloud as the navigator lands on it, with this Mac's voice.
    @Published var speaks = UserDefaults.standard.object(forKey: "inspector.speaks") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(speaks, forKey: "inspector.speaks")
            if !speaks { synthesizer.stopSpeaking(at: .immediate) }
        }
    }
    private let synthesizer = AVSpeechSynthesizer()

    /// The simulator's own VoiceOver cannot be switched on from outside, so the phrase it would say is
    /// spoken here instead. Like VoiceOver, a new element cuts off the one being read.
    private func speakFocus() {
        synthesizer.stopSpeaking(at: .immediate)
        guard speaks, visible, let node = nodes.first(where: { $0.id == focus }) else { return }
        let utterance = AVSpeechUtterance(string: node.spoken)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "es-MX")
        utterance.rate = 0.52
        synthesizer.speak(utterance)
    }
    @Published var selected: String? { didSet { updateMarks() } }
    @Published var numbers = true { didSet { updateMarks() } }
    @Published var findings: [AXFinding] = []
    @Published var audited = false
    @Published var auditing = false
    @Published var highlighted: String? { didSet { updateMarks() } }
    /// Why there is no tree, when there is none.
    @Published var problem: String?

    unowned let panel: PanelModel
    private var screen = CGRect.zero
    private let queue = DispatchQueue(label: "saguru.inspector")
    private var reading = false
    private(set) var visible = false

    init(panel: PanelModel) {
        self.panel = panel
    }

    /// VoiceOver's stops, in order, for the chosen rotor category.
    var stops: [AXNode] { nodes.filter { $0.isStop && rotor.accepts($0) } }

    var pointScale: CGFloat {
        let wide = min(panel.screenPoints.width, panel.screenPoints.height)
        return screen.width > 0 ? wide / min(screen.width, screen.height) : 1
    }

    func sizeInPoints(_ node: AXNode) -> CGSize {
        CGSize(width: (node.frame.width * pointScale).rounded(), height: (node.frame.height * pointScale).rounded())
    }

    func appear() {
        visible = true
        reload()
    }

    func disappear() {
        visible = false
        synthesizer.stopSpeaking(at: .immediate)
        panel.axMarks = []
    }

    func reload() {
        guard !reading else { return }
        guard SimulatorAX.trusted else { problem = "Saguru necesita el permiso de Accesibilidad para leer la app."; return }
        guard let window = panel.simulatorWindow else { problem = "No hay ninguna ventana del Simulador a la vista."; return }
        reading = true
        queue.async {
            let tree = SimulatorAX.tree(at: window)
            DispatchQueue.main.async {
                self.reading = false
                guard let tree else {
                    self.problem = "No se pudo leer la app. La ventana del Simulador tiene que estar en este escritorio."
                    return
                }
                self.problem = nil
                self.screen = tree.screen
                // Same screen as before: keep everything as it is (and the focus where it was).
                let same = tree.nodes.count == self.nodes.count && zip(tree.nodes, self.nodes).allSatisfy {
                    $0.id == $1.id && $0.label == $1.label && $0.value == $1.value && $0.frame == $1.frame && $0.role == $1.role
                }
                guard !same else { return }
                self.nodes = tree.nodes
                if let focus = self.focus, !tree.nodes.contains(where: { $0.id == focus }) { self.focus = nil }
                if let selected = self.selected, !tree.nodes.contains(where: { $0.id == selected }) { self.selected = nil }
                // The audit was of another screen.
                self.findings = []
                self.audited = false
                self.highlighted = nil
                self.updateMarks()
            }
        }
    }

    // MARK: Navigator

    func move(_ step: Int) {
        let stops = stops
        guard !stops.isEmpty else { return }
        let current = stops.firstIndex { $0.id == focus }
        let next = current.map { min(max($0 + step, 0), stops.count - 1) } ?? (step > 0 ? 0 : stops.count - 1)
        focus = stops[next].id
    }

    func turnRotor(_ step: Int) {
        let all = Rotor.allCases
        let index = (all.firstIndex(of: rotor)! + step + all.count) % all.count
        rotor = all[index]
    }

    /// Presses the focused element in the app, as a double tap would with VoiceOver.
    func activate() {
        guard let node = nodes.first(where: { $0.id == focus }) else { return }
        let result = AXUIElementPerformAction(node.element, kAXPressAction as CFString)
        panel.say(result == .success ? "Activado: \(node.title)" : "Este elemento no se puede activar")
        // The app navigates: read the new screen once it has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self.reload() }
    }

    // MARK: Overlay

    private func fraction(_ frame: CGRect) -> CGRect {
        guard screen.width > 0, screen.height > 0 else { return .zero }
        return CGRect(x: (frame.minX - screen.minX) / screen.width, y: (frame.minY - screen.minY) / screen.height,
                      width: frame.width / screen.width, height: frame.height / screen.height)
    }

    private func updateMarks() {
        guard visible else { return }
        var marks: [AXMark] = []
        switch tab {
        case .navigator:
            for (index, node) in stops.enumerated() where numbers || node.id == focus {
                marks.append(AXMark(id: node.id, rect: fraction(node.frame), number: numbers ? index + 1 : nil, strong: node.id == focus))
            }
        case .tree:
            if let node = nodes.first(where: { $0.id == selected }) {
                marks.append(AXMark(id: node.id, rect: fraction(node.frame), strong: true))
            }
        case .audit:
            for finding in findings {
                marks.append(AXMark(id: finding.id, rect: fraction(finding.node.frame), strong: finding.id == highlighted, tone: .warning))
            }
        case .settings:
            break
        }
        if marks != panel.axMarks { panel.axMarks = marks }
    }

    // MARK: Audit

    func audit() {
        guard !auditing, let udid = panel.selected else { return }
        auditing = true
        let nodes = nodes, screen = screen
        let scale = pointScale
        queue.async {
            var findings: [AXFinding] = []
            let stops = nodes.filter(\.isStop)
            for node in stops where node.interactive {
                if node.label.isEmpty && node.value.isEmpty {
                    findings.append(AXFinding(rule: .noLabel, node: node, detail: node.identifier.isEmpty ? node.kind : node.identifier))
                }
                let width = (node.frame.width * scale).rounded(), height = (node.frame.height * scale).rounded()
                if width < 44 || height < 44 {
                    findings.append(AXFinding(rule: .smallTarget, node: node, detail: "\(Int(width)) × \(Int(height)) pt"))
                }
            }
            for (_, group) in Dictionary(grouping: stops.filter { $0.interactive && !$0.label.isEmpty }, by: { "\($0.role)|\($0.label)" })
                where group.count > 1 {
                for node in group { findings.append(AXFinding(rule: .duplicateLabel, node: node, detail: "\(group.count) veces")) }
            }
            for (_, group) in Dictionary(grouping: nodes.filter { !$0.identifier.isEmpty }, by: \.identifier) where group.count > 1 {
                for node in group { findings.append(AXFinding(rule: .duplicateIdentifier, node: node, detail: node.identifier)) }
            }
            if let png = try? Simctl.screenshot(udid), let image = NSImage(data: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                for node in stops where node.isText && !node.label.isEmpty && screen.width > 0 {
                    let pixels = CGRect(x: (node.frame.minX - screen.minX) / screen.width * CGFloat(image.width),
                                        y: (node.frame.minY - screen.minY) / screen.height * CGFloat(image.height),
                                        width: node.frame.width / screen.width * CGFloat(image.width),
                                        height: node.frame.height / screen.height * CGFloat(image.height)).integral
                    guard let ratio = Self.contrast(of: image, in: pixels) else { continue }
                    // Large text needs 3:1, the rest 4.5:1 (WCAG AA).
                    let needed = node.role == "AXHeading" || node.frame.height * scale >= 24 ? 3.0 : 4.5
                    if ratio < needed {
                        findings.append(AXFinding(rule: .lowContrast, node: node,
                                                  detail: String(format: "%.1f:1, se pide %.1f:1", ratio, needed)))
                    }
                }
            }
            DispatchQueue.main.async {
                self.findings = findings
                self.audited = true
                self.auditing = false
                self.updateMarks()
            }
        }
    }

    /// Share of the audited elements with nothing to fix.
    var score: Int {
        let checked = nodes.filter(\.isStop)
        guard !checked.isEmpty else { return 100 }
        let flagged = Set(findings.map(\.node.id)).count
        return Int((Double(checked.count - flagged) / Double(checked.count) * 100).rounded())
    }

    /// Contrast between the lightest and darkest parts of a region: an estimate of text against background.
    private static func contrast(of image: CGImage, in rect: CGRect) -> Double? {
        guard rect.width >= 4, rect.height >= 4, let crop = image.cropping(to: rect) else { return nil }
        let width = min(crop.width, 160), height = min(crop.height, 60)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        func linear(_ c: UInt8) -> Double {
            let v = Double(c) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        var luminances: [Double] = []
        luminances.reserveCapacity(width * height)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            luminances.append(0.2126 * linear(pixels[index]) + 0.7152 * linear(pixels[index + 1]) + 0.0722 * linear(pixels[index + 2]))
        }
        luminances.sort()
        // The extremes, minus a little noise: the text's colour and the background's.
        let dark = luminances[luminances.count / 100], light = luminances[luminances.count - 1 - luminances.count / 100]
        return (light + 0.05) / (dark + 0.05)
    }
}

// MARK: - Form

struct AccessibilityForm: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var inspector: InspectorModel
    @State private var search = ""
    @FocusState private var keys: Bool
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    init(model: PanelModel) {
        self.model = model
        inspector = model.inspector
    }

    var body: some View {
        FormBox(title: "Accesibilidad", device: model.device?.name, width: 460, symbol: "accessibility") {
            Picker("Sección", selection: $inspector.tab) {
                ForEach(InspectorModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if inspector.tab == .settings {
                settings
            } else if let problem = inspector.problem {
                VStack(alignment: .leading, spacing: 10) {
                    Text(problem).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !SimulatorAX.trusted {
                        Button("Permitir Accesibilidad") { SimulatorAX.requestAccess() }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            } else {
                switch inspector.tab {
                case .navigator: navigator
                case .tree: tree
                case .audit: audit
                case .settings: EmptyView()
                }
            }
        }
        .onAppear {
            inspector.appear()
            model.loadAccessibility()
            keys = true
        }
        .onDisappear { inspector.disappear() }
        .onReceive(refresh) { _ in inspector.reload() }
    }

    // MARK: Navigator

    private var navigator: some View {
        let stops = inspector.stops
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Rotor", selection: $inspector.rotor) {
                    ForEach(InspectorModel.Rotor.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 190)
                Spacer()
                Toggle("Voz", isOn: $inspector.speaks).help("Lee cada elemento en voz alta al llegar a él")
                Toggle("Números", isOn: $inspector.numbers)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if stops.isEmpty {
                            Text("Ningún elemento en esta categoría.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 24)
                        }
                        ForEach(Array(stops.enumerated()), id: \.element.id) { index, node in
                            let focused = node.id == inspector.focus
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1)").font(.caption.monospacedDigit().weight(.semibold))
                                    .frame(width: 22, alignment: .trailing).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(node.spoken).lineLimit(2)
                                    if !node.identifier.isEmpty {
                                        Text(node.identifier).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(focused ? AnyShapeStyle(Color(nsColor: .systemBlue).opacity(0.3)) : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture { inspector.focus = node.id }
                            .id(node.id)
                        }
                    }
                }
                .frame(height: 300)
                .onChange(of: inspector.focus) { if let focus = inspector.focus { proxy.scrollTo(focus) } }
            }
            HStack(spacing: 8) {
                Button { inspector.move(-1) } label: { Image(systemName: "chevron.up") }.help("Elemento anterior (↑)")
                Button { inspector.move(1) } label: { Image(systemName: "chevron.down") }.help("Elemento siguiente (↓)")
                Text("\(stops.count) elementos").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Activar") { inspector.activate() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(inspector.focus == nil)
                    .help("Pulsa el elemento en la app (Intro)")
            }
            Text("↑ ↓ recorren los elementos en el orden de VoiceOver, ← → cambian el rotor e Intro activa. La voz es la de esta Mac leyendo lo que diría VoiceOver, que en el simulador no se puede encender.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .focusable()
        .focused($keys)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { inspector.move(1); return .handled }
        .onKeyPress(.upArrow) { inspector.move(-1); return .handled }
        .onKeyPress(.rightArrow) { inspector.turnRotor(1); return .handled }
        .onKeyPress(.leftArrow) { inspector.turnRotor(-1); return .handled }
        .onKeyPress(.return) { inspector.activate(); return .handled }
    }

    // MARK: Tree

    private var tree: some View {
        let needle = search.trimmingCharacters(in: .whitespaces)
        let nodes = needle.isEmpty ? inspector.nodes : inspector.nodes.filter {
            $0.label.localizedCaseInsensitiveContains(needle) || $0.identifier.localizedCaseInsensitiveContains(needle)
                || $0.role.localizedCaseInsensitiveContains(needle) || $0.value.localizedCaseInsensitiveContains(needle)
        }
        return VStack(alignment: .leading, spacing: 10) {
            TextField("Buscar por etiqueta, identificador o rol", text: $search)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(nodes) { node in
                        HStack(spacing: 6) {
                            Image(systemName: node.symbol).font(.caption).frame(width: 16).foregroundStyle(.secondary)
                            Text(node.title).lineLimit(1)
                            if !node.identifier.isEmpty {
                                Text(node.identifier).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, needle.isEmpty ? CGFloat(min(node.depth, 8)) * 12 : 0)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(node.id == inspector.selected ? AnyShapeStyle(Color(nsColor: .systemBlue).opacity(0.3)) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { inspector.selected = node.id }
                    }
                }
            }
            .frame(height: 220)
            if let node = inspector.nodes.first(where: { $0.id == inspector.selected }) {
                detail(node)
            } else {
                Text("Elige un elemento para ver sus datos y resaltarlo en la pantalla.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ node: AXNode) -> some View {
        let size = inspector.sizeInPoints(node)
        return VStack(alignment: .leading, spacing: 5) {
            Divider()
            field("Rol", node.role.replacingOccurrences(of: "AX", with: "") + (node.kind.isEmpty ? "" : " · \(node.kind)"))
            field("Etiqueta", node.label.isEmpty ? "—" : node.label)
            if !node.value.isEmpty { field("Valor", node.value) }
            HStack(alignment: .firstTextBaseline) {
                field("Identificador", node.identifier.isEmpty ? "—" : node.identifier)
                if !node.identifier.isEmpty {
                    Button("Copiar") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(node.identifier, forType: .string)
                        model.say("Identificador copiado")
                    }
                    .controlSize(.small)
                }
            }
            field("Tamaño", "\(Int(size.width)) × \(Int(size.height)) pt" + (node.enabled ? "" : " · deshabilitado"))
            field("VoiceOver", node.isStop ? node.spoken : "no se detiene aquí")
        }
    }

    private func field(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.callout).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            Text(value).font(.callout).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    // MARK: Audit

    private var audit: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if inspector.audited {
                    Text("\(inspector.score)").font(.system(size: 30, weight: .semibold).monospacedDigit())
                    VStack(alignment: .leading, spacing: 0) {
                        Text("de 100").font(.callout)
                        Text(inspector.findings.isEmpty ? "Sin hallazgos" : "\(inspector.findings.count) hallazgos")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Revisa la pantalla actual de la app.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if inspector.auditing { ProgressView().controlSize(.small) }
                Button(inspector.audited ? "Auditar de nuevo" : "Auditar pantalla") { inspector.audit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(inspector.auditing || inspector.nodes.isEmpty)
            }
            if inspector.audited {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(AXFinding.Rule.allCases, id: \.self) { rule in
                            let group = inspector.findings.filter { $0.rule == rule }
                            if !group.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(rule.rawValue) · \(group.count)").font(.headline)
                                    Text(rule.explanation).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    ForEach(group) { finding in
                                        HStack(spacing: 8) {
                                            Image(systemName: finding.node.symbol).font(.caption).frame(width: 16).foregroundStyle(.secondary)
                                            Text(finding.node.title).lineLimit(1)
                                            Spacer(minLength: 0)
                                            Text(finding.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(finding.id == inspector.highlighted
                                                        ? AnyShapeStyle(Color(nsColor: .systemOrange).opacity(0.3)) : AnyShapeStyle(.clear),
                                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                        .contentShape(Rectangle())
                                        .onTapGesture { inspector.highlighted = finding.id }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(height: 300)
                Text("La puntuación es la parte de los elementos sin nada que corregir. El contraste es una estimación.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Settings

    private var settings: some View {
        let index = Binding(get: { Double(Simctl.contentSizes.firstIndex(of: model.contentSize) ?? 3) },
                            set: { model.setContentSize(Simctl.contentSizes[Int($0.rounded())]) })
        return VStack(alignment: .leading, spacing: 12) {
            Labeled("Tamaño de texto") {
                HStack(spacing: 8) {
                    Image(systemName: "textformat.size.smaller")
                    Slider(value: index, in: 0...Double(Simctl.contentSizes.count - 1), step: 1)
                    Image(systemName: "textformat.size.larger")
                }
                Text(model.contentSize).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Aumentar contraste", isOn: Binding(get: { model.increaseContrast }, set: { model.setIncreaseContrast($0) }))
            Toggle("Animaciones lentas", isOn: Binding(get: { model.slowAnimations }, set: { model.setSlowAnimations($0) }))
                .help("Ralentiza todas las animaciones del simulador, para ver las transiciones con calma (Debug › Slow Animations)")
            ForEach(AXSetting.all) { setting in
                Toggle(setting.name, isOn: Binding(get: { model.axSettings[setting.key] ?? false },
                                                   set: { model.setAccessibility(setting, on: $0) }))
            }
            Text("Son los mismos ajustes de Ajustes › Accesibilidad del simulador y se quedan puestos hasta que los apagues.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
