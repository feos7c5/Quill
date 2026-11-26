import Foundation
import Observation
import QuillCore
import UIKit
import UserNotifications

/// Verbindung zu den Gerätediensten dieses iPhones (Remote Pairing über LocalDevVPN).
@MainActor
@Observable
final class DeviceLink {
    enum State: Equatable {
        case unpaired
        case checking
        case ready
        case unreachable(String)
    }

    static let addressKey = "device.address"
    static let defaultAddress = "10.7.0.1:49152"
    private static let udidKey = "device.udid"
    static let manualUDIDKey = "device.manualUDID"
    private static let nameKey = "device.name"

    private(set) var state: State = .unpaired
    private(set) var info: DeviceInfo?
    private(set) var lastChecked: Date?
    /// Beobachtet, damit die Anzeige nach dem Eintragen sofort aktualisiert.
    private(set) var manualUDID: String? = UserDefaults.standard.string(forKey: DeviceLink.manualUDIDKey)

    init() {
        state = isPaired ? .unreachable(String(localized: "Noch nicht geprüft.")) : .unpaired
    }

    var isPaired: Bool { FileManager.default.fileExists(atPath: Paths.pairingFile.path) }
    var isReady: Bool { state == .ready }

    /// UDID aus der letzten Prüfung, der Kopplung oder von Hand eingetragen.
    var udid: String? {
        info?.udid ?? UserDefaults.standard.string(forKey: Self.udidKey) ?? manualUDID
    }

    /// Von Hand eingetragene UDID, z. B. für einen bezahlten Account ohne Kopplung.
    func setManualUDID(_ value: String?) throws {
        guard let raw = value?.trimmed, !raw.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.manualUDIDKey)
            manualUDID = nil
            return
        }
        let udid = raw.uppercased()
        // iPhone-UDIDs seit 2018: 8 Hex, Bindestrich, 16 Hex. Ältere: 40 Hex.
        let modern = udid.range(of: #"^[0-9A-F]{8}-[0-9A-F]{16}$"#, options: .regularExpression) != nil
        let legacy = udid.range(of: #"^[0-9A-F]{40}$"#, options: .regularExpression) != nil
        guard modern || legacy else {
            throw AppError("Das ist keine gültige UDID (Format 00008130-001C…).")
        }
        UserDefaults.standard.set(udid, forKey: Self.manualUDIDKey)
        manualUDID = udid
    }
    var deviceName: String { info?.name ?? UserDefaults.standard.string(forKey: Self.nameKey) ?? UIDevice.current.name }
    var developerMode: Bool? { info?.developerMode }

    private var address: String {
        let value = (UserDefaults.standard.string(forKey: Self.addressKey) ?? "").trimmed
        return value.isEmpty ? Self.defaultAddress : value
    }

    // MARK: - Status

    func refresh() async {
        guard isPaired else {
            state = .unpaired
            info = nil
            return
        }
        state = .checking
        let path = Paths.pairingFile.path
        let address = address
        do {
            let info = try await Core.run(DeviceInfo.self) {
                path.withCString { p in address.withCString { a in sc_device_info(p, a) } }
            }
            self.info = info
            if let udid = info.udid { UserDefaults.standard.set(udid, forKey: Self.udidKey) }
            if let name = info.name { UserDefaults.standard.set(name, forKey: Self.nameKey) }
            state = .ready
        } catch {
            state = .unreachable(error.localizedDescription)
        }
        lastChecked = .now
    }

    /// Prüft die Verbindung, wenn sie nicht bereit ist, und wirft sonst einen verständlichen Fehler.
    func requireReady() async throws {
        if state != .ready { await refresh() }
        switch state {
        case .ready: return
        case .unpaired: throw AppError("Quill ist noch nicht gekoppelt. Unter „Koppeln ohne Computer“ koppeln.")
        case .unreachable(let reason): throw AppError(verbatim: reason)
        case .checking: throw AppError("Die Verbindung wird gerade geprüft.")
        }
    }

    // MARK: - Dienste

    func install(_ package: URL, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        try await requireReady()
        let path = Paths.pairingFile.path
        let address = address
        let reporter = CoreProgress(progress)
        try await Core.perform {
            withExtendedLifetime(reporter) {
                path.withCString { p in
                    address.withCString { a in
                        package.path.withCString { pkg in
                            sc_device_install(p, a, pkg, CoreProgress.callback, reporter.context)
                        }
                    }
                }
            }
        }
    }

    func uninstall(bundleID: String) async throws {
        try await requireReady()
        let path = Paths.pairingFile.path
        let address = address
        try await Core.perform {
            path.withCString { p in address.withCString { a in bundleID.withCString { b in sc_device_uninstall(p, a, b) } } }
        }
    }

    func installedApps() async throws -> [DeviceApp] {
        try await requireReady()
        let path = Paths.pairingFile.path
        let address = address
        return try await Core.run([DeviceApp].self) {
            path.withCString { p in address.withCString { a in sc_device_apps(p, a) } }
        }
    }

    // MARK: - Pairing-Datei

    /// Übernimmt eine Remote-Pairing-Datei (z. B. aus StikDebug oder SideStore).
    func importPairingFile(_ data: Data) throws {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AppError("Die Datei ist keine Pairing-Datei (.plist).")
        }
        if plist["HostCertificate"] != nil || plist["DeviceCertificate"] != nil {
            throw AppError("Das ist eine Lockdown-Pairing-Datei. Ab iOS 27 nutzt Quill nur Remote Pairing; bitte „Koppeln ohne Computer“ verwenden oder eine Remote-Pairing-Datei wählen.")
        }
        guard plist["identifier"] is String else {
            throw AppError("Die Datei ist keine Remote-Pairing-Datei.")
        }
        try Paths.writeProtected(data, to: Paths.pairingFile)
        info = nil
        state = .unreachable(String(localized: "Noch nicht geprüft."))
    }

    func didPair(udid: String, name: String?) {
        UserDefaults.standard.set(udid, forKey: Self.udidKey)
        if let name { UserDefaults.standard.set(name, forKey: Self.nameKey) }
        info = nil
        state = .unreachable(String(localized: "Noch nicht geprüft."))
    }

    func unpair() {
        try? FileManager.default.removeItem(at: Paths.pairingFile)
        UserDefaults.standard.removeObject(forKey: Self.udidKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        info = nil
        state = .unpaired
    }
}

