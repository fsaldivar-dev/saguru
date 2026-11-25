import AppKit
import SQLite3
import SwiftUI

// MARK: - Reading the app's files

/// A file in the app's data container.
struct DataFile: Identifiable, Hashable {
    let url: URL
    /// Path inside the container ("Library/Application Support/default.store").
    let path: String
    let size: Int
    let isDatabase: Bool
    var id: String { path }
    var name: String { url.lastPathComponent }
}

struct QueryResult: Equatable {
    var columns: [String] = []
    var rows: [[String]] = []
    /// More rows existed than were read.
    var truncated = false
    var error: String?
}

/// Reads SQLite databases. Always opened read-only: the app may be running and owns its data.
enum SQLiteReader {
    static let rowLimit = 500

    static func isDatabase(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return handle.readData(ofLength: 15) == Data("SQLite format 3".utf8)
    }

    private static func open(_ url: URL) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 800)
        return handle
    }

    /// Tables and views of a database, with how many rows each has.
    static func tables(_ url: URL) -> [(name: String, rows: Int)] {
        let list = query(url, "SELECT name FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name")
        return list.rows.compactMap(\.first).map { name in
            let count = query(url, "SELECT COUNT(*) FROM \"\(name.replacingOccurrences(of: "\"", with: "\"\""))\"")
            return (name, Int(count.rows.first?.first ?? "") ?? 0)
        }
    }

    static func query(_ url: URL, _ sql: String) -> QueryResult {
        guard let handle = open(url) else { return QueryResult(error: "No se pudo abrir la base de datos.") }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return QueryResult(error: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        // The file is open read-only anyway; this gives a clear message instead of SQLite's.
        guard sqlite3_stmt_readonly(statement) != 0 else {
            return QueryResult(error: "Solo consultas de lectura (SELECT). Saguru no modifica las bases de datos de la app.")
        }
        var result = QueryResult()
        let count = sqlite3_column_count(statement)
        result.columns = (0..<count).map { String(cString: sqlite3_column_name(statement, $0)) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                result.error = String(cString: sqlite3_errmsg(handle))
                break
            }
            if result.rows.count == rowLimit {
                result.truncated = true
                break
            }
            result.rows.append((0..<count).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_NULL: return "NULL"
                case SQLITE_BLOB: return "‹\(sqlite3_column_bytes(statement, column)) bytes›"
                default: return sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
                }
            })
        }
        return result
    }
}

// MARK: - State

final class DataModel: ObservableObject {
    @Published var files: [DataFile] = []
    @Published var database: DataFile? { didSet { if database != oldValue { loadTables() } } }
    @Published var tables: [(name: String, rows: Int)] = []
    @Published var table: String?
    @Published var sql = ""
    @Published var result = QueryResult()
    @Published var running = false
    @Published var problem: String?

    unowned let panel: PanelModel
    private let queue = DispatchQueue(label: "saguru.data")
    private var loaded = ""

    init(panel: PanelModel) {
        self.panel = panel
    }

    var databases: [DataFile] { files.filter(\.isDatabase) }

    /// Scans the active app's data container.
    func reload() {
        guard let udid = panel.selected, !panel.appID.isEmpty else { files = []; return }
        let bundleID = panel.appID
        let key = "\(udid)|\(bundleID)"
        if key != loaded {
            loaded = key
            files = []
            database = nil
            tables = []
            table = nil
            result = QueryResult()
            sql = ""
        }
        queue.async {
            guard let root = try? Simctl.dataContainer(udid, bundleID: bundleID) else {
                DispatchQueue.main.async { self.problem = "Esta app aún no tiene datos: ábrela una vez en el simulador." }
                return
            }
            var files: [DataFile] = []
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
            let prefix = root.resolvingSymlinksInPath().path + "/"
            while let url = enumerator?.nextObject() as? URL, files.count < 4000 {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let path = url.resolvingSymlinksInPath().path
                // The -wal and -shm companions are part of their database, not databases themselves.
                let companion = path.hasSuffix("-wal") || path.hasSuffix("-shm")
                files.append(DataFile(url: url, path: path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent,
                                      size: values.fileSize ?? 0, isDatabase: !companion && SQLiteReader.isDatabase(url)))
            }
            files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            DispatchQueue.main.async {
                guard key == self.loaded else { return }
                self.problem = nil
                if files != self.files { self.files = files }
                if self.database == nil {
                    // The app's own store first; caches and SDK databases are rarely what one is after.
                    let databases = files.filter(\.isDatabase)
                    self.database = databases.first { !$0.path.contains("Caches/") && !$0.path.contains("HTTPStorages/") && !$0.path.contains("Google/") }
                        ?? databases.first
                }
            }
        }
    }

