import Foundation
import UIKit
import ZIPFoundation
import Zsign

/// Eine entpackte, angepasste, aber noch nicht signierte App.
struct PreparedApp {
    /// Arbeitsordner; enthält `Payload/<Name>.app`. Der Aufrufer räumt ihn mit `cleanup()` weg.
    let workDirectory: URL
    let appURL: URL
    let bundleID: String
    let name: String
    let version: String

    var payload: URL { workDirectory.appendingPathComponent("Payload", isDirectory: true) }

    func cleanup() {
        try? FileManager.default.removeItem(at: workDirectory)
    }
}

struct PrepareRequest {
    var ipaURL: URL
    var options: SignOptions
    /// Zusätzliche .dylib-Dateien oder .framework-Ordner, die eingebettet und geladen werden sollen.
    var libraries: [URL] = []
    /// Neues App-Icon als PNG/JPEG-Daten.
    var iconData: Data?
}

/// Entpacken → Anpassen → Signieren → wieder als IPA packen.
///
/// Das Anpassen (`prepare`) ist für beide Signierwege gleich. Signiert wird entweder mit
/// einer eigenen Identität über zsign (`signWithIdentity`) oder über den Apple-Account
/// im Rust-Kern (siehe `SigningPipeline`).
enum SigningService {
    typealias Log = @Sendable (String) -> Void

    static func prepare(_ request: PrepareRequest, log: @escaping Log) async throws -> PreparedApp {
        try await Task.detached(priority: .userInitiated) {
            try runPrepare(request, log: log)
        }.value
    }

    private static func runPrepare(_ request: PrepareRequest, log: Log) throws -> PreparedApp {
        let fm = FileManager.default
        let work = try Paths.workDirectory("sign")
        do {
            log("Entpacke IPA …")
            try fm.unzipItem(at: request.ipaURL, to: work)

            let payload = work.appendingPathComponent("Payload", isDirectory: true)
            let contents = (try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
            guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
                throw AppError("In der IPA wurde keine .app gefunden.")
            }

            let plistURL = appURL.appendingPathComponent("Info.plist")
            guard let plist = NSMutableDictionary(contentsOf: plistURL) else {
                throw AppError("Die Info.plist der App ist nicht lesbar.")
            }
            guard let executableName = plist["CFBundleExecutable"] as? String else {
                throw AppError("In der Info.plist fehlt CFBundleExecutable.")
            }
            let executable = appURL.appendingPathComponent(executableName)
            guard fm.fileExists(atPath: executable.path) else {
                throw AppError("Die ausführbare Datei der App fehlt.")
            }

            let options = request.options
            let originalBundleID = plist["CFBundleIdentifier"] as? String ?? ""
            applyIdentityOptions(options, to: plist, log: log)
            applyPlistOptions(options, to: plist, log: log)
            removeComponents(options, in: appURL, log: log)

            if let iconData = request.iconData {
                log("Ersetze App-Icon …")
                try replaceIcon(iconData, in: appURL, plist: plist)
            }
            guard plist.write(to: plistURL, atomically: true) else {
                throw AppError("Die Info.plist konnte nicht geschrieben werden.")
            }

            let newBundleID = plist["CFBundleIdentifier"] as? String ?? originalBundleID
            if newBundleID != originalBundleID {
                renameNestedBundles(in: appURL, from: originalBundleID, to: newBundleID, log: log)
            }

            try embedLibraries(request.libraries, in: appURL, executable: executable, log: log)

            return PreparedApp(
                workDirectory: work,
                appURL: appURL,
                bundleID: plist["CFBundleIdentifier"] as? String ?? "",
                name: plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String ?? appURL.deletingPathExtension().lastPathComponent,
                version: plist["CFBundleShortVersionString"] as? String ?? plist["CFBundleVersion"] as? String ?? ""
            )
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    /// Signiert eine vorbereitete App mit eigener Identität und packt sie als IPA.
    static func signWithIdentity(_ app: PreparedApp, p12URL: URL, password: String, profileURL: URL,
                                 entitlementsURL: URL?, removeProvision: Bool, log: @escaping Log) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            log("Signiere …")
            let outcome = SignOutcomeBox()
            let result = Zsign.sign(
                appPath: app.appURL.path,
                provisionPath: profileURL.path,
                p12Path: p12URL.path,
                p12Password: password,
                entitlementsPath: entitlementsURL?.path ?? "",
                customIdentifier: "",
                customName: "",
                customVersion: "",
                adhoc: false,
                removeProvision: removeProvision,
                completion: { outcome.set($0) }
            )
            guard result, outcome.value else {
                throw AppError("Das Signieren ist fehlgeschlagen. Zertifikat, Passwort und Provisioning Profile prüfen.")
            }
            return try pack(app.payload, log: log)
        }.value
    }

