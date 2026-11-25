import Foundation
import Observation
import UIKit

/// Liest die UDID ohne Kopplung und ohne Rechner über ein temporäres iOS-Profil.
///
/// Ablauf: Quill startet einen Server auf 127.0.0.1 und öffnet in Safari ein Profil vom Typ
/// „Profile Service“. Nach „Installieren“ in den Einstellungen schickt iOS die UDID signiert
/// per POST an Quill zurück; Quill antwortet mit einer Weiterleitung auf `quill://udid`,
/// die Quill wieder öffnet. Installiert wird dabei nichts dauerhaft.
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

    private nonisolated static let port: UInt16 = 8765
    /// So lange wartet Quill auf die Antwort aus den Einstellungen.
    private static let waitSeconds = 180

    func start() {
        stop()
        let token = UUID().uuidString
        let base = "http://127.0.0.1:\(Self.port)"
        do {
            let profile = try Self.profile(callbackURL: "\(base)/udid/\(token)")
            let server = HTTPServer(port: Self.port, loopbackOnly: true,
                                    handler: Self.makeHandler(token: token, profile: profile) { [weak self] result in
                                        Task { @MainActor in self?.finish(result) }
                                    })
            try server.start()
            self.server = server
        } catch {
            phase = .failed("Der lokale Server ließ sich nicht starten: \(error.localizedDescription)")
            return
        }
        phase = .waiting
        // Während der Nutzer in Safari und den Einstellungen ist, liegt Quill im Hintergrund.
        background = BackgroundTime(name: "Quill-UDID")
        if !keepingAlive {
            KeepAlive.shared.begin()
            keepingAlive = true
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.waitSeconds))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(AppError("Keine Antwort aus den Einstellungen. Erneut versuchen oder die UDID von Hand eintragen.")))
        }
        UIApplication.shared.open(URL(string: "\(base)/udid.mobileconfig")!)
    }

    func stop() {
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
            phase = .received(udid)
            onReceived?(udid)
        case .failure(let error):
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
    private nonisolated static func makeHandler(token: String, profile: Data,
                                                result: @escaping @Sendable (Result<String, Error>) -> Void) -> HTTPServer.Handler {
        let port = Self.port
        return { request in
            switch (request.method, request.path) {
            case ("GET", "/udid.mobileconfig"):
                return HTTPResponse(contentType: "application/x-apple-aspen-config", body: .data(profile))

            case ("POST", "/udid/\(token)"):
                // iOS schickt eine CMS-signierte Property List; die XML steckt im Klartext darin.
                guard let file = request.bodyFile, let data = try? Data(contentsOf: file),
                      let plist = try? ProvisioningProfile.embeddedPlist(in: data),
                      let udid = (plist["UDID"] as? String)?.uppercased(), !udid.isEmpty else {
                    result(.failure(AppError("iOS hat keine UDID geliefert.")))
                    return .text("Keine UDID", status: 400)
                }
                result(.success(udid))
                // iOS erwartet hier eine Weiterleitung auf eine http(s)-Seite und öffnet sie in Safari.
                // Ein eigenes URL-Schema an dieser Stelle lässt die Installation scheitern.
                var response = HTTPResponse(status: 301)
                response.headers["Location"] = "http://127.0.0.1:\(port)/done?udid=\(udid)"
                return response

            case ("GET", "/done"):
                let udid = (request.query["udid"] ?? "").filter { $0.isHexDigit || $0 == "-" }
                let html = """
                <!doctype html><html lang="de"><head><meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <meta name="color-scheme" content="light dark"><title>Quill</title>
                <style>body{font:-apple-system-body;font-family:-apple-system;text-align:center;padding:3rem 1.5rem}
                a{display:inline-block;margin-top:1.5rem;padding:.8rem 1.6rem;border-radius:999px;background:#3366f2;color:#fff;text-decoration:none;font-weight:600}
                code{font-size:.85rem;word-break:break-all}</style></head><body>
                <h2>UDID erkannt</h2><p><code>\(udid)</code></p>
                <a href="quill://udid?value=\(udid)">Zurück zu Quill</a>
                <script>location.href = "quill://udid?value=\(udid)";</script>
                </body></html>
                """
                return HTTPResponse(contentType: "text/html; charset=utf-8", body: .data(Data(html.utf8)))

            default:
                return .text("Not found", status: 404)
            }
        }
    }

    /// Profil vom Typ „Profile Service“. Es wird nicht dauerhaft installiert; iOS liefert nur die
    /// angefragten Geräteattribute an `callbackURL`.
    private nonisolated static func profile(callbackURL: String) throws -> Data {
        let plist: [String: Any] = [
            "PayloadContent": [
                "URL": callbackURL,
                "DeviceAttributes": ["UDID", "PRODUCT", "VERSION", "DEVICE_NAME"],
            ],
            "PayloadOrganization": "Quill",
            "PayloadDisplayName": "Quill – UDID ermitteln",
            "PayloadDescription": "Temporäres Profil: Liest einmalig die UDID dieses iPhones und gibt sie an Quill auf diesem Gerät. Es wird nichts dauerhaft installiert und nichts ins Internet gesendet.",
            "PayloadIdentifier": "app.quill.udid",
            "PayloadUUID": UUID().uuidString,
            "PayloadVersion": 1,
            "PayloadType": "Profile Service",
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
