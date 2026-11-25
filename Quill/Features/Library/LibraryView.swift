import SwiftUI
import SwiftData

struct AppIconView: View {
    let url: URL
    var size: CGFloat = 52

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "app.dashed").font(.system(size: size * 0.45)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LibraryApp.addedAt, order: .reverse) private var apps: [LibraryApp]

    @State private var showSigned = false
    @State private var searchText = ""
    @State private var showImporter = false
    @State private var isImporting = false
    @State private var errorText: String?

    private var visible: [LibraryApp] {
        apps.filter { app in
            app.isSigned == showSigned &&
            (searchText.isEmpty
             || app.name.localizedCaseInsensitiveContains(searchText)
             || app.bundleID.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        List {
            ForEach(visible) { app in
                NavigationLink {
                    AppDetailView(app: app)
                } label: {
                    HStack(spacing: 12) {
                        AppIconView(url: app.iconURL)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.headline).lineLimit(1)
                            Text(app.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text("Version \(app.version) · \(app.size.fileSizeText)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("Löschen", systemImage: "trash", role: .destructive) {
                        AppLibrary.delete(app, context: context)
                    }
                }
            }
        }
        .overlay {
            if isImporting {
                ProgressView("Importiere …").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if visible.isEmpty {
                ContentUnavailableView(
                    showSigned ? "Keine signierten Apps" : "Keine Apps",
                    systemImage: "square.grid.2x2",
                    description: Text(showSigned ? "Signierte Apps erscheinen hier." : "Eine IPA über + importieren.")
                )
            }
        }
        .navigationTitle("Apps")
        .searchable(text: $searchText, prompt: "Name oder Bundle-ID")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Status", selection: $showSigned) {
                    Text("Unsigniert").tag(false)
                    Text("Signiert").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("IPA importieren", systemImage: "plus") { showImporter = true }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importIPAs(urls) }
        }
        .alert("Import fehlgeschlagen", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func importIPAs(_ urls: [URL]) {
        isImporting = true
        Task {
            for url in urls {
                do {
                    try await AppLibrary.importIPA(from: url, context: context)
                } catch {
                    errorText = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            isImporting = false
        }
    }
}

struct AppDetailView: View {
    @Bindable var app: LibraryApp

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(InstallService.self) private var installer
    @Environment(DeviceLink.self) private var device

    @State private var showSignSheet = false
    @State private var isInstalling = false
    @State private var installProgress = 0.0
    @State private var installStatus = "Installiere …"
    @State private var didInstall = false
    @State private var libraries: [String]?
    @State private var isLoadingLibraries = false
    @State private var confirmDelete = false
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    AppIconView(url: app.iconURL, size: 76)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(.title3.weight(.semibold))
                        Text(app.bundleID).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        Label(app.isSigned ? "Signiert" : "Unsigniert",
                              systemImage: app.isSigned ? "checkmark.seal.fill" : "seal")
                            .font(.caption)
                            .foregroundStyle(app.isSigned ? Color.green : Color.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Button(app.isSigned ? "Erneut signieren" : "Signieren", systemImage: "signature") {
                    showSignSheet = true
                }
                if app.isSigned {
                    if isInstalling {
                        ProgressView(value: installProgress) { Text(installStatus).font(.subheadline) }
                    } else {
                        Button("Installieren", systemImage: "arrow.down.app") { install() }
                    }
                    if didInstall {
                        Label("Installiert.", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                ShareLink(item: app.ipaURL, preview: SharePreview(app.exportFileName)) {
                    Label("IPA teilen", systemImage: "square.and.arrow.up")
                }
            }

            Section("Details") {
                LabeledContent("Version", value: app.version)
                if !app.minimumOS.isEmpty {
                    LabeledContent("Mindestens iOS", value: app.minimumOS)
                }
                LabeledContent("Größe", value: app.size.fileSizeText)
                if let certificateName = app.certificateName {
                    LabeledContent("Zertifikat", value: certificateName)
                }
                LabeledContent("Hinzugefügt", value: app.addedAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section("Verknüpfte Bibliotheken") {
                if let libraries {
                    if libraries.isEmpty {
                        Text("Keine gefunden").foregroundStyle(.secondary)
                    }
                    ForEach(libraries, id: \.self) { library in
                        Text(library).font(.system(.caption, design: .monospaced))
                    }
                } else if isLoadingLibraries {
                    ProgressView()
                } else {
                    Button("Anzeigen") { loadLibraries() }
                }
            }

            Section {
                Button("Aus Apps löschen", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSignSheet) {
            SignView(app: app)
        }
        .confirmationDialog("„\(app.name)“ löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                // Erst die Ansicht schließen, dann löschen: die Ansicht darf kein gelöschtes Modell mehr lesen.
                let app = app
                let context = context
                dismiss()
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    AppLibrary.delete(app, context: context)
                }
            }
        }
        .alert("Hinweis", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    /// Über den Gerätekanal, wenn gekoppelt; sonst über itms-services (Einstellungen → Installation).
    private func install() {
        isInstalling = true
        didInstall = false
        installProgress = 0
        installStatus = "Verbinde …"
        Task {
            defer { isInstalling = false }
            do {
                if device.isPaired {
                    try await device.install(app.ipaURL) { fraction, message in
                        Task { @MainActor in
                            installProgress = fraction
                            if !message.isEmpty { installStatus = message }
                        }
                    }
                    didInstall = true
                } else {
                    try installer.install(ipaURL: app.ipaURL, bundleID: app.bundleID, version: app.version, title: app.name)
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func loadLibraries() {
        isLoadingLibraries = true
        let url = app.ipaURL
        Task {
            do {
                libraries = try await SigningService.linkedLibraries(inIPA: url)
            } catch {
                errorText = error.localizedDescription
            }
            isLoadingLibraries = false
        }
    }
}
