import Foundation
import Security
import QuillCore
import SwiftData
import ZIPFoundation
import Zsign

/// Inhalt eines .mobileprovision (CMS-signierte Property List).
struct ProvisioningProfile {
    let name: String
    let uuid: String
    let teamName: String
    let teamID: String
    let applicationIdentifier: String
    let creationDate: Date
    let expirationDate: Date
    let devices: [String]
    let provisionsAllDevices: Bool
    let entitlements: [String: Any]
    let developerCertificates: [Data]
    let plist: [String: Any]

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    init(data: Data) throws {
        let plist = try Self.embeddedPlist(in: data)
        self.plist = plist
        name = plist["Name"] as? String ?? "Unbenannt"
        uuid = plist["UUID"] as? String ?? ""
        teamName = plist["TeamName"] as? String ?? ""
        teamID = (plist["TeamIdentifier"] as? [String])?.first ?? ""
        creationDate = plist["CreationDate"] as? Date ?? .distantPast
        expirationDate = plist["ExpirationDate"] as? Date ?? .distantPast
        devices = plist["ProvisionedDevices"] as? [String] ?? []
        provisionsAllDevices = plist["ProvisionsAllDevices"] as? Bool ?? false
        entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        developerCertificates = plist["DeveloperCertificates"] as? [Data] ?? []
        applicationIdentifier = entitlements["application-identifier"] as? String ?? ""
    }

    var kind: ProfileKind {
        if provisionsAllDevices { return .enterprise }
        if devices.isEmpty { return .appStore }
        return (entitlements["get-task-allow"] as? Bool ?? false) ? .development : .adHoc
    }

    /// Schneidet die XML-Property-List aus der CMS-Hülle heraus.
    static func embeddedPlist(in data: Data) throws -> [String: Any] {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
            throw AppError("Die Datei enthält kein lesbares Provisioning Profile.")
        }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] else {
            throw AppError("Das Provisioning Profile ist beschädigt.")
        }
        return plist
    }
}

enum PKCS12 {
    /// Öffnet eine .p12-Datei und liefert die enthaltene Identität (Zertifikat + privater Schlüssel).
    /// Nutzt Apples Implementierung, die auch ältere Verschlüsselungen (RC2, 3DES) liest.
    static func identity(p12 data: Data, password: String) throws -> SecIdentity {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        if status == errSecAuthFailed {
            throw IdentityStore.PasswordRequired()
        }
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let value = array.first?[kSecImportItemIdentity as String] else {
            throw AppError("Die .p12-Datei konnte nicht gelesen werden (Status \(status)).")
        }
        // swiftlint:disable:next force_cast
        return value as! SecIdentity
    }

    static func certificateDER(of identity: SecIdentity) throws -> Data {
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        guard let certificate else { throw AppError("Die .p12-Datei enthält kein Zertifikat.") }
        return SecCertificateCopyData(certificate) as Data
    }
}

/// Dateien aus einer Auswahl, Zip-Archive bereits aufgelöst.
struct ImportBatch {
    struct File {
        let name: String
        let data: Data
    }
    var p12s: [File] = []
    var profiles: [File] = []
    var certificates: [File] = []
    var skipped: [String] = []

    var isEmpty: Bool { p12s.isEmpty && profiles.isEmpty && certificates.isEmpty }
}

/// Zertifikate, Profile, Import/Export und CSR.
enum IdentityStore {
    struct PasswordRequired: LocalizedError {
        var errorDescription: String? { "Das Passwort der .p12-Datei ist falsch." }
    }

    private static let pendingKeyKey = "csr-pending-key"
    private static let pendingDateKey = "csr.pendingSince"

    // MARK: - Dateien einsammeln