    private func loadTables() {
        tables = []
        table = nil
        result = QueryResult()
        guard let database else { return }
        queue.async {
            let tables = SQLiteReader.tables(database.url)
            DispatchQueue.main.async {
                guard database == self.database else { return }
                self.tables = tables
                if let first = tables.first(where: { $0.rows > 0 }) ?? tables.first { self.show(first.name) }
            }
        }
    }

    /// Shows a table's rows, and leaves the query that does it in the editor to be changed.
    func show(_ name: String) {
        table = name
        sql = "SELECT * FROM \"\(name.replacingOccurrences(of: "\"", with: "\"\""))\" LIMIT 100"
        run()
    }

    func run() {
        guard let database, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let sql = sql
        running = true
        queue.async {
            let result = SQLiteReader.query(database.url, sql)
            DispatchQueue.main.async {
                self.running = false
                self.result = result
            }
        }
    }

    /// The result as tab-separated text, for pasting into a spreadsheet.
    func copyResult() {
        let lines = [result.columns] + result.rows
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.map { $0.joined(separator: "\t") }.joined(separator: "\n"), forType: .string)
        panel.say("\(result.rows.count) filas copiadas")
    }
}

// MARK: - Form

struct DataForm: View {
    enum Tab: String, CaseIterable { case defaults = "Preferencias", databases = "Bases de datos", files = "Archivos", actions = "Acciones" }

    @ObservedObject var model: PanelModel
    @ObservedObject var data: DataModel
    @AppStorage("data.tab") private var tab = Tab.defaults
    @AppStorage("data.language") private var language = ""
    @AppStorage("data.region") private var region = ""
    @State private var search = ""
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var newKind = DefaultsEntry.Kind.string

    init(model: PanelModel) {
        self.model = model
        data = model.data
    }

    private var bundleID: String { model.appID }