/// Kopplung ab iOS 27: Quill erscheint in Einstellungen → Datenschutz & Sicherheit →
/// Entwicklermodus als Rechner; der Nutzer tippt dort den Code ein, den Quill anzeigt.
///
/// Ablauf wie bei Husk und StikPair: Der Kern öffnet einen TCP-Port, Quill meldet ihn per Bonjour
/// an, die Einstellungen verbinden sich, der Kern liefert den Code. Der Code erscheint im
/// schwebenden Fenster (Bild im Bild) und in der Live-Aktivität.
///
/// LocalDevVPN muss dabei getrennt sein: Solange es verbunden ist, lässt iOS Verbindungen auf dem
/// iPhone selbst nicht durch („Network is down“), und die Einstellungen erreichen Quill nie.
@MainActor
@Observable
final class PairingService {
    enum Phase: Equatable {
        case idle, listening, connected, pin(String), paired, failed(String), stopped
    }

    private(set) var phase: Phase = .idle
    private(set) var message = ""
    /// Die Freigabe „Lokales Netzwerk“ fehlt; die Ansicht bietet dann den Weg in die Einstellungen an.
    private(set) var needsLocalNetwork = false

    @ObservationIgnored private let advertiser = BonjourAdvertiser()
    @ObservationIgnored private var check: Task<Void, Never>?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var lastLoggedPhase: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored var onPaired: ((PairSnapshot.Peer) -> Void)?

    var isRunning: Bool {
        switch phase {
        case .listening, .connected, .pin: return true
        default: return false
        }
    }

