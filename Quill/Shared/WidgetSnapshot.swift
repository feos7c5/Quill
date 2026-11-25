import Foundation

/// Stand für Widget und Steuerzentrale. Die App schreibt ihn in den gemeinsamen
/// App-Group-Container, das Widget liest ihn nur. Diese Datei gehört zu beiden Targets.
struct WidgetSnapshot: Codable, Equatable {
    struct App: Codable, Equatable, Identifiable {
        let name: String
        let bundleID: String
        let expiration: Date
        var id: String { bundleID }

        func daysLeft(at date: Date = .now) -> Int {
            max(0, Calendar.current.dateComponents([.day], from: date, to: expiration).day ?? 0)
        }
    }

    var apps: [App]
    var updatedAt: Date
    var deviceReady: Bool
    var signerReady: Bool
    var lastError: String?

    static let empty = WidgetSnapshot(apps: [], updatedAt: .distantPast, deviceReady: false, signerReady: false)

    /// App-Group-Kennung aus der Info.plist (`QuillAppGroup`, gesetzt aus der Build-Einstellung `APP_GROUP`).
    static var groupID: String? {
        (Bundle.main.object(forInfoDictionaryKey: "QuillAppGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// nil, wenn die App Group fehlt (z. B. nicht im Profil). Das Widget zeigt dann einen Hinweis.
    static var directory: URL? {
        groupID.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    private static var fileURL: URL? { directory?.appendingPathComponent("widget.json") }

    static func iconURL(for bundleID: String) -> URL? {
        directory?.appendingPathComponent("icons", isDirectory: true).appendingPathComponent("\(bundleID).png")
    }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() throws {
        guard let url = Self.fileURL else { return }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Die App, die als nächste abläuft.
    var nextApp: App? { apps.min { $0.expiration < $1.expiration } }

    /// Deep Links, die die App versteht.
    static let refreshAllURL = URL(string: "quill://refresh-all")!
    static func refreshURL(for bundleID: String) -> URL {
        var components = URLComponents()
        components.scheme = "quill"
        components.host = "refresh"
        components.queryItems = [URLQueryItem(name: "bundle", value: bundleID)]
        return components.url ?? refreshAllURL
    }
}