    /// Packt im Hintergrund, damit große Apps die Oberfläche nicht blockieren.
    static func packInBackground(_ folder: URL, log: @escaping Log) async throws -> URL {
        try await Task.detached(priority: .userInitiated) { try pack(folder, log: log) }.value
    }

    /// Packt einen Payload-Ordner (oder einen .app-Ordner) als IPA in tmp.
    static func pack(_ folder: URL, log: Log) throws -> URL {
        log("Packe IPA …")
        let fm = FileManager.default
        var payload = folder
        var temporaryPayload: URL?
        if folder.pathExtension == "app" {
            let wrapper = try Paths.workDirectory("pack").appendingPathComponent("Payload", isDirectory: true)
            try fm.createDirectory(at: wrapper, withIntermediateDirectories: true)
            try fm.copyItem(at: folder, to: wrapper.appendingPathComponent(folder.lastPathComponent))
            payload = wrapper
            temporaryPayload = wrapper.deletingLastPathComponent()
        }
        defer { if let temporaryPayload { try? fm.removeItem(at: temporaryPayload) } }
        let output = Paths.temporary.appendingPathComponent("signed-\(UUID().uuidString).ipa")
        try fm.zipItem(at: payload, to: output, shouldKeepParent: true, compressionMethod: .deflate)
        log("Fertig.")
        return output
    }

    // MARK: - Schritte

    /// Name, Bundle-ID und Version. Früher erledigte das zsign; jetzt gilt es für beide Signierwege.
    private static func applyIdentityOptions(_ options: SignOptions, to plist: NSMutableDictionary, log: Log) {
        if !options.displayName.trimmed.isEmpty {
            plist["CFBundleDisplayName"] = options.displayName.trimmed
            log("Name → \(options.displayName.trimmed)")
        }
        if !options.version.trimmed.isEmpty {
            plist["CFBundleShortVersionString"] = options.version.trimmed
            log("Version → \(options.version.trimmed)")
        }
        let newID = options.bundleID.trimmed
        if !newID.isEmpty, let oldID = plist["CFBundleIdentifier"] as? String, oldID != newID {
            plist["CFBundleIdentifier"] = newID
            log("Bundle-ID → \(newID)")
        }
    }

    private static func applyPlistOptions(_ options: SignOptions, to plist: NSMutableDictionary, log: Log) {
        if !options.minimumOSVersion.trimmed.isEmpty {
            plist["MinimumOSVersion"] = options.minimumOSVersion.trimmed
            log("MinimumOSVersion → \(options.minimumOSVersion.trimmed)")
        }
        if options.removeSupportedDevices, plist["UISupportedDevices"] != nil {
            plist.removeObject(forKey: "UISupportedDevices")
            log("UISupportedDevices entfernt")
        }
        if options.removeURLSchemes, plist["CFBundleURLTypes"] != nil {
            plist.removeObject(forKey: "CFBundleURLTypes")
            log("URL-Schemata entfernt")
        }
        if options.enableFileSharing {
            plist["UIFileSharingEnabled"] = true
            plist["LSSupportsOpeningDocumentsInPlace"] = true
            log("Dateifreigabe aktiviert")
        }
    }

    /// Erweiterungen und Watch-Apps tragen die Bundle-ID der Haupt-App als Präfix; sie ziehen mit.
    private static func renameNestedBundles(in appURL: URL, from oldID: String, to newID: String, log: Log) {
        guard !oldID.isEmpty else { return }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: appURL, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator where url.lastPathComponent == "Info.plist" && url.deletingLastPathComponent() != appURL {
            let bundle = url.deletingLastPathComponent()
            guard ["appex", "app"].contains(bundle.pathExtension), let plist = NSMutableDictionary(contentsOf: url) else { continue }
            var changed = false
            for key in ["CFBundleIdentifier", "WKCompanionAppBundleIdentifier"] {
                if let value = plist[key] as? String, value.hasPrefix(oldID) {
                    plist[key] = newID + value.dropFirst(oldID.count)
                    changed = true
                }
            }
            // Verschachtelte Werte als Kopie ändern; ob eingelesene Unterwörterbücher veränderbar sind, ist nicht garantiert.
            if var ext = plist["NSExtension"] as? [String: Any],
               var attributes = ext["NSExtensionAttributes"] as? [String: Any],
               let companion = attributes["WKAppBundleIdentifier"] as? String, companion.hasPrefix(oldID) {
                attributes["WKAppBundleIdentifier"] = newID + companion.dropFirst(oldID.count)
                ext["NSExtensionAttributes"] = attributes
                plist["NSExtension"] = ext
                changed = true
            }
            if changed, plist.write(to: url, atomically: true) {
                log("Bundle-ID angepasst: \(bundle.lastPathComponent)")
            }
        }
    }

