import Foundation
import Observation
import UIKit

/// Liest die UDID ohne Kopplung und ohne Rechner über ein temporäres iOS-Profil.
///
/// Ablauf: Quill startet einen Server auf 127.0.0.1 und öffnet in Safari ein Profil vom Typ
/// „Profile Service“. Nach „Installieren“ in den Einstellungen schickt iOS die Geräteattribute
/// signiert per POST an Quill; Quill antwortet mit einer Weiterleitung auf eine lokale Seite,
/// die zurück zu Quill führt. Installiert wird dabei nichts dauerhaft.
@MainActor
@Observable
final class UDIDProfileService {
    enum Phase: Equatable {
        case idle
        case waiting
        case received(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    @ObservationIgnored private var server: HTTPServer?
    @ObservationIgnored private var background: BackgroundTime?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var keepingAlive = false
    @ObservationIgnored var onReceived: ((String) -> Void)?
    @ObservationIgnored private var lifecycle: [NSObjectProtocol] = []

    /// Bevorzugte Ports; ist einer belegt (z. B. von einer anderen App), nimmt Quill den nächsten.
    private nonisolated static let ports: [UInt16] = [8765, 8766, 8767, 8768]
    /// So lange wartet Quill auf die Antwort aus den Einstellungen.
    private static let waitSeconds = 300

    static var logURL: URL { UDIDLog.url }

    func start() {
        stop()
        UDIDLog.reset()
        UDIDLog.write("Start, iOS \(UIDevice.current.systemVersion)")
        let token = UUID().uuidString
        var started: (server: HTTPServer, port: UInt16)?
        for port in Self.ports {
            do {
                let base = "http://127.0.0.1:\(port)"
                let profile = try Self.profile(callbackURL: "\(base)/udid/\(token)")
                let server = HTTPServer(port: port, loopbackOnly: true,
                                        handler: Self.makeHandler(token: token, port: port, profile: profile) { [weak self] result in
                                            Task { @MainActor in self?.finish(result) }
                                        })
                server.onState = { state in UDIDLog.write("Server \(port): \(state)") }
                server.onTrace = { line in UDIDLog.write(line) }
                try server.start()
                started = (server, port)
                break
            } catch {
                UDIDLog.write("Port \(port) nicht nutzbar: \(error.localizedDescription)")
            }
        }
        guard let started else {
            phase = .failed(String(localized: "Der lokale Server ließ sich nicht starten."))
            return
        }
        server = started.server
        phase = .waiting
        // Während der Nutzer in Safari und den Einstellungen ist, liegt Quill im Hintergrund.
        background = BackgroundTime(name: "Quill-UDID")
        KeepAlive.shared.begin()
        keepingAlive = true
        UDIDLog.write("Wachhalten: \(KeepAlive.shared.isPlaying ? "aktiv" : "NICHT aktiv")")
        observeLifecycle()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.waitSeconds))
            guard !Task.isCancelled else { return }
            UDIDLog.write("Zeitüberschreitung ohne Antwort von iOS")
            self?.finish(.failure(AppError("Keine Antwort aus den Einstellungen. Erneut versuchen oder die UDID von Hand eintragen.")))
        }
        // Kurz warten, bis der Server bereit ist, sonst lädt Safari ins Leere.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            await UIApplication.shared.open(URL(string: "http://127.0.0.1:\(started.port)/udid.mobileconfig")!)
        }
    }

    /// Bricht das Warten ab, ohne einen Fehler zu melden.
    func cancel() {
        UDIDLog.write("Vom Nutzer abgebrochen")
        stop()
        phase = .idle
    }

    /// Protokolliert, ob Quill im Hintergrund wach bleibt, solange Safari und Einstellungen offen sind.
    private func observeLifecycle() {
        let center = NotificationCenter.default
        let events: [(Notification.Name, String)] = [
            (UIApplication.didEnterBackgroundNotification, "Quill im Hintergrund"),
            (UIApplication.willEnterForegroundNotification, "Quill wieder im Vordergrund"),
        ]
        lifecycle = events.map { name, text in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let rest = UIApplication.shared.backgroundTimeRemaining
                    let restText = rest > 10_000 ? "unbegrenzt" : "\(Int(rest)) s"
                    UDIDLog.write("\(text) · Wachhalten \(KeepAlive.shared.isPlaying ? "aktiv" : "NICHT aktiv") · Restzeit \(restText)")
                }
            }
        }
    }

    func stop() {
        lifecycle.forEach(NotificationCenter.default.removeObserver)
        lifecycle = []
        server?.stop()
        server = nil
        timeout?.cancel()
        timeout = nil
        background?.end()
        background = nil
        if keepingAlive {
            KeepAlive.shared.end()
            keepingAlive = false
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard phase == .waiting else { return }
        switch result {
        case .success(let udid):
            UDIDLog.write("UDID erkannt: \(udid)")
            phase = .received(udid)
            onReceived?(udid)
        case .failure(let error):
            UDIDLog.write("Fehler: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
        // Weiterlaufen lassen, bis Safari die Abschlussseite geladen hat.
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    // MARK: - Server

    /// Läuft auf der Server-Queue, deshalb nicht an den Main-Actor gebunden.
    private nonisolated static func makeHandler(token: String, port: UInt16, profile: Data,
                                                result: @escaping @Sendable (Result<String, Error>) -> Void) -> HTTPServer.Handler {
        return { request in
            let size = request.bodyFile.map { Paths.size(of: $0) } ?? 0
            UDIDLog.write("\(request.method) \(request.path) · \(request.headers["content-type"] ?? "-") · \(size) Bytes · \(request.headers["user-agent"] ?? "-")")
            let response = respond(to: request, token: token, port: port, profile: profile, result: result)
            UDIDLog.write("→ \(response.status)")
            return response
        }
    }

    private nonisolated static func respond(to request: HTTPRequest, token: String, port: UInt16, profile: Data,
                                            result: @Sendable (Result<String, Error>) -> Void) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/udid.mobileconfig"), ("HEAD", "/udid.mobileconfig"):
            return HTTPResponse(contentType: "application/x-apple-aspen-config", body: .data(profile))

        case ("POST", let path) where path.hasPrefix("/udid/"):
            if path != "/udid/\(token)" { UDIDLog.write("Hinweis: unerwarteter Pfad, Token passt nicht") }
            guard let file = request.bodyFile, let data = try? Data(contentsOf: file), let udid = extractUDID(from: data) else {
                result(.failure(AppError("iOS hat keine UDID geliefert.")))
                return .text("No UDID", status: 400)
            }
            result(.success(udid))
            // iOS erwartet eine Weiterleitung auf eine http(s)-Seite und öffnet sie in Safari.
            var response = HTTPResponse(status: 301)
            response.headers["Location"] = "http://127.0.0.1:\(port)/done?udid=\(udid)"
            return response

        case ("GET", "/done"):
            let udid = (request.query["udid"] ?? "").filter { $0.isHexDigit || $0 == "-" }
            let language = Bundle.main.preferredLocalizations.first ?? "en"
            let html = """
            <!doctype html><html lang="\(language)"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="color-scheme" content="light dark"><title>Quill</title>
            <style>body{font:-apple-system-body;font-family:-apple-system;text-align:center;padding:3rem 1.5rem}
            a{display:inline-block;margin-top:1.5rem;padding:.8rem 1.6rem;border-radius:999px;background:#3366f2;color:#fff;text-decoration:none;font-weight:600}
            code{font-size:.85rem;word-break:break-all}</style></head><body>
            <h2>\(String(localized: "UDID erkannt"))</h2><p><code>\(udid)</code></p>
            <a href="quill://udid?value=\(udid)">\(String(localized: "Zurück zu Quill"))</a>
            <script>location.href = "quill://udid?value=\(udid)";</script>
            </body></html>
            """
            return HTTPResponse(contentType: "text/html; charset=utf-8", body: .data(Data(html.utf8)))

        default:
            return .text("Not found", status: 404)
        }
    }

    /// Holt die UDID aus der CMS-signierten Antwort von iOS. Der Inhalt ist eine Property List,
    /// je nach iOS-Version als XML oder binär; als letzter Ausweg wird nach dem UDID-Muster gesucht.
    nonisolated static func extractUDID(from data: Data) -> String? {
        if let plist = try? ProvisioningProfile.embeddedPlist(in: data), let udid = plist["UDID"] as? String, !udid.isEmpty {
            UDIDLog.write("Antwort: XML-Property-List")
            return udid.uppercased()
        }
        if let content = derOctetString(startingWith: Data("bplist00".utf8), in: data),
           let plist = try? PropertyListSerialization.propertyList(from: content, format: nil) as? [String: Any],
           let udid = plist["UDID"] as? String, !udid.isEmpty {
            UDIDLog.write("Antwort: binäre Property List")
            return udid.uppercased()
        }
        let text = String(decoding: data, as: UTF8.self)
        for pattern in [#"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}"#, #"\b[0-9a-fA-F]{40}\b"#] {
            if let range = text.range(of: pattern, options: .regularExpression) {
                UDIDLog.write("Antwort: UDID über Muster gefunden")
                return String(text[range]).uppercased()
            }
        }
        UDIDLog.write("Antwort ohne erkennbare UDID, Anfang: \(data.prefix(48).map { String(format: "%02x", $0) }.joined())")
        return nil
    }

    /// Sucht in DER-Daten ein OCTET STRING, dessen Inhalt mit `prefix` beginnt, und liefert den Inhalt.
    nonisolated static func derOctetString(startingWith prefix: Data, in data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard let found = data.range(of: prefix) else { return nil }
        let start = found.lowerBound - data.startIndex
        // Kopf eines OCTET STRING: 0x04, dann Länge kurz (1 Byte) oder lang (0x81…0x84 + 1–4 Bytes).
        for headerLength in 2...6 {
            let tag = start - headerLength
            guard tag >= 0, bytes[tag] == 0x04 else { continue }
            let first = Int(bytes[tag + 1])
            var length = 0
            if headerLength == 2 {
                guard first < 0x80 else { continue }
                length = first
            } else {
                guard first == 0x80 + headerLength - 2 else { continue }
                for index in 0..<(headerLength - 2) { length = length << 8 | Int(bytes[tag + 2 + index]) }
            }
            guard length > 0, start + length <= bytes.count else { continue }
            return Data(bytes[start..<start + length])
        }
        return nil
    }

    /// Profil vom Typ „Profile Service“. Es wird nicht dauerhaft installiert; iOS liefert nur die
    /// angefragten Geräteattribute an `callbackURL`.
    private nonisolated static func profile(callbackURL: String) throws -> Data {
        let plist: [String: Any] = [
            "PayloadContent": [
                "URL": callbackURL,
                // DEVICE_NAME ist seit iOS 16 eingeschränkt und kann die Installation scheitern lassen.
                "DeviceAttributes": ["UDID", "PRODUCT", "VERSION", "SERIAL"],
            ],
            "PayloadOrganization": "Quill",
            "PayloadDisplayName": String(localized: "Quill – UDID ermitteln"),
            "PayloadDescription": String(localized: "Temporäres Profil: Liest einmalig die UDID dieses iPhones und gibt sie an Quill auf diesem Gerät. Es wird nichts dauerhaft installiert und nichts ins Internet gesendet."),
            "PayloadIdentifier": "app.quill.udid",
            "PayloadUUID": UUID().uuidString,
            "PayloadVersion": 1,
            "PayloadType": "Profile Service",
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}

/// Protokoll der UDID-Erkennung, damit sich Fehler auf dem Gerät nachvollziehen lassen.
enum UDIDLog {
    static let url = Paths.core.appendingPathComponent("udid.log")
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    static func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = Date.now.formatted(.iso8601.time(includingFractionalSeconds: true))
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
