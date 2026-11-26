import dnssd
import Foundation
import Network

/// Meldet den Kopplungsdienst direkt bei mDNSResponder an, wie Husk (`JITPairing.swift`).
/// Anders als das veraltete `NetService` meldet dieser Weg eine fehlende Freigabe
/// „Lokales Netzwerk“ zuverlässig als `kDNSServiceErr_PolicyDenied`.
@MainActor
final class BonjourAdvertiser {
    /// Ergebnis der Anmeldung: Fehlercode (0 = angemeldet) und der tatsächlich registrierte Name.
    static var onResult: ((DNSServiceErrorType, String?) -> Void)?

    private var ref: DNSServiceRef?

    /// Gibt einen sofortigen Fehler zurück; das endgültige Ergebnis kommt über `onResult`.
    func publish(name: String, type: String, port: UInt16, txt: [String: String], interfaceIndex: UInt32 = 0) -> DNSServiceErrorType {
        stop()
        // TXT-Record: je Eintrag ein Längenbyte und „key=value“.
        var record = Data()
        for (key, value) in txt.sorted(by: { $0.key < $1.key }) {
            let entry = Data("\(key)=\(value)".utf8).prefix(255)
            record.append(UInt8(entry.count))
            record.append(entry)
        }
        let serviceType = type.hasSuffix(".") ? String(type.dropLast()) : type
        var newRef: DNSServiceRef?
        let error = record.withUnsafeBytes { raw in
            DNSServiceRegister(&newRef, 0, interfaceIndex, name, serviceType, nil, nil, port.bigEndian,
                               UInt16(raw.count), raw.baseAddress, { _, _, error, name, _, _, _ in
                let registered = name.map { String(cString: $0) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { BonjourAdvertiser.onResult?(error, registered) }
                }
            }, nil)
        }
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let newRef else { return error }
        DNSServiceSetDispatchQueue(newRef, .main)
        ref = newRef
        return error
    }

    func stop() {
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
    }

    static func isPolicyDenied(_ error: DNSServiceErrorType) -> Bool {
        error == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
    }
}

/// Prüft, ob Quill seinen eigenen Kopplungsdienst so sieht, wie die Einstellungen ihn suchen.
/// Die Suche löst außerdem die Abfrage „Lokales Netzwerk“ aus, falls iOS sie noch nicht gestellt hat.
enum LocalNetworkProbe {
    enum Outcome: Equatable {
        case visible
        case denied
        case notFound(String)
    }

    static func check(type: String, name: String, seconds: Int) async -> Outcome {
        let serviceType = type.hasSuffix(".") ? String(type.dropLast()) : type
        return await withCheckedContinuation { continuation in
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: "local."), using: .tcp)
            let once = OnceFlag()
            let finish: @Sendable (Outcome) -> Void = { outcome in
                guard once.set() else { return }
                browser.cancel()
                continuation.resume(returning: outcome)
            }
            browser.browseResultsChangedHandler = { results, _ in
                let found = results.contains { result in
                    if case .service(let service, _, _, _) = result.endpoint { return service == name }
                    return false
                }
                if found { finish(.visible) }
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .waiting(let error), .failed(let error):
                    if case .dns(let code) = error, BonjourAdvertiser.isPolicyDeniedCode(code) {
                        finish(.denied)
                    } else if case .failed = state {
                        finish(.notFound("\(error)"))
                    }
                default:
                    break
                }
            }
            browser.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) {
                finish(.notFound("not found within \(seconds) seconds"))
            }
        }
    }
}

/// Beobachtet laufend, ob WLAN da ist und ob ein VPN (LocalDevVPN) verbunden ist.
@MainActor
@Observable
final class NetworkState {
    static let shared = NetworkState()

    private(set) var vpnActive = false
    private(set) var wifi = false

    @ObservationIgnored private let monitor = NWPathMonitor()

    var summary: String { "\(wifi ? "Wi-Fi" : "no Wi-Fi") · \(vpnActive ? "VPN connected" : "no VPN")" }

    private init() {
        monitor.pathUpdateHandler = { path in
            // LocalDevVPN erscheint als „utun“-Schnittstelle.
            let vpn = path.availableInterfaces.contains { $0.name.hasPrefix("utun") || $0.name.hasPrefix("ipsec") }
            let wifi = path.usesInterfaceType(.wifi) || path.availableInterfaces.contains { $0.type == .wifi }
            Task { @MainActor in
                NetworkState.shared.vpnActive = vpn
                NetworkState.shared.wifi = wifi
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }
}

extension BonjourAdvertiser {
    nonisolated static func isPolicyDeniedCode(_ code: DNSServiceErrorType) -> Bool {
        code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
    }
}

/// Lässt genau einen Aufruf durch (für Continuations mit mehreren möglichen Enden).
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func set() -> Bool {
        lock.withLock {
            if fired { return false }
            fired = true
            return true
        }
    }
}
