import AppKit
import QuickLookThumbnailing
import SQLite3
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The simulator's photo library

/// A photo or video in a simulator's library. The original file lives on this Mac.
struct MediaItem: Identifiable, Hashable {
    let file: URL
    let isVideo: Bool
    /// Seconds, for videos.
    let duration: Double
    var id: String { file.lastPathComponent }
    /// Identifies the picture itself. File names are reused when the library is rebuilt
    /// ("IMG_0001.JPG" becomes a different photo), so the name alone must never key a thumbnail or a cell.
    let content: String

    init(file: URL, isVideo: Bool, duration: Double) {
        self.file = file
        self.isVideo = isVideo
        self.duration = duration
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        content = "\(file.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
    }
}

/// Reading and rebuilding a simulator's photo library. `simctl` can only add to it, so the rest works on the
/// library's own files, which are ordinary folders inside the simulator's data on this Mac.
enum MediaLibrary {
    private static func media(_ udid: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/data/Media", isDirectory: true)
    }

    /// What the Photos app shows, in its order (by capture date). Read from the library's database when possible (it knows what
    /// is in the trash and how long a video is), otherwise from the folder of originals.
    static func items(_ udid: String) -> [MediaItem] {
        let root = media(udid)
        if let rows = query(root.appendingPathComponent("PhotoData/Photos.sqlite")) {
            return rows.compactMap { row in
                let file = root.appendingPathComponent(row.directory).appendingPathComponent(row.name)
                return FileManager.default.fileExists(atPath: file.path)
                    ? MediaItem(file: file, isVideo: row.isVideo, duration: row.duration) : nil
            }
        }
        let folder = root.appendingPathComponent("DCIM/100APPLE")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
            let type = UTType(filenameExtension: $0.pathExtension)
            return MediaItem(file: $0, isVideo: type?.conforms(to: .movie) == true, duration: 0)
        }
    }

    private static func query(_ database: URL) -> [(name: String, directory: String, isVideo: Bool, duration: Double)]? {
        var handle: OpaquePointer?
        // Read-only: Simuru never writes to this database (iOS rejects outside writes anyway).
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let sql = "SELECT ZFILENAME, ZDIRECTORY, ZKIND, ZDURATION FROM ZASSET WHERE ZTRASHEDSTATE = 0 AND ZHIDDEN = 0 ORDER BY ZDATECREATED, Z_PK"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var rows: [(String, String, Bool, Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0), let directory = sqlite3_column_text(statement, 1) else { continue }
            rows.append((String(cString: name), String(cString: directory),
                         sqlite3_column_int(statement, 2) == 1, sqlite3_column_double(statement, 3)))
        }
        return rows
    }

    /// Removes items from the library. There is no way to delete a single photo from outside the simulator,
    /// so the library is emptied and the items to keep are added again. Albums, favourites and edits made
    /// inside the simulator are lost; the files to keep are safe in a temporary folder until they are back.
    static func remove(_ doomed: Set<String>, from udid: String) throws {
        let keep = items(udid).filter { !doomed.contains($0.id) }
        let fm = FileManager.default
        let safe = fm.temporaryDirectory.appendingPathComponent("simuru-fototeca-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: safe, withIntermediateDirectories: true)
        var copies: [URL] = []
        for (index, item) in keep.enumerated() {
            // A numeric prefix keeps the order when they are added back.
            let copy = safe.appendingPathComponent(String(format: "%04d-%@", index, item.file.lastPathComponent))
            try fm.copyItem(at: item.file, to: copy)
            copies.append(copy)
        }

        let user = "user/\(getuid())"
        Simctl.terminate(udid, bundleID: "com.apple.mobileslideshow")
        for service in ["com.apple.assetsd", "com.apple.photoanalysisd"] {
            _ = try? Simctl.run(["spawn", udid, "launchctl", "kill", "9", "\(user)/\(service)"])
        }
        let root = media(udid)
        try? fm.removeItem(at: root.appendingPathComponent("DCIM"))
        try? fm.removeItem(at: root.appendingPathComponent("PhotoData"))
        _ = try? Simctl.run(["spawn", udid, "launchctl", "kickstart", "-k", "\(user)/com.apple.assetsd"])
        Thread.sleep(forTimeInterval: 2)

        if !copies.isEmpty {
            do {
                try Simctl.addMedia(udid, files: copies)
            } catch {
                throw SimError(description: "la fototeca quedó vacía y no se pudieron volver a añadir las fotos; están a salvo en \(safe.path)")
            }
        }
        try? fm.removeItem(at: safe)
    }
}

