import AppKit
import SwiftUI

// MARK: - Grid that knows the layout

/// A box of the layout, in device points: a container found by its background, or an element of the app.
struct LayoutNode: Identifiable {
    let id: String
    var title: String
    let rect: CGRect
    let isContainer: Bool
}

/// A child of the container being inspected, and how it sits on the grid.
struct LayoutItem: Identifiable {
    let id: String
    let title: String
    let rect: CGRect
    let isContainer: Bool
    /// How many boxes it holds (containers only).
    let children: Int
    /// Measurements that are not a multiple of the grid step, with their value ("separación 35").
    let offsets: [String]
    var aligned: Bool { offsets.isEmpty }
}

/// Finds the layout's containers in a picture of the screen. The app's accessibility tree is usually flat
/// (cards and panels are not elements), so containers are recognised the way the eye does: as sizeable
/// regions with a background of their own.
enum ContainerFinder {
    /// Boxes in device points. `scale` is how many pixels of the working copy make a point.
    static func boxes(in image: CGImage, points: CGSize, scale: Int = 2) -> [CGRect] {
        let width = Int(points.width) * scale, height = Int(points.height) * scale
        guard width > 0, height > 0 else { return [] }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func close(_ a: Int, _ b: Int) -> Bool {
            abs(Int(pixels[a]) - Int(pixels[b])) + abs(Int(pixels[a + 1]) - Int(pixels[b + 1])) + abs(Int(pixels[a + 2]) - Int(pixels[b + 2])) <= 6
        }
        var seen = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        var found: [CGRect] = []
        let least = 24 * scale
        for start in 0..<(width * height) where !seen[start] {
            // Flood-fill from here across neighbours of nearly the same colour (so soft gradients stay whole).
            seen[start] = true
            stack.append(start)
            var count = 0, minX = start % width, maxX = minX, minY = start / width, maxY = minY
            while let index = stack.popLast() {
                count += 1
                let x = index % width, y = index / width
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
                if x > 0, !seen[index - 1], close(index * 4, (index - 1) * 4) { seen[index - 1] = true; stack.append(index - 1) }
                if x < width - 1, !seen[index + 1], close(index * 4, (index + 1) * 4) { seen[index + 1] = true; stack.append(index + 1) }
                if y > 0, !seen[index - width], close(index * 4, (index - width) * 4) { seen[index - width] = true; stack.append(index - width) }
                if y < height - 1, !seen[index + width], close(index * 4, (index + width) * 4) { seen[index + width] = true; stack.append(index + width) }
            }
            let w = maxX - minX + 1, h = maxY - minY + 1
            // A container: big enough, mostly filled by its own colour, and not the whole screen.
            guard w >= least, h >= least, Double(count) >= 0.45 * Double(w * h),
                  !(Double(w) > Double(width) * 0.97 && Double(h) > Double(height) * 0.9) else { continue }
            let s = CGFloat(scale)
            found.append(CGRect(x: CGFloat(minX) / s, y: CGFloat(minY) / s, width: CGFloat(w) / s, height: CGFloat(h) / s))
        }
        return found
    }
}

