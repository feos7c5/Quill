import SwiftUI
import SwiftData
import QuickLook
import ZIPFoundation

struct FileItem: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let size: Int64
    let modified: Date

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }

    var symbol: String {
        if isDirectory { return "folder.fill" }
        switch ext {
        case "ipa": return "app.badge"
        case "zip", "gz", "tar", "deb": return "doc.zipper"
        case "p12", "cer", "mobileprovision": return "checkmark.seal"
        case "plist", "entitlements": return "list.bullet.indent"
        case "dylib", "framework": return "shippingbox"
        case "png", "jpg", "jpeg", "gif", "heic": return "photo"
        default: return "doc"
        }
    }

    static let textExtensions: Set<String> = [
        "txt", "md", "json", "xml", "log", "strings", "swift", "h", "m", "mm", "c", "cpp",
        "js", "css", "html", "yml", "yaml", "sh", "conf", "ini", "csv"
    ]
}

/// Zwischenablage für Kopieren/Ausschneiden innerhalb des Dateibrowsers.
@Observable
final class FileClipboard {
    var urls: [URL] = []
    var isCut = false
}

enum FileRoute: Identifiable {
    case plist(URL), text(URL), hex(URL)

    var id: String {
        switch self {
        case .plist(let url): return "plist:" + url.path
        case .text(let url): return "text:" + url.path
        case .hex(let url): return "hex:" + url.path
        }
    }
}

struct FileBrowserView: View {
    let directory: URL
    let title: String

    @Environment(\.modelContext) private var context
    @Environment(FileClipboard.self) private var clipboard

    @State private var items: [FileItem] = []
    @State private var searchText = ""
    @State private var route: FileRoute?
    @State private var previewURL: URL?
    @State private var showImporter = false
    @State private var nameDialog: NameDialog?
    @State private var nameInput = ""
    @State private var isBusy = false
    @State private var message: String?

    private enum NameDialog: Identifiable {
        case newFolder, newFile, rename(FileItem)
        var id: String {
            switch self {
            case .newFolder: return "folder"
            case .newFile: return "file"
            case .rename(let item): return "rename:" + item.url.path
            }
        }
        var title: String {
            switch self {
            case .newFolder: return String(localized: "Neuer Ordner")
            case .newFile: return String(localized: "Neue Datei")
            case .rename: return String(localized: "Umbenennen")
            }
        }
    }