    /// Liest die gewählten Dateien und packt .zip-Archive aus. Unbekanntes wird übersprungen.
    static func collect(_ urls: [URL]) throws -> ImportBatch {
        var batch = ImportBatch()
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            try add(name: url.lastPathComponent, data: data, to: &batch, depth: 0)
        }
        return batch
    }

    private static func add(name: String, data: Data, to batch: inout ImportBatch, depth: Int) throws {
        switch (name as NSString).pathExtension.lowercased() {
        case "p12", "pfx":
            batch.p12s.append(.init(name: name, data: data))
        case "mobileprovision", "provisionprofile":
            batch.profiles.append(.init(name: name, data: data))
        case "cer", "crt", "der":
            batch.certificates.append(.init(name: name, data: data))
        case "zip" where depth == 0:
            let archive = try Archive(data: data, accessMode: .read)
            for entry in archive where entry.type == .file {
                let entryName = (entry.path as NSString).lastPathComponent
                guard !entryName.hasPrefix("."), !entry.path.contains("__MACOSX") else { continue }
                var content = Data()
                _ = try archive.extract(entry) { content.append($0) }
                try add(name: entryName, data: content, to: &batch, depth: depth + 1)
            }
        default:
            batch.skipped.append(name)
        }
    }

    // MARK: - Import

    @MainActor
    @discardableResult
    static func importProfile(_ data: Data, context: ModelContext) throws -> ProfileRecord {
        let profile = try ProvisioningProfile(data: data)
        let uuid = profile.uuid
        if let existing = try context.fetch(FetchDescriptor<ProfileRecord>(predicate: #Predicate { $0.uuid == uuid })).first {
            return existing
        }
        let record = ProfileRecord(profile: profile)
        try Paths.writeProtected(data, to: record.fileURL)
        context.insert(record)
        try context.save()
        return record
    }

    /// Prüft das Passwort und legt die Identität an. Gibt es dasselbe Zertifikat schon,
    /// wird es aktualisiert statt doppelt angelegt.
    @MainActor
    @discardableResult
    static func importP12(_ data: Data, password: String, origin: IdentityOrigin = .imported,
                          context: ModelContext) throws -> SigningIdentity {
        let identity = try PKCS12.identity(p12: data, password: password)
        let der = try PKCS12.certificateDER(of: identity)
        let info = try inspectCertificate(der)
        let hash = der.sha256

        let record: SigningIdentity
        if let existing = try context.fetch(FetchDescriptor<SigningIdentity>(predicate: #Predicate { $0.certificateHash == hash })).first {
            record = existing
        } else {
            record = SigningIdentity(
                name: info.commonName ?? "Zertifikat",
                teamID: info.teamId ?? "",
                teamName: info.organization ?? "",
                serial: info.serial,
                certificateHash: hash,
                expirationDate: Date(timeIntervalSince1970: info.notAfter),
                origin: origin
            )
            context.insert(record)
        }
        try Paths.writeProtected(data, to: record.p12URL)
        Keychain.set(password, for: record.keychainKey)
        try context.save()
        return record
    }

    static func inspectCertificate(_ der: Data) throws -> CertificateInfo {
        try Core.now(CertificateInfo.self, der.base64EncodedString().withCString { sc_certificate_inspect($0) })
    }

    /// Prüft, ob die .p12 ein Passwort braucht.
    static func needsPassword(_ data: Data) -> Bool {
        (try? PKCS12.identity(p12: data, password: "")) == nil
    }

    // MARK: - CSR

    /// Erzeugt Schlüssel und CSR. Der Schlüssel bleibt im Schlüsselbund, bis die .cer importiert ist.
    /// Liefert eine CSR-Datei zum Hochladen auf developer.apple.com.
    static func createCSR(commonName: String, email: String?) throws -> URL {
        let result = try commonName.withCString { name in
            try (email ?? "").withCString { mail in
                try Core.now(CSRResult.self, sc_csr_create(name, email == nil ? nil : mail))
            }
        }
        Keychain.set(result.keyPkcs8, for: pendingKeyKey)
        UserDefaults.standard.set(Date.now, forKey: pendingDateKey)
        let url = try Paths.workDirectory("csr").appendingPathComponent("CertificateSigningRequest.certSigningRequest")
        try Data(result.csrPem.utf8).write(to: url)
        return url
    }

    static var pendingCSRDate: Date? {
        Keychain.get(pendingKeyKey) == nil ? nil : UserDefaults.standard.object(forKey: pendingDateKey) as? Date
    }

    /// Verbindet die von Apple geladene .cer mit dem wartenden Schlüssel.
    @MainActor
    @discardableResult
    static func importCertificate(_ data: Data, context: ModelContext) throws -> SigningIdentity {
        guard let key = Keychain.get(pendingKeyKey) else {
            throw AppError("Zu dieser .cer gibt es keinen Schlüssel. Zuerst unter „Zertifikatsanfrage (CSR) erzeugen“ eine CSR erzeugen und bei Apple hochladen.")
        }
        // Apple liefert DER; manche Werkzeuge PEM.
        let der = pemToDER(data) ?? data
        let password = randomPassword()
        let p12 = try der.base64EncodedString().withCString { cert in
            try key.withCString { k in
                try password.withCString { p in
                    try Core.now(P12Data.self, sc_p12_build(cert, k, p))
                }
            }
        }
        guard let p12Data = Data(base64Encoded: p12.p12) else { throw AppError("Die .p12 konnte nicht erzeugt werden.") }
        let identity = try importP12(p12Data, password: password, origin: .csr, context: context)
        Keychain.delete(pendingKeyKey)
        UserDefaults.standard.removeObject(forKey: pendingDateKey)
        return identity
    }

    private static func pemToDER(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN") else { return nil }
        let body = text.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body)
    }

    // MARK: - Export

    enum ExportPassword {
        case original
        case new(String)
    }

    /// Exportiert eine Identität als .p12 oder, mit Profilen, als .zip. Liefert eine temporäre Datei.
    @MainActor
    static func export(_ identity: SigningIdentity, password: ExportPassword, profiles: [ProfileRecord]) throws -> URL {
        var p12 = try Data(contentsOf: identity.p12URL)
        if case .new(let newPassword) = password {
            let original = identity.password
            let rewrapped = try p12.base64EncodedString().withCString { data in
                try original.withCString { old in
                    try newPassword.withCString { new in
                        try Core.now(P12Data.self, sc_p12_rewrap(data, old, new))
                    }
                }
            }
            guard let data = Data(base64Encoded: rewrapped.p12) else { throw AppError("Umverschlüsseln fehlgeschlagen.") }
            p12 = data
        }

        let folder = try Paths.workDirectory("export")
        let base = identity.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "")
        let p12URL = folder.appendingPathComponent("\(base).p12")
        try p12.write(to: p12URL, options: .completeFileProtection)
        guard !profiles.isEmpty else { return p12URL }

        let zipURL = folder.appendingPathComponent("\(base).zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: p12URL.lastPathComponent, relativeTo: folder)
        for profile in profiles {
            let name = "\(profile.name.replacingOccurrences(of: "/", with: "-")).mobileprovision"
            let data = try Data(contentsOf: profile.fileURL)
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        try? FileManager.default.removeItem(at: p12URL)
        return zipURL
    }

    // MARK: - Zuordnung

    static func profiles(for identity: SigningIdentity, in all: [ProfileRecord]) -> [ProfileRecord] {
        all.filter { $0.certificateHashes.contains(identity.certificateHash) }
            .sorted { $0.expirationDate > $1.expirationDate }
    }

    /// Bestes gültiges Profil für eine Bundle-ID und ein Gerät: exakte App-ID vor Wildcard.
    static func bestProfile(for identity: SigningIdentity, bundleID: String, udid: String?,
                            in all: [ProfileRecord]) -> ProfileRecord? {
        let candidates = profiles(for: identity, in: all).filter { profile in
            !profile.isExpired && profile.matches(bundleID: bundleID) && (udid.map(profile.includes(device:)) ?? true)
        }
        return candidates.first { !$0.bundlePattern.contains("*") } ?? candidates.first
    }

    // MARK: - Löschen

    @MainActor
    static func delete(_ identity: SigningIdentity, context: ModelContext) {
        try? FileManager.default.removeItem(at: identity.directory)
        Keychain.delete(identity.keychainKey)
        context.delete(identity)
        try? context.save()
    }

    @MainActor
    static func delete(_ profile: ProfileRecord, context: ModelContext) {
        try? FileManager.default.removeItem(at: profile.fileURL)
        context.delete(profile)
        try? context.save()
    }

    /// Löscht alle Identitäten, Profile und einen wartenden CSR-Schlüssel.
    @MainActor
    static func reset(context: ModelContext) throws {
        for identity in try context.fetch(FetchDescriptor<SigningIdentity>()) {
            Keychain.delete(identity.keychainKey)
            context.delete(identity)
        }
        for profile in try context.fetch(FetchDescriptor<ProfileRecord>()) {
            context.delete(profile)
        }
        try context.save()
        try? FileManager.default.removeItem(at: Paths.identities)
        try? FileManager.default.removeItem(at: Paths.profiles)
        try FileManager.default.createDirectory(at: Paths.identities, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Paths.profiles, withIntermediateDirectories: true)
        Keychain.delete(pendingKeyKey)
        UserDefaults.standard.removeObject(forKey: pendingDateKey)
    }

    // MARK: - Widerruf

    /// Fragt per OCSP bei Apple, ob das Zertifikat widerrufen wurde. Braucht ein passendes Profil.
    @MainActor
    static func checkRevocation(_ identity: SigningIdentity, profile: ProfileRecord) async -> (status: Int, message: String?) {
        let provisionPath = profile.fileURL.path
        let p12Path = identity.p12URL.path
        let password = identity.password
        let result: (Int, String?) = await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            Zsign.checkRevokage(provisionPath: provisionPath, p12Path: p12Path, p12Password: password) { status, _, error in
                guard once.claim() else { return }
                continuation.resume(returning: (Int(status), error))
            }
        }
        identity.revocationStatus = result.0
        return result
    }
}

/// Stellt sicher, dass eine Continuation nur einmal fortgesetzt wird.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
