import SwiftData
import UIKit
import WidgetKit

/// Schreibt den Stand für Widget und Steuerzentrale und lässt sie neu zeichnen.
@MainActor
enum WidgetPublisher {
    /// Kantenlänge der Icons im App-Group-Container. Widgets haben wenig Speicher; klein halten.
    private static let iconSize: CGFloat = 96

    static func publish() {
        guard let directory = WidgetSnapshot.directory else { return }
        let services = AppServices.shared
        let apps = (try? services.context.fetch(FetchDescriptor<InstalledApp>(sortBy: [SortDescriptor(\.expirationDate)]))) ?? []
        let identities = (try? services.context.fetch(FetchDescriptor<SigningIdentity>())) ?? []

        let snapshot = WidgetSnapshot(
            apps: apps.map { .init(name: $0.name, bundleID: $0.bundleID, expiration: $0.expirationDate) },
            updatedAt: .now,
            deviceReady: services.device.isReady,
            signerReady: services.account.isReady || identities.contains { !$0.isExpired },
            lastError: services.refresher.lastError
        )
        // Nur schreiben und neu zeichnen, wenn sich inhaltlich etwas geändert hat.
        if let old = WidgetSnapshot.load(), old.apps == snapshot.apps, old.deviceReady == snapshot.deviceReady,
           old.signerReady == snapshot.signerReady, old.lastError == snapshot.lastError {
            return
        }

        let icons = directory.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        for app in apps {
            guard let target = WidgetSnapshot.iconURL(for: app.bundleID),
                  let source = app.iconURL, let image = UIImage(contentsOfFile: source.path) else { continue }
            let size = CGSize(width: iconSize, height: iconSize)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let png = UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            try? png.write(to: target, options: .atomic)
        }

        try? snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }
}
