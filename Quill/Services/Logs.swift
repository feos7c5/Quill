import CoreTransferable
import Foundation
import UIKit

/// Schreibt Diagnosezeilen mit Zeitstempel in eine Datei, damit sich Fehler auf dem Gerät nachvollziehen lassen.
final class FileLog: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()

    init(_ name: String) { url = Paths.core.appendingPathComponent(name) }

    /// Ortszeit des iPhones mit Zeitzone, z. B. „06:46:19.892 +01:00“.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss.SSS xxx"
        return formatter
    }()

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = Self.formatter.string(from: .now)
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            let size = handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
            // Nicht endlos wachsen lassen: ab 512 KB nur die zweite Hälfte behalten.
            if size > 512 * 1024, let all = try? Data(contentsOf: url) {
                try? all.suffix(256 * 1024).write(to: url)
            }
        } else {
            try? data.write(to: url)
        }
    }
}

/// Allgemeines Protokoll der App (Anmeldedaten-Sicherung u. Ä.), ohne Passwörter und Schlüssel.
enum AppLog {
    private static let log = FileLog("app.log")
    static var url: URL { log.url }
    static func write(_ line: String) { log.write(line) }
}

/// Protokoll der Kopplung (ohne Code und Schlüssel).
enum PairingLog {
    private static let log = FileLog("pairing.log")
    static var url: URL { log.url }
    static func reset() { log.reset() }
    static func write(_ line: String) { log.write(line) }
}

/// Alle Protokolle in einer Datei zum Teilen (App, Kopplung, Kern).
struct LogBundle: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { _ in
            SentTransferredFile(try LogBundle.write())
        }
    }

    static func write() throws -> URL {
        let info = Bundle.main.infoDictionary ?? [:]
        var text = "Quill \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        text += " · bundle \(Bundle.main.bundleIdentifier ?? "?") · iOS \(UIDevice.current.systemVersion)\n"
        let parts: [(String, URL)] = [
            ("App", AppLog.url),
            ("Pairing", PairingLog.url),
            ("Core", Paths.core.appendingPathComponent("core.log")),
            ("Core (previous session)", Paths.core.appendingPathComponent("core.previous.log")),
        ]
        for (title, url) in parts {
            let body = (try? String(contentsOf: url, encoding: .utf8)) ?? "(empty)\n"
            text += "\n===== \(title) =====\n" + String(body.suffix(200_000))
        }
        let url = Paths.temporary.appendingPathComponent("Quill-logs.txt")
        try Data(text.utf8).write(to: url)
        return url
    }
}
