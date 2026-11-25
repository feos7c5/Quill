import Foundation
import QuillCore

/// Dünne Brücke zum Rust-Kern (QuillCore.xcframework).
///
/// Alle Kernfunktionen blockieren; die Methoden hier laufen deshalb auf einem
/// Hintergrund-Thread. Die Antwort ist immer `{"ok": …, "data"|"error": …}`.
enum Core {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Einmal beim App-Start.
    static func start() {
        CoreVault.restoreIfMissing()
        _ = try? decodeRaw(Paths.core.path.withCString { sc_init($0) })
    }

    /// Führt einen blockierenden Kernaufruf im Hintergrund aus und dekodiert `data`.
    static func run<T: Decodable & Sendable>(_ type: T.Type = T.self,
                                             _ call: @escaping @Sendable () -> UnsafeMutablePointer<CChar>?) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try decode(T.self, call())
        }.value
    }

    /// Wie `run`, für Aufrufe, deren Ergebnis nicht gebraucht wird.
    static func perform(_ call: @escaping @Sendable () -> UnsafeMutablePointer<CChar>?) async throws {
        _ = try await run(Ignored.self, call)
    }

    /// Synchron, für schnelle Aufrufe ohne Netzwerk (Kopplungsstand, CSR, p12).
    static func now<T: Decodable>(_ type: T.Type = T.self, _ pointer: UnsafeMutablePointer<CChar>?) throws -> T {
        try decode(T.self, pointer)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ pointer: UnsafeMutablePointer<CChar>?) throws -> T {
        let data = try decodeRaw(pointer)
        do {
            return try JSONDecoder.core.decode(T.self, from: data)
        } catch {
            throw Failure(message: String(localized: "Unerwartete Antwort des Kerns: \(error.localizedDescription)"))
        }
    }

    /// Gibt den Zeiger frei und liefert `data` als JSON-Bytes.
    private static func decodeRaw(_ pointer: UnsafeMutablePointer<CChar>?) throws -> Data {
        guard let pointer else { throw Failure(message: String(localized: "Der Kern hat nicht geantwortet.")) }
        defer { sc_string_free(pointer) }
        let text = Data(String(cString: pointer).utf8)
        guard let object = try JSONSerialization.jsonObject(with: text) as? [String: Any] else {
            throw Failure(message: String(localized: "Unlesbare Antwort des Kerns."))
        }
        if object["ok"] as? Bool != true {
            let message = object["error"] as? String ?? "Unknown error."
            throw Failure(message: localized(message, detail: object["detail"] as? String))
        }
        let payload = object["data"] ?? NSNull()
        return try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
    }

    /// Meldungen des Kerns sind feste englische Sätze; die Übersetzung steht in `Core.xcstrings`.
    static func localized(_ message: String, detail: String? = nil) -> String {
        let text = Bundle.main.localizedString(forKey: message, value: message, table: "Core")
        guard let detail, !detail.isEmpty else { return text }
        return "\(text) (\(detail))"
    }

    struct Ignored: Decodable, Sendable {
        init(from decoder: Decoder) throws {}
    }
}

extension JSONDecoder {
    static let core: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

// MARK: - Fortschritt

/// Hält einen Swift-Closure für den C-Fortschrittsrückruf am Leben.
final class CoreProgress: @unchecked Sendable {
    let handler: @Sendable (Double, String) -> Void

    init(_ handler: @escaping @Sendable (Double, String) -> Void) {
        self.handler = handler
    }

    /// Kontextzeiger für den Kern. Gültig, solange dieses Objekt lebt.
    var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    static let callback: sc_progress_cb = { context, fraction, message in
        guard let context else { return }
        let box = Unmanaged<CoreProgress>.fromOpaque(context).takeUnretainedValue()
        box.handler(fraction, message.map { Core.localized(String(cString: $0)) } ?? "")
    }
}

// MARK: - Antworttypen

struct PairAdvert: Decodable, Sendable {
    let port: UInt16
    let name: String
    let serviceType: String
    let txt: [String: String]
}

struct PairSnapshot: Decodable, Sendable {
    struct Peer: Decodable, Sendable {
        let udid: String
        let name: String?
        let model: String?
    }
    let phase: String
    let message: String
    let detail: String?
    let pin: String?
    let peer: Peer?
    let running: Bool
}

struct DeviceInfo: Decodable, Sendable, Equatable {
    let udid: String?
    let name: String?
    let model: String?
    let productVersion: String?
    let developerMode: Bool?
}

struct DeviceApp: Decodable, Sendable {
    let bundleId: String
    let name: String?
    let version: String?
    let signer: String?
}

struct AccountTeam: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String?
    let type: String?
    let status: String?

    var displayName: String { name ?? id }
    /// Kostenlose Teams heißen bei Apple „Personal Team“ / Typ „Individual“ ohne Programm.
    var isFree: Bool {
        (type ?? "").localizedCaseInsensitiveContains("free") || (name ?? "").localizedCaseInsensitiveContains("personal")
    }
}

struct AccountStatus: Decodable, Sendable {
    let loggedIn: Bool
    let email: String?
    let name: String?
    let team: AccountTeam?
    let teams: [AccountTeam]?
}

struct AccountSignResult: Decodable, Sendable {
    let appPath: String
    let bundleId: String?
    let special: String?
}

struct AppIDQuota: Decodable, Sendable {
    struct Entry: Decodable, Sendable, Identifiable {
        let identifier: String
        let name: String
        let expires: Double?
        var id: String { identifier }
    }
    let available: Int?
    let max: Int?
    let appIds: [Entry]
}

struct AppleCertificate: Decodable, Sendable, Identifiable {
    let serial: String?
    let name: String?
    let machineName: String?
    let status: String?
    let isQuill: Bool
    let expires: Double?
    var id: String { serial ?? UUID().uuidString }
}

struct ExportedP12: Decodable, Sendable {
    let p12: String
    let serial: String
    let machineId: String
}

struct CSRResult: Decodable, Sendable {
    let csrPem: String
    let keyPkcs8: String
}

struct P12Data: Decodable, Sendable {
    let p12: String
}

struct CertificateInfo: Decodable, Sendable {
    let subject: String
    let commonName: String?
    let teamId: String?
    let organization: String?
    let serial: String
    let notAfter: Double
    let certificateDer: String
}