final class GridModel: ObservableObject {
    /// The children of the container being inspected.
    @Published var items: [LayoutItem] = []
    /// From the screen down to the container being inspected.
    @Published var trail: [LayoutNode] = []
    @Published var problem: String?
    @Published var showElements = UserDefaults.standard.object(forKey: "grid.elements") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showElements, forKey: "grid.elements"); publish() }
    }
    @Published var showSizes = UserDefaults.standard.object(forKey: "grid.sizes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSizes, forKey: "grid.sizes"); publish() }
    }
    @Published var highlighted: String? { didSet { publish() } }

    static let root = "pantalla"

    unowned let panel: PanelModel
    private let queue = DispatchQueue(label: "saguru.grid")
    private var timer: Timer?
    private var reading = false
    private var nodes: [String: LayoutNode] = [:]
    private var parents: [String: String] = [:]
    /// The container whose inside is shown; the screen itself at first.
    private var current = GridModel.root
    /// Distances to draw: the line, its value, and the box it belongs to.
    private var measures: [(rect: CGRect, value: CGFloat, owner: String)] = []
    private var screenSize = CGSize.zero

    init(panel: PanelModel) {
        self.panel = panel
    }

    /// Follows the screen while the grid is on, whether or not its popover is open.
    func sync() {
        if panel.gridOn, timer == nil {
            reload()
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.reload() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !panel.gridOn {
            timer?.invalidate()
            timer = nil
            items = []
            trail = []
            measures = []
            current = Self.root
            panel.gridMarks = []
        }
    }

    /// Goes inside a container, as a double click does in a design tool.
    func enter(_ id: String) {
        guard nodes[id]?.isContainer == true else { return }
        current = id
        highlighted = nil
        arrange()
    }

    /// Back out to the container (or the screen) that holds the current one.
    func leave(to id: String? = nil) {
        current = id ?? parents[current] ?? Self.root
        highlighted = nil
        arrange()
    }

    func reload() {
        guard panel.gridOn, !reading else { return }
        guard let window = panel.simulatorWindow, let udid = panel.selected else {
            problem = "No hay ninguna ventana del Simulador a la vista."
            return
        }
        reading = true
        let points = panel.screenPoints
        queue.async {
            let tree = SimulatorAX.tree(at: window)
            var nodes: [String: LayoutNode] = [:]
            var parents: [String: String] = [:]
            var size = CGSize.zero
            if let tree, tree.screen.width > 0 {
                let scale = min(points.width, points.height) / min(tree.screen.width, tree.screen.height)
                size = CGSize(width: (tree.screen.width * scale).rounded(), height: (tree.screen.height * scale).rounded())
                let screen = CGRect(origin: .zero, size: size)
                func snap(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
                // The app's own elements.
                for node in tree.nodes where node.isStop && node.frame.width > 1 && node.frame.height > 1 {
                    let rect = CGRect(x: snap((node.frame.minX - tree.screen.minX) * scale), y: snap((node.frame.minY - tree.screen.minY) * scale),
                                      width: snap(node.frame.width * scale), height: snap(node.frame.height * scale))
                    // What has scrolled off the screen is not part of what is being looked at.
                    guard rect.intersects(screen) else { continue }
                    nodes[node.id] = LayoutNode(id: node.id, title: node.title, rect: rect, isContainer: false)
                }
                // The containers, from a picture of the screen.
                if let png = try? Simctl.screenshot(udid), let image = NSImage(data: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    for box in ContainerFinder.boxes(in: image, points: size) {
                        // An element that fills its own background (an image, a button) is that element, not a container.
                        let same = nodes.values.contains {
                            !$0.isContainer && abs($0.rect.minX - box.minX) < 3 && abs($0.rect.minY - box.minY) < 3
                                && abs($0.rect.width - box.width) < 4 && abs($0.rect.height - box.height) < 4
                        }
                        guard !same else { continue }
                        let id = "caja \(Int(box.minX)),\(Int(box.minY)) \(Int(box.width))x\(Int(box.height))"
                        nodes[id] = LayoutNode(id: id, title: "", rect: box, isContainer: true)
                    }
                }
                // Each box belongs to the smallest container around it; what no container holds is on the screen.
                let containers = nodes.values.filter(\.isContainer)
                func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }
                for node in nodes.values {
                    let holder = containers.filter {
                        $0.id != node.id && area($0.rect) > area(node.rect) * 1.05 && $0.rect.insetBy(dx: -1.5, dy: -1.5).contains(node.rect)
                    }.min { area($0.rect) < area($1.rect) }
                    parents[node.id] = holder?.id ?? Self.root
                }
                // Name each container after what it holds, like a layer named after its text.
                for container in containers {
                    let inside = nodes.values.filter { !$0.isContainer && container.rect.insetBy(dx: -1.5, dy: -1.5).contains($0.rect) }
                        .sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
                    nodes[container.id]?.title = inside.first.map { "Contenedor · \($0.title)" } ?? "Contenedor"
                }
            }
            DispatchQueue.main.async {
                self.reading = false
                guard self.panel.gridOn else { return }
                self.problem = tree == nil ? "No se pudo leer la app. La ventana del Simulador tiene que estar en este escritorio." : nil
                self.nodes = nodes
                self.parents = parents
                self.screenSize = size
                self.arrange()
            }
        }
    }

    static func number(_ value: CGFloat) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }

    /// Measures the children of the current container: against each other, and against its walls.
    private func arrange() {
        guard screenSize.width > 0 else { return }
        if current != Self.root, nodes[current] == nil { current = Self.root }
        let wall = current == Self.root ? CGRect(origin: .zero, size: screenSize) : nodes[current]!.rect
        let kids = nodes.values.filter { parents[$0.id] == current }
            .sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
        let spacing = CGFloat(panel.gridSpacing)
        var measures: [(CGRect, CGFloat, String)] = []
        var items: [LayoutItem] = []

        for kid in kids {
            let others = kids.filter { $0.id != kid.id }
            func sideways(_ other: LayoutNode) -> Bool { other.rect.minX < kid.rect.maxX - 1 && other.rect.maxX > kid.rect.minX + 1 }
            func upright(_ other: LayoutNode) -> Bool { other.rect.minY < kid.rect.maxY - 1 && other.rect.maxY > kid.rect.minY + 1 }
            let above = others.filter { sideways($0) && $0.rect.maxY <= kid.rect.minY + 1 }.max { $0.rect.maxY < $1.rect.maxY }
            let below = others.contains { sideways($0) && $0.rect.minY >= kid.rect.maxY - 1 }
            let left = others.filter { upright($0) && $0.rect.maxX <= kid.rect.minX + 1 }.max { $0.rect.maxX < $1.rect.maxX }
            let right = others.contains { upright($0) && $0.rect.minX >= kid.rect.maxX - 1 }

            // Like a design tool: the distance to the sibling next to it, or to the wall when there is none.
            var checks: [(String, CGFloat)] = []
            func note(_ name: String, _ value: CGFloat, _ line: CGRect) {
                guard value >= 0.5 else { return }
                checks.append((name, value))
                measures.append((line, value, kid.id))
            }
            let midX = kid.rect.midX, midY = kid.rect.midY
            if let above {
                let from = above.rect.maxY
                note("separación", kid.rect.minY - from, CGRect(x: max(kid.rect.minX, above.rect.minX) / 2 + min(kid.rect.maxX, above.rect.maxX) / 2 - 0.5,
                                                              y: from, width: 1, height: kid.rect.minY - from))
            } else {
                note("arriba", kid.rect.minY - wall.minY, CGRect(x: midX - 0.5, y: wall.minY, width: 1, height: kid.rect.minY - wall.minY))
            }
            if !below { note("abajo", wall.maxY - kid.rect.maxY, CGRect(x: midX - 0.5, y: kid.rect.maxY, width: 1, height: wall.maxY - kid.rect.maxY)) }
            if let left {
                let from = left.rect.maxX
                note("separación h.", kid.rect.minX - from, CGRect(x: from, y: max(kid.rect.minY, left.rect.minY) / 2 + min(kid.rect.maxY, left.rect.maxY) / 2 - 0.5,
                                                                 width: kid.rect.minX - from, height: 1))
            } else {
                note("izquierda", kid.rect.minX - wall.minX, CGRect(x: wall.minX, y: midY - 0.5, width: kid.rect.minX - wall.minX, height: 1))
            }
            if !right { note("derecha", wall.maxX - kid.rect.maxX, CGRect(x: kid.rect.maxX, y: midY - 0.5, width: wall.maxX - kid.rect.maxX, height: 1)) }
            // A container's size is a design decision; a text's size is whatever its words need.
            if kid.isContainer {
                checks.append(("ancho", kid.rect.width))
                checks.append(("alto", kid.rect.height))
            }
            // Containers come from a picture, so their edges can be half a point off.
            let tolerance: CGFloat = kid.isContainer || current != Self.root ? 1 : 0.5
            let offsets = checks.compactMap { name, value -> String? in
                let rest = value.truncatingRemainder(dividingBy: spacing)
                let off = rest > spacing / 2 ? rest - spacing : rest
                return abs(off) > tolerance ? "\(name) \(Self.number(value))" : nil
            }
            items.append(LayoutItem(id: kid.id, title: kid.title, rect: kid.rect, isContainer: kid.isContainer,
                                    children: kid.isContainer ? parents.values.filter { $0 == kid.id }.count : 0, offsets: offsets))
        }
        var trail: [LayoutNode] = []
        var step = current
        while step != Self.root, let node = nodes[step] {
            trail.insert(node, at: 0)
            step = parents[step] ?? Self.root
        }
        self.items = items
        self.trail = trail
        self.measures = measures
        publish()
    }

    private func publish() {
        guard panel.gridOn, screenSize.width > 0 else { return }
        func fraction(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX / screenSize.width, y: rect.minY / screenSize.height,
                   width: rect.width / screenSize.width, height: rect.height / screenSize.height)
        }
        var marks: [AXMark] = []
        if let container = trail.last {
            // The container being inspected, so its walls are visible.
            marks.append(AXMark(id: "actual", rect: fraction(container.rect), strong: true))
        }
        if showElements {
            for item in items {
                // Sizes are written on boxes with room for them, and always on the selected one.
                let roomy = item.rect.width >= 90 || item.id == highlighted
                marks.append(AXMark(id: item.id, rect: fraction(item.rect),
                                    label: showSizes && roomy ? "\(Self.number(item.rect.width)) × \(Self.number(item.rect.height))" : nil,
                                    strong: item.id == highlighted, tone: item.aligned ? .good : .warning))
            }
        }
        if showSizes {
            // Short distances (paddings, gaps) are always drawn. Long ones would cover the screen with
            // lines, so they appear for the selected box only, as in a design tool.
            for (index, measure) in measures.enumerated() where measure.value <= 40 || measure.owner == highlighted {
                marks.append(AXMark(id: "medida\(index)", rect: fraction(measure.rect), label: Self.number(measure.value), tone: .measure))
            }
        }
        if marks != panel.gridMarks { panel.gridMarks = marks }
    }
}

