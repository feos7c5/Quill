import Foundation
import Observation
import SwiftData

/// Womit signiert wird.
enum SigningMethod {
    /// Zertifikat und Profil über die Apple-ID.
    case account
    /// Eigene Identität; `profile == nil` wählt automatisch das beste passende Profil.
    case identity(SigningIdentity, profile: ProfileRecord?)
}

struct SigningInput {
    var source: LibraryApp
    var options: SignOptions
    var method: SigningMethod
    var libraries: [URL] = []
    var iconData: Data?
    var entitlementsURL: URL?
    var install = true
}

struct SigningOutcome {
    let signed: LibraryApp
    let installed: InstalledApp?
}

/// Ein Signiervorgang von der unsignierten IPA bis zur installierten App.
@MainActor
@Observable
final class SigningPipeline {
    static let liveContainerBundleID = "com.kdt.livecontainer"

    private(set) var isRunning = false
    private(set) var progress: Double = 0
    private(set) var status = ""
    private(set) var log: [String] = []
    private(set) var failed = false

    @ObservationIgnored private let device: DeviceLink
    @ObservationIgnored private let account: AppleAccountService
    @ObservationIgnored private let ota: InstallService

    init(device: DeviceLink, account: AppleAccountService, ota: InstallService) {
        self.device = device
        self.account = account
        self.ota = ota
    }