    var body: some View {
        FormBox(title: "Datos de la app", width: 660, target: model) {
            Picker("Sección", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Group {
                switch tab {
                case .defaults: defaults
                case .databases: databases
                case .files: files
                case .actions: actions
                }
            }
            .frame(height: 400, alignment: .top)
        }
        .disabled(bundleID.isEmpty)
        .onAppear(perform: reload)
        .onChange(of: model.appID) { reload() }
    }

    private func reload() {
        model.reloadApps()
        model.loadDefaults(bundleID: bundleID)
        data.reload()
    }

    private func bytes(_ size: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    // MARK: Preferences

    private var defaults: some View {
        let entries = search.isEmpty ? model.defaults : model.defaults.filter {
            $0.key.localizedCaseInsensitiveContains(search) || $0.text.localizedCaseInsensitiveContains(search)
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("User Defaults · \(model.defaults.count) valores · la app los lee al arrancar")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                TextField("Buscar clave o valor", text: $search).frame(width: 220)
            }
            HStack(spacing: 10) {
                Text("Clave").frame(width: 250, alignment: .leading)
                Text("Tipo").frame(width: 62, alignment: .leading)
                Text("Valor")
                Spacer()
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if entries.isEmpty {
                        Text(model.defaults.isEmpty ? "La app no ha guardado ninguna preferencia." : "Sin resultados")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        DefaultsRow(model: model, bundleID: bundleID, entry: entry)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(index.isMultiple(of: 2) ? Color.white.opacity(0.04) : .clear)
                    }
                }
            }
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 8) {
                TextField("nueva clave", text: $newKey).frame(width: 190)
                Picker("Tipo", selection: $newKind) {
                    Text("texto").tag(DefaultsEntry.Kind.string)
                    Text("bool").tag(DefaultsEntry.Kind.bool)
                    Text("entero").tag(DefaultsEntry.Kind.int)
                    Text("decimal").tag(DefaultsEntry.Kind.float)
                }
                .labelsHidden().frame(width: 96)
                TextField(newKind == .bool ? "true o false" : "valor", text: $newValue)
                Button("Añadir") {
                    model.writeDefault(bundleID: bundleID, key: newKey.trimmingCharacters(in: .whitespaces), kind: newKind, value: newValue)
                    newKey = ""
                    newValue = ""
                }
                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: Databases

    @ViewBuilder
    private var databases: some View {
        if data.databases.isEmpty {
            Text(data.problem ?? "Esta app no tiene bases de datos SQLite (Core Data, SwiftData, GRDB…) en su contenedor.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Base", selection: Binding(get: { data.database?.id ?? "" },
                                                  set: { id in data.database = data.databases.first { $0.id == id } })) {
                    ForEach(data.databases) { file in
                        Text("\(file.path) · \(bytes(file.size))").tag(file.id)
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(data.tables, id: \.name) { entry in
                                HStack(spacing: 6) {
                                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Text("\(entry.rows)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(entry.name == data.table ? AnyShapeStyle(Color(nsColor: .systemBlue).opacity(0.3)) : AnyShapeStyle(.clear),
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture { data.show(entry.name) }
                            }
                        }
                    }
                    .frame(width: 170)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            TextField("SELECT …", text: $data.sql, axis: .vertical)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1...3)
                                .onSubmit { data.run() }
                            Button("Ejecutar") { data.run() }
                                .buttonStyle(PrimaryButtonStyle())
                                .keyboardShortcut(.return, modifiers: .command)
                                .help("Ejecutar la consulta (⌘↩)")
                        }
                        if let error = data.result.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(Color(nsColor: .systemOrange))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ResultGrid(result: data.result)
                        HStack {
                            Text(data.result.columns.isEmpty ? "" :
                                 "\(data.result.rows.count) filas" + (data.result.truncated ? " (hay más; añade LIMIT o WHERE)" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                            if data.running { ProgressView().controlSize(.small) }
                            Spacer()
                            Button("Copiar resultado") { data.copyResult() }
                                .controlSize(.small)
                                .disabled(data.result.rows.isEmpty)
                        }
                    }
                }
                Text("Solo lectura: Saguru no modifica las bases de datos de la app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Files

    private var files: some View {
        let list = search.isEmpty ? data.files : data.files.filter { $0.path.localizedCaseInsensitiveContains(search) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(data.files.count) archivos · \(bytes(data.files.reduce(0) { $0 + $1.size }))")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                TextField("Buscar archivo", text: $search).frame(width: 220)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, file in
                        HStack(spacing: 8) {
                            Image(systemName: file.isDatabase ? "cylinder.split.1x2" : "doc")
                                .font(.caption).frame(width: 16).foregroundStyle(.secondary)
                            Text(file.path).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(bytes(file.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(index.isMultiple(of: 2) ? Color.white.opacity(0.04) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                        .help("Mostrar en Finder")
                    }
                }
            }
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(data.problem ?? "Haz clic en un archivo para mostrarlo en Finder.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Labeled("Carpeta de datos") {
                HStack {
                    Button("Abrir en Finder") { model.openDataFolder(bundleID: bundleID) }
                    Spacer()
                    Button("Borrar datos…", role: .destructive) { model.eraseData(bundleID: bundleID) }
                }
            }
            Divider()
            Labeled("Reiniciar la app en otro idioma") {
                HStack {
                    TextField("Idioma: es", text: $language).frame(width: 110)
                    TextField("Región: MX", text: $region).frame(width: 110)
                    Spacer()
                    Button("Reiniciar") { model.relaunch(bundleID: bundleID, language: language, region: region) }
                }
                Text("Sin idioma, solo reinicia la app.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A plain grid of text: a header and rows, scrolling both ways.
private struct ResultGrid: View {
    let result: QueryResult
    private let width: CGFloat = 132

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(result.rows.enumerated()), id: \.offset) { index, row in
                        line(row, header: false)
                            .background(index.isMultiple(of: 2) ? Color.white.opacity(0.04) : .clear)
                    }
                } header: {
                    if !result.columns.isEmpty {
                        line(result.columns, header: true).background(Color(red: 0.17, green: 0.17, blue: 0.19))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func line(_ cells: [String], header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell)
                    .font(header ? .caption.weight(.semibold) : .system(.caption, design: .monospaced))
                    .foregroundStyle(cell == "NULL" && !header ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: width, alignment: .leading)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .help(cell)
            }
        }
    }
}

private struct DefaultsRow: View {
    @ObservedObject var model: PanelModel
    let bundleID: String
    let entry: DefaultsEntry
    @State private var text = ""

    private var kind: String {
        switch entry.kind {
        case .string: return "texto"
        case .bool: return "bool"
        case .int: return "entero"
        case .float: return "decimal"
        case .other: return "otro"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.key).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                .frame(width: 250, alignment: .leading).help(entry.key)
            Text(kind).font(.caption).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            switch entry.kind {
            case .bool:
                Toggle("", isOn: Binding(
                    get: { entry.text == "true" },
                    set: { model.writeDefault(bundleID: bundleID, key: entry.key, kind: .bool, value: $0 ? "true" : "false") }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                Spacer()
            case .other:
                Text(entry.text).font(.callout).foregroundStyle(.secondary).lineLimit(1)
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
        .onAppear { text = entry.text }
        .onChange(of: entry.text) { text = entry.text }
    }
}