    private static func removeComponents(_ options: SignOptions, in appURL: URL, log: Log) {
        let fm = FileManager.default
        var folders: [String] = []
        if options.removePlugIns { folders += ["PlugIns", "Extensions"] }
        if options.removeWatchApp { folders += ["Watch", "com.apple.WatchPlaceholder"] }
        for folder in folders {
            let url = appURL.appendingPathComponent(folder)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
                log("\(folder) entfernt")
            }
        }
    }

    /// Schreibt lose Icon-Dateien und stellt die Info.plist von Asset-Katalog auf diese Dateien um.
    private static func replaceIcon(_ data: Data, in appURL: URL, plist: NSMutableDictionary) throws {
        guard let image = UIImage(data: data) else {
            throw AppError("Das gewählte Icon ist kein gültiges Bild.")
        }
        let files: [(name: String, pixels: CGFloat)] = [
            ("QuillIcon60x60@2x.png", 120),
            ("QuillIcon60x60@3x.png", 180),
            ("QuillIcon76x76@2x~ipad.png", 152),
            ("QuillIcon83.5x83.5@2x~ipad.png", 167)
        ]
        for file in files {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let size = CGSize(width: file.pixels, height: file.pixels)
            let png = UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            try png.write(to: appURL.appendingPathComponent(file.name))
        }
        let phone: [String: Any] = [
            "CFBundlePrimaryIcon": ["CFBundleIconFiles": ["QuillIcon60x60"]]
        ]
        let pad: [String: Any] = [
            "CFBundlePrimaryIcon": ["CFBundleIconFiles": ["QuillIcon60x60", "QuillIcon76x76", "QuillIcon83.5x83.5"]]
        ]
        plist["CFBundleIcons"] = phone
        plist["CFBundleIcons~ipad"] = pad
        plist.removeObject(forKey: "CFBundleIconFiles")
    }

    private static func embedLibraries(_ libraries: [URL], in appURL: URL, executable: URL, log: Log) throws {
        guard !libraries.isEmpty else { return }
        let fm = FileManager.default
        let frameworks = appURL.appendingPathComponent("Frameworks", isDirectory: true)
        try fm.createDirectory(at: frameworks, withIntermediateDirectories: true)

        for library in libraries {
            let scoped = library.startAccessingSecurityScopedResource()
            defer { if scoped { library.stopAccessingSecurityScopedResource() } }

            let name = library.lastPathComponent
            let destination = frameworks.appendingPathComponent(name)
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: library, to: destination)

            let loadPath: String
            if library.pathExtension == "framework" {
                let binary = library.deletingPathExtension().lastPathComponent
                loadPath = "@executable_path/Frameworks/\(name)/\(binary)"
            } else {
                loadPath = "@executable_path/Frameworks/\(name)"
            }
            guard Zsign.injectDyLib(appExecutable: executable.path, with: loadPath, weak: true) else {
                throw AppError("„\(name)“ konnte nicht in die App eingebunden werden.")
            }
            log("Eingebunden: \(name)")
        }
    }

    /// Listet die Ladebefehle (verknüpfte Bibliotheken) der App in einer IPA auf.
    static func linkedLibraries(inIPA ipaURL: URL) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let work = Paths.temporary.appendingPathComponent("inspect-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            try fm.unzipItem(at: ipaURL, to: work)
            let payload = work.appendingPathComponent("Payload")
            let contents = (try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
            guard let appURL = contents.first(where: { $0.pathExtension == "app" }),
                  let plist = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")),
                  let executable = plist["CFBundleExecutable"] as? String else {
                throw AppError("In der IPA wurde keine App gefunden.")
            }
            return Zsign.listDylibs(appExecutable: appURL.appendingPathComponent(executable).path)
        }.value
    }
}

/// Ergebnis des zsign-Rückrufs; threadsicher, weil zsign ihn auf beliebigem Thread aufrufen kann.
private final class SignOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