    /// Bevorzugter Weg: Apple-Account, wenn angemeldet; sonst die neueste gültige Identität.
    func defaultMethod(context: ModelContext) -> SigningMethod? {
        if account.isReady { return .account }
        let identities = (try? context.fetch(FetchDescriptor<SigningIdentity>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)]))) ?? []
        return identities.first { !$0.isExpired }.map { .identity($0, profile: nil) }
    }

    // MARK: - Ablauf

    @discardableResult
    func run(_ input: SigningInput, context: ModelContext) async throws -> SigningOutcome {
        guard !isRunning else { throw AppError("Es läuft bereits ein Signiervorgang.") }
        isRunning = true
        failed = false
        progress = 0
        log = []
        defer { isRunning = false }
        do {
            return try await perform(input, context: context)
        } catch {
            failed = true
            status = "Fehlgeschlagen: \(error.localizedDescription)"
            log.append(status)
            throw error
        }
    }

    private func perform(_ input: SigningInput, context: ModelContext) async throws -> SigningOutcome {
        let logger: SigningService.Log = { [weak self] line in Task { @MainActor in self?.append(line) } }
        let isLiveContainer = input.source.bundleID == Self.liveContainerBundleID

        step(0.05, "Bereite App vor …")
        let prepared = try await SigningService.prepare(
            PrepareRequest(ipaURL: input.source.ipaURL, options: input.options, libraries: input.libraries, iconData: input.iconData),
            log: logger
        )
        defer { prepared.cleanup() }

        let signedIPA: URL
        let installTarget: URL
        let expiration: Date
        let teamID: String
        let bundleID: String
        let certificateName: String
        let identityID: UUID?

        switch input.method {
        case .account:
            guard account.isReady else {
                throw AppError("Nicht mit der Apple-ID angemeldet oder kein Team gewählt.")
            }
            guard let udid = device.udid else {
                throw AppError("Quill kennt die UDID dieses iPhones noch nicht. Über „Wireless Pair“ koppeln oder die UDID unter „Detect“ von Hand eintragen.")
            }
            step(0.15, "Registriere Gerät …")
            try await account.registerDevice(udid: udid, name: device.deviceName)
            step(0.2, "Signiere mit Apple-Account …")
            let result = try await account.sign(appURL: prepared.appURL, options: input.options) { [weak self] fraction, message in
                Task { @MainActor in self?.step(0.2 + 0.4 * fraction, message) }
            }
            let signedApp = URL(fileURLWithPath: result.appPath)
            let profile = try ProvisioningProfile(url: signedApp.appendingPathComponent("embedded.mobileprovision"))
            expiration = profile.expirationDate
            teamID = account.team?.id ?? profile.teamID
            bundleID = result.bundleId ?? prepared.bundleID
            certificateName = "Apple-Account (\(account.team?.displayName ?? teamID))"
            identityID = nil
            signedIPA = try await SigningService.packInBackground(signedApp, log: logger)
            // Ordner statt IPA installieren: idevice installiert Ordner als Upgrade, die Daten bleiben.
            installTarget = signedApp

        case .identity(let identity, let chosenProfile):
            let profiles = (try? context.fetch(FetchDescriptor<ProfileRecord>())) ?? []
            guard let profile = chosenProfile ?? IdentityStore.bestProfile(
                for: identity, bundleID: prepared.bundleID, udid: device.udid, in: profiles
            ) else {
                throw AppError("Kein gültiges Profil für „\(prepared.bundleID)“ zu diesem Zertifikat gefunden. Passendes .mobileprovision importieren oder die Bundle-ID anpassen.")
            }
            var entitlements = input.entitlementsURL
            if isLiveContainer, entitlements == nil {
                entitlements = try Self.liveContainerEntitlements(profile: profile)
            }
            step(0.2, "Signiere mit „\(identity.name)“ …")
            signedIPA = try await SigningService.signWithIdentity(
                prepared, p12URL: identity.p12URL, password: identity.password, profileURL: profile.fileURL,
                entitlementsURL: entitlements, removeProvision: input.options.excludeProvisioningProfile, log: logger
            )
            expiration = min(profile.expirationDate, identity.expirationDate)
            teamID = profile.teamID
            bundleID = prepared.bundleID
            certificateName = identity.name
            identityID = identity.id
            installTarget = signedIPA
        }

        step(0.62, "Lege signierte App ab …")
        let signed = try await AppLibrary.importIPA(from: signedIPA, signed: true, certificateName: certificateName,
                                                   move: true, context: context)
        removeOlderSignedCopies(of: signed, context: context)
        guard input.install else {
            step(1, "Signiert.")
            return SigningOutcome(signed: signed, installed: nil)
        }

        if device.isPaired {
            try await device.install(installTarget) { [weak self] fraction, message in
                Task { @MainActor in self?.step(0.65 + 0.35 * fraction, message) }
            }
        } else if ota.isConfigured {
            // Ohne Kopplung über itms-services. Klappt, wenn dieses iPhone im Profil registriert ist;
            // beim bezahlten Account erledigt das Quill selbst über die UDID.
            step(0.9, "Übergebe an iOS …")
            try ota.install(ipaURL: signed.ipaURL, bundleID: bundleID, version: signed.version, title: signed.name)
        } else {
            throw AppError("Zum Installieren entweder über „Wireless Pair“ koppeln oder unter Einstellungen → „Installation ohne Kopplung“ einrichten. Die signierte IPA liegt in der Bibliothek.")
        }

        let installed = try record(
            name: signed.name, bundleID: bundleID, originalBundleID: input.source.bundleID, version: signed.version,
            teamID: teamID, method: input.method, identityID: identityID, source: input.source,
            options: input.options, isLiveContainer: isLiveContainer, expiration: expiration, context: context
        )
        RefreshService.scheduleReminder(for: installed)
        WidgetPublisher.publish()
        step(1, "Installiert.")
        return SigningOutcome(signed: signed, installed: installed)
    }

    /// Signiert eine installierte App neu und installiert sie als Upgrade (Daten bleiben).
    /// `interactive == false` für Kurzbefehle und Hintergrund: keine 2FA-Dialoge.
    func refresh(_ app: InstalledApp, context: ModelContext, interactive: Bool = true) async throws {
        guard let sourceID = app.sourceAppID,
              let source = try context.fetch(FetchDescriptor<LibraryApp>(predicate: #Predicate { $0.id == sourceID })).first else {
            throw AppError("Die ursprüngliche IPA von „\(app.name)“ ist nicht mehr in der Bibliothek. Bitte erneut importieren und signieren.")
        }
        let method: SigningMethod
        switch app.method {
        case .account:
            await account.restoreIfPossible(interactive: interactive)
            guard account.isReady else {
                throw AppError(account.lastError ?? "Für den Refresh bitte mit der Apple-ID anmelden.")
            }
            method = .account
        case .identity:
            guard let identityID = app.identityID,
                  let identity = try context.fetch(FetchDescriptor<SigningIdentity>(predicate: #Predicate { $0.id == identityID })).first else {
                throw AppError("Das Zertifikat, mit dem „\(app.name)“ signiert wurde, ist nicht mehr vorhanden.")
            }
            method = .identity(identity, profile: nil)
        }
        try await run(SigningInput(source: source, options: app.options, method: method), context: context)
    }

    // MARK: - Hilfen

    /// Behält pro Bundle-ID nur die neueste signierte IPA; sonst wächst die Bibliothek mit jedem Refresh.
    private func removeOlderSignedCopies(of newest: LibraryApp, context: ModelContext) {
        let bundleID = newest.bundleID
        let newestID = newest.id
        let older = (try? context.fetch(FetchDescriptor<LibraryApp>(predicate: #Predicate {
            $0.isSigned && $0.bundleID == bundleID && $0.id != newestID
        }))) ?? []
        for app in older { AppLibrary.delete(app, context: context) }
    }

    private func step(_ fraction: Double, _ message: String) {
        progress = max(progress, min(1, fraction))
        if !message.isEmpty, message != status {
            status = message
            log.append(message)
        }
    }

    private func append(_ line: String) {
        log.append(line)
    }

    private func record(name: String, bundleID: String, originalBundleID: String, version: String, teamID: String,
                        method: SigningMethod, identityID: UUID?, source: LibraryApp, options: SignOptions,
                        isLiveContainer: Bool, expiration: Date, context: ModelContext) throws -> InstalledApp {
        let kind: SigningMethodKind
        switch method {
        case .account: kind = .account
        case .identity: kind = .identity
        }
        let existing = try context.fetch(FetchDescriptor<InstalledApp>(predicate: #Predicate { $0.bundleID == bundleID })).first
        let app: InstalledApp
        if let existing {
            app = existing
            app.name = name
            app.version = version
            app.teamID = teamID
            app.methodRaw = kind.rawValue
            app.identityID = identityID
            app.sourceAppID = source.id
            app.optionsData = try? JSONEncoder().encode(options)
            app.refreshedAt = .now
            app.expirationDate = expiration
        } else {
            app = InstalledApp(name: name, bundleID: bundleID, originalBundleID: originalBundleID, version: version,
                               teamID: teamID, method: kind, identityID: identityID, sourceAppID: source.id,
                               options: options, isLiveContainer: isLiveContainer, expirationDate: expiration)
            context.insert(app)
        }
        try context.save()
        return app
    }

    /// Entitlements für LiveContainer beim Signieren mit eigener Identität: Profil-Entitlements plus
    /// die Schlüsselbund-Gruppen, die LiveContainer für seine Container braucht.
    static func liveContainerEntitlements(profile: ProfileRecord) throws -> URL {
        let parsed = try ProvisioningProfile(url: profile.fileURL)
        var entitlements = parsed.entitlements
        let team = parsed.teamID
        var groups = ["\(team).com.kdt.livecontainer.shared"]
        groups += (1..<128).map { "\(team).com.kdt.livecontainer.shared.\($0)" }
        entitlements["keychain-access-groups"] = groups
        let data = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        let url = try Paths.workDirectory("entitlements").appendingPathComponent("LiveContainer.entitlements")
        try data.write(to: url)
        return url
    }
}
