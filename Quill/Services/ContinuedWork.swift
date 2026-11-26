import BackgroundTasks
import Foundation
import UIKit

/// Hält Quill im Hintergrund am Laufen, während der Nutzer in den Einstellungen etwas bestätigt
/// (Kopplungscode, UDID-Profil), und zeigt dabei eine Systemanzeige über allen Apps.
///
/// Technik: `BGContinuedProcessingTask` (ab iOS 26). Die Systemanzeige trägt Titel und Untertitel,
/// so steht der Kopplungscode direkt über den Einstellungen. Lehnt iOS die Aufgabe ab (etwa weil
/// eine Signier-App die Bundle-ID geändert hat), bleibt die kurze Hintergrundzeit plus KeepAlive.
/// Vorbild: Husk (`JITPairing.swift`), das denselben Weg für die Kopplung ab iOS 27 nutzt.
@MainActor
final class ContinuedWork {
    static let shared = ContinuedWork()

    private var task: BGContinuedProcessingTask?
    private var registered: Set<String> = []
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private var current: (title: String, subtitle: String)?
    private var onExpire: (() -> Void)?
    private var log: ((String) -> Void)?

    /// Läuft die Systemanzeige? Sonst bleibt nur die begrenzte Hintergrundzeit.
    private(set) var isSystemTask = false

    /// Muss im Vordergrund aufgerufen werden.
    func begin(kind: String, title: String, subtitle: String,
               log: @escaping (String) -> Void, onExpire: @escaping () -> Void) {
        end(success: false)
        self.current = (title, subtitle)
        self.onExpire = onExpire
        self.log = log
        grace = UIApplication.shared.beginBackgroundTask(withName: "Quill-\(kind)") { [weak self] in
            MainActor.assumeIsolated { self?.endGrace() }
        }
        guard let identifier = identifier(kind) else {
            log("Background task: no permitted identifier in Info.plist")
            return
        }
        if !registered.contains(identifier) {
            let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                MainActor.assumeIsolated { ContinuedWork.shared.attach(task) }
            }
            guard ok else {
                log("Background task: registration refused (\(identifier)); the installed bundle ID differs, so the system banner is unavailable")
                return
            }
            registered.insert(identifier)
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        BGTaskScheduler.shared.submitTaskRequest(request) { error in
            let line = error.map { "Background task refused: \($0)" }
                ?? "Background task requested (\(identifier))"
            DispatchQueue.main.async { log(line) }
        }
    }

    func update(title: String, subtitle: String, step: Int64 = 1) {
        current = (title, subtitle)
        guard let task else { return }
        task.updateTitle(title, subtitle: subtitle)
        task.progress.completedUnitCount = min(step, task.progress.totalUnitCount - 1)
    }

    func end(success: Bool) {
        if let task {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        }
        task = nil
        isSystemTask = false
        onExpire = nil
        current = nil
        endGrace()
    }

    private func attach(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask, let current else {
            task.setTaskCompleted(success: false)
            return
        }
        self.task = task
        isSystemTask = true
        task.progress.totalUnitCount = 3
        task.updateTitle(current.title, subtitle: current.subtitle)
        task.expirationHandler = {
            DispatchQueue.main.async {
                let shared = ContinuedWork.shared
                shared.log?("Background task ended by iOS")
                let expire = shared.onExpire
                shared.task = nil
                shared.isSystemTask = false
                expire?()
            }
        }
        log?("Background task running, system banner shown")
    }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

    /// Kennung aus dem erlaubten Muster „<Bundle-ID>.continued.*“ der Info.plist. Das Muster wird beim
    /// Bauen mit der echten Bundle-ID gefüllt; passt es nicht mehr zur laufenden App, lehnt iOS ab.
    private func identifier(_ kind: String) -> String? {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard let wildcard = permitted.first(where: { $0.hasSuffix(".continued.*") }) else { return nil }
        return String(wildcard.dropLast()) + kind
    }
}
