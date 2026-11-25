import Foundation
import Observation
import QuillCore

/// Anmeldung mit der Apple-ID. Quill holt damit Zertifikat, App-IDs und Profile selbst.
///
/// Die Anmeldung läuft direkt gegen Apple. Zusätzlich braucht Apple Gerätekenndaten
/// („Anisette“), die eine App nicht selbst erzeugen kann; sie kommen von einem
/// Anisette-Server, dessen Adresse in den Einstellungen steht.
@MainActor
@Observable
final class AppleAccountService {
    struct TwoFactorRequest: Equatable {
        struct Number: Equatable, Identifiable {
            let id: UInt32
            let number: String
        }
        let sms: Bool
        let unknown: Bool
        let lastError: String?
        let numbers: [Number]
        let selectedNumberID: UInt32?
    }

    enum State: Equatable {
        case signedOut
        case signingIn
        case needsCode(TwoFactorRequest)
        case signedIn
    }

    static let emailKey = "account.email"
    static let rememberKey = "account.remember"
    static let teamKey = "account.team"
    static let anisetteKey = "account.anisetteURL"
    static let defaultAnisette = "https://ani.iloader.app"
    private static let passwordKey = "account-password"

    private(set) var state: State = .signedOut
    private(set) var status: AccountStatus?
    private(set) var lastError: String?

    var email: String? { status?.email ?? Self.savedEmail }

    /// E-Mail und „merken“ liegen auch im Schlüsselbund: Der übersteht eine Neuinstallation der IPA,
    /// UserDefaults nicht. Sonst müsste man sich nach jedem Update neu anmelden.
    private static var savedEmail: String? {
        UserDefaults.standard.string(forKey: emailKey) ?? Keychain.get(emailKey)
    }
    private static var savedRemember: Bool {
        UserDefaults.standard.bool(forKey: rememberKey) || Keychain.get(rememberKey) == "1"
    }
    var team: AccountTeam? { status?.team }
    var teams: [AccountTeam] { status?.teams ?? [] }
    var isSignedIn: Bool { state == .signedIn && status?.loggedIn == true }
    /// Angemeldet und Team gewählt: bereit zum Signieren.
    var isReady: Bool { isSignedIn && team != nil }
    var canRestore: Bool { Self.savedRemember && Keychain.get(Self.passwordKey) != nil }

    private var anisetteURL: String {
        let value = (UserDefaults.standard.string(forKey: Self.anisetteKey) ?? "").trimmed
        return value.isEmpty ? Self.defaultAnisette : value
    }

    // MARK: - Anmeldung

    /// `interactive == false` (Kurzbefehl, Hintergrund): Verlangt Apple einen Code, bricht Quill sofort ab,
    /// statt zehn Minuten auf eine Eingabe zu warten, die niemand machen kann.
    func signIn(email: String, password: String, remember: Bool, interactive: Bool = true) async {
        lastError = nil
        state = .signingIn
        let anisette = anisetteURL
        let bridge = TwoFactorBridge { [weak self] request in
            Task { @MainActor in
                guard let self else { return }
                if interactive {
                    self.state = .needsCode(request)
                } else {
                    self.abortSignIn()
                    self.lastError = String(localized: "Apple verlangt einen Bestätigungscode. Bitte Quill öffnen und anmelden.")
                }
            }
        }
        do {
            let status = try await Core.run(AccountStatus.self) {
                withExtendedLifetime(bridge) {
                    email.withCString { e in
                        password.withCString { p in
                            anisette.withCString { a in
                                sc_account_login(e, p, a, TwoFactorBridge.callback, bridge.context)
                            }
                        }
                    }
                }
            }
            UserDefaults.standard.set(email, forKey: Self.emailKey)
            UserDefaults.standard.set(remember, forKey: Self.rememberKey)
            Keychain.set(email, for: Self.emailKey)
            if remember {
                Keychain.set(password, for: Self.passwordKey)
                Keychain.set("1", for: Self.rememberKey)
            } else {
                Keychain.delete(Self.passwordKey)
                Keychain.delete(Self.rememberKey)
            }
            // Anisette-Zustand und Account-Schlüssel sichern: Nach einer Neuinstallation erkennt
            // Apple dasselbe „Gerät“ wieder und verlangt keinen neuen Bestätigungscode.
            CoreVault.backup()
            self.status = status
            state = .signedIn
            await restoreTeamChoice()
        } catch {
            // Eine Meldung aus dem Abbruch ohne Eingabe hat Vorrang vor der allgemeinen Fehlermeldung.
            if interactive || lastError == nil { lastError = error.localizedDescription }
            state = .signedOut
        }
    }

    /// Meldet mit gespeichertem Passwort an, z. B. beim App-Start oder vor einem Refresh.
    func restoreIfPossible(interactive: Bool = true) async {
        guard !isSignedIn, state != .signingIn, canRestore,
              let email = Self.savedEmail,
              let password = Keychain.get(Self.passwordKey) else { return }
        await signIn(email: email, password: password, remember: true, interactive: interactive)
    }

    func submitCode(_ code: String) { respond(["code": code]) }
    func sendSMS(to id: UInt32) { respond(["sms": id]) }
    func sendToDevices() { respond(["devices": true]) }
    func resendCode() { respond(["resend": true]) }

    func abortSignIn() {
        respond(["abort": true])
    }

