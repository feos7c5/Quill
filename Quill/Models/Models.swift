import Foundation
import SwiftData

/// Ein Signierzertifikat mit privatem Schlüssel (.p12).
/// Datei: Application Support/Identities/<id>/identity.p12, Passwort im Schlüsselbund.
@Model
final class SigningIdentity {
    @Attribute(.unique) var id: UUID
    var name: String
    var teamID: String
    var teamName: String
    /// Seriennummer in Großbuchstaben-Hex ohne führende Nullen (wie Apple sie anzeigt).
    var serial: String
    /// SHA-256 des Zertifikats (DER), um passende Profile zu finden.
    var certificateHash: String
    var expirationDate: Date
    var originRaw: String
    var addedAt: Date
    /// 0 = gültig, 1 = widerrufen, 2 = unbekannt, nil = nie geprüft
    var revocationStatus: Int?

    init(id: UUID = UUID(), name: String, teamID: String, teamName: String, serial: String,
         certificateHash: String, expirationDate: Date, origin: IdentityOrigin) {
        self.id = id
        self.name = name
        self.teamID = teamID
        self.teamName = teamName
        self.serial = serial
        self.certificateHash = certificateHash
        self.expirationDate = expirationDate
        self.originRaw = origin.rawValue
        self.addedAt = .now
    }

    var origin: IdentityOrigin { IdentityOrigin(rawValue: originRaw) ?? .imported }
    var isExpired: Bool { expirationDate < .now }
    var directory: URL { Paths.identities.appendingPathComponent(id.uuidString, isDirectory: true) }
    var p12URL: URL { directory.appendingPathComponent("identity.p12") }
    var keychainKey: String { "identity-\(id.uuidString)" }
    var password: String { Keychain.get(keychainKey) ?? "" }
}

enum IdentityOrigin: String {
    case imported, appleAccount, csr

    var label: String {
        switch self {
        case .imported: return "Importiert"
        case .appleAccount: return "Apple-Account"
        case .csr: return "Eigene CSR"
        }
    }
}

/// Ein Provisioning Profile. Datei: Application Support/Profiles/<id>.mobileprovision.
@Model
final class ProfileRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var uuid: String
    var teamID: String
    var teamName: String
    var applicationIdentifier: String
    var expirationDate: Date
    var deviceCount: Int
    var devices: [String]
    var kindRaw: String
    /// SHA-256 aller enthaltenen Entwicklerzertifikate.
    var certificateHashes: [String]
    var addedAt: Date

    init(id: UUID = UUID(), profile: ProvisioningProfile) {
        self.id = id
        self.name = profile.name
        self.uuid = profile.uuid
        self.teamID = profile.teamID
        self.teamName = profile.teamName
        self.applicationIdentifier = profile.applicationIdentifier
        self.expirationDate = profile.expirationDate
        self.deviceCount = profile.devices.count
        self.devices = profile.devices
        self.kindRaw = profile.kind.rawValue
        self.certificateHashes = profile.developerCertificates.map(\.sha256)
        self.addedAt = .now
    }

    var kind: ProfileKind { ProfileKind(rawValue: kindRaw) ?? .development }
    var isExpired: Bool { expirationDate < .now }
    var fileURL: URL { Paths.profiles.appendingPathComponent("\(id.uuidString).mobileprovision") }

    /// App-ID ohne Team-Präfix, z. B. `com.example.*`.
    var bundlePattern: String {
        guard let dot = applicationIdentifier.firstIndex(of: ".") else { return applicationIdentifier }
        return String(applicationIdentifier[applicationIdentifier.index(after: dot)...])
    }

    func matches(bundleID: String) -> Bool {
        let pattern = bundlePattern
        if pattern == "*" { return true }
        if pattern.hasSuffix(".*") { return bundleID.hasPrefix(String(pattern.dropLast(1))) }
        return pattern == bundleID
    }

    func includes(device udid: String) -> Bool {
        kind == .enterprise || devices.contains { $0.caseInsensitiveCompare(udid) == .orderedSame }
    }
}

/// Eine App in der Bibliothek (unsignierte oder signierte IPA).
@Model
final class LibraryApp {
    @Attribute(.unique) var id: UUID
    var name: String
    var bundleID: String
    var version: String
    var minimumOS: String
    var size: Int64
    var isSigned: Bool
    var certificateName: String?
    var addedAt: Date

    init(id: UUID, name: String, bundleID: String, version: String, minimumOS: String,
         size: Int64, isSigned: Bool, certificateName: String?) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.minimumOS = minimumOS
        self.size = size
        self.isSigned = isSigned
        self.certificateName = certificateName
        self.addedAt = .now
    }

    var directory: URL { Paths.library.appendingPathComponent(id.uuidString, isDirectory: true) }
    var ipaURL: URL { directory.appendingPathComponent("app.ipa") }
    var iconURL: URL { directory.appendingPathComponent("icon.png") }

    /// Dateiname für Teilen und Export.
    var exportFileName: String {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        return "\(safe)_\(version)\(isSigned ? "_signed" : "").ipa"
    }
}

/// Eine von Quill auf diesem Gerät installierte App. Grundlage für den Refresh.
@Model
final class InstalledApp {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Bundle-ID der installierten App (beim Apple-Account mit Team-ID-Suffix).
    var bundleID: String
    var originalBundleID: String
    var version: String
    var teamID: String
    var methodRaw: String
    var identityID: UUID?
    /// Unsignierte Quelle in der Bibliothek; ohne sie ist kein Refresh möglich.
    var sourceAppID: UUID?
    /// Signieroptionen als JSON, damit der Refresh dieselbe App erzeugt.
    var optionsData: Data?
    var isLiveContainer: Bool
    var installedAt: Date
    var refreshedAt: Date
    var expirationDate: Date

