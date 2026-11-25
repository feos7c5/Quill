import CryptoKit
import Foundation
import Security

enum Paths {
    static let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    static let support: URL = directory(
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    )
    static let identities: URL = directory(support.appendingPathComponent("Identities", isDirectory: true))
    static let profiles: URL = directory(support.appendingPathComponent("Profiles", isDirectory: true))
    /// Privates Verzeichnis des Rust-Kerns (Anisette-Zustand, Account-Schlüssel, Protokoll).
    static let core: URL = directory(support.appendingPathComponent("Core", isDirectory: true))
    /// Remote-Pairing-Datei. Gibt denselben Zugriff wie ein vertrauter Rechner, daher nie in Dokumente.
    static let pairingFile: URL = support.appendingPathComponent("pairing.plist")
    static let library: URL = directory(support.appendingPathComponent("Library", isDirectory: true))
    static var downloads: URL { directory(documents.appendingPathComponent("Downloads", isDirectory: true)) }
    static var temporary: URL { directory(FileManager.default.temporaryDirectory.appendingPathComponent("Quill", isDirectory: true)) }
    static let tlsIdentity: URL = support.appendingPathComponent("install-tls.p12")

    private static func directory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return url
    }

    /// Schreibt eine Datei mit Dateischutz; nur zugänglich, nachdem das Gerät einmal entsperrt wurde.
    static func writeProtected(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Ein frischer, leerer Arbeitsordner unter tmp/Quill.
    static func workDirectory(_ prefix: String) throws -> URL {
        let url = temporary.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Liefert eine freie URL, indem bei Bedarf „ 2“, „ 3“ … angehängt wird.
    static func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// Gesamtgröße eines Ordners (rekursiv).
    static func folderSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += size(of: file)
        }
        return total
    }
}

/// Minimaler Schlüsselbund-Zugriff für Zertifikatspasswörter.
enum Keychain {
    private static let service = "quill"

    static func set(_ value: String, for key: String) {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Fehler mit lesbarer Meldung. Literale werden über den Sprachkatalog übersetzt.
struct AppError: LocalizedError {
    let message: String
    init(_ message: LocalizedStringResource) { self.message = String(localized: message) }
    init(verbatim message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// „noch 3 Tage“ mit richtiger Einzahl/Mehrzahl in jeder Sprache.
func daysLeftText(_ days: Int) -> String {
    String(localized: "noch \(days) Tage")
}

extension Int64 {
    var fileSizeText: String { formatted(.byteCount(style: .file)) }
}

extension Data {
    var sha256: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// UDID für die Anzeige: Anfang und Ende sichtbar, Mitte maskiert.
    var maskedUDID: String {
        guard count > 12 else { return self }
        return "\(prefix(8))-••••-••••-\(suffix(4))"
    }
}

/// Zufälliges Passwort für intern gespeicherte .p12-Dateien.
func randomPassword() -> String {
    var bytes = [UInt8](repeating: 0, count: 18)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).base64EncodedString()
}
