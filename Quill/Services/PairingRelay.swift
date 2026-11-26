import Foundation
import Network

/// Nimmt die Verbindung der Einstellungen mit Apples Network-Framework an und reicht sie an den
/// Kopplungskern (Rust, 127.0.0.1) weiter.
///
/// Warum: `NWListener` meldet den Dienst selbst bei Bonjour an und läuft durch dieselben Regeln
/// für „Lokales Netzwerk“ und VPN wie Systemdienste. Jede eingehende Verbindung wird protokolliert,
/// so zeigt das Protokoll eindeutig, ob die Einstellungen Quill überhaupt erreichen.
final class PairingRelay: @unchecked Sendable {
    enum Event: Sendable {
        case ready(port: UInt16)
        case failed(NWError)
        case denied
    }

    private let queue = DispatchQueue(label: "quill.pairing.relay")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let corePort: UInt16
    private let log: @Sendable (String) -> Void

    init(corePort: UInt16, log: @escaping @Sendable (String) -> Void) {
        self.corePort = corePort
        self.log = log
    }

    func start(name: String, type: String, txt: [String: String], onEvent: @escaping @Sendable (Event) -> Void) {
        let parameters = NWParameters.tcp
        // Nie über einen VPN-Tunnel (LocalDevVPN ist ein „utun“ vom Typ .other) und nicht über Mobilfunk.
        parameters.prohibitedInterfaceTypes = [.other, .cellular]
        parameters.includePeerToPeer = false
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            log("Relay: listener could not be created: \(error)")
            onEvent(.failed(error as? NWError ?? .posix(.EINVAL)))
            return
        }
        var record = NWTXTRecord()
        for (key, value) in txt { record[key] = value }
        let serviceType = type.hasSuffix(".") ? String(type.dropLast()) : type
        listener.service = NWListener.Service(name: name, type: serviceType, domain: nil, txtRecord: record)
        listener.serviceRegistrationUpdateHandler = { [log] change in
            switch change {
            case .add(let endpoint): log("Relay: Bonjour registered \(endpoint)")
            case .remove(let endpoint): log("Relay: Bonjour removed \(endpoint)")
            @unknown default: break
            }
        }
        listener.stateUpdateHandler = { [log] state in
            switch state {
            case .ready:
                let port = listener.port?.rawValue ?? 0
                log("Relay: listening on port \(port)")
                onEvent(.ready(port: port))
            case .waiting(let error), .failed(let error):
                log("Relay: \(state) \(error)")
                if case .dns(let code) = error, BonjourAdvertiser.isPolicyDeniedCode(code) {
                    onEvent(.denied)
                } else if case .failed = state {
                    onEvent(.failed(error))
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.relay(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values { connection.cancel() }
            self.connections = [:]
        }
    }

    // MARK: - Weiterleiten

    private func relay(_ incoming: NWConnection) {
        log("Relay: incoming connection from \(incoming.endpoint)")
        let outgoing = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: corePort)!, using: .tcp)
        connections[ObjectIdentifier(incoming)] = incoming
        connections[ObjectIdentifier(outgoing)] = outgoing
        incoming.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.log("Relay: incoming connection failed: \(error)") }
            if case .cancelled = state { self?.forget(incoming) }
        }
        outgoing.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.pump(from: incoming, to: outgoing)
                self?.pump(from: outgoing, to: incoming)
            case .failed(let error):
                self?.log("Relay: connection to the pairing core failed: \(error)")
                incoming.cancel()
            case .cancelled:
                self?.forget(outgoing)
            default:
                break
            }
        }
        incoming.start(queue: queue)
        outgoing.start(queue: queue)
    }

    private func pump(from source: NWConnection, to target: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                target.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil {
                        source.cancel()
                        target.cancel()
                    } else if isComplete {
                        target.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                    } else {
                        self?.pump(from: source, to: target)
                    }
                })
            } else if isComplete || error != nil {
                target.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                source.cancel()
            } else {
                self?.pump(from: source, to: target)
            }
        }
    }

    private func forget(_ connection: NWConnection) {
        queue.async { self.connections[ObjectIdentifier(connection)] = nil }
    }

    /// Prüft den Weg der Einstellungen: Bonjour-Eintrag auflösen und verbinden. Kommt die Verbindung
    /// an, steht im Protokoll „Relay: incoming connection“.
    static func selfConnect(name: String, type: String, log: @escaping @Sendable (String) -> Void) async {
        let serviceType = type.hasSuffix(".") ? String(type.dropLast()) : type
        let endpoint = NWEndpoint.service(name: name, type: serviceType, domain: "local.", interface: nil)
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.other, .cellular]
        let connection = NWConnection(to: endpoint, using: parameters)
        let once = OnceFlag()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.set() else { return }
                    let remote = connection.currentPath?.remoteEndpoint.map { "\($0)" } ?? "?"
                    let interface = connection.currentPath?.availableInterfaces.first.map { $0.name } ?? "?"
                    log("Self-connect through Bonjour: reached \(remote) via \(interface)")
                    connection.cancel()
                    continuation.resume()
                case .waiting(let error), .failed(let error):
                    guard once.set() else { return }
                    log("Self-connect through Bonjour failed: \(error)")
                    connection.cancel()
                    continuation.resume()
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                guard once.set() else { return }
                log("Self-connect through Bonjour: no answer within 8 seconds")
                connection.cancel()
                continuation.resume()
            }
        }
    }
}
