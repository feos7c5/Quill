import Foundation
import Observation
import SwiftData
import UIKit

/// LiveContainer laden, signieren und das Zertifikat übergeben.
///
/// Ohne JIT müssen Apps in LiveContainer signiert sein, und zwar mit dem Zertifikat,
/// das auch LiveContainer selbst signiert hat. LiveContainer importiert dieses
/// Zertifikat in seinen Einstellungen („Import Certificate“) als .p12 mit Passwort.
@MainActor
@Observable
final class LiveContainerService {
    struct Release: Equatable {
        let version: String
        let downloadURL: URL
    }

    static let releaseAPI = URL(string: "https://api.github.com/repos/LiveContainer/LiveContainer/releases/latest")!
    static let assetName = "LiveContainer.ipa"
    static let appURL = URL(string: "livecontainer://")!

    private(set) var latest: Release?
    private(set) var isLoading = false
    private(set) var downloadProgress: Double?

    // MARK: - Release

    func fetchLatest() async throws -> Release {
        isLoading = true
        defer { isLoading = false }
        var request = URLRequest(url: Self.releaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError("GitHub hat die Release-Daten nicht geliefert. Später erneut versuchen.")
        }
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browserDownloadUrl: URL
            }
            let tagName: String
            let assets: [Asset]
        }
        let payload = try JSONDecoder.core.decode(Payload.self, from: data)
        guard let asset = payload.assets.first(where: { $0.name == Self.assetName }) else {
            throw AppError("Im aktuellen Release fehlt \(Self.assetName).")
        }
        // Nur Downloads vom offiziellen Repository annehmen.
        guard asset.browserDownloadUrl.host == "github.com",
              asset.browserDownloadUrl.path.hasPrefix("/LiveContainer/LiveContainer/") else {
            throw AppError("Unerwartete Download-Adresse für LiveContainer.")
        }
        let release = Release(version: payload.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v")),
                              downloadURL: asset.browserDownloadUrl)
        latest = release
        return release
    }

    /// Lädt die IPA, prüft die Bundle-ID und legt sie in die Bibliothek.
    func download(_ release: Release, context: ModelContext) async throws -> LibraryApp {
        downloadProgress = 0
        defer { downloadProgress = nil }
        let (temporary, response) = try await URLSession.shared.download(from: release.downloadURL, delegate: ProgressDelegate { [weak self] value in
            Task { @MainActor in self?.downloadProgress = value }
        })
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError("Der Download von LiveContainer ist fehlgeschlagen.")
        }
        let ipa = Paths.temporary.appendingPathComponent("LiveContainer-\(release.version).ipa")
        try? FileManager.default.removeItem(at: ipa)
        try FileManager.default.moveItem(at: temporary, to: ipa)
        let info = try IPAInspector.inspect(ipa)
        guard info.bundleID == SigningPipeline.liveContainerBundleID else {
            try? FileManager.default.removeItem(at: ipa)
            throw AppError("Die geladene Datei ist nicht LiveContainer (Bundle-ID \(info.bundleID)).")
        }
        return try await AppLibrary.importIPA(from: ipa, move: true, context: context)
    }

    // MARK: - Zertifikat übergeben

    /// Erzeugt die .p12 für LiveContainer. Beim Apple-Account wird das Zertifikat zusätzlich
    /// als Identität in Quill abgelegt, damit es unter „Export .p12“ erscheint.
    func certificateForLiveContainer(installed: InstalledApp, password: String, account: AppleAccountService,
                                     context: ModelContext) async throws -> URL {
        let data: Data
        switch installed.method {
        case .account:
            let exported = try await account.exportP12(password: password)
            data = exported.data
            _ = try? IdentityStore.importP12(data, password: password, origin: .appleAccount, context: context)
        case .identity:
            guard let identityID = installed.identityID,
                  let identity = try context.fetch(FetchDescriptor<SigningIdentity>(predicate: #Predicate { $0.id == identityID })).first else {
                throw AppError("Das Zertifikat, mit dem LiveContainer signiert wurde, fehlt.")
            }
            let url = try IdentityStore.export(identity, password: .new(password), profiles: [])
            data = try Data(contentsOf: url)
        }
        let url = try Paths.workDirectory("livecontainer").appendingPathComponent("LiveContainer-Zertifikat.p12")
        try data.write(to: url, options: .completeFileProtection)
        return url
    }
}

/// Meldet den Download-Fortschritt.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let handler: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(_ handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [handler] progress, _ in
            handler(progress.fractionCompleted)
        }
    }
}