// MARK: - Gallery window

final class GalleryModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var selection = Set<String>()
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var busy = false
    @Published var dropTargeted = false

    let panel: PanelModel
    private let work = DispatchQueue(label: "simuru.gallery")
    private var loaded: String?

    init(panel: PanelModel) {
        self.panel = panel
    }

    func reload() {
        guard let udid = panel.selected else { items = []; return }
        if udid != loaded {
            loaded = udid
            thumbnails = [:]
            selection = []
        }
        work.async {
            let items = MediaLibrary.items(udid)
            DispatchQueue.main.async {
                guard udid == self.panel.selected, items != self.items else { return }
                self.items = items
                self.selection.formIntersection(items.map(\.id))
                let current = Set(items.map(\.content))
                self.thumbnails = self.thumbnails.filter { current.contains($0.key) }
            }
        }
    }

    func needThumbnail(_ item: MediaItem) {
        let key = item.content
        guard thumbnails[key] == nil else { return }
        let request = QLThumbnailGenerator.Request(fileAt: item.file, size: CGSize(width: 220, height: 220),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async { self.thumbnails[key] = image }
        }
    }

    func toggle(_ item: MediaItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func add(_ files: [URL]) {
        guard !files.isEmpty, let udid = panel.selected else { return }
        run("\(files.count == 1 ? "1 archivo añadido" : "\(files.count) archivos añadidos")") {
            try Simctl.addMedia(udid, files: files)
        }
    }

    func pickFiles() {
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.allowedContentTypes = [.image, .movie]
        open.prompt = "Añadir a Fotos"
        NSApp.activate(ignoringOtherApps: true)
        open.begin { response in
            if response == .OK { self.add(open.urls) }
        }
    }

    func export() {
        let chosen = items.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.prompt = "Exportar aquí"
        NSApp.activate(ignoringOtherApps: true)
        open.begin { response in
            guard response == .OK, let folder = open.url else { return }
            var exported: [URL] = []
            for item in chosen {
                // Never overwrite: "IMG_0001.JPG" becomes "IMG_0001 2.JPG" if it is already there.
                var target = folder.appendingPathComponent(item.file.lastPathComponent)
                var copy = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    let name = "\(item.file.deletingPathExtension().lastPathComponent) \(copy).\(item.file.pathExtension)"
                    target = folder.appendingPathComponent(name)
                    copy += 1
                }
                if (try? FileManager.default.copyItem(at: item.file, to: target)) != nil { exported.append(target) }
            }
            self.panel.say(exported.count == chosen.count
                ? (exported.count == 1 ? "1 archivo exportado" : "\(exported.count) archivos exportados")
                : "Solo se exportaron \(exported.count) de \(chosen.count)")
            if !exported.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(exported) }
        }
    }

    func deleteSelection() {
        guard !selection.isEmpty, let udid = panel.selected else { return }
        let doomed = selection
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = doomed.count == 1 ? "¿Eliminar esta foto del simulador?" : "¿Eliminar \(doomed.count) elementos del simulador?"
        alert.informativeText = "El simulador no permite borrar fotos sueltas, así que Simuru vacía la fototeca y vuelve a añadir las demás. Se pierden los álbumes, favoritos y ediciones hechos dentro del simulador."
        alert.addButton(withTitle: "Eliminar").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The library is rebuilt and its file names reassigned: nothing selected before means the same after.
        selection = []
        run(doomed.count == 1 ? "1 elemento eliminado" : "\(doomed.count) elementos eliminados") {
            try MediaLibrary.remove(doomed, from: udid)
        }
    }

    private func run(_ done: String, _ action: @escaping () throws -> Void) {
        busy = true
        work.async {
            var message = done
            do { try action() } catch { message = "\(error)" }
            // The library takes a moment to register what was added.
            Thread.sleep(forTimeInterval: 1)
            DispatchQueue.main.async {
                self.busy = false
                self.panel.say(message)
                self.reload()
            }
        }
    }
}

