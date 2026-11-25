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
    @ObservationIgnored var onReceived: ((String) -> Void)?

    private static let port: UInt16 = 8765
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
        // Kurz weiterlaufen lassen, damit die Weiterleitung noch ausgeliefert wird.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.stop()
        }
    }

    // MARK: - Server

    /// Läuft auf der Server-Queue, deshalb nicht an den Main-Actor gebunden.
    private nonisolated static func makeHandler(token: String, profile: Data,
                                                result: @escaping @Sendable (Result<String, Error>) -> Void) -> HTTPServer.Handler {
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
                var response = HTTPResponse(status: 301)
                response.headers["Location"] = "quill://udid?value=\(udid)"
                return response

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
