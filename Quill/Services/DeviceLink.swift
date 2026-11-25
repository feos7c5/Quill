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
@MainActor
@Observable
final class PairingService: NSObject, NetServiceDelegate {
    enum Phase: Equatable {
        case idle, listening, connected, pin(String), paired, failed(String), stopped
    }

    private(set) var phase: Phase = .idle
    private(set) var message = ""
    /// Hinweis zur Restzeit im Hintergrund.
    private(set) var backgroundNote: String?

    @ObservationIgnored private var service: NetService?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var notifiedPIN: String?
    @ObservationIgnored private var keepingAlive = false
    @ObservationIgnored var onPaired: ((PairSnapshot.Peer) -> Void)?

    private static let pinNotification = "quill-pairing-pin"

    var isRunning: Bool {
        switch phase {
        case .listening, .connected, .pin: return true
        default: return false
        }
    }

    func start() {
        guard !isRunning else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // In eine temporäre Datei schreiben; erst bei Erfolg ersetzt sie eine vorhandene Kopplung.
        let pending = Paths.support.appendingPathComponent("pairing.pending.plist")
        try? FileManager.default.removeItem(at: pending)
        let hostName = String(localized: "Quill auf \(UIDevice.current.name)")
        do {
            let advert = try hostName.withCString { name in
                try pending.path.withCString { path in
                    try Core.now(PairAdvert.self, sc_pair_start(name, path))
                }
            }
            publish(advert)
            phase = .listening
            message = String(localized: "Jetzt Einstellungen → Datenschutz & Sicherheit → Entwicklermodus öffnen und Quill auswählen.")
            notifiedPIN = nil
            observeLifecycle()
            KeepAlive.shared.begin()
            keepingAlive = true
            startPolling(pending: pending)
        } catch {
            phase = .failed(error.localizedDescription)
            message = error.localizedDescription
        }
    }

    func cancel() {
        sc_pair_cancel()
    }

    private func publish(_ advert: PairAdvert) {
        let type = advert.serviceType.hasSuffix(".") ? String(advert.serviceType.dropLast()) : advert.serviceType
        let service = NetService(domain: "local.", type: type + ".", name: advert.name, port: Int32(advert.port))
        let txt = advert.txt.mapValues { Data($0.utf8) }
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.delegate = self
        service.publish()
        self.service = service
    }

    private func startPolling(pending: URL) {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let snapshot = try? Core.now(PairSnapshot.self, sc_pair_snapshot()) else { break }
                self.apply(snapshot, pending: pending)
                if !snapshot.running { break }
                self.updateBackgroundNote()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func apply(_ snapshot: PairSnapshot, pending: URL) {
        message = Core.localized(snapshot.message, detail: snapshot.detail)
        switch snapshot.phase {
        case "listening": phase = .listening
        case "connected": phase = .connected
        case "pin":
            if let pin = snapshot.pin {
                phase = .pin(pin)
                notify(pin: pin)
            }
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
            phase = .failed(Core.localized(snapshot.message, detail: snapshot.detail))
            finish()
        case "stopped":
            phase = .stopped
            finish()
        default:
            break
        }
    }

    private func notify(pin: String) {
        guard notifiedPIN != pin else { return }
        notifiedPIN = pin
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Quill-Kopplungscode")
        content.body = String(localized: "\(pin) in den Einstellungen eingeben.")
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: Self.pinNotification, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func finish() {
        poller?.cancel()
        poller = nil
        service?.stop()
        service = nil
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.pinNotification])
        center.removePendingNotificationRequests(withIdentifiers: [Self.pinNotification])
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        endBackgroundTask()
        backgroundNote = nil
        if keepingAlive {
            KeepAlive.shared.end()
            keepingAlive = false
        }
    }

    // MARK: - Hintergrund

    /// Während der Nutzer in den Einstellungen ist, liegt Quill im Hintergrund.
    /// Eine Hintergrund-Aufgabe hält den Port offen, aber nur begrenzt lange.
    private func observeLifecycle() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginBackgroundTask() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endBackgroundTask()
                self?.backgroundNote = nil
            }
        })
    }

    private func beginBackgroundTask() {
        guard isRunning, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Quill-Kopplung") { [weak self] in
            // Die stumme Wiedergabe (KeepAlive) hält Quill weiter wach; nur die Aufgabe sauber beenden.
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func updateBackgroundNote() {
        guard UIApplication.shared.applicationState == .background else { return }
        let seconds = UIApplication.shared.backgroundTimeRemaining
        if seconds < 10_000 {
            backgroundNote = String(localized: "Noch \(Int(seconds)) Sekunden Hintergrundzeit. Kopplung jetzt abschließen.")
        }
    }

    // MARK: - NetServiceDelegate

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        Task { @MainActor in
            self.phase = .failed(String(localized: "Bonjour-Veröffentlichung fehlgeschlagen. Quill braucht Zugriff auf das lokale Netzwerk (Einstellungen → Quill)."))
            self.cancel()
        }
    }
}
