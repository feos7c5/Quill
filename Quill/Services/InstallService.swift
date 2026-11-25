import Foundation
import Observation
import UIKit

enum InstallMode: String, CaseIterable, Identifiable {
    /// Manifest und IPA kommen vom eigenen HTTPS-Server auf dem Gerät.
    case localTLS
    /// Das Manifest liefert ein externer HTTPS-Dienst, die IPA der lokale Server.
    case manifestService

    var id: String { rawValue }

    var label: String {
        switch self {
        case .localTLS: return "Lokal (eigenes TLS-Zertifikat)"
        case .manifestService: return "Manifest-Dienst"
        }
    }
}

enum InstallSettings {
    static let modeKey = "install.mode"
    static let hostKey = "install.tlsHost"
    static let templateKey = "install.manifestTemplate"
    static let tlsPasswordKey = "install-tls-password"

    static var mode: InstallMode {
        InstallMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .localTLS
    }
    static var host: String { (UserDefaults.standard.string(forKey: hostKey) ?? "").trimmed }
    static var template: String { (UserDefaults.standard.string(forKey: templateKey) ?? "").trimmed }
    static var hasTLSIdentity: Bool { FileManager.default.fileExists(atPath: Paths.tlsIdentity.path) }
}

/// Installiert eine signierte IPA über `itms-services`.
///
/// iOS lädt das Manifest nur über HTTPS mit einem Zertifikat, dem das Gerät vertraut.
/// Deshalb braucht die lokale Variante ein TLS-Zertifikat (.p12) für einen Hostnamen,
/// der auf 127.0.0.1 zeigt.
@MainActor
@Observable
final class InstallService {
    @ObservationIgnored private var server: HTTPServer?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private let port: UInt16 = 8443

    var isConfigured: Bool {
        switch InstallSettings.mode {
        case .localTLS: return InstallSettings.hasTLSIdentity && !InstallSettings.host.isEmpty
        case .manifestService: return InstallSettings.template.contains("{ipa}")
        }
    }

    func install(ipaURL: URL, bundleID: String, version: String, title: String) throws {
        guard isConfigured else {
            throw AppError("Die Installation ist noch nicht eingerichtet (Einstellungen → Installation). Bis dahin lässt sich die IPA über „Teilen“ exportieren.")
        }
        server?.stop()
        server = nil

        let manifestURL: String
        switch InstallSettings.mode {
        case .localTLS:
            let p12 = try Data(contentsOf: Paths.tlsIdentity)
            let password = Keychain.get(InstallSettings.tlsPasswordKey) ?? ""
            let identity = try PKCS12.identity(p12: p12, password: password)
            let base = "https://\(InstallSettings.host):\(port)"
            let manifest = try Self.manifest(ipaURL: "\(base)/app.ipa", bundleID: bundleID, version: version, title: title)
            try startServer(ipaURL: ipaURL, manifest: manifest, identity: identity)
            manifestURL = "\(base)/manifest.plist"

        case .manifestService:
            try startServer(ipaURL: ipaURL, manifest: nil, identity: nil)
            let values = [
                "{ipa}": "http://127.0.0.1:\(port)/app.ipa",
                "{bundleid}": bundleID,
                "{version}": version,
                "{name}": title
            ]
            var url = InstallSettings.template
            for (placeholder, value) in values {
                url = url.replacingOccurrences(of: placeholder, with: Self.encode(value))
            }
            manifestURL = url
        }

        guard let itms = URL(string: "itms-services://?action=download-manifest&url=\(Self.encode(manifestURL))") else {
            throw AppError("Die Manifest-Adresse ist ungültig.")
        }

        // Der Server muss weiterlaufen, während iOS im Hintergrund lädt.
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "quill.install") { [weak self] in
            self?.endBackgroundTask()
        }
        UIApplication.shared.open(itms)
    }

    func stop() {
        server?.stop()
        server = nil
        endBackgroundTask()
    }

    private func startServer(ipaURL: URL, manifest: Data?, identity: SecIdentity?) throws {
        let server = HTTPServer(port: port, identity: identity, loopbackOnly: true,
                                handler: Self.makeHandler(ipaURL: ipaURL, manifest: manifest))
        try server.start()
        self.server = server
    }

    /// Der Handler läuft auf der Server-Queue und darf deshalb nicht an den Main-Actor gebunden sein.
    private nonisolated static func makeHandler(ipaURL: URL, manifest: Data?) -> HTTPServer.Handler {
        return { request in
            switch request.path {
            case "/app.ipa":
                return .file(ipaURL)
            case "/manifest.plist":
                guard let manifest else { return .text("Not found", status: 404) }
                return HTTPResponse(contentType: "text/xml", body: .data(manifest))
            default:
                return .text("Not found", status: 404)
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private nonisolated static func manifest(ipaURL: String, bundleID: String, version: String, title: String) throws -> Data {
        let plist: [String: Any] = [
            "items": [[
                "assets": [[
                    "kind": "software-package",
                    "url": ipaURL
                ]],
                "metadata": [
                    "bundle-identifier": bundleID,
                    "bundle-version": version,
                    "kind": "software",
                    "title": title
                ]
            ]]
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private nonisolated static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
