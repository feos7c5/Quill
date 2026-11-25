import Foundation
import SwiftData
import ZIPFoundation

struct IPAInfo {
    var name: String
    var bundleID: String
    var version: String
    var minimumOS: String
    var iconPNG: Data?
    var size: Int64
}

/// Liest Metadaten aus einer IPA, ohne sie vollständig zu entpacken.
enum IPAInspector {
    static func inspect(_ url: URL) throws -> IPAInfo {
        let archive = try Archive(url: url, accessMode: .read)

        var appRoot: String?
        var plistEntry: Entry?
        for entry in archive {
            let parts = entry.path.split(separator: "/")
            if parts.count == 3, parts[0] == "Payload", parts[1].hasSuffix(".app"), parts[2] == "Info.plist" {
                plistEntry = entry
                appRoot = "Payload/\(parts[1])/"
                break
            }
        }
        guard let plistEntry, let appRoot else {
            throw AppError("Die IPA enthält keine App (Payload/*.app/Info.plist fehlt).")
        }

        var plistData = Data()
        _ = try archive.extract(plistEntry) { plistData.append($0) }
        guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw AppError("Die Info.plist der App ist nicht lesbar.")
        }

        let name = plist["CFBundleDisplayName"] as? String
            ?? plist["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        guard let bundleID = plist["CFBundleIdentifier"] as? String else {
            throw AppError("In der Info.plist fehlt der Bundle Identifier.")
        }

        var info = IPAInfo(
            name: name,
            bundleID: bundleID,
            version: plist["CFBundleShortVersionString"] as? String ?? plist["CFBundleVersion"] as? String ?? "–",
            minimumOS: plist["MinimumOSVersion"] as? String ?? "",
            iconPNG: nil,
            size: Paths.size(of: url)
        )

        // Größte PNG-Datei wählen, deren Name mit einem der Icon-Namen beginnt.
        let iconNames = iconFileNames(in: plist)
        var best: Entry?
        for entry in archive where entry.path.hasPrefix(appRoot) && entry.path.lowercased().hasSuffix(".png") {
            let file = String(entry.path.dropFirst(appRoot.count))
            guard !file.contains("/"), iconNames.contains(where: { file.hasPrefix($0) }) else { continue }
            if best == nil || entry.uncompressedSize > best!.uncompressedSize {
                best = entry
            }
        }
        if let best {
            var icon = Data()
            _ = try? archive.extract(best) { icon.append($0) }
            info.iconPNG = icon.isEmpty ? nil : icon
        }
        return info
    }

    private static func iconFileNames(in plist: [String: Any]) -> [String] {
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            if let icons = plist[key] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
               let files = primary["CFBundleIconFiles"] as? [String] {
                names.append(contentsOf: files)
            }
        }
        if let files = plist["CFBundleIconFiles"] as? [String] {
            names.append(contentsOf: files)
        }
        return names.isEmpty ? ["AppIcon"] : names
    }
}

enum AppLibrary {
    /// Kopiert (oder verschiebt) eine IPA in die Bibliothek und legt den Datensatz an.
    @MainActor
    @discardableResult
    static func importIPA(from source: URL, signed: Bool = false, certificateName: String? = nil,
                          move: Bool = false, context: ModelContext) async throws -> LibraryApp {
        let id = UUID()
        let directory = Paths.library.appendingPathComponent(id.uuidString, isDirectory: true)

        let info = try await Task.detached(priority: .userInitiated) { () -> IPAInfo in
            let fm = FileManager.default
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }

            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("app.ipa")
            do {
                if move {
                    try fm.moveItem(at: source, to: destination)
                } else {
                    try fm.copyItem(at: source, to: destination)
                }
                let info = try IPAInspector.inspect(destination)
                if let icon = info.iconPNG {
                    try? icon.write(to: directory.appendingPathComponent("icon.png"))
                }
                return info
            } catch {
                try? fm.removeItem(at: directory)
                throw error
            }
        }.value

        let app = LibraryApp(
            id: id,
            name: info.name,
            bundleID: info.bundleID,
            version: info.version,
            minimumOS: info.minimumOS,
            size: info.size,
            isSigned: signed,
            certificateName: certificateName
        )
        context.insert(app)
        try context.save()
        return app
    }

    @MainActor
    static func delete(_ app: LibraryApp, context: ModelContext) {
        try? FileManager.default.removeItem(at: app.directory)
        context.delete(app)
        try? context.save()
    }
}