    init(name: String, bundleID: String, originalBundleID: String, version: String, teamID: String,
         method: SigningMethodKind, identityID: UUID?, sourceAppID: UUID?, options: SignOptions,
         isLiveContainer: Bool, expirationDate: Date) {
        self.id = UUID()
        self.name = name
        self.bundleID = bundleID
        self.originalBundleID = originalBundleID
        self.version = version
        self.teamID = teamID
        self.methodRaw = method.rawValue
        self.identityID = identityID
        self.sourceAppID = sourceAppID
        self.optionsData = try? JSONEncoder().encode(options)
        self.isLiveContainer = isLiveContainer
        self.installedAt = .now
        self.refreshedAt = .now
        self.expirationDate = expirationDate
    }

    var method: SigningMethodKind { SigningMethodKind(rawValue: methodRaw) ?? .identity }
    var options: SignOptions {
        optionsData.flatMap { try? JSONDecoder().decode(SignOptions.self, from: $0) } ?? SignOptions()
    }
    var daysLeft: Int {
        max(0, Calendar.current.dateComponents([.day], from: .now, to: expirationDate).day ?? 0)
    }
    var isExpired: Bool { expirationDate < .now }
    var iconURL: URL? {
        sourceAppID.map { Paths.library.appendingPathComponent($0.uuidString).appendingPathComponent("icon.png") }
    }
}

enum SigningMethodKind: String, Codable {
    /// Zertifikat und Profil kommen über die Apple-ID (isideload).
    case account
    /// Importierte oder per CSR erstellte Identität plus passendes Profil (zsign).
    case identity
}

/// Eine App-Quelle im AltStore-Quellenformat (JSON-URL).
@Model
final class AppSource {
    @Attribute(.unique) var id: UUID
    var name: String
    var urlString: String
    var addedAt: Date

    init(name: String, urlString: String) {
        self.id = UUID()
        self.name = name
        self.urlString = urlString
        self.addedAt = .now
    }

    var url: URL? { URL(string: urlString) }
}

enum ProfileKind: String {
    case development, adHoc, enterprise, appStore

    var label: String {
        switch self {
        case .development: return "Development"
        case .adHoc: return "Ad Hoc"
        case .enterprise: return "Enterprise"
        case .appStore: return "App Store"
        }
    }
}

/// Optionen für einen Signiervorgang. Leere Strings bedeuten „Original beibehalten“.
struct SignOptions: Codable, Equatable {
    var displayName = ""
    var bundleID = ""
    var version = ""
    var minimumOSVersion = ""
    var removePlugIns = false
    var removeWatchApp = true
    var removeSupportedDevices = true
    var removeURLSchemes = false
    var enableFileSharing = false
    var excludeProvisioningProfile = false
    var installAfterSigning = true
    /// Apple-Account: Berechtigung für mehr Arbeitsspeicher anfragen („+RAM“).
    var increasedMemoryLimit = false
    /// Apple-Account: Erweiterungen bekommen eigene App-IDs. Aus: sie teilen das Profil der Haupt-App.
    var registerExtensions = true

    private static let defaultsKey = "sign.defaultOptions"

    init() {}

    // Eigene Dekodierung, damit ältere gespeicherte Voreinstellungen ohne neue Felder lesbar bleiben.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SignOptions()
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? fallback.displayName
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? fallback.bundleID
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? fallback.version
        minimumOSVersion = try c.decodeIfPresent(String.self, forKey: .minimumOSVersion) ?? fallback.minimumOSVersion
        removePlugIns = try c.decodeIfPresent(Bool.self, forKey: .removePlugIns) ?? fallback.removePlugIns
        removeWatchApp = try c.decodeIfPresent(Bool.self, forKey: .removeWatchApp) ?? fallback.removeWatchApp
        removeSupportedDevices = try c.decodeIfPresent(Bool.self, forKey: .removeSupportedDevices) ?? fallback.removeSupportedDevices
        removeURLSchemes = try c.decodeIfPresent(Bool.self, forKey: .removeURLSchemes) ?? fallback.removeURLSchemes
        enableFileSharing = try c.decodeIfPresent(Bool.self, forKey: .enableFileSharing) ?? fallback.enableFileSharing
        excludeProvisioningProfile = try c.decodeIfPresent(Bool.self, forKey: .excludeProvisioningProfile) ?? fallback.excludeProvisioningProfile
        installAfterSigning = try c.decodeIfPresent(Bool.self, forKey: .installAfterSigning) ?? fallback.installAfterSigning
        increasedMemoryLimit = try c.decodeIfPresent(Bool.self, forKey: .increasedMemoryLimit) ?? fallback.increasedMemoryLimit
        registerExtensions = try c.decodeIfPresent(Bool.self, forKey: .registerExtensions) ?? fallback.registerExtensions
    }

    /// Gespeicherte Voreinstellungen; Name, Bundle-ID und Version sind nie Teil davon.
    static func loadDefaults() -> SignOptions {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let options = try? JSONDecoder().decode(SignOptions.self, from: data) else {
            return SignOptions()
        }
        return options
    }

    func saveAsDefaults() {
        var copy = self
        copy.displayName = ""
        copy.bundleID = ""
        copy.version = ""
        if let data = try? JSONEncoder().encode(copy) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