    private func respond(_ answer: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: answer),
              let text = String(data: data, encoding: .utf8) else { return }
        _ = try? Core.now(Core.Ignored.self, text.withCString { sc_account_two_factor_respond($0) })
        state = .signingIn
    }

    // MARK: - Team

    func select(team: AccountTeam) async {
        do {
            status = try await Core.run(AccountStatus.self) { team.id.withCString { sc_account_select_team($0) } }
            UserDefaults.standard.set(team.id, forKey: Self.teamKey)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func restoreTeamChoice() async {
        guard team == nil, let saved = UserDefaults.standard.string(forKey: Self.teamKey),
              let match = teams.first(where: { $0.id == saved }) else { return }
        await select(team: match)
    }

    // MARK: - Abmelden

    /// `forget`: auch Passwort, Account-Schlüssel und Anisette-Zustand löschen.
    func signOut(forget: Bool) async {
        if forget {
            _ = try? await Core.run(Core.Ignored.self) { sc_account_forget() }
            Keychain.delete(Self.passwordKey)
            Keychain.delete(Self.emailKey)
            Keychain.delete(Self.rememberKey)
            CoreVault.clear()
            UserDefaults.standard.removeObject(forKey: Self.emailKey)
            UserDefaults.standard.removeObject(forKey: Self.teamKey)
            UserDefaults.standard.set(false, forKey: Self.rememberKey)
        } else {
            _ = try? await Core.run(Core.Ignored.self) { sc_account_logout() }
        }
        status = nil
        state = .signedOut
    }

    // MARK: - Entwicklerdienste

    func registerDevice(udid: String, name: String) async throws {
        try await Core.perform { udid.withCString { u in name.withCString { n in sc_account_register_device(u, n) } } }
    }

    func appIDQuota() async throws -> AppIDQuota {
        try await Core.run(AppIDQuota.self) { sc_account_app_ids() }
    }

    func certificates() async throws -> [AppleCertificate] {
        try await Core.run([AppleCertificate].self) { sc_account_certificates() }
    }

    func revoke(serial: String) async throws {
        try await Core.perform { serial.withCString { sc_account_revoke_certificate($0) } }
    }

    /// Signiert einen vorbereiteten `.app`-Ordner. Liefert den signierten Ordner.
    func sign(appURL: URL, options: SignOptions, progress: @escaping @Sendable (Double, String) -> Void) async throws -> AccountSignResult {
        let optionsJSON = """
        {"increased_memory_limit":\(options.increasedMemoryLimit),"register_extensions":\(options.registerExtensions)}
        """
        let reporter = CoreProgress(progress)
        return try await Core.run(AccountSignResult.self) {
            withExtendedLifetime(reporter) {
                appURL.path.withCString { path in
                    optionsJSON.withCString { opts in
                        sc_account_sign(path, opts, CoreProgress.callback, reporter.context)
                    }
                }
            }
        }
    }

    /// Exportiert das Account-Zertifikat als .p12 mit dem angegebenen Passwort.
    func exportP12(password: String) async throws -> (data: Data, serial: String) {
        let result = try await Core.run(ExportedP12.self) { password.withCString { sc_account_export_p12($0) } }
        guard let data = Data(base64Encoded: result.p12) else { throw AppError("Ungültige .p12 vom Kern.") }
        return (data, result.serial)
    }
}

/// Reicht die 2FA-Anfrage des Kerns an Swift weiter.
final class TwoFactorBridge: @unchecked Sendable {
    let handler: @Sendable (AppleAccountService.TwoFactorRequest) -> Void

    init(_ handler: @escaping @Sendable (AppleAccountService.TwoFactorRequest) -> Void) {
        self.handler = handler
    }

    var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private struct Payload: Decodable {
        struct Number: Decodable {
            let id: UInt32
            let number: String
        }
        let sms: Bool
        let unknown: Bool
        let lastError: String?
        let selectedNumberId: UInt32?
        let numbers: [Number]
    }

    static let callback: sc_two_factor_cb = { context, json in
        guard let context, let json else { return }
        let bridge = Unmanaged<TwoFactorBridge>.fromOpaque(context).takeUnretainedValue()
        let data = Data(String(cString: json).utf8)
        guard let payload = try? JSONDecoder.core.decode(Payload.self, from: data) else { return }
        bridge.handler(.init(
            sms: payload.sms,
            unknown: payload.unknown,
            lastError: payload.lastError,
            numbers: payload.numbers.map { .init(id: $0.id, number: $0.number) },
            selectedNumberID: payload.selectedNumberId
        ))
    }
}


/// Sichert die kleinen Anmeldedateien des Kerns (Anisette-Zustand, Account-Schlüssel) im Schlüsselbund
/// und stellt sie nach einer Neuinstallation wieder her. Der Schlüsselbund bleibt bei Neuinstallation
/// erhalten, der App-Ordner nicht.
enum CoreVault {
    private static let key = "core.vault"
    private static let folders = ["anisette", "account"]
    /// Schutz gegen Ausreißer: Der Schlüsselbund ist nicht für große Daten gedacht.
    private static let maxBytes = 256 * 1024

    static func backup() {
        var files: [String: String] = [:]
        var total = 0
        for folder in folders {
            let root = Paths.core.appendingPathComponent(folder, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let data = try? Data(contentsOf: url) else { continue }
                total += data.count
                guard total <= maxBytes else { return }
                let relative = folder + "/" + url.path.replacingOccurrences(of: root.path + "/", with: "")
                files[relative] = data.base64EncodedString()
            }
        }
        guard !files.isEmpty, let json = try? JSONEncoder().encode(files) else { return }
        Keychain.set(String(decoding: json, as: UTF8.self), for: key)
    }

    /// Vor dem Start des Kerns aufrufen. Überschreibt nichts, was schon da ist.
    static func restoreIfMissing() {
        guard let text = Keychain.get(key),
              let files = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) else { return }
        for (relative, base64) in files {
            guard !relative.contains(".."), let data = Data(base64Encoded: base64) else { continue }
            let url = Paths.core.appendingPathComponent(relative)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Paths.writeProtected(data, to: url)
        }
    }

    static func clear() { Keychain.delete(key) }
}