struct GridForm: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var grid: GridModel

    init(model: PanelModel) {
        self.model = model
        grid = model.grid
    }

    var body: some View {
        let off = grid.items.filter { !$0.aligned }.count
        FormBox(title: "Cuadrícula", device: model.device?.name, width: 460, symbol: "grid") {
            Toggle("Mostrar la cuadrícula", isOn: Binding(get: { model.gridOn }, set: { _ in model.toggleGrid() }))
            VStack(alignment: .leading, spacing: 14) {
                Labeled("Paso de la rejilla") {
                    Picker("Paso", selection: $model.gridSpacing) {
                        ForEach([2.0, 4, 8, 16], id: \.self) { Text("\(Int($0)) pt").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                Labeled("Columnas de maquetación") {
                    HStack(spacing: 10) {
                        Stepper("\(model.gridColumns == 0 ? "Ninguna" : "\(model.gridColumns)")", value: $model.gridColumns, in: 0...12)
                            .frame(width: 130, alignment: .leading)
                        Text("Margen").foregroundStyle(.secondary)
                        TextField("", value: $model.gridMargin, format: .number).frame(width: 46)
                        Text("Espacio").foregroundStyle(.secondary)
                        TextField("", value: $model.gridGutter, format: .number).frame(width: 46)
                    }
                }
                HStack(spacing: 18) {
                    Toggle("Cajas", isOn: $grid.showElements)
                    Toggle("Medidas", isOn: $grid.showSizes)
                    Spacer()
                }
                Divider()
                if let problem = grid.problem {
                    Text(problem).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    // Where we are: the screen, or the container we went into.
                    HStack(spacing: 6) {
                        Button {
                            grid.leave()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(grid.trail.isEmpty)
                        .help("Salir al contenedor de fuera")
                        Button("Pantalla") { grid.leave(to: GridModel.root) }.buttonStyle(.link)
                        ForEach(grid.trail) { node in
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                            Button("\(GridModel.number(node.rect.width)) × \(GridModel.number(node.rect.height))") { grid.leave(to: node.id) }
                                .buttonStyle(.link)
                        }
                        Spacer()
                        Circle().fill(Color(nsColor: .systemGreen)).frame(width: 8, height: 8)
                        Text("\(grid.items.count - off)")
                        Circle().fill(Color(nsColor: .systemOrange)).frame(width: 8, height: 8)
                        Text("\(off)")
                    }
                    .font(.callout)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(grid.items) { item in
                                HStack(spacing: 8) {
                                    Image(systemName: item.isContainer ? "rectangle" : "textformat")
                                        .font(.caption).frame(width: 16).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title).lineLimit(1)
                                        Text(item.aligned ? "\(GridModel.number(item.rect.width)) × \(GridModel.number(item.rect.height))"
                                                          : item.offsets.joined(separator: " · "))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(item.aligned ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color(nsColor: .systemOrange)))
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 6)
                                    if item.isContainer, item.children > 0 {
                                        Button {
                                            grid.enter(item.id)
                                        } label: {
                                            Label("\(item.children)", systemImage: "arrow.down.right.square")
                                        }
                                        .controlSize(.small)
                                        .help("Entrar y medir lo que contiene")
                                    }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(item.id == grid.highlighted ? AnyShapeStyle(Color(nsColor: .systemBlue).opacity(0.25)) : AnyShapeStyle(.clear),
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture { grid.highlighted = grid.highlighted == item.id ? nil : item.id }
                            }
                            if grid.items.isEmpty {
                                Text("Aquí dentro no hay nada que medir.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                            }
                        }
                    }
                    .frame(minHeight: 190, maxHeight: .infinity)
                    Text("Como en una herramienta de diseño: cada caja se mide contra la de al lado, o contra la pared de su contenedor si no tiene vecina. Elige una caja para ver todas sus distancias, y entra en un contenedor para medir lo de dentro. Los contenedores se detectan por su fondo en una captura, con medio punto de margen de error.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!model.gridOn)
            .opacity(model.gridOn ? 1 : 0.5)
        }
        .onChange(of: model.gridSpacing) { grid.reload() }
    }
}

// MARK: - Colours

/// A colour found on the screen.
struct Swatch: Identifiable {
    let red: Int, green: Int, blue: Int
    /// Share of the screen, 0…1.
    let share: Double
    /// Name of the app's catalog colour with this value, if there is one.
    var token: String?
    var id: String { hex }
    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    /// Whether it reads as a colour rather than a grey.
    var hasHue: Bool { max(red, green, blue) - min(red, green, blue) > 24 }
    var color: Color { Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255) }
    var swift: String {
        String(format: "Color(red: %.3f, green: %.3f, blue: %.3f) // %@", Double(red) / 255, Double(green) / 255, Double(blue) / 255, hex)
    }
}

/// A colour the app declares in its asset catalog.
struct NamedColor: Identifiable {
    let name: String
    let red: Int, green: Int, blue: Int
    /// "claro", "oscuro" or "" when it has a single value.
    let appearance: String
    var id: String { "\(name)|\(appearance)" }
    var swatch: Swatch { Swatch(red: red, green: green, blue: blue, share: 0, token: name) }
}

final class PaletteModel: ObservableObject {
    @Published var swatches: [Swatch] = []
    @Published var named: [NamedColor] = []
    @Published var working = false
    @Published var problem: String?

    unowned let panel: PanelModel
    private let queue = DispatchQueue(label: "saguru.palette")

    init(panel: PanelModel) {
        self.panel = panel
    }

    /// Colours declared in the app's compiled asset catalog. Colours written in code leave no name behind.
    static func namedColors(of app: SimApp) -> [NamedColor] {
        guard let path = app.path, FileManager.default.fileExists(atPath: path + "/Assets.car") else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["assetutil", "--info", path + "/Assets.car"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var colors: [NamedColor] = []
        for entry in entries where entry["AssetType"] as? String == "Color" {
            guard let name = entry["Name"] as? String, let parts = entry["Color components"] as? [Double], parts.count >= 3 else { continue }
            let appearance = (entry["Appearance"] as? String ?? "").lowercased()
            func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            colors.append(NamedColor(name: name, red: byte(parts[0]), green: byte(parts[1]), blue: byte(parts[2]),
                                     appearance: appearance.contains("dark") ? "oscuro" : (appearance.contains("light") ? "claro" : "")))
        }
        // A catalog lists a colour once per device idiom and scale: keep one of each.
        var seen = Set<String>()
        colors = colors.filter { seen.insert("\($0.name)|\($0.appearance)|\($0.red),\($0.green),\($0.blue)").inserted }
        // "oscuro" only means something next to a different light value.
        let byName = Dictionary(grouping: colors, by: \.name)
        colors = colors.filter { color in
            guard color.appearance == "oscuro", let others = byName[color.name] else { return true }
            return !others.contains { $0.appearance != "oscuro" && $0.red == color.red && $0.green == color.green && $0.blue == color.blue }
        }
        return colors.sorted { ($0.name, $0.appearance) < ($1.name, $1.appearance) }
    }

    func analyze() {
        guard let udid = panel.selected, !working else { return }
        working = true
        let app = panel.app
        queue.async {
            let named = app.map(Self.namedColors) ?? []
            var swatches: [Swatch] = []
            var problem: String?
            if let png = try? Simctl.screenshot(udid), let image = NSImage(data: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                swatches = Self.palette(of: image)
                for index in swatches.indices {
                    let swatch = swatches[index]
                    swatches[index].token = named.first {
                        abs($0.red - swatch.red) <= 2 && abs($0.green - swatch.green) <= 2 && abs($0.blue - swatch.blue) <= 2
                    }?.name
                }
            } else {
                problem = "No se pudo capturar la pantalla del simulador."
            }
            DispatchQueue.main.async {
                self.working = false
                self.swatches = swatches
                self.named = named
                self.problem = problem
            }
        }
    }

    /// The colours on the screen. Every pixel of a point-sized copy is counted and near-identical tones are
    /// merged. Colours with a hue are kept even when tiny (an accent on an icon is a real colour); greys need
    /// a larger share, because the smoothed edges of text produce dozens of in-between greys that nobody chose.
    static func palette(of image: CGImage) -> [Swatch] {
        let width = 402, height = max(1, image.height * 402 / max(image.width, 1))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        // No smoothing: blended pixels would invent colours that are not on the screen.
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var counts: [UInt32: Int] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            counts[UInt32(pixels[index]) << 16 | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2]), default: 0] += 1
        }
        // Most common first; a colour within reach of one already taken joins it.
        var groups: [(red: Int, green: Int, blue: Int, count: Int)] = []
        for (key, count) in counts.sorted(by: { $0.value > $1.value }) {
            let red = Int(key >> 16 & 0xFF), green = Int(key >> 8 & 0xFF), blue = Int(key & 0xFF)
            if let index = groups.firstIndex(where: { abs($0.red - red) + abs($0.green - green) + abs($0.blue - blue) <= 14 }) {
                groups[index].count += count
            } else if groups.count < 1500 {
                groups.append((red, green, blue, count))
            }
        }
        let total = Double(width * height)
        return groups.sorted { $0.count > $1.count }
            .map { Swatch(red: $0.red, green: $0.green, blue: $0.blue, share: Double($0.count) / total) }
            .filter { $0.share >= ($0.hasHue ? 0.0004 : 0.003) }
    }
}

struct ColorsForm: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var palette: PaletteModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    init(model: PanelModel) {
        self.model = model
        palette = model.palette
    }

    var body: some View {
        FormBox(title: "Colores", width: 440, target: model) {
            HStack {
                Button {
                    model.pickColor()
                } label: {
                    Label("Cuentagotas", systemImage: "eyedropper")
                }
                .help("Elige un píxel de la pantalla y copia su color")
                Spacer()
                if palette.working { ProgressView().controlSize(.small) }
                Button("Analizar pantalla") { palette.analyze() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(palette.working || model.device == nil)
            }
            if let problem = palette.problem {
                Text(problem).font(.callout).foregroundStyle(.secondary)
            }
            if !palette.swatches.isEmpty {
                let hues = palette.swatches.filter(\.hasHue), greys = palette.swatches.filter { !$0.hasHue }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !hues.isEmpty {
                            Labeled("Colores de esta pantalla · \(hues.count)") {
                                LazyVGrid(columns: columns, spacing: 8) { ForEach(hues) { tile($0, detail: share($0)) } }
                            }
                        }
                        if !greys.isEmpty {
                            Labeled("Fondos y neutros · \(greys.count)") {
                                LazyVGrid(columns: columns, spacing: 8) { ForEach(greys) { tile($0, detail: share($0)) } }
                            }
                        }
                    }
                }
                .frame(maxHeight: 330)
            }
            Labeled(palette.named.isEmpty ? "Catálogo de la app" : "Catálogo de la app · \(palette.named.count == 1 ? "1 color con nombre" : "\(palette.named.count) colores con nombre")") {
                if palette.named.isEmpty {
                    Text(palette.swatches.isEmpty && !palette.working
                         ? "Pulsa «Analizar pantalla» para ver los colores en uso y los que la app declara."
                         : "Esta app no declara colores con nombre en su catálogo: los define en código, y ahí el nombre no se conserva.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(palette.named) { named in tile(named.swatch, detail: named.appearance) }
                    }
                }
            }
            Text("Un clic copia el color como Color de SwiftUI. Los degradados y las fotos aportan muchos tonos intermedios; los grises muy pequeños se omiten porque suelen ser el suavizado del texto.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if palette.swatches.isEmpty { palette.analyze() } }
        .onChange(of: model.appID) { palette.analyze() }
    }

    private func share(_ swatch: Swatch) -> String {
        swatch.share >= 0.01 ? "\(Int((swatch.share * 100).rounded())) %" : "menos del 1 %"
    }

    private func tile(_ swatch: Swatch, detail: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(swatch.swift, forType: .string)
            model.say("\(swatch.token ?? swatch.hex) copiado como Color de SwiftUI")
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(swatch.color)
                    .frame(height: 38)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.18)))
                Text(swatch.token ?? swatch.hex)
                    .font(swatch.token == nil ? .system(.caption, design: .monospaced) : .caption.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(swatch.token == nil ? detail : [swatch.hex, detail].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(swatch.swift)
    }
}