    func start() {
        guard !isRunning else { return }
        guard !NetworkState.shared.vpnActive else {
            phase = .failed(String(localized: "LocalDevVPN ist verbunden. Zuerst in LocalDevVPN trennen."))
            return
        }
        // In eine temporäre Datei schreiben; erst bei Erfolg ersetzt sie eine vorhandene Kopplung.
        let pending = Paths.support.appendingPathComponent("pairing.pending.plist")
        try? FileManager.default.removeItem(at: pending)
        let hostName = String(localized: "Quill auf \(UIDevice.current.name)")
        let advert: PairAdvert
        do {
            advert = try hostName.withCString { name in
                try pending.path.withCString { path in
                    try Core.now(PairAdvert.self, sc_pair_start(name, path))
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        PairingLog.reset()
        PairingLog.write("Start, iOS \(UIDevice.current.systemVersion), port \(advert.port), \(NetworkState.shared.summary)")
        needsLocalNetwork = false
        phase = .listening
        message = String(localized: "Jetzt Einstellungen → Datenschutz & Sicherheit → Entwicklermodus öffnen und Quill auswählen. Der Code erscheint dann im schwebenden Fenster.")

        BonjourAdvertiser.onResult = { [weak self] error, name in
            guard let self, self.isRunning else { return }
            if error == 0 {
                PairingLog.write("Bonjour registered: \(name ?? advert.name)")
            } else if BonjourAdvertiser.isPolicyDenied(error) {
                self.fail(localNetwork: true)
            } else {
                PairingLog.write("Bonjour registration failed: \(error)")
                self.fail(String(localized: "Quill konnte sich nicht im lokalen Netzwerk anmelden. WLAN einschalten und erneut versuchen."))
            }
        }
        let error = advertiser.publish(name: advert.name, type: advert.serviceType, port: advert.port, txt: advert.txt)
        if error != 0 { BonjourAdvertiser.onResult?(error, nil) }

        // Prüfen, ob Quill so sichtbar ist, wie die Einstellungen suchen. Erkennt auch eine
        // verweigerte Freigabe „Lokales Netzwerk“.
        check = Task { [weak self] in
            let outcome = await LocalNetworkProbe.check(type: advert.serviceType, name: advert.name, seconds: 10)
            guard let self, !Task.isCancelled, self.isRunning else { return }
            switch outcome {
            case .visible: PairingLog.write("Quill is visible on the local network")
            case .denied: self.fail(localNetwork: true)
            case .notFound(let reason): PairingLog.write("Quill not found on the local network (\(reason))")
            }
        }

        KeepAlive.shared.begin()
        observeLifecycle()
        PairingActivityController.start()
        CodePictureInPicture.shared.prepare { [weak self] in
            // Fenster geschlossen, bevor die Kopplung fertig war: abbrechen.
            guard let self, self.isRunning else { return }
            PairingLog.write("Floating window closed by the user")
            self.cancel()
        }
        startPolling(pending: pending)
    }

    func cancel() {
        sc_pair_cancel()
    }

    private func fail(_ text: String = "", localNetwork: Bool = false) {
        if localNetwork {
            PairingLog.write("Local Network access denied")
            needsLocalNetwork = true
            phase = .failed(String(localized: "Quill hat keinen Zugriff auf das lokale Netzwerk. Unter Einstellungen → Apps → Quill „Lokales Netzwerk“ einschalten und erneut koppeln."))
        } else {
            phase = .failed(text)
        }
        cancel()
    }

    private func startPolling(pending: URL) {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let snapshot = try? Core.now(PairSnapshot.self, sc_pair_snapshot()) else { break }
                self.apply(snapshot, pending: pending)
                if !snapshot.running { break }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func apply(_ snapshot: PairSnapshot, pending: URL) {
        if snapshot.phase != lastLoggedPhase {
            lastLoggedPhase = snapshot.phase
            PairingLog.write("Phase \(snapshot.phase): \(snapshot.message)\(snapshot.detail.map { " · \($0)" } ?? "")")
        }
        if isRunning || snapshot.phase == "paired" {
            message = Core.localized(snapshot.message, detail: snapshot.detail)
        }
        switch snapshot.phase {
        case "listening":
            guard isRunning else { return }
            phase = .listening
            show(.waiting)
        case "connected":
            guard isRunning else { return }
            phase = .connected
            show(.connected)
        case "pin":
            guard isRunning, let pin = snapshot.pin else { return }
            phase = .pin(pin)
            show(.code(pin))
        case "paired":
            do {
                let data = try Data(contentsOf: pending)
                try Paths.writeProtected(data, to: Paths.pairingFile)
                try? FileManager.default.removeItem(at: pending)
                phase = .paired
                message = String(localized: "Gekoppelt. Jetzt LocalDevVPN verbinden, dann prüft Quill die Verbindung.")
                if let peer = snapshot.peer { onPaired?(peer) }
            } catch {
                phase = .failed(String(localized: "Die Pairing-Datei konnte nicht gespeichert werden: \(error.localizedDescription)"))
            }
            finish()
        case "error":
            if isRunning { phase = .failed(Core.localized(snapshot.message, detail: snapshot.detail)) }
            finish()
        case "stopped":
            // Eine bereits gemeldete Ursache (z. B. fehlendes „Lokales Netzwerk“) nicht überschreiben.
            if case .failed = phase {} else { phase = .stopped }
            finish()
        default:
            break
        }
    }

    private func show(_ content: CodePictureInPicture.Content) {
        CodePictureInPicture.shared.show(content)
        switch content {
        case .waiting: PairingActivityController.update(.waiting)
        case .connected: PairingActivityController.update(.connected)
        case .code(let pin): PairingActivityController.update(.code, code: pin)
        case .paired, .failed: break
        }
    }

    private func finish() {
        poller?.cancel()
        poller = nil
        check?.cancel()
        check = nil
        advertiser.stop()
        BonjourAdvertiser.onResult = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        lastLoggedPhase = nil
        let paired = phase == .paired
        PairingActivityController.end(paired ? .paired : .failed)
        // Wachhalten erst beenden, wenn das schwebende Fenster zu ist; sonst hält iOS Quill an,
        // bevor es das Fenster schließen kann.
        CodePictureInPicture.shared.finish(paired ? .paired : .failed) {
            KeepAlive.shared.end()
        }
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                PairingLog.write("Quill in background · keep-alive \(KeepAlive.shared.isPlaying ? "on" : "off") · \(NetworkState.shared.summary)")
            }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PairingLog.write("Quill back in foreground") }
        })
    }

    /// Wird LocalDevVPN während der Kopplung verbunden, kann sie nicht mehr gelingen.
    func vpnChanged(active: Bool) {
        guard active, isRunning else { return }
        PairingLog.write("LocalDevVPN connected during pairing")
        fail(String(localized: "LocalDevVPN wurde verbunden. Kopplung abgebrochen; erst nach dem Koppeln verbinden."))
    }
}
