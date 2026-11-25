import Foundation
import Observation

/// Lädt Dateien nach Dokumente/Downloads und meldet den Fortschritt.
@Observable
final class DownloadManager: NSObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case running, finished
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        var name: String
        var progress: Double = 0
        var state: State = .running
        var fileURL: URL?
    }

    private(set) var items: [Item] = []

    /// Wird auf dem Main-Thread aufgerufen, sobald eine Datei fertig geladen ist.
    @ObservationIgnored var onFinished: ((URL) -> Void)?
    @ObservationIgnored private var tasks: [Int: (id: UUID, task: URLSessionDownloadTask)] = [:]
    @ObservationIgnored private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    var activeCount: Int { items.filter { $0.state == .running }.count }

    func start(_ url: URL, name: String? = nil) {
        let item = Item(name: name ?? url.lastPathComponent)
        items.insert(item, at: 0)
        let task = session.downloadTask(with: url)
        tasks[task.taskIdentifier] = (item.id, task)
        task.resume()
    }

    func cancel(_ id: UUID) {
        if let entry = tasks.first(where: { $0.value.id == id }) {
            entry.value.task.cancel()
        }
    }

    func remove(_ id: UUID) {
        cancel(id)
        items.removeAll { $0.id == id }
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
    }

    private func update(_ taskIdentifier: Int, _ change: (inout Item) -> Void) {
        guard let id = tasks[taskIdentifier]?.id,
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    // MARK: - URLSessionDownloadDelegate (läuft auf der Main-Queue)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        update(downloadTask.taskIdentifier) { $0.progress = progress }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            update(downloadTask.taskIdentifier) { $0.state = .failed("Server antwortet mit Status \(http.statusCode)") }
            return
        }
        var name = downloadTask.response?.suggestedFilename ?? downloadTask.originalRequest?.url?.lastPathComponent ?? "Download"
        name = name.replacingOccurrences(of: "/", with: "-")
        let destination = Paths.uniqueURL(for: Paths.downloads.appendingPathComponent(name))
        do {
            // Die temporäre Datei existiert nur bis zum Ende dieser Methode.
            try FileManager.default.moveItem(at: location, to: destination)
            update(downloadTask.taskIdentifier) {
                $0.progress = 1
                $0.state = .finished
                $0.fileURL = destination
                $0.name = destination.lastPathComponent
            }
            onFinished?(destination)
        } catch {
            update(downloadTask.taskIdentifier) { $0.state = .failed(error.localizedDescription) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            update(task.taskIdentifier) { item in
                if item.state == .running { item.state = .failed(error.localizedDescription) }
            }
        }
        tasks[task.taskIdentifier] = nil
    }
}

// MARK: - Quellen (AltStore-Quellenformat)

struct SourceFeed: Decodable {
    var name: String?
    var apps: [SourceApp]?
}

struct SourceApp: Decodable, Identifiable {
    struct Version: Decodable {
        var version: String?
        var downloadURL: String?
        var size: Int64?
    }

    var name: String?
    var bundleIdentifier: String?
    var developerName: String?
    var subtitle: String?
    var localizedDescription: String?
    var iconURL: String?
    var version: String?
    var downloadURL: String?
    var size: Int64?
    var versions: [Version]?

    var id: String { (bundleIdentifier ?? "") + "|" + (name ?? "") }
    var displayName: String { name ?? bundleIdentifier ?? "Unbenannt" }
    var latestVersion: String? { versions?.first?.version ?? version }
    var latestSize: Int64? { versions?.first?.size ?? size }
    var latestDownloadURL: URL? {
        guard let string = versions?.first?.downloadURL ?? downloadURL else { return nil }
        return URL(string: string)
    }
}

enum SourceService {
    static func fetch(_ url: URL) async throws -> SourceFeed {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppError("Die Quelle antwortet mit Status \(http.statusCode).")
        }
        do {
            return try JSONDecoder().decode(SourceFeed.self, from: data)
        } catch {
            throw AppError("Die Quelle liefert kein gültiges Quellen-JSON.")
        }
    }
}
