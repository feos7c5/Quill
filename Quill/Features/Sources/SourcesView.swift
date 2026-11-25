import SwiftUI
import SwiftData

struct SourcesView: View {
    @Environment(\.modelContext) private var context
    @Environment(DownloadManager.self) private var downloads
    @Query(sort: \AppSource.addedAt) private var sources: [AppSource]

    @State private var showAddSource = false
    @State private var showDirectDownload = false
    @State private var input = ""
    @State private var isAdding = false
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    DownloadsView()
                } label: {
                    LabeledContent {
                        if downloads.activeCount > 0 {
                            Text("\(downloads.activeCount) aktiv")
                        }
                    } label: {
                        Label("Downloads", systemImage: "arrow.down.circle")
                    }
                }
                Button("Von URL laden", systemImage: "link") {
                    input = ""
                    showDirectDownload = true
                }
            }

            Section {
                ForEach(sources) { source in
                    NavigationLink {
                        SourceDetailView(source: source)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                            Text(source.urlString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(sources[index]) }
                    try? context.save()
                }
                if isAdding {
                    ProgressView()
                }
            } header: {
                Text("Quellen")
            } footer: {
                Text("Quellen sind JSON-Adressen im AltStore-Quellenformat. Nur Quellen hinzufügen, deren Apps du nutzen darfst.")
            }
        }
        .navigationTitle("Quellen")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Quelle hinzufügen", systemImage: "plus") {
                    input = ""
                    showAddSource = true
                }
            }
        }
        .alert("Quelle hinzufügen", isPresented: $showAddSource) {
            urlField
            Button("Hinzufügen") { addSource() }
            Button("Abbrechen", role: .cancel) {}
        }
        .alert("Von URL laden", isPresented: $showDirectDownload) {
            urlField
            Button("Laden") {
                if let url = validURL(input) { downloads.start(url) } else { errorText = "Die Adresse ist ungültig." }
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .alert("Fehler", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private var urlField: some View {
        TextField("https://…", text: $input)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    private func validURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    private func addSource() {
        guard let url = validURL(input) else {
            errorText = "Die Adresse ist ungültig."
            return
        }
        guard !sources.contains(where: { $0.urlString == url.absoluteString }) else {
            errorText = "Diese Quelle ist bereits vorhanden."
            return
        }
        isAdding = true
        Task {
            do {
                let feed = try await SourceService.fetch(url)
                context.insert(AppSource(name: feed.name ?? url.host ?? "Quelle", urlString: url.absoluteString))
                try context.save()
            } catch {
                errorText = error.localizedDescription
            }
            isAdding = false
        }
    }
}

struct SourceDetailView: View {
    let source: AppSource

    @Environment(DownloadManager.self) private var downloads
    @State private var apps: [SourceApp] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var searchText = ""
    @State private var started: Set<String> = []

    private var visible: [SourceApp] {
        guard !searchText.isEmpty else { return apps }
        return apps.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List(visible) { app in
            HStack(spacing: 12) {
                AsyncImage(url: app.iconURL.flatMap { URL(string: $0) }) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.displayName).font(.headline).lineLimit(1)
                    Text([app.developerName, app.latestVersion.map { "Version \($0)" }, app.latestSize?.fileSizeText]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let description = app.subtitle ?? app.localizedDescription {
                        Text(description).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                    }
                }
                Spacer()
                if let url = app.latestDownloadURL {
                    Button(started.contains(app.id) ? "Gestartet" : "Laden") {
                        downloads.start(url, name: app.displayName)
                        started.insert(app.id)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(started.contains(app.id))
                }
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            } else if let errorText {
                ContentUnavailableView("Quelle nicht ladbar", systemImage: "wifi.exclamationmark", description: Text(errorText))
            } else if apps.isEmpty {
                ContentUnavailableView("Keine Apps", systemImage: "tray")
            }
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Suchen")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let url = source.url else {
            errorText = "Die Adresse der Quelle ist ungültig."
            isLoading = false
            return
        }
        do {
            apps = try await SourceService.fetch(url).apps ?? []
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }
}

struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        List {
            ForEach(downloads.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name).lineLimit(1)
                    switch item.state {
                    case .running:
                        ProgressView(value: item.progress)
                        Text(item.progress.formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .finished:
                        Label("Fertig – liegt unter Dateien/Downloads", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .failed(let reason):
                        Label(reason, systemImage: "xmark.octagon.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("Entfernen", systemImage: "xmark", role: .destructive) { downloads.remove(item.id) }
                }
            }
        }
        .overlay {
            if downloads.items.isEmpty {
                ContentUnavailableView("Keine Downloads", systemImage: "arrow.down.circle")
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Aufräumen") { downloads.clearFinished() }
                    .disabled(downloads.items.allSatisfy { $0.state == .running })
            }
        }
    }
}