    private var filtered: [FileItem] {
        guard !searchText.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            ForEach(filtered) { item in
                row(for: item)
                    .swipeActions(edge: .trailing) {
                        Button("Löschen", systemImage: "trash", role: .destructive) { delete(item) }
                    }
                    .contextMenu { menu(for: item) }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("Keine Dateien", systemImage: "folder",
                                       description: Text("Dateien über + importieren oder per WLAN-Übertragung hochladen."))
            } else if isBusy {
                ProgressView().controlSize(.large)
            }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "Suchen")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Dateien importieren", systemImage: "square.and.arrow.down") { showImporter = true }
                    Button("Neuer Ordner", systemImage: "folder.badge.plus") { open(.newFolder, text: "") }
                    Button("Neue Datei", systemImage: "doc.badge.plus") { open(.newFile, text: "Notiz.txt") }
                    if !clipboard.urls.isEmpty {
                        Button("Einsetzen (\(clipboard.urls.count))", systemImage: "doc.on.clipboard") { paste() }
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .alert(nameDialog?.title ?? "", isPresented: nameDialogBinding, presenting: nameDialog) { dialog in
            TextField("Name", text: $nameInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("OK") { confirm(dialog) }
            Button("Abbrechen", role: .cancel) {}
        }
        .alert("Hinweis", isPresented: messageBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .sheet(item: $route) { route in
            NavigationStack {
                switch route {
                case .plist(let url): PlistDocumentView(url: url)
                case .text(let url): TextFileEditorView(url: url)
                case .hex(let url): HexView(url: url)
                }
            }
        }
        .quickLookPreview($previewURL)
        .refreshable { reload() }
        .onAppear { reload() }
    }

    // MARK: - Zeilen

    @ViewBuilder
    private func row(for item: FileItem) -> some View {
        if item.isDirectory && item.ext != "framework" {
            NavigationLink {
                FileBrowserView(directory: item.url, title: item.name)
            } label: {
                label(for: item)
            }
        } else {
            Button { open(item) } label: { label(for: item) }
                .tint(.primary)
        }
    }

    private func label(for item: FileItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.title2)
                .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text(item.isDirectory
                     ? item.modified.formatted(date: .abbreviated, time: .shortened)
                     : "\(item.size.fileSizeText) · \(item.modified.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func menu(for item: FileItem) -> some View {
        if item.ext == "ipa" {
            Button("In Apps importieren", systemImage: "square.grid.2x2") { importToLibrary(item) }
        }
        if ["zip", "ipa"].contains(item.ext) {
            Button("Entpacken", systemImage: "arrow.up.bin") { unzip(item) }
        }
        if !item.isDirectory {
            Button("Hex-Ansicht", systemImage: "number") { route = .hex(item.url) }
            Button("Als Text öffnen", systemImage: "doc.plaintext") { route = .text(item.url) }
        }
        Button("Komprimieren", systemImage: "doc.zipper") { compress(item) }
        Button("Umbenennen", systemImage: "pencil") { open(.rename(item), text: item.name) }
        Button("Kopieren", systemImage: "doc.on.doc") { clipboard.urls = [item.url]; clipboard.isCut = false }
        Button("Ausschneiden", systemImage: "scissors") { clipboard.urls = [item.url]; clipboard.isCut = true }
        ShareLink(item: item.url) { Label("Teilen", systemImage: "square.and.arrow.up") }
        Divider()
        Button("Löschen", systemImage: "trash", role: .destructive) { delete(item) }
    }

    // MARK: - Aktionen

    private func reload() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        items = urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return FileItem(url: url,
                            isDirectory: values?.isDirectory ?? false,
                            size: Int64(values?.fileSize ?? 0),
                            modified: values?.contentModificationDate ?? .distantPast)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func open(_ item: FileItem) {
        switch item.ext {
        case "plist", "entitlements", "mobileprovision":
            route = .plist(item.url)
        case "ipa":
            importToLibrary(item)
        case let ext where FileItem.textExtensions.contains(ext):
            route = .text(item.url)
        default:
            previewURL = item.url
        }
    }

    private func open(_ dialog: NameDialog, text: String) {
        nameInput = text
        nameDialog = dialog
    }

    private func confirm(_ dialog: NameDialog) {
        let name = nameInput.trimmed.replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty else { return }
        let target = directory.appendingPathComponent(name)
        attempt {
            switch dialog {
            case .newFolder:
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            case .newFile:
                guard !FileManager.default.fileExists(atPath: target.path) else {
                    throw AppError("Eine Datei mit diesem Namen existiert bereits.")
                }
                try Data().write(to: target)
            case .rename(let item):
                try FileManager.default.moveItem(at: item.url, to: target)
            }
        }
    }

    private func delete(_ item: FileItem) {
        attempt { try FileManager.default.removeItem(at: item.url) }
    }

    private func paste() {
        let urls = clipboard.urls
        let isCut = clipboard.isCut
        attempt {
            for url in urls {
                let destination = Paths.uniqueURL(for: directory.appendingPathComponent(url.lastPathComponent))
                if isCut {
                    try FileManager.default.moveItem(at: url, to: destination)
                } else {
                    try FileManager.default.copyItem(at: url, to: destination)
                }
            }
        }
        if isCut { clipboard.urls = [] }
    }

    private func importFiles(_ urls: [URL]) {
        attempt {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let destination = Paths.uniqueURL(for: directory.appendingPathComponent(url.lastPathComponent))
                try FileManager.default.copyItem(at: url, to: destination)
            }
        }
    }

    private func importToLibrary(_ item: FileItem) {
        isBusy = true
        Task {
            do {
                let app = try await AppLibrary.importIPA(from: item.url, context: context)
                message = String(localized: "„\(app.name)“ wurde in die Apps importiert.")
            } catch {
                message = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func unzip(_ item: FileItem) {
        let source = item.url
        let destination = Paths.uniqueURL(for: directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent))
        background {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: source, to: destination)
        }
    }

    private func compress(_ item: FileItem) {
        let source = item.url
        let destination = Paths.uniqueURL(for: directory.appendingPathComponent(item.name + ".zip"))
        background {
            try FileManager.default.zipItem(at: source, to: destination, shouldKeepParent: true, compressionMethod: .deflate)
        }
    }

    /// Führt eine schnelle Dateioperation aus und zeigt Fehler an.
    private func attempt(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            message = error.localizedDescription
        }
        reload()
    }

    /// Führt eine länger laufende Dateioperation im Hintergrund aus.
    private func background(_ work: @escaping @Sendable () throws -> Void) {
        isBusy = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try work() }.value
            } catch {
                message = error.localizedDescription
            }
            isBusy = false
            reload()
        }
    }

    private var nameDialogBinding: Binding<Bool> {
        Binding(get: { nameDialog != nil }, set: { if !$0 { nameDialog = nil } })
    }

    private var messageBinding: Binding<Bool> {
        Binding(get: { message != nil }, set: { if !$0 { message = nil } })
    }
}