struct GalleryView: View {
    @ObservedObject var model: GalleryModel
    @ObservedObject var panel: PanelModel
    private let refresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.selection.isEmpty {
                selectionBar
                Divider()
            }
            grid
            Divider()
            Text(panel.status.isEmpty
                 ? "Arrastra archivos aquí para añadirlos, o arrastra una foto a Finder para exportarla."
                 : panel.status)
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 470, height: 500)
        .tint(Color(nsColor: .systemBlue))
        .environment(\.colorScheme, .dark)
        .overlay {
            if model.dropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .systemBlue), lineWidth: 3).padding(4)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $model.dropTargeted) { providers in
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
            // Dragging a photo out and back in must not add a copy of itself.
            group.notify(queue: .main) {
                let own = Set(model.items.map(\.file.path))
                model.add(urls.filter { !own.contains($0.path) })
            }
            return true
        }
        .onAppear { model.reload() }
        .onReceive(refresh) { _ in if !model.busy { model.reload() } }
        .onChange(of: panel.selected) { model.reload() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Galería").font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Button {
                model.pickFiles()
            } label: {
                Label("Añadir", systemImage: "plus")
            }
            .disabled(panel.device == nil || model.busy)
            Button {
                panel.galleryOpen = false
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cerrar galería")
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 14)
    }

    private var subtitle: String {
        guard let device = panel.device else { return "Ningún simulador arrancado" }
        return "\(device.name) · \(model.items.count == 1 ? "1 elemento" : "\(model.items.count) elementos")"
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text(model.selection.count == 1 ? "1 seleccionado" : "\(model.selection.count) seleccionados")
            Button("Quitar selección") { model.selection = [] }.buttonStyle(.link)
            Spacer()
            Button {
                model.export()
            } label: {
                Label("Exportar", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                model.deleteSelection()
            } label: {
                Label("Eliminar", systemImage: "trash")
            }
        }
        .disabled(model.busy)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Color(nsColor: .systemBlue).opacity(0.16))
    }

    private var grid: some View {
        ScrollView {
            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("La fototeca está vacía").font(.title3)
                    Text("Arrastra fotos o videos aquí.").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 90)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    // Keyed by content, not by name: after the library is rebuilt the same name is another
                    // photo, and a cell kept under the old name would never ask for its new thumbnail.
                    ForEach(model.items, id: \.content) { item in cell(item) }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cell(_ item: MediaItem) -> some View {
        let selected = model.selection.contains(item.id)
        return Color.white.opacity(0.06)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = model.thumbnails[item.content] {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if item.isVideo {
                    Label(Self.clock(item.duration), systemImage: "play.fill")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(nsColor: .systemBlue))
                        .padding(6)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .systemBlue), lineWidth: selected ? 3 : 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.toggle(item) }
            .onDrag { NSItemProvider(contentsOf: item.file) ?? NSItemProvider() }
            .onAppear { model.needThumbnail(item) }
            .help(item.file.lastPathComponent)
            .accessibilityElement()
            .accessibilityLabel(item.file.lastPathComponent)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction { model.toggle(item) }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - A popover that stays open

/// A popover like the rail's other ones, arrow included, that does not close when another app is clicked.
/// SwiftUI's own popover always does, and the gallery has to stay up while files are dragged from Finder.
struct PersistentPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSView { NSView() }

    func makeCoordinator() -> Coordinator { Coordinator(isPresented: $isPresented) }

    func updateNSView(_ anchor: NSView, context: Context) {
        let coordinator = context.coordinator
        if isPresented, coordinator.popover == nil, anchor.window != nil {
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.appearance = NSAppearance(named: .darkAqua)
            popover.contentViewController = SolidHostingController(rootView: AnyView(content()))
            popover.delegate = coordinator
            coordinator.popover = popover
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        } else if !isPresented {
            coordinator.close()
        }
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        @Binding var isPresented: Bool
        var popover: NSPopover?

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func close() {
            guard let popover else { return }
            self.popover = nil
            popover.close()
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            if isPresented { isPresented = false }
        }
    }
}

/// Paints the whole popover, arrow included, in the solid colour of the rail's other popovers.
private final class SolidHostingController: NSHostingController<AnyView> {
    override func viewDidAppear() {
        super.viewDidAppear()
        guard let frame = view.window?.contentView?.superview,
              !frame.subviews.contains(where: { $0.identifier?.rawValue == "simuru.solid" }) else { return }
        let fill = NSView(frame: frame.bounds)
        fill.identifier = NSUserInterfaceItemIdentifier("simuru.solid")
        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor(red: 0.13, green: 0.13, blue: 0.145, alpha: 1).cgColor
        fill.autoresizingMask = [.width, .height]
        frame.addSubview(fill, positioned: .below, relativeTo: frame.subviews.first)
    }
}
