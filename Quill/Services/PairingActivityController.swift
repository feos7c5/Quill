import ActivityKit
import Foundation

/// Startet und aktualisiert die Live-Aktivität mit dem Kopplungscode (Dynamic Island, Sperrbildschirm).
@MainActor
enum PairingActivityController {
    private static var activity: Activity<PairingActivityAttributes>?

    static func start() {
        for old in Activity<PairingActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            PairingLog.write("Live-Aktivität: in den Einstellungen für Quill ausgeschaltet")
            return
        }
        do {
            activity = try Activity.request(
                attributes: PairingActivityAttributes(),
                content: ActivityContent(state: .init(stage: .waiting, code: nil), staleDate: nil)
            )
            PairingLog.write("Live-Aktivität gestartet")
        } catch {
            PairingLog.write("Live-Aktivität nicht möglich: \(error.localizedDescription)")
        }
    }

    static func update(_ stage: PairingActivityAttributes.ContentState.Stage, code: String? = nil) {
        guard let activity else { return }
        let content = ActivityContent(state: PairingActivityAttributes.ContentState(stage: stage, code: code), staleDate: nil)
        Task { await activity.update(content) }
    }

    static func end(_ stage: PairingActivityAttributes.ContentState.Stage) {
        guard let activity else { return }
        self.activity = nil
        let content = ActivityContent(state: PairingActivityAttributes.ContentState(stage: stage, code: nil), staleDate: nil)
        let policy: ActivityUIDismissalPolicy = stage == .paired ? .after(.now.addingTimeInterval(8)) : .immediate
        Task { await activity.end(content, dismissalPolicy: policy) }
    }
}
